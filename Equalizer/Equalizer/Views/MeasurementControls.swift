import SwiftUI

/// Panneau de commandes en bas de l'écran, à portée du pouce : cinq touches de verre carrées de même taille
/// (bruit, sortie AirPlay, mesure, analyse des enceintes, réglages). Le bruit choisi s'affiche sur le graphe.
struct MeasurementControls: View {
    let session: MeasurementSession
    let onShowAnalysis: () -> Void
    let onShowSettings: () -> Void


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
                .font(.title)
                .foregroundStyle(.white)
                .controlKey(AppTheme.controlNoise)
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
        // La taille du glyphe du sélecteur système n'est pas réglable : les autres icônes
        // (`.title`) sont choisies pour avoir la même taille visuelle.
        AirPlayRoutePicker()
            .frame(width: ControlKey.size, height: ControlKey.size)
            .controlKey(AppTheme.controlOutput)
            .accessibilityLabel("Sortie audio")
    }
    #endif

    private var measureButton: some View {
        Button {
            session.toggleMeasurement()
        } label: {
            Image(systemName: session.isMeasuring ? "stop.fill" : "play.fill")
                .font(.title)
                .foregroundStyle(.white)
                .controlKey(AppTheme.controlMeasure)
        }
        .buttonStyle(ControlKeyButtonStyle())
        .disabled(!canToggleMeasurement)
        .opacity(canToggleMeasurement ? 1 : 0.4)
        .accessibilityLabel(session.isMeasuring ? "Arrêter la mesure" : "Mesurer")
        .accessibilityHint(generator.signal == nil && !session.isMeasuring ? Text("Choisissez d'abord un bruit") : Text(""))
    }

    /// Sans micro ouvert il n'y aurait rien à mesurer, et sans bruit choisi, rien à comparer : le
    /// bouton est alors désactivé. Pendant une mesure il reste actif, pour pouvoir l'arrêter même si
    /// l'on a choisi « Aucun » entre-temps.
    private var canToggleMeasurement: Bool {
        guard analyzer.isRunning else { return false }
        return session.isMeasuring || generator.signal != nil
    }

    private func iconButton(_ systemImage: String, color: Color, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.white)
                .controlKey(color)
        }
        .buttonStyle(ControlKeyButtonStyle())
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

// MARK: - Touche de verre

private enum ControlKey {
    /// Taille commune à tous les boutons du bas : au-dessus du minimum de 44 points d'une zone tactile.
    static let size: CGFloat = 56
    /// Coins arrondis des touches, en style `.continuous`.
    static let cornerRadius: CGFloat = 16
    /// Échelle à l'appui, pour un retour visuel discret.
    static let pressedScale: CGFloat = 0.97
}

/// Enfonce légèrement la touche à l'appui.
private struct ControlKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? ControlKey.pressedScale : 1)
            .animation(.smooth(duration: 0.2), value: configuration.isPressed)
    }
}

private extension View {
    /// Habille le contenu en touche de verre teinté : carré arrondi, reflet en haut et ombre douce.
    /// Avant iOS 26, le verre est imité par un dégradé de la teinte avec un reflet.
    @ViewBuilder
    func controlKey(_ color: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: ControlKey.cornerRadius, style: .continuous)
        if #available(iOS 26.0, macCatalyst 26.0, macOS 26.0, *) {
            frame(width: ControlKey.size, height: ControlKey.size)
                .glassEffect(.regular.tint(color.opacity(0.75)), in: shape)
                .contentShape(shape)
        } else {
            frame(width: ControlKey.size, height: ControlKey.size)
                .background {
                    shape.fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                }
                .overlay(alignment: .top) {
                    // Reflet : une lueur claire qui s'estompe vers le milieu de la touche.
                    shape
                        .fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center))
                        .padding(2)
                }
                .overlay { shape.strokeBorder(.white.opacity(0.3), lineWidth: 1) }
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .contentShape(shape)
        }
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
