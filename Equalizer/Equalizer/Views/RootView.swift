#if !os(macOS)
import SwiftUI

/// Permet de choisir ce que fait cet iPhone/iPad : écouter avec son microphone (analyse)
/// ou jouer la musique de référence (source).
struct RootView: View {
    private enum Role: String {
        case analysis
        case source
    }

    /// Rôle mémorisé d'un lancement à l'autre ; une chaîne vide signifie « pas encore choisi ».
    @AppStorage("deviceRole") private var storedRole = ""

    /// `nil` tant que l'utilisateur n'a pas choisi (ou si la valeur stockée est inconnue).
    private var role: Role? {
        Role(rawValue: storedRole)
    }

    var body: some View {
        switch role {
        case .analysis:
            ContentView()
                .overlay(alignment: .bottomLeading) { changeRoleButton }
        case .source:
            PlayerSourceView()
                .overlay(alignment: .bottomLeading) { changeRoleButton }
        case nil:
            roleChooser
        }
    }

    /// Bouton flottant pour revenir au choix du rôle.
    private var changeRoleButton: some View {
        Button("Changer de rôle") { storedRole = "" }
            .glassButtonStyle()
            .controlSize(.small)
            .padding(.leading, 44)
            .padding(.bottom, 8)
    }

    /// Écran de premier lancement : deux gros boutons, un par rôle.
    private var roleChooser: some View {
        VStack(spacing: 20) {
            Text("Que fait cet appareil ?")
                .font(.title2.bold())

            Button {
                storedRole = Role.analysis.rawValue
            } label: {
                Label("Mesurer avec le micro", systemImage: "mic.fill")
                    .frame(maxWidth: 320)
            }
            .glassProminentButtonStyle()

            Button {
                storedRole = Role.source.rawValue
            } label: {
                Label("Jouer la musique (source)", systemImage: "play.circle.fill")
                    .frame(maxWidth: 320)
            }
            .glassButtonStyle()
        }
        .controlSize(.large)
        .glassCard()
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackground() }
    }
}

#Preview {
    RootView()
}
#endif
