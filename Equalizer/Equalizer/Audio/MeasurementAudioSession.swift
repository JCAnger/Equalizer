#if os(iOS)
import AVFoundation

/// Session audio commune au générateur de bruit et au sonomètre.
///
/// Les deux tournent en même temps dans l'app : une session `.record` couperait la sortie,
/// une session `.playback` couperait le micro. `.playAndRecord` permet d'émettre vers AirPlay
/// tout en écoutant avec le micro de l'appareil.
enum MeasurementAudioSession {
    /// Configure puis active la session. Peut bloquer : à appeler hors du thread principal.
    /// - Throws: l'erreur d'`AVAudioSession` si la configuration est refusée.
    nonisolated static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        // Le mode « mesure » désactive les traitements du signal (réduction de bruit,
        // contrôle automatique de gain) qui fausseraient l'analyse.
        // `.allowAirPlay` n'est accepté qu'avec `.playAndRecord`.
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.duckOthers, .allowAirPlay, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true)
    }
}
#endif
