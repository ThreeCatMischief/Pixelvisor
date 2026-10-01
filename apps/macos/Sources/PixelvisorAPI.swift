// HTTP client for the control API (docs/protocol.md). One value per resolved device.

import CryptoKit
import Foundation
import os

enum PixelvisorError: Error, Equatable, LocalizedError {
    case unreachable
    case http(Int, String)
    case decoding
    case incompatibleAPI(Int)

    var errorDescription: String? {
        switch self {
        case .unreachable: "Device not reachable"
        case let .http(status, message): "HTTP \(status): \(message)"
        case .decoding: "Unexpected response from the device"
        case .incompatibleAPI: "Firmware is newer than this app. Update the app."
        }
    }
}

struct Endpoint: Hashable, Sendable, CustomStringConvertible {
    var host: String
    var port: Int

    /// Parses "host" or "host:port".
    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard let host = parts.first, !host.isEmpty, parts.count <= 2 else { return nil }
        let port = parts.count == 2 ? Int(parts[1]) : 80
        guard let port, (1...65535).contains(port) else { return nil }
        self.host = String(host)
        self.port = port
    }

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    var description: String { "\(host):\(port)" }
}

struct PixelvisorAPI: Sendable {
    static let supportedAPI = 1
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "pixelvisor", category: "api")

    let endpoint: Endpoint
    private let session: URLSession

    init(endpoint: Endpoint) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func info() async throws -> DeviceInfo {
        let info: DeviceInfo = try await request("GET", "/api/info")
        if info.api > Self.supportedAPI { throw PixelvisorError.incompatibleAPI(info.api) }
        return info
    }

    func state() async throws -> LightState { try await request("GET", "/api/state") }
    func patch(_ patch: StatePatch) async throws -> LightState { try await request("PATCH", "/api/state", body: patch) }
    func effects() async throws -> [EffectInfo] { try await request("GET", "/api/effects") }
    func config() async throws -> DeviceConfig { try await request("GET", "/api/config") }
    func patchConfig(_ patch: ConfigPatch) async throws -> DeviceConfig { try await request("PATCH", "/api/config", body: patch) }

    func reboot() async throws {
        let _: OkBody = try await request("POST", "/api/reboot")
    }

    func identify() async throws {
        let _: OkBody = try await request("POST", "/api/identify")
    }

    /// Clears the stored WiFi credentials; the device restarts into its setup portal.
    func forgetWifi() async throws {
        let _: OkBody = try await request("DELETE", "/api/wifi")
    }

    /// POST /api/ota with the raw image. The device restarts about 1 s after answering.
    func uploadFirmware(_ image: Data, progress: @escaping @Sendable (Double) -> Void) async throws {
        var req = urlRequest("POST", "/api/ota")
        req.timeoutInterval = 120
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.md5(image), forHTTPHeaderField: "X-Firmware-MD5")
        let delegate = UploadProgress(progress)
        let (data, response) = try await transport { try await session.upload(for: req, from: image, delegate: delegate) }
        let _: OkBody = try decode(data, response)
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Plumbing

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func urlRequest(_ method: String, _ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "http://\(endpoint)\(path)")!)
        req.httpMethod = method
        return req
    }

    private func request<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        try await send(urlRequest(method, path))
    }

    private func request<T: Decodable>(_ method: String, _ path: String, body: some Encodable) async throws -> T {
        var req = urlRequest(method, path)
        req.httpBody = try Self.encoder.encode(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await transport { try await session.data(for: req) }
        return try decode(data, response)
    }

    private func transport(_ call: () async throws -> (Data, URLResponse)) async throws -> (Data, URLResponse) {
        do {
            return try await call()
        } catch {
            Self.log.debug("\(endpoint, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw PixelvisorError.unreachable
        }
    }

    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? Self.decoder.decode(APIErrorBody.self, from: data))?.error ?? "request failed"
            throw PixelvisorError.http(status, message)
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            Self.log.error("decoding \(T.self): \(error.localizedDescription, privacy: .public)")
            throw PixelvisorError.decoding
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { report(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
}
