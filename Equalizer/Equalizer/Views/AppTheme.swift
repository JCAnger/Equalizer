import SwiftUI

/// Palette pastel vert et bleu partagée par tous les écrans.
enum AppTheme {
    static let mint = Color(red: 0.62, green: 0.86, blue: 0.74)
    static let sky = Color(red: 0.55, green: 0.76, blue: 0.95)
    static let seafoam = Color(red: 0.45, green: 0.78, blue: 0.70)

    /// Accent des contrôles teintés (boutons proéminents, sélecteurs).
    /// Bleu profond : environ 5,8:1 de contraste avec le texte blanc des boutons proéminents,
    /// et toujours visible sur les fonds sombres.
    static let accent = Color(red: 0.13, green: 0.41, blue: 0.63)

    /// Versions profondes et désaturées, utilisées derrière le spectre et en mode sombre.
    static let deepTeal = Color(red: 0.05, green: 0.16, blue: 0.19)
    static let deepBlue = Color(red: 0.07, green: 0.12, blue: 0.24)
}

/// Dégradé pastel doux que les contrôles Liquid Glass réfractent : sans fond coloré,
/// l'effet de verre serait à peine visible.
struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [AppTheme.deepTeal, AppTheme.deepBlue]
                    : [Color(red: 0.84, green: 0.96, blue: 0.90), Color(red: 0.80, green: 0.90, blue: 0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Deux halos flous décalés aux coins opposés donnent de la profondeur au dégradé.
            Circle()
                .fill(AppTheme.mint.opacity(colorScheme == .dark ? 0.25 : 0.55))
                .frame(width: 380)
                .blur(radius: 70)
                .offset(x: -140, y: -260)
            Circle()
                .fill(AppTheme.sky.opacity(colorScheme == .dark ? 0.25 : 0.55))
                .frame(width: 420)
                .blur(radius: 80)
                .offset(x: 160, y: 280)
        }
        .ignoresSafeArea()
    }
}

/// Surface pastel menthe vers ciel, utilisée à la place de Liquid Glass avant la version 26 des OS.
private struct PastelSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S
    /// Reproduit la variante de verre `.clear` : aucune teinte, seulement le matériau.
    let isClear: Bool

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let fillOpacity = isClear ? 0.0 : (isDark ? 0.22 : 0.55)
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.fill(
                            LinearGradient(
                                colors: [AppTheme.mint, AppTheme.sky],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .opacity(fillOpacity)
                        )
                    }
                    .overlay {
                        shape.strokeBorder(.white.opacity(isDark ? 0.18 : 0.55), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            }
    }
}

/// Style de bouton pastel utilisé à la place de `.glass` / `.glassProminent` avant iOS 26.
private struct PastelButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    /// Vrai pour le bouton principal d'un écran (fond d'accent plein).
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isDark = colorScheme == .dark
        configuration.label
            .font(.body.weight(.semibold))
            // Les boutons proéminents ont l'accent pour fond : leur texte reste blanc pour le contraste.
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(
                        isProminent
                            ? AnyShapeStyle(AppTheme.accent)
                            : AnyShapeStyle(
                                LinearGradient(
                                    colors: [AppTheme.mint, AppTheme.sky],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .opacity(isDark ? 0.35 : 0.8)
                            )
                    )
                    .overlay { Capsule().strokeBorder(.white.opacity(isDark ? 0.2 : 0.6), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            }
            // Rend toute la capsule sensible au toucher, pas seulement le texte.
            .contentShape(Capsule())
            // Légère réduction à l'appui, comme retour visuel discret.
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.2), value: configuration.isPressed)
    }
}

extension View {
    /// Enveloppe le contenu dans un panneau Liquid Glass aux coins arrondis.
    /// Se rabat sur une surface pastel sur les versions d'OS sans Liquid Glass.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 28) -> some View {
        padding(24)
            .glassSurface(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Applique Liquid Glass dans la forme donnée, ou une surface pastel avant iOS 26.
    /// - Parameters:
    ///   - shape: forme qui découpe la surface.
    ///   - isClear: utilise la variante de verre `.clear`, plus transparente.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(in shape: S, isClear: Bool = false) -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, macOS 26.0, visionOS 26.0, *) {
            glassEffect(isClear ? .clear : .regular, in: shape)
        } else {
            modifier(PastelSurface(shape: shape, isClear: isClear))
        }
    }

    /// Style de bouton `.glass`, ou capsule pastel avant iOS 26.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, macOS 26.0, visionOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(PastelButtonStyle(isProminent: false))
        }
    }

    /// Style de bouton `.glassProminent`, ou capsule d'accent avant iOS 26.
    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, macOS 26.0, visionOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(PastelButtonStyle(isProminent: true))
        }
    }
}
