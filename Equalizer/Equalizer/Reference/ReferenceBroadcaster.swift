import Foundation
import Network

/// Advertises the reference stream with Bonjour and sends each frame to every connected
/// measuring device.
nonisolated final class ReferenceBroadcaster: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ReferenceBroadcaster")
    private let encoder = JSONEncoder()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Called on a private queue whenever the number of connected devices changes.
    var onClientCountChange: (@Sendable (Int) -> Void)?
    /// Called on a private queue if the listener fails.
    var onFailure: (@Sendable (String) -> Void)?

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

    func send(_ frame: ReferenceFrame) {
        queue.async { [self] in
            guard !connections.isEmpty, var data = try? encoder.encode(frame) else { return }
            data.append(0x0A)
            for connection in connections.values {
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
    }

    // MARK: - Private (always on `queue`)

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                connections[id] = connection
                onClientCountChange?(connections.count)
            case .failed, .cancelled:
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
