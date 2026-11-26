import AVFoundation
import os

/// Moteur audio unique, partagé par le micro (analyse) et le générateur de bruit.
///
/// Deux `AVAudioEngine` distincts se disputent les entrées et sorties de l'appareil : démarrer le
/// second laisse le premier muet, ou rend le second silencieux. Un seul moteur, avec un tap sur
/// l'entrée et un nœud source vers la sortie, fonctionne de façon fiable.
///
/// **La sortie n'est connectée que pendant le bruit, et un peu après.** Un moteur dont la sortie
/// est ouverte envoie du silence à l'enceinte : le micro tourne donc seul tant que le bruit n'a
/// jamais été lancé. Mais refermer la sortie dès l'arrêt du bruit rendait le lancement suivant
/// muet sur une enceinte AirPlay, qui n'accepte pas d'être reconnectée aussitôt. La sortie reste
/// donc ouverte après l'arrêt (le bruit est seulement coupé), et ne se referme qu'après
/// `outputIdleDelay` secondes sans bruit.
///
/// Chaque client (micro, générateur) déclare quand il a besoin du moteur, qui ne s'arrête que
/// lorsque plus personne ne l'utilise. Quand le système l'arrête (changement de sortie AirPlay ou
/// Bluetooth, interruption), il le relance après avoir laissé chaque client refaire ses connexions.
///
/// Les appels viennent de plusieurs threads (main actor, tâche détachée, notifications) : ce type
/// n'est donc volontairement pas isolé au main actor, et sérialise ses opérations avec un verrou.
nonisolated final class SharedAudioEngine: @unchecked Sendable {
    enum Client: Hashable {
        case microphone
        case generator
    }

    /// Durée, en secondes, pendant laquelle la sortie reste ouverte après l'arrêt du bruit.
    static let outputIdleDelay: TimeInterval = 60

    let engine = AVAudioEngine()

    var isRunning: Bool { engine.isRunning }

    /// Vrai quand le moteur tourne avec la sortie connectée : un nouveau bruit peut alors démarrer
    /// aussitôt, sans rouvrir la liaison avec l'enceinte.
    var isOutputOpen: Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return isOutputConnected && engine.isRunning
    }

    /// Exécute `body` en excluant les opérations du moteur (démarrage, arrêt, reconstruction après un
    /// changement de sortie), qui s'exécutent sur d'autres threads. À utiliser pour modifier le
    /// graphe audio, sinon la modification pourrait avoir lieu pendant une reconstruction.
    func withExclusiveAccess<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try body()
    }

    private static let logger = Logger(subsystem: "Equalizer", category: "Audio")

    /// Sérialise les opérations qui démarrent, arrêtent ou reconfigurent le moteur. Récursif : un
    /// client rappelé pendant une reconfiguration peut avoir besoin de reprendre le verrou.
    private let operationLock = NSRecursiveLock()
    private var activeClients: Set<Client> = []
    /// Vrai quand le mélangeur est connecté à la sortie.
    private var isOutputConnected = false
    private var reconfigureHandlers: [Client: @Sendable () -> Void] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Identifie la fermeture de sortie programmée : une fermeture déjà annulée ou remplacée ne fait rien.
    private var closeToken = 0
    private let idleQueue = DispatchQueue(label: "Equalizer.SharedAudioEngine.idle", qos: .utility)

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restartAfterSystemStop(reason: "changement de configuration")
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            // On ne relance qu'à la fin de l'interruption (appel, alarme…), pas à son début.
            if rawType == AVAudioSession.InterruptionType.ended.rawValue {
                self?.restartAfterSystemStop(reason: "fin d'interruption")
            }
        })
        #endif
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        engine.stop()
    }

    /// Enregistre ce que `client` doit refaire quand le moteur est reconstruit : reconnecter ses
    /// nœuds ou réinstaller ses taps, car les formats audio ont pu changer.
    func setReconfigureHandler(for client: Client, _ handler: @escaping @Sendable () -> Void) {
        operationLock.lock()
        defer { operationLock.unlock() }
        reconfigureHandlers[client] = handler
    }

    /// Déclare que `client` a besoin du moteur, et le démarre s'il ne tourne pas.
    ///
    /// Quand le générateur arrive alors que le micro fait déjà tourner le moteur, celui-ci est
    /// arrêté puis relancé avec la sortie : le micro est interrompu un court instant. Si la sortie
    /// est déjà ouverte (bruit arrêté depuis peu), rien n'est relancé.
    /// - Throws: l'erreur d'`AVAudioEngine` si le démarrage échoue.
    func start(for client: Client) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        if client == .generator {
            cancelScheduledClose()
        }
        activeClients.insert(client)
        if engine.isRunning {
            // Le moteur n'est reconstruit que si la présence de la sortie doit changer.
            guard activeClients.contains(.generator) != isOutputConnected else { return }
            engine.stop()
            try rebuildAndStart(reason: "relancé avec la sortie")
        } else {
            try startEngine()
        }
    }

    /// Déclare que `client` n'a plus besoin du moteur. Il s'arrête quand plus personne ne l'utilise ;
    /// si seul le micro reste, la sortie est refermée pour ne plus envoyer de silence à l'enceinte.
    /// - Parameters:
    ///   - client: le client qui se retire.
    ///   - keepOutputOpen: pour le générateur, garde la sortie ouverte `outputIdleDelay` secondes
    ///     au lieu de la refermer aussitôt (voir la description du type).
    func stop(for client: Client, keepOutputOpen: Bool = false) {
        operationLock.lock()
        defer { operationLock.unlock() }
        if client == .generator {
            if keepOutputOpen, activeClients.contains(.generator) {
                scheduleClose()
                return
            }
            cancelScheduledClose()
        }
        guard activeClients.remove(client) != nil else { return }
        if activeClients.isEmpty {
            engine.stop()
        } else if client == .generator, isOutputConnected, engine.isRunning {
            engine.stop()
            do {
                try rebuildAndStart(reason: "relancé sans la sortie")
            } catch {
                Self.logger.error("Relance du micro impossible : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Fermeture différée de la sortie

    /// Programme la fermeture de la sortie après `outputIdleDelay` secondes. Le verrou doit être pris.
    private func scheduleClose() {
        closeToken += 1
        let token = closeToken
        idleQueue.asyncAfter(deadline: .now() + Self.outputIdleDelay) { [weak self] in
            self?.closeOutputIfStillIdle(token: token)
        }
    }

    /// Annule la fermeture programmée, s'il y en a une. Le verrou doit être pris.
    private func cancelScheduledClose() {
        closeToken += 1
    }

    private func closeOutputIfStillIdle(token: Int) {
        operationLock.lock()
        defer { operationLock.unlock() }
        // Un nouveau bruit, ou une autre fermeture programmée, a pris le relais depuis.
        guard token == closeToken else { return }
        Self.logger.info("Sortie refermée après \(Int(Self.outputIdleDelay)) s sans bruit")
        stop(for: .generator)
    }

    // MARK: - Privé

    /// Connecte le mélangeur à la sortie quand le générateur est actif, et l'en détache sinon.
    /// Le moteur doit être arrêté.
    private func configureOutput() {
        let needsOutput = activeClients.contains(.generator)
        if needsOutput {
            // Reconnecté explicitement, avec le format actuel du matériel : après un changement de
            // sortie, l'ancienne connexion peut avoir un format périmé.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        } else if isOutputConnected {
            engine.disconnectNodeOutput(engine.mainMixerNode)
        }
        isOutputConnected = needsOutput
    }

    private func startEngine() throws {
        configureOutput()
        engine.prepare()
        try engine.start()
    }

    /// Relance le moteur arrêté par le système, si au moins un client en a encore besoin.
    private func restartAfterSystemStop(reason: String) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !activeClients.isEmpty, !engine.isRunning else { return }
        #if os(iOS)
        // Après une interruption, la session doit être réactivée. Cet appel bloque : il ne doit
        // jamais venir du fil principal, d'où sa présence ici (thread de notification) et non
        // dans `rebuildAndStart`, que le micro appelle aussi depuis le fil principal.
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        do {
            try rebuildAndStart(reason: "arrêté par le système (\(reason))")
        } catch {
            Self.logger.error("Relance du moteur audio impossible : \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Refait les connexions du moteur arrêté, laisse chaque client refaire les siennes, puis le
    /// démarre. Le verrou doit être pris par l'appelant.
    private func rebuildAndStart(reason: String) throws {
        Self.logger.info("Moteur audio \(reason, privacy: .public) : reconstruction")
        configureOutput()
        // Les formats ont pu changer : chaque client refait ses propres connexions et ses taps.
        for client in activeClients {
            reconfigureHandlers[client]?()
        }
        engine.prepare()
        try engine.start()
        Self.logger.info("Moteur audio relancé — sortie connectée = \(self.isOutputConnected)")
    }
}
