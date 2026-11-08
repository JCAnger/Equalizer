import SwiftUI

/// Montre quelles zones de fréquences les enceintes (et la pièce) atténuent ou exagèrent,
/// d'après la moyenne à long terme de la musique captée par le microphone.
struct ResponseAnalysisView: View {
    let analyzer: AudioSpectrumAnalyzer
    let reference: ReferenceReceiver
    let settings: SpectrumSettings

    @Environment(\.dismiss) private var dismiss

    /// Étendue (dB) des graphiques de part et d'autre de la courbe attendue ou de l'axe zéro.
    private let displayRange: Float = 12

    /// La référence n'est utilisée que si la source a envoyé de l'audio pendant la mesure.
    private var usesReference: Bool {
        reference.frameCount > 0
    }

    /// Rapport recalculé à chaque évaluation de la vue : le calcul est léger (quelques dizaines de bandes).
    private var report: FrequencyResponseReport? {
        FrequencyResponseAnalysis.report(
            averageLevels: analyzer.averageBandLevels,
            referenceLevels: usesReference ? reference.averageLevels : nil,
            settings: settings
        )
    }

    private var isMeasuring: Bool {
        analyzer.isMeasuring
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    controls
                } footer: {
                    Text(usesReference
                         ? "Les écarts comparent ce que capte le micro à ce que la source envoie aux enceintes, relativement aux médiums (250 Hz–2 kHz)."
                         : "Sans référence, les écarts sont relatifs aux médiums (250 Hz–2 kHz) par rapport à un spectre musical typique (−3 dB/octave). Démarrez la source (Mac ou autre iPhone/iPad) pour une comparaison exacte.")
                }

                if let report {
                    Section("Courbes") {
                        curvesChart(expected: report.expected, restituted: report.restituted)
                            .frame(height: 180)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        legend
                    }

                    Section("Écart par fréquence") {
                        deviationChart(report.bands)
                            .frame(height: 140)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }

                    Section("Zones") {
                        ForEach(report.zones) { zone in
                            HStack {
                                Text(zone.name)
                                Spacer()
                                Text(String(format: "%+.1f dB", zone.deviation))
                                    .monospacedDigit()
                                Text(zone.verdict.label)
                                    .font(.caption.bold())
                                    .foregroundStyle(color(for: zone.verdict))
                                    .frame(width: 80, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Analyse des enceintes")

            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }

    /// État de la connexion à la source et boutons de pilotage de la mesure.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                reference.isConnected ? "Référence : \(reference.sourceName ?? "source") connectée" : "Référence : recherche de la source…",
                systemImage: reference.isConnected ? "checkmark.circle.fill" : "magnifyingglass"
            )
            .font(.footnote)
            .foregroundStyle(reference.isConnected ? .green : .secondary)

            HStack {
                if isMeasuring {
                    Button("Arrêter la mesure") {
                        analyzer.stopMeasurement()
                        reference.stopMeasurement()
                    }
                } else {
                    Button("Démarrer la mesure") {
                        analyzer.startMeasurement()
                        reference.startMeasurement()
                    }
                    // Sans capture du micro, il n'y aurait rien à mesurer.
                    .disabled(!analyzer.isRunning)
                }
                Spacer()
                Button("Réinitialiser", role: .destructive) {
                    analyzer.resetMeasurement()
                    reference.resetMeasurement()
                }
                .disabled(analyzer.measuredFrameCount == 0)
            }
            .buttonStyle(.bordered)

            if !analyzer.isRunning {
                Text("Démarrez d'abord la capture du micro.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Résumé de l'avancée de la mesure (nombre d'analyses du micro et de la référence).
    private var status: String {
        let count = analyzer.measuredFrameCount
        if analyzer.isMeasuring && count == 0 {
            return "Mesure en cours… en attente d'un signal audible."
        }
        let state = analyzer.isMeasuring ? "Mesure en cours" : "Mesure arrêtée"
        return "\(state) · \(count) analyses micro · \(reference.frameCount) analyses référence"
    }

    /// Couleur associée à un verdict : rouge pour un manque, orange pour un excès, vert si équilibré.
    private func color(for verdict: ResponseVerdict) -> Color {
        switch verdict {
        case .lacking: return .red
        case .balanced: return .green
        case .excess: return .orange
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            Label(usesReference ? "Attendu (source)" : "Attendu (spectre typique)", systemImage: "minus")
                .foregroundStyle(.secondary)
            Label("Restitué (micro)", systemImage: "minus")
                .foregroundStyle(.cyan)
        }
        .font(.caption)
    }

    /// Fréquences (Hz) repérées sous les courbes.
    private let frequencyLabels: [Double] = [100, 1_000, 10_000]

    /// Les deux courbes sur un axe de fréquences logarithmique. Les bandes étant espacées de
    /// façon logarithmique, l'indice de bande correspond linéairement à l'axe horizontal.
    private func curvesChart(expected: [Float], restituted: [Float]) -> some View {
        Canvas { context, size in
            guard expected.count > 1, expected.count == restituted.count else { return }

            let axisHeight: CGFloat = 16
            let plotHeight = size.height - axisHeight

            // L'échelle verticale ne suit que la courbe attendue : elle ne change pas d'échelle
            // (et la courbe en pointillés ne semble pas bouger) quand la courbe mesurée varie.
            // La courbe mesurée est alignée sur l'attendue dans les médiums, donc une marge de
            // `displayRange` autour de l'attendue suffit pour montrer les écarts.
            let low = (expected.min() ?? 0) - displayRange
            let high = (expected.max() ?? 0) + displayRange

            func point(_ index: Int, _ value: Float) -> CGPoint {
                CGPoint(
                    x: CGFloat(index) / CGFloat(expected.count - 1) * size.width,
                    y: plotHeight - CGFloat((value - low) / (high - low)) * plotHeight
                )
            }

            func path(for levels: [Float]) -> Path {
                var path = Path()
                for (index, value) in levels.enumerated() {
                    let p = point(index, value)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                return path
            }

            // Repères de fréquence avec de discrets guides verticaux.
            let minFreq = max(settings.minFrequency, 1)
            let maxFreq = max(settings.maxFrequency, minFreq + 1)
            for frequency in frequencyLabels where frequency > minFreq && frequency < maxFreq {
                let fraction = (log10(frequency) - log10(minFreq)) / (log10(maxFreq) - log10(minFreq))
                let x = CGFloat(fraction) * size.width
                var guide = Path()
                guide.move(to: CGPoint(x: x, y: 0))
                guide.addLine(to: CGPoint(x: x, y: plotHeight))
                context.stroke(guide, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                let text = frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
                context.draw(
                    Text(text).font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: x, y: plotHeight + axisHeight / 2)
                )
            }

            context.stroke(
                path(for: expected),
                with: .color(.primary.opacity(0.8)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 4])
            )
            context.stroke(
                path(for: restituted),
                with: .color(.cyan),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// Barres montant (excès) ou descendant (manque) à partir d'une ligne centrale à 0 dB.
    /// Les écarts au-delà de `displayRange` sont tronqués pour rester dans le cadre.
    private func deviationChart(_ bands: [BandDeviation]) -> some View {
        Canvas { context, size in
            let midY = size.height / 2
            let spacing: CGFloat = 2
            let barWidth = max((size.width - spacing * CGFloat(bands.count - 1)) / CGFloat(bands.count), 1)

            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: midY))
            axis.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(axis, with: .color(.secondary.opacity(0.5)), lineWidth: 1)

            for (index, band) in bands.enumerated() {
                let clamped = min(max(band.deviation, -displayRange), displayRange)
                let height = CGFloat(abs(clamped) / displayRange) * midY
                let x = CGFloat(index) * (barWidth + spacing)
                let y = clamped >= 0 ? midY - height : midY
                let verdict: ResponseVerdict = band.deviation < -FrequencyResponseAnalysis.tolerance
                    ? .lacking
                    : (band.deviation > FrequencyResponseAnalysis.tolerance ? .excess : .balanced)
                context.fill(
                    Path(CGRect(x: x, y: y, width: barWidth, height: max(height, 1))),
                    with: .color(color(for: verdict))
                )
            }
        }
    }
}
