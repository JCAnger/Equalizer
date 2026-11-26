import AVFoundation
import Accelerate
import Observation
import os

/// Capture le son du microphone et produit un spectre à échelle logarithmique,
/// réparti en bandes selon les `SpectrumSettings` modifiables.
@Observable
final class AudioSpectrumAnalyzer {
    // MARK: - État observable

    /// Niveau (dB) de chaque bande, lissé par l'attaque et le relâchement.
    private(set) var bandLevels: [Float] = []
    private(set) var isRunning = false
    /// Message destiné à l'utilisateur lorsque la capture ne peut pas démarrer.
    private(set) var errorMessage: String?

    /// Moyenne à long terme des niveaux de bandes (dB), calculée tant que `isMeasuring` est vrai.
    private(set) var averageBandLevels: [Float] = []
    private(set) var isMeasuring = false
    /// Nombre d'images d'analyse incluses dans `averageBandLevels`.
    private(set) var measuredFrameCount = 0

    // MARK: - Propriétés internes

    /// Niveau (dB) sous lequel une image est considérée comme du silence et exclue de la moyenne.
    private let silenceThreshold = FrequencyResponseAnalysis.silenceThreshold

    /// Somme des puissances par bande, dont on tire la moyenne.
    private var powerSums: [Double] = []

    // Lu depuis le thread du tap audio : voir la note sur les accès concurrents dans `SpectrumSettings`.
    nonisolated(unsafe) private let settings: SpectrumSettings
    /// Moteur partagé avec le générateur de bruit : voir `SharedAudioEngine`.
    nonisolated private let audio: SharedAudioEngine
    private var engine: AVAudioEngine { audio.engine }

    // Configuré sur le main actor uniquement quand le tap n'est pas installé (avant le
    // démarrage ou après l'arrêt), puis utilisé depuis le thread audio temps réel pendant l'exécution.
    private let calculator = SpectrumBandCalculator()

    private static let logger = Logger(subsystem: "Equalizer", category: "Audio")

    /// Instant du dernier niveau consigné dans le journal pendant une mesure : un relevé toutes les
    /// deux secondes suffit à voir si le micro entend le bruit, sans inonder la console.
    @ObservationIgnored private var lastLevelLog = Date.distantPast

    init(settings: SpectrumSettings, audio: SharedAudioEngine) {
        self.settings = settings
        self.audio = audio
        // Quand le système arrête le moteur (changement de sortie AirPlay ou Bluetooth…), le format
        // de l'entrée a pu changer : le tap est réinstallé avant la relance.
        audio.setReconfigureHandler(for: .microphone) { [weak self] in
            self?.installTap()
        }
    }

    // MARK: - Cycle de vie de la capture

    /// Demande l'accès au microphone, active la session audio puis démarre le moteur.
    /// Les erreurs sont publiées dans `errorMessage`.
    func start() {
        guard !isRunning else { return }
        errorMessage = nil

        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            Self.logger.info("Autorisation du micro : \(granted)")
            guard granted else {
                await MainActor.run {
                    self.errorMessage = String(localized: "L'accès au microphone a été refusé. Autorisez-le dans Réglages.")
                }
                return
            }
            #if os(iOS)
            do {
                // L'activation de la session audio peut bloquer : on la sort du thread principal.
                try await Task.detached { try MeasurementAudioSession.activate() }.value
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
                return
            }
            #endif
            await MainActor.run {
                self.startEngine()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        // Le moteur ne s'arrête que si le générateur de bruit n'en a pas besoin non plus.
        audio.stop(for: .microphone)
        isRunning = false
        isMeasuring = false
    }

    // MARK: - Mesure moyenne

    /// Lance une nouvelle mesure : fait la moyenne de la musique captée à partir de maintenant.
    func startMeasurement() {
        resetMeasurement()
        lastLevelLog = .distantPast
        isMeasuring = true
    }

    func stopMeasurement() {
        isMeasuring = false
    }

    func resetMeasurement() {
        powerSums = []
        averageBandLevels = []
        measuredFrameCount = 0
    }

    /// Cumule les niveaux de bandes dans le domaine des puissances, pour que les passages
    /// forts pèsent correctement dans la moyenne (une moyenne directe de dB les sous-estimerait).
    @MainActor
    private func accumulate(_ newBands: [Float]) {
        guard isMeasuring, let loudest = newBands.max() else { return }
        // Montre si le micro entend quelque chose au-dessus du seuil de silence.
        let now = Date()
        if now.timeIntervalSince(lastLevelLog) >= 2 {
            lastLevelLog = now
            Self.logger.info("Niveau du micro pendant la mesure : bande la plus forte \(loudest) dB, seuil de silence \(self.silenceThreshold) dB")
        }
        guard loudest > silenceThreshold else { return }
        // Si le nombre de bandes a changé en cours de mesure, les anciennes sommes sont inutilisables.
        if powerSums.count != newBands.count {
            powerSums = [Double](repeating: 0, count: newBands.count)
            measuredFrameCount = 0
        }
        for i in newBands.indices {
            // dB -> puissance : 10^(dB / 10)
            powerSums[i] += pow(10, Double(newBands[i]) / 10)
        }
        measuredFrameCount += 1
        let frames = Double(measuredFrameCount)
        // Puissance moyenne -> dB : 10 · log10(moyenne)
        averageBandLevels = powerSums.map { Float(10 * log10($0 / frames)) }
    }

    // MARK: - Moteur audio

    private func startEngine() {
        #if os(iOS)
        // La session est configurée et activée dans `start()`, hors du thread principal.
        let session = AVAudioSession.sharedInstance()
        guard !session.currentRoute.inputs.isEmpty, session.isInputAvailable else {
            errorMessage = String(localized: "Aucun périphérique d'entrée audio disponible.")
            return
        }
        #endif

        // `AVAudioEngine.prepare()` et `.start()` lèvent une NSException (et non une erreur
        // Swift) si aucun périphérique d'entrée ou de sortie n'est disponible. Toutes les
        // vérifications doivent donc avoir lieu avant, sinon le processus plante.
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = String(localized: "Aucun périphérique d'entrée audio disponible.")
            return
        }

        installTap()

        do {
            try audio.start(for: .microphone)
            isRunning = true
            #if os(iOS)
            Self.logger.info("Micro démarré — \(MeasurementAudioSession.routeDescription(), privacy: .public)")
            #endif
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = error.localizedDescription
            Self.logger.error("Démarrage du micro impossible : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Installe (ou réinstalle) le tap d'analyse sur l'entrée du moteur. Aussi appelé par le moteur
    /// partagé quand le système a changé la configuration audio, depuis un autre thread.
    nonisolated private func installTap() {
        let input = audio.engine.inputNode
        // Sans entrée valide, installer un tap lèverait une exception : on ne le fait pas.
        guard input.inputFormat(forBus: 0).sampleRate > 0 else { return }

        // On retire un éventuel tap résiduel : en installer deux sur le même bus est une erreur fatale.
        input.removeTap(onBus: 0)
        calculator.configure(fftSize: settings.fftSize)
        // Format `nil` : le tap suit toujours le format actuel de l'entrée, même après un changement de sortie.
        input.installTap(onBus: 0, bufferSize: UInt32(settings.fftSize), format: nil) { [weak self] buffer, _ in
            self?.process(buffer: buffer, sampleRate: Float(buffer.format.sampleRate))
        }
    }

    /// Calcule les bandes d'un buffer. S'exécute sur le thread interne du tap audio,
    /// d'où le renvoi vers le main actor pour publier le résultat.
    nonisolated private func process(buffer: AVAudioPCMBuffer, sampleRate: Float) {
        guard let channelData = buffer.floatChannelData else { return }

        let config = settings.analysisConfig
        guard let bands = calculator.bands(
            samples: channelData[0],
            count: Int(buffer.frameLength),
            sampleRate: sampleRate,
            config: config
        ) else { return }

        Task { @MainActor [weak self] in
            self?.updateBandLevels(bands)
        }
    }

    /// Met à jour les niveaux affichés en les lissant : montée rapide (`attack`),
    /// descente lente (`release`), comme sur un vumètre analogique.
    @MainActor
    private func updateBandLevels(_ newBands: [Float]) {
        accumulate(newBands)
        // Première image, ou nombre de bandes modifié : pas de valeur précédente à lisser.
        guard bandLevels.count == newBands.count else {
            bandLevels = newBands
            return
        }
        let attack = settings.attack
        let release = settings.release
        for i in newBands.indices {
            let coeff = newBands[i] > bandLevels[i] ? attack : release
            bandLevels[i] += (newBands[i] - bandLevels[i]) * coeff
        }
    }
}
