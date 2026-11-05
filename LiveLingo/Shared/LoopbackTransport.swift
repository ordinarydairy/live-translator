import Foundation
import Network

enum LoopbackTransport {
    static let framePort = NWEndpoint.Port(rawValue: 49_876)!
    static let stopPort = NWEndpoint.Port(rawValue: 49_877)!

    static func sendFrame(imageData: Data, observationsData: Data) {
        var jsonLength = UInt32(observationsData.count).bigEndian
        var imageLength = UInt32(imageData.count).bigEndian
        var packet = Data(bytes: &jsonLength, count: MemoryLayout<UInt32>.size)
        packet.append(Data(bytes: &imageLength, count: MemoryLayout<UInt32>.size))
        packet.append(observationsData)
        packet.append(imageData)
        send(packet, to: framePort)
    }

    static func sendStop() {
        send(Data("STOP".utf8), to: stopPort)
    }

    private static func send(_ data: Data, to port: NWEndpoint.Port) {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let queue = DispatchQueue(label: "LiveLingo.Loopback.Send")
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            connection.send(
                content: data,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
        connection.start(queue: queue)
    }
}

final class LoopbackFrameServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "LiveLingo.Loopback.Receive", qos: .userInitiated)
    var onFrame: ((Data, Data) -> Void)?

    func start() {
        guard listener == nil, let listener = try? NWListener(using: .tcp, on: LoopbackTransport.framePort) else { return }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(from: connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func receive(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, _ in
            var buffer = accumulated
            if let data { buffer.append(data) }
            if let frame = self?.decode(buffer) {
                self?.onFrame?(frame.image, frame.observations)
                connection.cancel()
            } else if !isComplete {
                self?.receive(from: connection, accumulated: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func decode(_ packet: Data) -> (image: Data, observations: Data)? {
        guard packet.count >= 8 else { return nil }
        let jsonLength = packet.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let imageLength = packet.dropFirst(4).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let total = 8 + Int(jsonLength) + Int(imageLength)
        guard packet.count >= total else { return nil }
        let jsonStart = 8
        let imageStart = jsonStart + Int(jsonLength)
        return (
            packet.subdata(in: imageStart..<total),
            packet.subdata(in: jsonStart..<imageStart)
        )
    }
}
