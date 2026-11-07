import SwiftUI
import Observation
import UniformTypeIdentifiers
#if os(iOS)
import MediaPlayer
import AVKit
#endif

/// Owns the file player and the network broadcaster for the "source" iPhone/iPad.
@Observable
final class PlayerSourceModel {
    private(set) var fileName: String?
    private(set) var isPlaying = false
    private(set) var clientCount = 0
    private(set) var errorMessage: String?
    /// Output the sound is currently sent to, shown to help diagnose silence.
    private(set) var outputName: String?

    private let settings = SpectrumSettings()
    private let player = ReferencePlayer()
    private let broadcaster = ReferenceBroadcaster()
    private var isBroadcasting = false
    private var accessedURL: URL?

    init() {
        player.onFrame = { [broadcaster] frame in
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
            }
        }
    }

    /// Makes the source visible to measuring devices, even before playback starts.
    func startBroadcasting() {
        guard !isBroadcasting else { return }
        do {
            let hostName = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
            try broadcaster.start(serviceName: hostName)
            isBroadcasting = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shutDown() {
        player.stop()
        broadcaster.stop()
        isBroadcasting = false
        isPlaying = false
        releaseFile()
    }

    func load(_ url: URL) {
        errorMessage = nil
        releaseFile()
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
        do {
            try player.load(url, config: settings.analysisConfig)
            fileName = url.lastPathComponent
            isPlaying = false
        } catch {
            fileName = nil
            isPlaying = false
            errorMessage = error.localizedDescription
        }
    }

    func loadNoise(_ color: NoiseColor) {
        errorMessage = nil
        releaseFile()
        player.loadNoise(color, config: settings.analysisConfig)
        fileName = color == .pink ? "Bruit rose" : "Bruit blanc"
        isPlaying = false
    }

    func togglePlayback() {
        errorMessage = nil
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        Task {
            do {
                // Activating the audio session can block, so keep it off the main thread.
                try await Task.detached { [player] in try player.play() }.value
                isPlaying = true
                outputName = player.outputName
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Reports a library item that can't be played (cloud-only or DRM-protected).
    func libraryItemUnavailable() {
        errorMessage = "Ce morceau n'est pas utilisable : il doit être téléchargé sur l'appareil et sans protection (DRM). Les titres Apple Music en streaming ne sont pas lisibles."
    }

    func fail(with error: Error) {
        errorMessage = error.localizedDescription
    }

    private func releaseFile() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }
}

/// Screen for the device that plays the music: it plays a file through its speakers
/// output and tells the measuring device what it is playing.
struct PlayerSourceView: View {
    @State private var model = PlayerSourceModel()
    @State private var showingImporter = false
    #if os(iOS)
    @State private var showingLibrary = false
    #endif

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: model.isPlaying ? "speaker.wave.3.fill" : "speaker.fill")
                .font(.system(size: 44))
                .foregroundStyle(model.isPlaying ? AppTheme.seafoam : .secondary)

            Text(model.fileName ?? "Aucun morceau choisi")
                .font(.headline)
                .multilineTextAlignment(.center)

            #if os(iOS)
            if model.isPlaying {
                Text("Sortie actuelle : \(model.outputName ?? "aucune")")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            #endif

            Text("Branchez cet appareil sur les enceintes à tester, choisissez un morceau (fichier sans protection), puis lancez la lecture. L'autre appareil, avec le micro, se connecte automatiquement sur le même réseau Wi-Fi.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(model.clientCount == 0 ? "En attente de l'appareil de mesure…" : "\(model.clientCount) appareil(s) connecté(s)")
                .font(.footnote)

            HStack {
                #if os(iOS)
                Button("Musique") { showingLibrary = true }
                    .glassButtonStyle()
                #endif
                Button("Fichiers") { showingImporter = true }
                    .glassButtonStyle()
            }
            .controlSize(.large)

            HStack {
                Button("Bruit rose") { model.loadNoise(.pink) }
                    .glassButtonStyle()
                Button("Bruit blanc") { model.loadNoise(.white) }
                    .glassButtonStyle()
            }
            .controlSize(.large)

            Button(model.isPlaying ? "Pause" : "Lecture") { model.togglePlayback() }
                .glassProminentButtonStyle()
                .controlSize(.large)
                .disabled(model.fileName == nil)

            #if os(iOS)
            HStack(spacing: 8) {
                Text("Sortie audio")
                    .font(.callout)
                AirPlayRoutePicker()
                    .frame(width: 44, height: 44)
            }
            #endif

            if let message = model.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .glassCard()
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackground() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case let .success(url):
                model.load(url)
            case let .failure(error):
                model.fail(with: error)
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showingLibrary) {
            MusicLibraryPicker { url in
                if let url {
                    model.load(url)
                } else {
                    model.libraryItemUnavailable()
                }
            }
        }
        #endif
        .onAppear { model.startBroadcasting() }
        .onDisappear { model.shutDown() }
    }
}

#if os(iOS)
/// System button that lets the user choose the AirPlay / Bluetooth output device.
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .systemBlue
        picker.activeTintColor = .systemGreen
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Lets the user pick a song from the Music library. Only songs downloaded on the
/// device and not DRM-protected expose a URL; otherwise the callback receives nil.
struct MusicLibraryPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.showsCloudItems = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: MPMediaPickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let parent: MusicLibraryPicker

        init(parent: MusicLibraryPicker) {
            self.parent = parent
        }

        func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems mediaItemCollection: MPMediaItemCollection) {
            parent.onPick(mediaItemCollection.items.first?.assetURL)
            parent.dismiss()
        }

        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            parent.dismiss()
        }
    }
}
#endif

#Preview {
    PlayerSourceView()
}
