// Bonjour discovery of `_pixelvisor._tcp` and resolution of a service to host:port.

import Foundation
import Network
import os

struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    let id: String  // TXT `id`, stable across renames
    let name: String
    let endpoint: NWEndpoint
    let txt: [String: String]
}

@MainActor @Observable
final class DeviceBrowser {
    private(set) var devices: [DiscoveredDevice] = []
    @ObservationIgnored private var browser: NWBrowser?
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "pixelvisor", category: "discovery")

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_pixelvisor._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state { Self.log.error("browser failed: \(error.localizedDescription, privacy: .public)") }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func restart() {
        browser?.cancel()
        browser = nil
        start()
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        devices = results.compactMap { result in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata { txt = record.dictionary }
            return DiscoveredDevice(id: txt["id"] ?? name, name: name, endpoint: result.endpoint, txt: txt)
        }
        .sorted { $0.name < $1.name }
    }
}

enum DeviceResolver {
    /// Opens a short-lived TCP connection to the service and reads the peer address, IPv4
    /// preferred. Requests then go to that address instead of a `.local` lookup each time.
    static func resolve(_ endpoint: NWEndpoint, timeout: Duration = .seconds(3)) async throws -> Endpoint {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: params)
        let once = Once<Endpoint>()
        defer { connection.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                        let address = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                        once.resume(.success(Endpoint(host: address, port: Int(port.rawValue))))
                    } else {
                        once.resume(.failure(PixelvisorError.unreachable))
                    }
                case .failed, .cancelled:
                    once.resume(.failure(PixelvisorError.unreachable))
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                once.resume(.failure(PixelvisorError.unreachable))
            }
        }
    }
}

/// Resumes a continuation exactly once, from any thread.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.withLock { continuation = c }
    }

    func resume(_ result: Result<T, Error>) {
        let c: CheckedContinuation<T, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
    }
}
