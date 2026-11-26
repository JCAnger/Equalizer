import Foundation
import Observation
import os

/// Pilote le générateur de bruit : choix du signal, lecture et niveaux de ce qui est envoyé
/// aux enceintes. Ces niveaux servent de référence à la courbe du sonomètre et, pendant une
/// mesure, à la moyenne à long terme utilisée par l'analyse des enceintes.
@Observable
final class NoiseGenerator {
    /// Signal choisi, `nil` tant que l'utilisateur n'en a pas sélectionné.
    private(set) var signal: GeneratedSignal?
    private(set) var isPlaying = false {
        didSet {
            // Vidé à l'arrêt pour qu'une reprise ne montre pas un spectre périmé.
            if !isPlaying { liveLevels = [] }
        }
    }
    /// Message destiné à l'utilisateur lorsque la lecture ne peut pas démarrer.
    private(set) var errorMessage: String?
    /// Sortie vers laquelle le son est envoyé, affichée pour aider à diagnostiquer un silence.
    private(set) var outputName: String?
    /// Niveaux (dB) lissés de ce qui est joué en ce moment, sur la même répartition en bandes
    /// que les réglages. Vide tant que rien n'est joué.
    private(set) var liveLevels: [Float] = []

    private(set) var isMeasuring = false
    /// Moyenne à long terme (dB) du bruit joué, calculée tant que `isMeasuring` est vrai.
    private(set) var averageLevels: [Float] = []
    /// Nombre d'images incluses dans `averageLevels`.
    private(set) var frameCount = 0

    /// Niveau (dB) sous lequel une image est considérée comme du silence et exclue de la moyenne.
    private let silenceThreshold = FrequencyResponseAnalysis.silenceThreshold

    private static let logger = Logger(subsystem: "Equalizer", category: "Audio")

    /// Vrai une fois le premier niveau du bruit généré consigné dans le journal, pour chaque lecture.
    @ObservationIgnored private var hasLoggedFrame = false

    /// Vrai de la demande de lecture jusqu'à la demande d'arrêt, même si le moteur n'a pas encore démarré.
    private var wantsPlayback = false

    private let settings: SpectrumSettings
    private let player: any SignalPlaying
    /// Somme des puissances par bande, dont on tire la moyenne.
    private var powerSums: [Double] = []

    init(settings: SpectrumSettings, player: any SignalPlaying) {
        self.settings = settings
        self.player = player
        // Les images arrivent d'un thread audio : on repasse sur le main actor avant de toucher à l'état.
        player.onFrame = { [weak self] frame in
            Task { @MainActor [weak self] in
                self?.receive(frame)
            }
        }
    }

    // MARK: - Lecture

    /// Choisit le signal à jouer, ou aucun (`nil`). Si le bruit jouait déjà, il reprend avec
    /// le nouveau signal, pour que l'on puisse comparer plusieurs signaux sans tout relancer.
    func select(_ signal: GeneratedSignal?) {
        errorMessage = nil
        let shouldResume = wantsPlayback
        wantsPlayback = false
        if let signal {
            player.loadSignal(signal, config: settings.analysisConfig)
        } else {
            player.stop()
        }
        self.signal = signal
        isPlaying = false
        if shouldResume { play() }
    }

    /// Lance le signal choisi. Sans effet si aucun signal n'est choisi.
    func play() {
        guard signal != nil, !wantsPlayback else {
            Self.logger.info("Lecture ignorée : signal choisi = \(self.signal != nil), déjà demandée = \(self.wantsPlayback)")
            return
        }
        errorMessage = nil
        wantsPlayback = true
        hasLoggedFrame = false
        Self.logger.info("Lecture demandée : \(self.signal?.title ?? "-", privacy: .public)")
        Task {
            do {
                // L'activation de la session audio peut bloquer : on la sort du thread principal.
                try await Task.detached { [player] in try player.play() }.value
                // L'arrêt a pu être demandé pendant l'activation de la session.
                guard wantsPlayback else {
                    Self.logger.info("Arrêt demandé pendant le démarrage : lecture suspendue")
                    player.pause()
                    return
                }
                isPlaying = true
                outputName = player.outputName
                Self.logger.info("Lecture démarrée — \(self.outputName ?? "sortie inconnue", privacy: .public)")
            } catch {
                wantsPlayback = false
                errorMessage = error.localizedDescription
                Self.logger.error("Échec de la lecture : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func pause() {
        wantsPlayback = false
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
    }

    func shutDown() {
        wantsPlayback = false
        player.stop()
        isPlaying = false
        isMeasuring = false
    }

    // MARK: - Mesure moyenne

    func startMeasurement() {
        resetMeasurement()
        isMeasuring = true
    }

    func stopMeasurement() {
        isMeasuring = false
    }

    func resetMeasurement() {
        powerSums = []
        averageLevels = []
        frameCount = 0
    }

    // MARK: - Traitement des images

    /// Traite une image : met à jour l'affichage en direct, puis la moyenne si une mesure est en cours.
    private func receive(_ frame: ReferenceFrame) {
        // Ignore les images arrivées juste après une pause.
        guard isPlaying else { return }

        // Montre si le moteur produit réellement du signal, indépendamment de la sortie audio.
        if !hasLoggedFrame {
            hasLoggedFrame = true
            Self.logger.info("Premier niveau du bruit généré : bande la plus forte \(frame.bands.max() ?? -.infinity) dB")
        }

        // Les réglages ont pu changer depuis le choix du signal : on aligne les bandes sur les actuels.
        let bands = frame.resampled(
            bandCount: settings.numberOfBands,
            minFrequency: settings.minFrequency,
            maxFrequency: settings.maxFrequency
        )
        updateLiveLevels(bands)

        // Le silence est testé sur les bandes d'origine, avant rééchantillonnage.
        guard isMeasuring, let loudest = frame.bands.max(), loudest > silenceThreshold else { return }

        // Moyenne dans le domaine des puissances, comme dans `AudioSpectrumAnalyzer.accumulate`.
        if powerSums.count != bands.count {
            powerSums = [Double](repeating: 0, count: bands.count)
            frameCount = 0
        }
        for i in bands.indices {
            powerSums[i] += pow(10, Double(bands[i]) / 10)
        }
        frameCount += 1
        let frames = Double(frameCount)
        averageLevels = powerSums.map { Float(10 * log10($0 / frames)) }
    }

    /// Même lissage attaque/relâchement que la courbe du microphone, pour que les deux bougent de la même façon.
    private func updateLiveLevels(_ bands: [Float]) {
        guard liveLevels.count == bands.count else {
            liveLevels = bands
            return
        }
        for i in bands.indices {
            let coefficient = bands[i] > liveLevels[i] ? settings.attack : settings.release
            liveLevels[i] += (bands[i] - liveLevels[i]) * coefficient
        }
    }
}
