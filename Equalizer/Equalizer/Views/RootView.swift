#if !os(macOS)
import SwiftUI

/// Lets the user choose what this iPhone/iPad does: listen with its microphone (analysis)
/// or play the reference music (source).
struct RootView: View {
    private enum Role: String {
        case analysis
        case source
    }

    @AppStorage("deviceRole") private var storedRole = ""

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

    private var changeRoleButton: some View {
        Button("Changer de rôle") { storedRole = "" }
            .glassButtonStyle()
            .controlSize(.small)
            .padding(.leading, 44)
            .padding(.bottom, 8)
    }

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
