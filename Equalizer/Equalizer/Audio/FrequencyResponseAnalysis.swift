import Foundation

/// Verdict pour une zone de fréquences, selon son écart par rapport à la courbe cible.
enum ResponseVerdict {
    case lacking
    case balanced
    case excess

    var label: String {
        switch self {
        case .lacking: return String(localized: "Manque")
        case .balanced: return String(localized: "Équilibré")
        case .excess: return String(localized: "Excès")
        }
    }
}

/// Écart (en dB) d'une bande d'analyse par rapport à la courbe cible.
struct BandDeviation: Identifiable {
    let id: Int
    let centerFrequency: Double
    let deviation: Float
}

/// Écart moyen d'une plage de fréquences nommée (sub-graves, graves, médiums…).
struct ZoneDeviation: Identifiable {
    let name: String
    let range: Range<Double>
    let deviation: Float
    let verdict: ResponseVerdict

    var id: String { name }
}

/// Résultat complet de l'analyse, prêt à être affiché par `ResponseAnalysisView`.
struct FrequencyResponseReport {
    let bands: [BandDeviation]
    let zones: [ZoneDeviation]
    /// Niveau attendu (dB) par bande : ce que la source envoie, ou le spectre typique de la musique.
    let expected: [Float]
    /// Niveau (dB) par bande entendu par le microphone, décalé pour coïncider avec `expected`
    /// sur les médiums. L'écart entre les deux courbes est la déviation.
    let restituted: [Float]
}

/// Compare le spectre moyen à long terme de la musique captée par le microphone avec un
/// spectre de musique typique (une droite de `targetSlope` dB par octave).
///
/// Les niveaux absolus sont inconnus (volume, gain du micro) : la cible est donc alignée sur
/// le niveau moyen des médiums. Les écarts sont relatifs aux médiums : une zone à -6 dB
/// signifie « 6 dB plus faible qu'elle ne devrait l'être par rapport aux médiums ».
enum FrequencyResponseAnalysis {
    /// Pente typique du spectre moyen de la musique, en dB par octave.
    static let targetSlope: Float = -3
    /// Les écarts compris dans ± cette valeur sont jugés équilibrés, en dB.
    static let tolerance: Float = 3

    /// Les images dont la bande la plus forte est sous ce niveau (dB) sont du silence : elles sont
    /// exclues des moyennes, sinon les pauses les tireraient vers le bas. Le micro d'un iPhone dans
    /// une pièce calme lit entre −130 et −165 dB : le seuil se place juste au-dessus de ce plancher.
    /// Placé à −80 dB, il écartait aussi les sons faibles mais bien audibles.
    static let silenceThreshold: Float = -135

    /// Plage servant à aligner la cible sur la mesure. Les médiums sont choisis car ils
    /// sont peu affectés par la pièce et par la réponse du microphone.
    private static let referenceRange = 250.0..<2_000.0

    /// Zones de fréquences évaluées, en hertz. La dernière est ouverte vers l'infini.
    private static let zoneDefinitions: [(name: String, range: Range<Double>)] = [
        (String(localized: "Sub-graves"), 0..<60),
        (String(localized: "Graves"), 60..<250),
        (String(localized: "Bas-médiums"), 250..<500),
        (String(localized: "Médiums"), 500..<2_000),
        (String(localized: "Haut-médiums"), 2_000..<4_000),
        (String(localized: "Présence"), 4_000..<6_000),
        (String(localized: "Aigus"), 6_000..<Double.infinity)
    ]

    /// Calcule l'écart de chaque bande et de chaque zone par rapport à la cible.
    /// - Parameters:
    ///   - averageLevels: niveaux moyens (dB) captés par le microphone, une valeur par bande.
    ///   - referenceLevels: niveaux moyens de ce que la source envoie aux enceintes
    ///     (même répartition en bandes que `averageLevels`). Si `nil` ou de taille différente,
    ///     le spectre typique de la musique (`targetSlope`) sert de cible.
    ///   - settings: réglages dont on tire la plage de fréquences et donc le centre de chaque bande.
    /// - Returns: le rapport, ou `nil` s'il y a trop peu de bandes pour comparer.
    static func report(
        averageLevels: [Float],
        referenceLevels: [Float]? = nil,
        settings: SpectrumSettings
    ) -> FrequencyResponseReport? {
        let count = averageLevels.count
        guard count > 1 else { return nil }
        let reference = referenceLevels.flatMap { $0.count == count ? $0 : nil }

        let minFreq = max(settings.minFrequency, 1)
        let maxFreq = max(settings.maxFrequency, minFreq + 1)
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)

        // Écart brut = niveau mesuré - cible. Sans référence, la cible est la pente typique
        // exprimée par rapport à 1 kHz.
        var centers: [Double] = []
        var targets: [Float] = []
        var raw: [Float] = []
        for i in 0..<count {
            // Centre de la bande sur l'échelle logarithmique (d'où le + 0,5).
            let fraction = (Double(i) + 0.5) / Double(count)
            let center = pow(10, logMin + (logMax - logMin) * fraction)
            let octavesFromReference = Float(log2(center / 1_000))
            centers.append(center)
            let target = reference?[i] ?? targetSlope * octavesFromReference
            targets.append(target)
            raw.append(averageLevels[i] - target)
        }

        // Décalage d'alignement : écart moyen sur les médiums. À défaut de bande dans cette
        // plage (plage analysée réduite), on se rabat sur toutes les bandes.
        let referenceValues = zip(centers, raw)
            .filter { referenceRange.contains($0.0) }
            .map(\.1)
        let offsetSource = referenceValues.isEmpty ? raw : referenceValues
        let offset = offsetSource.reduce(0, +) / Float(offsetSource.count)

        let bands = raw.indices.map {
            BandDeviation(id: $0, centerFrequency: centers[$0], deviation: raw[$0] - offset)
        }

        // Moyenne des écarts par zone ; les zones sans aucune bande sont ignorées.
        let zones: [ZoneDeviation] = zoneDefinitions.compactMap { definition in
            let members = bands.filter { definition.range.contains($0.centerFrequency) }
            guard !members.isEmpty else { return nil }
            let mean = members.map(\.deviation).reduce(0, +) / Float(members.count)
            let verdict: ResponseVerdict = mean < -tolerance ? .lacking : (mean > tolerance ? .excess : .balanced)
            return ZoneDeviation(name: definition.name, range: definition.range, deviation: mean, verdict: verdict)
        }

        // Courbe « restituée » : la cible à laquelle on ajoute l'écart aligné.
        let restituted = zip(targets, bands).map { $0 + $1.deviation }
        return FrequencyResponseReport(bands: bands, zones: zones, expected: targets, restituted: restituted)
    }
}
