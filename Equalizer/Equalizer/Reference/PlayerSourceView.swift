import SwiftUI
import Observation
import UniformTypeIdentifiers
#if os(iOS)
import MediaPlayer
import AVKit
#endif

/// Possède le lecteur de fichier et le diffuseur réseau de l'iPhone/iPad « source ».
@Observable
final class PlayerSourceModel {
    private(set) var fileName: String?
    private(set) var isPlaying = false {
        didSet {
            // Vidé à l'arrêt pour qu'une reprise de lecture ne montre pas un spectre périmé.
            if !isPlaying { bandLevels = [] }
        }
    }
    /// Nombre d'appareils de mesure actuellement connectés.
    private(set) var clientCount = 0
    private(set) var errorMessage: String?
    /// Sortie vers laquelle le son est envoyé, affichée pour aider à diagnostiquer un silence.
    private(set) var outputName: String?
    /// Spectre lissé de ce qui est envoyé aux enceintes, identique à ce que reçoit l'appareil de
    /// mesure : il sert à vérifier visuellement la référence sur l'appareil source.
    private(set) var bandLevels: [Float] = []
    /// Morceaux déjà ouverts, du plus récent au plus ancien, proposés dans le menu.
    private(set) var recentTracks: [RecentTrack] = []

    let settings = SpectrumSettings()
    private let recentStore = RecentTracksStore()
    private let player = ReferencePlayer()
    private let broadcaster = ReferenceBroadcaster()
    private var isBroadcasting = false
    /// Fichier dont l'accès sécurisé est ouvert ; à refermer quand on n'en a plus besoin.
    private var accessedURL: URL?

    init() {
        recentTracks = recentStore.load()
        // Les rappels viennent de threads audio ou réseau : on repasse sur le main actor avant de toucher à l'état.
        player.onFrame = { [broadcaster, weak self] frame in
            broadcaster.send(frame)
            Task { @MainActor [weak self] in
                self?.updateBandLevels(frame.bands)
            }
        }
        broadcaster.onClientCountChange = { [weak self] count in
            Task { @MainActor [weak self] in
                self?.clientCount = count
            }
        }
        broadcaster.onFailure = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.errorMessage = message
            }
        }
    }

    /// Rend la source visible des appareils de mesure, même avant le début de la lecture.
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

    /// Charge un morceau choisi par l'utilisateur et l'ajoute aux morceaux récents.
    /// - Parameters:
    ///   - url: fichier ou morceau de la bibliothèque Musique.
    ///   - title: nom à afficher ; à défaut, le nom du fichier sans extension.
    func load(_ url: URL, title: String? = nil) {
        errorMessage = nil
        releaseFile()
        // Nécessaire pour lire un fichier choisi hors du bac à sable de l'app (sélecteur de fichiers).
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
        do {
            try player.load(url, config: settings.analysisConfig)
            fileName = title ?? url.deletingPathExtension().lastPathComponent
            isPlaying = false
            // Le bookmark doit être créé pendant que l'accès sécurisé est ouvert, donc ici.
            // Le recréer à chaque ouverture le garde aussi à jour si le fichier a bougé.
            if let track = recentStore.makeTrack(for: url, title: title) {
                recentTracks = recentStore.adding(track, to: recentTracks)
            }
        } catch {
            fileName = nil
            isPlaying = false
            errorMessage = error.localizedDescription
        }
    }

    /// Rouvre un morceau récent. S'il n'est plus accessible, il est retiré de la liste.
    func loadRecent(_ track: RecentTrack) {
        guard let url = recentStore.resolveURL(of: track) else {
            recentTracks = recentStore.removing(track, from: recentTracks)
            errorMessage = "« \(track.name) » n'est plus disponible : il a peut-être été supprimé ou déplacé."
            return
        }
        load(url, title: track.name)
    }

    /// Remplace le morceau par un signal de test généré (bruit, balayage, bruit par bande).
    func loadSignal(_ signal: GeneratedSignal) {
        errorMessage = nil
        releaseFile()
        player.loadSignal(signal, config: settings.analysisConfig)
        fileName = signal.title
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
                // L'activation de la session audio peut bloquer : on la sort du thread principal.
                try await Task.detached { [player] in try player.play() }.value
                isPlaying = true
                outputName = player.outputName
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Signale un morceau de la bibliothèque impossible à lire (dans le cloud uniquement ou protégé par DRM).
    func libraryItemUnavailable() {
        errorMessage = "Ce morceau n'est pas utilisable : il doit être téléchargé sur l'appareil et sans protection (DRM). Les titres Apple Music en streaming ne sont pas lisibles."
    }

    func fail(with error: Error) {
        errorMessage = error.localizedDescription
    }

    /// Même lissage attaque/relâchement que la courbe du microphone, pour que les deux écrans
    /// bougent de la même façon et restent comparables à l'œil.
    private func updateBandLevels(_ bands: [Float]) {
        // Ignore les images arrivées juste après une pause.
        guard isPlaying else { return }
        guard bandLevels.count == bands.count else {
            bandLevels = bands
            return
        }
        for i in bands.indices {
            let coefficient = bands[i] > bandLevels[i] ? settings.attack : settings.release
            bandLevels[i] += (bands[i] - bandLevels[i]) * coefficient
        }
    }

    private func releaseFile() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }
}

/// Écran de l'appareil qui joue la musique : il lit un fichier vers sa sortie audio
/// et indique à l'appareil de mesure ce qu'il joue.
struct PlayerSourceView: View {
    @State private var model = PlayerSourceModel()
    @State private var showingImporter = false
    @State private var showingGenerator = false
    #if os(iOS)
    @State private var showingLibrary = false
    #endif

    var body: some View {
        VStack(spacing: 16) {
            // Spectre de ce qui est envoyé aux enceintes, pour vérifier la référence à l'œil.
            // Affiché seulement pendant la lecture : à l'arrêt, il n'y aurait rien à montrer.
            if model.isPlaying {
                SpectrumView(levels: model.bandLevels, settings: model.settings)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .transition(.opacity)
            }
            controlsCard
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { AppBackground() }
        .animation(AppTheme.fade, value: model.isPlaying)
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
            MusicLibraryPicker { url, title in
                if let url {
                    model.load(url, title: title)
                } else {
                    model.libraryItemUnavailable()
                }
            }
        }
        #endif
        .sheet(isPresented: $showingGenerator) {
            TestSignalView { signal in model.loadSignal(signal) }
        }
        .onAppear { model.startBroadcasting() }
        .onDisappear { model.shutDown() }
    }

    /// Menu unique de choix du son : son libellé affiche le morceau en cours, et il propose
    /// les morceaux récents puis les autres sources.
    private var sourceMenu: some View {
        Menu {
            if !model.recentTracks.isEmpty {
                Section("Récents") {
                    ForEach(model.recentTracks) { track in
                        Button {
                            model.loadRecent(track)
                        } label: {
                            // La coche repère le morceau actuellement chargé.
                            if track.name == model.fileName {
                                Label(track.name, systemImage: "checkmark")
                            } else {
                                Text(track.name)
                            }
                        }
                    }
                }
            }
            Section {
                #if os(iOS)
                Button("Musique…", systemImage: "music.note") { showingLibrary = true }
                #endif
                Button("Fichiers…", systemImage: "folder") { showingImporter = true }
            }
            Section {
                Button("Bruit rose", systemImage: "waveform") { model.loadSignal(.noise(.pink)) }
                Button("Bruit blanc", systemImage: "waveform") { model.loadSignal(.noise(.white)) }
                Button("Générateur…", systemImage: "slider.horizontal.below.waveform") { showingGenerator = true }
            }
        } label: {
            Label(model.fileName ?? "Choisir un morceau", systemImage: "chevron.up.chevron.down")
                .labelStyle(TrailingIconLabelStyle())
                .font(.headline)
                .lineLimit(1)
        }
        .glassButtonStyle()
        .controlSize(.large)
        .accessibilityLabel("Morceau")
        .accessibilityValue(model.fileName ?? "Aucun morceau choisi")
    }

    /// Carte avec le morceau choisi, l'état de la connexion et les commandes de lecture.
    private var controlsCard: some View {
        VStack(spacing: 16) {
            Image(systemName: model.isPlaying ? "speaker.wave.3.fill" : "speaker.fill")
                .font(.system(size: 44))
                .foregroundStyle(model.isPlaying ? AppTheme.seafoam : .secondary)

            sourceMenu

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
    }
}

/// Place l'icône après le texte, comme l'indicateur d'un menu déroulant.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.title
            configuration.icon
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
    }
}

#if os(iOS)
/// Bouton système qui permet de choisir la sortie AirPlay / Bluetooth.
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

/// Permet de choisir un morceau dans la bibliothèque Musique. Seuls les morceaux téléchargés
/// sur l'appareil et sans DRM exposent une URL ; sinon le rappel reçoit `nil`.
/// Le titre est transmis à part : l'URL de la bibliothèque ne contient qu'un nom générique.
struct MusicLibraryPicker: UIViewControllerRepresentable {
    let onPick: (URL?, String?) -> Void
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
            let item = mediaItemCollection.items.first
            parent.onPick(item?.assetURL, item?.title)
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
