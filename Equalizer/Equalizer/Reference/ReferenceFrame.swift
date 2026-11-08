import Foundation

/// Un bloc de niveaux de bandes décrivant ce que l'appareil source envoie aux enceintes.
///
/// Les images voyagent de la source (Mac) vers l'appareil de mesure (iPhone) sous forme de
/// JSON délimité par des sauts de ligne, sur une connexion TCP découverte avec Bonjour.
nonisolated struct ReferenceFrame: Codable, Sendable {
    /// Niveaux de bandes en dB, espacés de façon logarithmique entre `minFrequency` et `maxFrequency`.
    var bands: [Float]
    var minFrequency: Double
    var maxFrequency: Double

    /// Reporte les bandes sur une autre répartition logarithmique des fréquences, par
    /// interpolation linéaire, pour que la source et l'appareil de mesure n'aient pas besoin
    /// de réglages identiques.
    /// - Returns: `bandCount` niveaux ; `-∞` partout si la source a moins de deux bandes.
    func resampled(bandCount: Int, minFrequency targetMin: Double, maxFrequency targetMax: Double) -> [Float] {
        guard bands.count > 1, bandCount > 0 else { return [Float](repeating: -.infinity, count: max(bandCount, 0)) }

        // Les logarithmes exigent des fréquences strictement positives et des bornes distinctes.
        let sourceLogMin = log10(max(minFrequency, 1))
        let sourceLogMax = log10(max(maxFrequency, minFrequency + 1))
        let targetLogMin = log10(max(targetMin, 1))
        let targetLogMax = log10(max(targetMax, targetMin + 1))

        return (0..<bandCount).map { index in
            // Centre de la bande cible, converti en position relative dans la plage de la source.
            let fraction = (Double(index) + 0.5) / Double(bandCount)
            let logFrequency = targetLogMin + (targetLogMax - targetLogMin) * fraction
            let sourceFraction = (logFrequency - sourceLogMin) / (sourceLogMax - sourceLogMin)
            // La bande i de la source est centrée sur (i + 0,5) / count. Le résultat est borné
            // pour ne pas extrapoler hors de la plage de la source.
            let position = min(max(sourceFraction * Double(bands.count) - 0.5, 0), Double(bands.count - 1))
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, bands.count - 1)
            let weight = Float(position - Double(lower))
            return bands[lower] * (1 - weight) + bands[upper] * weight
        }
    }
}

nonisolated enum ReferenceProtocol {
    /// Type de service Bonjour annoncé par la source et recherché par l'appareil de mesure.
    static let serviceType = "_equalizerref._tcp"
}
