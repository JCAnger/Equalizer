import SwiftUI

// MARK: - Libellés

extension GeneratedSignal {
    /// Nom affiché dans le menu du morceau une fois le signal choisi.
    var title: String {
        switch self {
        case .noise(.pink):
            return "Bruit rose"
        case .noise(.white):
            return "Bruit blanc"
        case let .sweep(start, end, duration):
            return "Balayage \(FrequencyFormat.label(start))–\(FrequencyFormat.label(end)) · \(Int(duration)) s"
        case let .bandNoise(low, high):
            return "Bruit rose \(FrequencyFormat.label(low))–\(FrequencyFormat.label(high))"
        }
    }
}

/// Mise en forme compacte des fréquences : « 60 Hz », « 2 kHz », « 2,5 kHz ».
enum FrequencyFormat {
    static func label(_ frequency: Double) -> String {
        guard frequency >= 1_000 else { return "\(Int(frequency.rounded())) Hz" }
        let kilohertz = (frequency / 1_000).formatted(.number.precision(.fractionLength(0...1)))
        return "\(kilohertz) kHz"
    }
}

// MARK: - Feuille du générateur

/// Réglages d'un signal de test sur mesure : balayage ou bruit rose limité à une bande.
struct TestSignalView: View {
    private enum Kind: String, CaseIterable, Identifiable {
        case sweep
        case bandNoise

        var id: Self { self }

        var label: String {
            switch self {
            case .sweep: return "Balayage"
            case .bandNoise: return "Bruit par bande"
            }
        }
    }

    /// Zones prédéfinies, alignées sur celles de l'analyse des enceintes.
    private static let presets: [(name: String, low: Double, high: Double)] = [
        ("Graves", 60, 250),
        ("Médiums", 250, 2_000),
        ("Aigus", 2_000, 20_000)
    ]

    /// Appelé avec le signal choisi quand l'utilisateur valide.
    let onSelect: (GeneratedSignal) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .sweep
    @State private var sweepStart: Double = 20
    @State private var sweepEnd: Double = 20_000
    @State private var sweepDuration: Double = 10
    @State private var bandLow: Double = 60
    @State private var bandHigh: Double = 250

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ExpectedSpectrumSketch(signal: selectedSignal)
                        .frame(height: 112)
                        .listRowInsets(EdgeInsets())
                }

                Section {
                    Picker("Signal", selection: $kind) {
                        ForEach(Kind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch kind {
                case .sweep:
                    sweepSection
                case .bandNoise:
                    bandNoiseSection
                }
            }
            .navigationTitle("Générateur")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Utiliser") {
                        onSelect(selectedSignal)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private var sweepSection: some View {
        Section {
            LogFrequencySlider(title: "Départ", value: $sweepStart)
            LogFrequencySlider(title: "Arrivée", value: $sweepEnd)
            Stepper("Durée : \(Int(sweepDuration)) s", value: $sweepDuration, in: 2...60, step: 1)
        } footer: {
            Text("La fréquence monte en continu du départ à l'arrivée, puis le balayage recommence. Chaque octave dure le même temps.")
        }
    }

    private var bandNoiseSection: some View {
        Section {
            HStack {
                ForEach(Self.presets, id: \.name) { preset in
                    Button(preset.name) {
                        bandLow = preset.low
                        bandHigh = preset.high
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
            LogFrequencySlider(title: "Bas", value: $bandLow)
            LogFrequencySlider(title: "Haut", value: $bandHigh)
        } footer: {
            Text(isValid
                 ? "Bruit rose limité à cette plage, pour tester une seule zone de fréquences."
                 : "La fréquence haute doit être supérieure à la fréquence basse.")
        }
    }

    /// Un balayage peut descendre (départ > arrivée), mais une bande doit être orientée
    /// et les deux bornes doivent rester distinctes.
    private var isValid: Bool {
        switch kind {
        case .sweep: return sweepStart != sweepEnd
        case .bandNoise: return bandHigh > bandLow
        }
    }

    private var selectedSignal: GeneratedSignal {
        switch kind {
        case .sweep:
            return .sweep(startFrequency: sweepStart, endFrequency: sweepEnd, duration: sweepDuration)
        case .bandNoise:
            return .bandNoise(lowFrequency: bandLow, highFrequency: bandHigh)
        }
    }
}

// MARK: - Schéma du spectre attendu

/// Schéma symbolique du spectre que doit produire un signal de test, sur la même échelle
/// logarithmique que l'analyse. Il ne s'agit pas d'une mesure : il montre seulement quelle
/// zone de fréquences le signal doit remplir, pour savoir quoi chercher sur l'autre appareil.
struct ExpectedSpectrumSketch: View {
    let signal: GeneratedSignal

    @Environment(\.colorScheme) private var colorScheme

    private static let frequencyRange = 20.0...20_000.0
    /// Profondeur représentée sous le plateau : assez pour voir les flancs des filtres.
    private static let displayRange = 48.0
    /// Pente des flancs du bruit par bande : deux filtres du 2e ordre en cascade.
    private static let bandSlope = 24.0
    private static let axisLabels: [Double] = [100, 1_000, 10_000]
    /// Nombre de points calculés en largeur : assez pour une courbe lisse, peu coûteux.
    private static let resolution = 120

    var body: some View {
        Canvas { context, size in
            let axisHeight: CGFloat = 16
            // Marges : le plateau ne doit pas coller au bord haut, ni un balayage pleine
            // largeur se confondre avec les bords de la ligne de formulaire.
            let plotRect = CGRect(x: 16, y: 24, width: size.width - 32, height: size.height - axisHeight - 32)
            drawGuides(context: context, plotRect: plotRect, size: size)
            drawShape(context: context, plotRect: plotRect)
            if case let .sweep(start, end, _) = signal {
                drawDirectionArrow(context: context, plotRect: plotRect, from: start, to: end)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Spectre attendu")
        .accessibilityValue(accessibilityDescription)
    }

    // MARK: Forme

    /// Niveau attendu (dB, 0 = plateau) à une fréquence donnée, ou `nil` hors du signal.
    private func expectedLevel(at frequency: Double) -> Double? {
        switch signal {
        case .noise(.pink):
            return 0
        case .noise(.white):
            // Énergie égale par hertz : vu par octave, le niveau monte de 3 dB par octave.
            return 3 * log2(frequency / Self.frequencyRange.upperBound)
        case let .sweep(start, end, _):
            // Un balayage logarithmique passe le même temps dans chaque octave : plateau net,
            // rien en dehors de sa plage.
            return (min(start, end)...max(start, end)).contains(frequency) ? 0 : nil
        case let .bandNoise(low, high):
            guard high > low else { return nil }
            if frequency < low { return -Self.bandSlope * log2(low / frequency) }
            if frequency > high { return -Self.bandSlope * log2(frequency / high) }
            return 0
        }
    }

    private func drawShape(context: GraphicsContext, plotRect: CGRect) {
        // Points de la courbe ; les zones hors du signal sont ramenées au bas du schéma.
        let points: [CGPoint] = (0...Self.resolution).map { index in
            let fraction = Double(index) / Double(Self.resolution)
            let level = expectedLevel(at: frequency(atFraction: fraction)).map {
                max($0, -Self.displayRange)
            } ?? -Self.displayRange
            return CGPoint(
                x: plotRect.minX + CGFloat(fraction) * plotRect.width,
                y: plotRect.minY + CGFloat(-level / Self.displayRange) * plotRect.height
            )
        }
        var line = Path()
        line.addLines(points)
        // Un seul trait, sans remplissage : volontairement minimaliste, c'est un schéma.
        context.stroke(
            line,
            // Le bleu d'accent profond disparaît sur fond sombre : on prend sa version claire.
            with: .color(colorScheme == .dark ? AppTheme.sky : AppTheme.accent),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
    }

    /// Flèche fine au-dessus du plateau, dans le sens du balayage (il peut aussi descendre).
    private func drawDirectionArrow(context: GraphicsContext, plotRect: CGRect, from start: Double, to end: Double) {
        let startX = xPosition(for: start, in: plotRect)
        let endX = xPosition(for: end, in: plotRect)
        guard abs(endX - startX) > 24 else { return }
        let y = plotRect.minY - 12
        let direction: CGFloat = endX > startX ? 1 : -1
        let headLength: CGFloat = 6

        var arrow = Path()
        arrow.move(to: CGPoint(x: startX + direction * 8, y: y))
        arrow.addLine(to: CGPoint(x: endX - direction * 8, y: y))
        arrow.move(to: CGPoint(x: endX - direction * (8 + headLength), y: y - headLength / 1.5))
        arrow.addLine(to: CGPoint(x: endX - direction * 8, y: y))
        arrow.addLine(to: CGPoint(x: endX - direction * (8 + headLength), y: y + headLength / 1.5))
        context.stroke(arrow, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
    }

    // MARK: Axe

    private func drawGuides(context: GraphicsContext, plotRect: CGRect, size: CGSize) {
        for frequency in Self.axisLabels {
            let x = xPosition(for: frequency, in: plotRect)
            var guide = Path()
            guide.move(to: CGPoint(x: x, y: plotRect.minY))
            guide.addLine(to: CGPoint(x: x, y: plotRect.maxY))
            context.stroke(guide, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
            context.draw(
                Text(FrequencyFormat.label(frequency)).font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: x, y: size.height - 8)
            )
        }
    }

    private func frequency(atFraction fraction: Double) -> Double {
        let logLow = log10(Self.frequencyRange.lowerBound)
        let logHigh = log10(Self.frequencyRange.upperBound)
        let frequency = pow(10, logLow + fraction * (logHigh - logLow))
        // L'arrondi de `pow` peut dépasser légèrement 20 kHz au dernier point, qui sortirait
        // alors d'un balayage s'arrêtant à 20 kHz.
        return min(max(frequency, Self.frequencyRange.lowerBound), Self.frequencyRange.upperBound)
    }

    private func xPosition(for frequency: Double, in plotRect: CGRect) -> CGFloat {
        let logLow = log10(Self.frequencyRange.lowerBound)
        let logHigh = log10(Self.frequencyRange.upperBound)
        let clamped = min(max(frequency, Self.frequencyRange.lowerBound), Self.frequencyRange.upperBound)
        return plotRect.minX + CGFloat((log10(clamped) - logLow) / (logHigh - logLow)) * plotRect.width
    }

    private var accessibilityDescription: String {
        switch signal {
        case .noise:
            return "Énergie sur toute la plage audible"
        case let .sweep(start, end, _):
            return "Énergie de \(FrequencyFormat.label(start)) à \(FrequencyFormat.label(end))"
        case let .bandNoise(low, high):
            return high > low
                ? "Énergie entre \(FrequencyFormat.label(low)) et \(FrequencyFormat.label(high)), atténuée en dehors"
                : "Plage invalide"
        }
    }
}

// MARK: - Curseur de fréquence

/// Curseur de fréquence de 20 Hz à 20 kHz sur une échelle logarithmique : une échelle
/// linéaire écraserait les graves sur quelques pixels.
struct LogFrequencySlider: View {
    private static let range = 20.0...20_000.0

    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent("\(title) : \(FrequencyFormat.label(value))") {
            Slider(value: logBinding, in: 0...1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(FrequencyFormat.label(value))
    }

    private var logBinding: Binding<Double> {
        let logLow = log10(Self.range.lowerBound)
        let logHigh = log10(Self.range.upperBound)
        return Binding(
            get: {
                let clamped = min(max(value, Self.range.lowerBound), Self.range.upperBound)
                return (log10(clamped) - logLow) / (logHigh - logLow)
            },
            set: { fraction in
                // Arrondi à 3 chiffres significatifs : des valeurs comme 1 237 Hz n'apportent
                // rien et encombrent le libellé.
                let raw = pow(10, logLow + fraction * (logHigh - logLow))
                let magnitude = pow(10, floor(log10(raw)) - 2)
                value = (raw / magnitude).rounded() * magnitude
            }
        )
    }
}

#Preview("Clair") {
    TestSignalView { _ in }
}

#Preview("Sombre") {
    TestSignalView { _ in }
        .preferredColorScheme(.dark)
}

#Preview("Schémas") {
    List {
        ExpectedSpectrumSketch(signal: .bandNoise(lowFrequency: 60, highFrequency: 250))
            .frame(height: 112)
            .listRowInsets(EdgeInsets())
        ExpectedSpectrumSketch(signal: .sweep(startFrequency: 20_000, endFrequency: 200, duration: 10))
            .frame(height: 112)
            .listRowInsets(EdgeInsets())
        ExpectedSpectrumSketch(signal: .sweep(startFrequency: 20, endFrequency: 20_000, duration: 10))
            .frame(height: 112)
            .listRowInsets(EdgeInsets())
    }
}
