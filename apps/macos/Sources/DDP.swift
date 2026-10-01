// DDP realtime frames over UDP (docs/protocol.md, Realtime: DDP).

import Foundation
import Network

enum DDP {
    /// One frame in one packet: version 1 with PUSH, RGB 8 bit, default output, offset 0.
    static func packet(sequence: UInt8, rgb: [UInt8]) -> Data {
        var data = Data([0x41, sequence & 0x0F, 0x0B, 0x01, 0, 0, 0, 0, UInt8(rgb.count >> 8), UInt8(rgb.count & 0xFF)])
        data.append(contentsOf: rgb)
        return data
    }

    /// Sequence numbers cycle 1-15; 0 means unused.
    static func next(_ sequence: UInt8) -> UInt8 { sequence % 15 + 1 }
}

/// Sends frames to one device. Not thread-safe; owned by the MirrorEngine queue.
final class DDPSender {
    private let connection: NWConnection
    private var sequence: UInt8 = 0

    init(host: String, port: Int) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .udp)
        connection.start(queue: .global(qos: .userInteractive))
    }

    func send(_ rgb: [UInt8]) {
        sequence = DDP.next(sequence)
        connection.send(content: DDP.packet(sequence: sequence, rgb: rgb), completion: .idempotent)
    }

    func close() {
        connection.cancel()
    }
}
