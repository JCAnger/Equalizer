import Foundation
import Observation

/// Côté main actor du lien de référence : conserve l'état de la connexion et, pendant une
/// mesure, la moyenne à long terme de ce que la source envoie aux enceintes.
@Observable
final class ReferenceReceiver {
    /// Nom de la source connectée, `nil` si aucune.
    private(set) var sourceName: String?
    private(set) var isMeasuring = false
    /// Moyenne à long terme (dB) de la référence, sur la même répartition en bandes que les réglages.
    private(set) var averageLevels: [Float] = []
    private(set) var frameCount = 0
    /// Niveaux (dB) lissés de ce que la source joue en ce moment, sur la même répartition en
    /// bandes que les réglages. Vide quand aucune source n'est connectée.
    private(set) var liveLevels: [Float] = []

    var isConnected: Bool { sourceName != nil }

    private let settings: SpectrumSettings
    private let client = ReferenceClient()
    private var powerSums: [Double] = []

    /// Les images dont la bande la plus forte est sous ce niveau (dB) sont considérées comme du silence.
    private let silenceThreshold: Float = -80

    init(settings: SpectrumSettings) {
        self.settings = settings
        // Le client appelle ses closures sur sa file privée : on repasse sur le main actor.
        client.onFrame = { [weak self] frame in
            Task { @MainActor [weak self] in
                self?.receive(frame)
            }
        }
        client.onConnectionChange = { [weak self] name in
            Task { @MainActor [weak self] in
                self?.sourceName = name
                if name == nil {
                    self?.liveLevels = []
                }
            }
        }
    }

    func startBrowsing() {
        client.start()
    }

    func stopBrowsing() {
        client.stop()
        isMeasuring = false
    }

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

    /// Traite une image reçue : met à jour l'affichage en direct, puis la moyenne si une mesure est en cours.
    private func receive(_ frame: ReferenceFrame) {
        // La source peut avoir d'autres réglages que cet appareil : on aligne ses bandes sur les nôtres.
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
