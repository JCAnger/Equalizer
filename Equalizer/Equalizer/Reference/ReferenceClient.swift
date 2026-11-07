import Foundation
import Network

/// Finds a reference source on the local network and delivers its frames.
///
/// All Network framework callbacks run on a private queue, so this type is deliberately
/// not main-actor isolated. Callbacks are delivered from that queue.
nonisolated final class ReferenceClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ReferenceClient")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()

    // Set before `start()`.
    var onFrame: (@Sendable (ReferenceFrame) -> Void)?
    /// Called with the source's name when connected, or `nil` when the link is lost.
    var onConnectionChange: (@Sendable (String?) -> Void)?

    func start() {
        queue.async { [self] in
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

    // MARK: - Private (always on `queue`)

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
                if self.connection === connection {
                    self.connection = nil
                    buffer.removeAll()
                    onConnectionChange?(nil)
                    // The browser only reports changes, so look again for the source shortly.
                    retryConnection()
                }
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func retryConnection() {
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            guard connection == nil, let result = browser?.browseResults.first else { return }
            connect(to: result)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data, !data.isEmpty {
                consume(data)
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection)
            }
        }
    }

    /// Splits the stream on newlines and decodes each complete line as a frame.
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
