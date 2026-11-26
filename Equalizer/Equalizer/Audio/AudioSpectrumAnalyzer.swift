import AVFoundation
import Accelerate
import Observation

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

    /// Les images dont la bande la plus forte est sous ce niveau (dB) sont considérées comme
    /// du silence et exclues de la moyenne, sinon les pauses tireraient le résultat vers le bas.
    private let silenceThreshold: Float = -80

    /// Somme des puissances par bande, dont on tire la moyenne.
    private var powerSums: [Double] = []

    // Lu depuis le thread du tap audio : voir la note sur les accès concurrents dans `SpectrumSettings`.
    nonisolated(unsafe) private let settings: SpectrumSettings
    private let engine = AVAudioEngine()

    // Configuré sur le main actor uniquement quand le tap n'est pas installé (avant le
    // démarrage ou après l'arrêt), puis utilisé depuis le thread audio temps réel pendant l'exécution.
    private let calculator = SpectrumBandCalculator()

    init(settings: SpectrumSettings) {
        self.settings = settings
    }

    // MARK: - Cycle de vie de la capture

    /// Demande l'accès au microphone, active la session audio puis démarre le moteur.
    /// Les erreurs sont publiées dans `errorMessage`.
    func start() {
        guard !isRunning else { return }
        errorMessage = nil

        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                await MainActor.run {
                    self.errorMessage = "L'accès au microphone a été refusé. Autorisez-le dans Réglages."
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
        engine.stop()
        isRunning = false
        isMeasuring = false
    }

    // MARK: - Mesure moyenne

    /// Lance une nouvelle mesure : fait la moyenne de la musique captée à partir de maintenant.
    func startMeasurement() {
        resetMeasurement()
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
        guard isMeasuring, let loudest = newBands.max(), loudest > silenceThreshold else { return }
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
            errorMessage = "Aucun périphérique d'entrée audio disponible."
            return
        }
        #endif

        // `AVAudioEngine.prepare()` et `.start()` lèvent une NSException (et non une erreur
        // Swift) si aucun périphérique d'entrée ou de sortie n'est disponible. Toutes les
        // vérifications doivent donc avoir lieu avant, sinon le processus plante.
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "Aucun périphérique d'entrée audio disponible."
            return
        }

        engine.prepare()

        calculator.configure(fftSize: settings.fftSize)

        // On retire un éventuel tap résiduel : en installer deux sur le même bus est une erreur fatale.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: UInt32(settings.fftSize), format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer, sampleRate: Float(format.sampleRate))
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            errorMessage = error.localizedDescription
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
