import Foundation
import Network

/// Annonce le flux de référence via Bonjour et envoie chaque image à tous les appareils
/// de mesure connectés.
nonisolated final class ReferenceBroadcaster: @unchecked Sendable {
    /// File série : elle protège `listener` et `connections` sans verrou.
    private let queue = DispatchQueue(label: "ReferenceBroadcaster")
    private let encoder = JSONEncoder()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Appelé sur une file privée à chaque changement du nombre d'appareils connectés.
    var onClientCountChange: (@Sendable (Int) -> Void)?
    /// Appelé sur une file privée si l'écouteur échoue.
    var onFailure: (@Sendable (String) -> Void)?

    /// Démarre l'écoute TCP et la publication Bonjour.
    /// - Parameter serviceName: nom sous lequel la source apparaît chez les appareils de mesure.
    func start(serviceName: String) throws {
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: serviceName, type: ReferenceProtocol.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                self?.onFailure?(error.localizedDescription)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
            onClientCountChange?(0)
        }
    }

    /// Envoie une image à tous les clients. Sans client, l'image est ignorée sans être encodée.
    func send(_ frame: ReferenceFrame) {
        queue.async { [self] in
            guard !connections.isEmpty, var data = try? encoder.encode(frame) else { return }
            // Saut de ligne (0x0A) : délimiteur de messages que `ReferenceClient` attend pour découper le flux.
            data.append(0x0A)
            for connection in connections.values {
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
    }

    // MARK: - Privé (toujours sur `queue`)

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                // Le client n'est compté qu'une fois la connexion établie.
                connections[id] = connection
                onClientCountChange?(connections.count)
            case .failed, .cancelled:
                // Évite de notifier deux fois si la connexion n'était pas (ou plus) enregistrée.
                if connections.removeValue(forKey: id) != nil {
                    onClientCountChange?(connections.count)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}
