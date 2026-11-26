#if os(iOS)
import AVFoundation
import os

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

    /// Si la sortie est AirPlay, la bascule un instant sur le haut-parleur de l'appareil puis la
    /// rétablit. C'est ce que fait un changement de sortie manuel (choisir « iPhone » puis revenir
    /// à l'enceinte), seul moyen constaté de débloquer une liaison AirPlay restée muette depuis le
    /// lancement de l'app : le bruit était produit, mais l'enceinte ne jouait rien.
    ///
    /// Bloque environ une seconde : à appeler hors du fil principal, et quand le moteur n'envoie
    /// aucun son à la sortie (sinon le bruit sortirait un instant sur l'appareil).
    nonisolated static func renewAirPlayRoute() {
        let session = AVAudioSession.sharedInstance()
        func isAirPlay() -> Bool {
            session.currentRoute.outputs.contains { $0.portType == .airPlay }
        }
        guard isAirPlay() else { return }

        do {
            try session.overrideOutputAudioPort(.speaker)
            logger.info("Sortie basculée un instant — \(routeDescription(), privacy: .public)")
            Thread.sleep(forTimeInterval: 0.5)
            try session.overrideOutputAudioPort(.none)
        } catch {
            logger.error("Bascule de la sortie impossible : \(error.localizedDescription, privacy: .public)")
            return
        }
        // La route met un instant à revenir sur AirPlay.
        let deadline = Date().addingTimeInterval(3)
        while !isAirPlay(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        logger.info("Sortie rétablie — \(routeDescription(), privacy: .public)")
    }

    nonisolated private static let logger = Logger(subsystem: "Equalizer", category: "Audio")

    /// Entrées et sorties audio actuelles, pour le journal de diagnostic.
    nonisolated static func routeDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let describe: (AVAudioSessionPortDescription) -> String = { "\($0.portName) (\($0.portType.rawValue))" }
        let inputs = route.inputs.map(describe).joined(separator: ", ")
        let outputs = route.outputs.map(describe).joined(separator: ", ")
        return "entrées : \(inputs) · sorties : \(outputs)"
    }
}
#endif
