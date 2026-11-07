#if os(macOS)
import SwiftUI
import Observation

/// Owns the Music tap and the network broadcaster for the Mac screen.
@Observable
final class ReferenceSourceModel {
    private(set) var isBroadcasting = false
    private(set) var clientCount = 0
    private(set) var errorMessage: String?

    private let settings = SpectrumSettings()
    private let tap = MusicAudioTap()
    private let broadcaster = ReferenceBroadcaster()

    init() {
        tap.onFrame = { [broadcaster] frame in
            broadcaster.send(frame)
        }
        broadcaster.onClientCountChange = { [weak self] count in
            Task { @MainActor in
                self?.clientCount = count
            }
        }
        broadcaster.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.errorMessage = message
                self?.stop()
            }
        }
    }

    func start() {
        guard !isBroadcasting else { return }
        errorMessage = nil
        do {
            try broadcaster.start(serviceName: Host.current().localizedName ?? "Mac")
            try tap.start(config: settings.analysisConfig)
            isBroadcasting = true
        } catch {
            errorMessage = error.localizedDescription
            tap.stop()
            broadcaster.stop()
        }
    }

    func stop() {
        tap.stop()
        broadcaster.stop()
        isBroadcasting = false
    }
}

/// Mac screen: sends what Music plays to the measuring iPhone.
struct ReferenceSourceView: View {
    @State private var model = ReferenceSourceModel()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(model.isBroadcasting ? AppTheme.seafoam : .secondary)

            Text(model.isBroadcasting ? "Diffusion de la référence en cours" : "Référence arrêtée")
                .font(.headline)

            Text("Lancez la lecture dans Music (sortie AirPlay vers vos enceintes), puis démarrez la diffusion. L'iPhone se connecte automatiquement sur le même réseau.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if model.isBroadcasting {
                Text(model.clientCount == 0 ? "En attente de l'iPhone…" : "\(model.clientCount) appareil(s) connecté(s)")
                    .font(.footnote)
            }

            Button(model.isBroadcasting ? "Arrêter" : "Démarrer la diffusion") {
                if model.isBroadcasting {
                    model.stop()
                } else {
                    model.start()
                }
            }
            .glassProminentButtonStyle()
            .controlSize(.large)

            if let message = model.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .glassCard()
        .padding(24)
        .frame(minWidth: 420, minHeight: 320)
        .background { AppBackground() }
        .onDisappear { model.stop() }
    }
}

#Preview {
    ReferenceSourceView()
}
#endif
