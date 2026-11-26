#if !os(macOS)
import SwiftUI

/// Écran d'accueil affiché brièvement au démarrage, par-dessus l'écran de lancement natif :
/// celui-ci ne peut montrer qu'une couleur unie et une image, sans texte ni dégradé.
struct SplashView: View {
    /// Durée d'affichage avant le fondu vers l'app. Courte, pour ne pas retarder l'accès.
    static let displayDuration: Duration = .seconds(1.2)

    var body: some View {
        ZStack {
            AppBackground()
            SplashSpectrumBackdrop()
            VStack(spacing: Metrics.contentSpacing) {
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: Metrics.logoSize, height: Metrics.logoSize)
                    .shadow(color: .black.opacity(0.15), radius: 16, y: 8)
                    .accessibilityHidden(true)
                Text("Equalizer")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, Metrics.cardHorizontalPadding)
            .padding(.vertical, Metrics.cardVerticalPadding)
            .glassSurface(in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
        }
    }

    private enum Metrics {
        static let logoSize: CGFloat = 96
        static let contentSpacing: CGFloat = 16
        static let cardHorizontalPadding: CGFloat = 32
        static let cardVerticalPadding: CGFloat = 24
        static let cardCornerRadius: CGFloat = 32
    }
}

/// Rangée de barres de spectre qui ondulent doucement en arrière-plan.
/// Immobile si « Réduire les animations » est activé.
private struct SplashSpectrumBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: Metrics.barSpacing) {
                    ForEach(0..<Metrics.barCount, id: \.self) { index in
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [AppTheme.spectrumLow, AppTheme.spectrumMid, AppTheme.spectrumHigh],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(height: proxy.size.height * Metrics.maxHeightRatio
                                   * level(of: index, at: reduceMotion ? 0 : time))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .opacity(colorScheme == .dark ? Metrics.darkOpacity : Metrics.lightOpacity)
        .blur(radius: Metrics.blurRadius)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Hauteur relative (0…1) d'une barre : une courbe en cloche, comme un spectre musical,
    /// modulée par une onde qui se déplace le long de la rangée.
    private func level(of index: Int, at time: TimeInterval) -> CGFloat {
        let position = Double(index) / Double(Metrics.barCount - 1)
        let bell = 0.35 + 0.55 * exp(-pow((position - 0.4) / 0.3, 2))
        let wave = 0.12 * sin(time * Metrics.waveSpeed + Double(index) * Metrics.wavePhaseStep)
        return CGFloat(min(max(bell + wave, 0.1), 1))
    }

    private enum Metrics {
        static let barCount = 18
        static let barSpacing: CGFloat = 8
        static let horizontalPadding: CGFloat = 16
        static let maxHeightRatio: CGFloat = 0.7
        static let lightOpacity = 0.45
        static let darkOpacity = 0.55
        static let blurRadius: CGFloat = 2
        static let waveSpeed = 2.4
        static let wavePhaseStep = 0.6
    }
}

#Preview("Clair") {
    SplashView()
        .preferredColorScheme(.light)
}

#Preview("Sombre") {
    SplashView()
        .preferredColorScheme(.dark)
}
#endif
