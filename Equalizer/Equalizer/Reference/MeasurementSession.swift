import Foundation
import Observation

/// Coordonne le micro (sonomètre) et le générateur de bruit : le micro écoute dès l'ouverture
/// de l'app, et « Mesurer » lance d'un coup le bruit choisi et la moyenne de l'analyse.
@Observable
final class MeasurementSession {
    let analyzer: AudioSpectrumAnalyzer
    let generator: NoiseGenerator

    var isMeasuring: Bool {
        analyzer.isMeasuring
    }

    init(settings: SpectrumSettings) {
        // Un seul moteur audio pour le micro et le bruit : deux moteurs se gênent mutuellement.
        let audio = SharedAudioEngine()
        analyzer = AudioSpectrumAnalyzer(settings: settings, audio: audio)
        generator = NoiseGenerator(settings: settings, player: ReferencePlayer(audio: audio))
    }

    /// Ouvre le micro. Les erreurs (accès refusé, pas d'entrée) sont publiées par l'analyseur.
    func startListening() {
        analyzer.start()
    }

    /// Lance ou arrête la mesure : le bruit choisi (s'il y en a un) et la moyenne du micro
    /// démarrent et s'arrêtent ensemble.
    func toggleMeasurement() {
        if isMeasuring {
            analyzer.stopMeasurement()
            generator.stopMeasurement()
            generator.pause()
        } else {
            // Une mesure compare le micro au bruit joué : sans bruit choisi, elle n'a pas de sens.
            guard generator.signal != nil else { return }
            analyzer.startMeasurement()
            generator.startMeasurement()
            generator.play()
        }
    }

    /// Change de signal. Une mesure en cours est remise à zéro : sa moyenne mélangerait deux signaux.
    func select(_ signal: GeneratedSignal?) {
        generator.select(signal)
        if isMeasuring {
            analyzer.resetMeasurement()
            generator.resetMeasurement()
        }
    }

    func shutDown() {
        analyzer.stop()
        generator.shutDown()
    }
}
