import SwiftUI

/// Panneau de commandes en bas de l'écran, à portée du pouce : cinq boutons ronds de même taille
/// (bruit, sortie AirPlay, mesure, analyse des enceintes, réglages). Le bruit choisi s'affiche sur le graphe.
struct MeasurementControls: View {
    let session: MeasurementSession
    let onShowAnalysis: () -> Void
    let onShowSettings: () -> Void

    private static let airPlayIconScale: CGFloat = 1.5

    @State private var showingGenerator = false

    private var generator: NoiseGenerator { session.generator }
    private var analyzer: AudioSpectrumAnalyzer { session.analyzer }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                noiseMenu
                Spacer()
                #if os(iOS)
                airPlayButton
                Spacer()
                #endif
                measureButton
                Spacer()
                iconButton("waveform.badge.magnifyingglass", color: AppTheme.controlAnalysis, label: "Analyse des enceintes", action: onShowAnalysis)
                Spacer()
                iconButton("slider.horizontal.3", color: AppTheme.controlSettings, label: "Réglages", action: onShowSettings)
            }

            statusMessages
        }
        // Le bas de l'écran garde le fond sombre du graphe : en clair, le verre y paraîtrait blanchâtre.
        // Appliqué avant `.sheet` pour que les feuilles gardent l'apparence du système.
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showingGenerator) {
            TestSignalView { signal in session.select(signal) }
        }
    }

    // MARK: - Boutons

    /// Menu du bruit, ouvert par un bouton à icône.
    private var noiseMenu: some View {
        Menu {
            choice("Aucun", systemImage: "speaker.slash", signal: nil)
            choice("Bruit rose", systemImage: "waveform", signal: .noise(.pink))
            choice("Bruit blanc", systemImage: "waveform", signal: .noise(.white))
            Button("Générateur…", systemImage: "slider.horizontal.below.waveform") { showingGenerator = true }
        } label: {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(.white)
                .controlCircle(AppTheme.controlNoise)
        }
        .accessibilityLabel("Choisir le bruit")
        .accessibilityValue(generator.signal?.title ?? String(localized: "Aucun"))
    }

    /// Entrée du menu ; la coche repère le signal actuellement choisi.
    private func choice(_ title: LocalizedStringKey, systemImage: String, signal: GeneratedSignal?) -> some View {
        Button {
            session.select(signal)
        } label: {
            Label(title, systemImage: generator.signal == signal ? "checkmark" : systemImage)
        }
    }

    #if os(iOS)
    private var airPlayButton: some View {
        // L'icône du sélecteur système est petite et sa taille n'est pas réglable : on l'agrandit.
        AirPlayRoutePicker()
            .frame(width: ControlCircle.size, height: ControlCircle.size)
            .scaleEffect(Self.airPlayIconScale)
            .controlCircle(AppTheme.controlOutput)
            .accessibilityLabel("Sortie audio")
    }
    #endif

    private var measureButton: some View {
        Button {
            session.toggleMeasurement()
        } label: {
            Image(systemName: session.isMeasuring ? "stop.fill" : "play.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .controlCircle(AppTheme.controlMeasure)
        }
        .buttonStyle(.plain)
        // Sans micro ouvert, il n'y aurait rien à mesurer.
        .disabled(!analyzer.isRunning)
        .opacity(analyzer.isRunning ? 1 : 0.4)
        .accessibilityLabel(session.isMeasuring ? "Arrêter la mesure" : "Mesurer")
    }

    private func iconButton(_ systemImage: String, color: Color, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.white)
                .controlCircle(color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Messages

    @ViewBuilder
    private var statusMessages: some View {
        if let message = analyzer.errorMessage {
            VStack(spacing: 4) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Réessayer") { session.startListening() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }

        if let message = generator.errorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Bouton rond

private enum ControlCircle {
    /// Taille commune à tous les boutons du bas : au-dessus du minimum de 44 points d'une zone tactile.
    static let size: CGFloat = 56
}

private extension View {
    /// Habille le contenu en bouton rond plein de la couleur donnée, avec un liseré clair et une ombre douce.
    func controlCircle(_ color: Color) -> some View {
        frame(width: ControlCircle.size, height: ControlCircle.size)
            .background(color, in: .circle)
            .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            .contentShape(.circle)
    }
}

#Preview {
    MeasurementControls(
        session: MeasurementSession(settings: SpectrumSettings()),
        onShowAnalysis: {},
        onShowSettings: {}
    )
    .padding()
    .background { AppBackground().environment(\.colorScheme, .dark) }
}
