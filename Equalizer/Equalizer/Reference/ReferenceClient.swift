import Foundation
import Network

/// Trouve une source de référence sur le réseau local et en reçoit les images.
///
/// Tous les rappels du framework Network s'exécutent sur une file privée : ce type n'est donc
/// volontairement pas isolé au main actor. Les closures sont appelées depuis cette file.
nonisolated final class ReferenceClient: @unchecked Sendable {
    /// File série : elle protège l'état mutable ci-dessous sans verrou.
    private let queue = DispatchQueue(label: "ReferenceClient")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    /// Octets reçus mais pas encore découpés en lignes complètes (un message peut arriver en plusieurs morceaux).
    private var buffer = Data()

    // À renseigner avant `start()`.
    var onFrame: (@Sendable (ReferenceFrame) -> Void)?
    /// Appelé avec le nom de la source à la connexion, ou avec `nil` quand le lien est perdu.
    var onConnectionChange: (@Sendable (String?) -> Void)?

    func start() {
        queue.async { [self] in
            // Une seule recherche à la fois.
            guard browser == nil else { return }
            let browser = NWBrowser(for: .bonjour(type: ReferenceProtocol.serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.handle(results: results)
            }
            browser.start(queue: queue)
            self.browser = browser
        }
    }

    func stop() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            connection?.cancel()
            connection = nil
            buffer.removeAll()
            onConnectionChange?(nil)
        }
    }

    // MARK: - Privé (toujours sur `queue`)

    /// Se connecte à la première source trouvée, sauf si une connexion existe déjà.
    private func handle(results: Set<NWBrowser.Result>) {
        guard connection == nil, let result = results.first else { return }
        connect(to: result)
    }

    private func connect(to result: NWBrowser.Result) {
        var name = "Source"
        if case let .service(serviceName, _, _, _) = result.endpoint {
            name = serviceName
        }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                onConnectionChange?(name)
                receive(on: connection)
            case .failed, .cancelled:
                // On ignore l'échec d'une ancienne connexion déjà remplacée par une autre.
                if self.connection === connection {
                    self.connection = nil
                    buffer.removeAll()
                    onConnectionChange?(nil)
                    // Le navigateur ne signale que les changements : on cherche à nouveau la source peu après.
                    retryConnection()
                }
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    /// Retente une connexion après un court délai, pour ne pas boucler sur une source indisponible.
    private func retryConnection() {
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            guard connection == nil, let result = browser?.browseResults.first else { return }
            connect(to: result)
        }
    }

    /// Lit le flux en continu : chaque lecture programme la suivante tant que la connexion vit.
    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            // Ignore les données d'une connexion qui n'est plus la connexion courante.
            guard let self, let connection, self.connection === connection else { return }
            if let data, !data.isEmpty {
                consume(data)
            }
            if isComplete || error != nil {
                // L'annulation déclenche `.cancelled`, ce qui lance la reconnexion.
                connection.cancel()
            } else {
                receive(on: connection)
            }
        }
    }

    /// Découpe le flux sur les sauts de ligne et décode chaque ligne complète en image.
    /// Une ligne illisible est simplement ignorée : mieux vaut perdre une image que couper le flux.
    private func consume(_ data: Data) {
        buffer.append(data)
        let decoder = JSONDecoder()
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let frame = try? decoder.decode(ReferenceFrame.self, from: line) {
                onFrame?(frame)
            }
        }
    }
}
