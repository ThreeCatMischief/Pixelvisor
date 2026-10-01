// Mirror screen: the top band of a display, reduced to per-LED colors and streamed over DDP.

import CoreMedia
import Foundation
import ScreenCaptureKit
import os

enum MirrorStyle: String, Codable, Sendable, CaseIterable {
    case zones, average
}

enum OutsideRange: String, Codable, Sendable, CaseIterable {
    case extend, off
}

struct MirrorSettings: Codable, Hashable, Sendable {
    var displayUUID: String?  // nil: main display
    var style = MirrorStyle.zones
    var bandHeight = 0.15     // share of the display height
    var ledStart = 0
    var ledEnd: Int?          // nil: last LED
    var outside = OutsideRange.extend
    var saturation = 1.3
    var smoothingMs = 120.0   // time constant; 0 = off
    var fps = 30
}

/// sRGB color, each channel 0...1.
typealias Color3 = SIMD3<Double>

enum ZoneReducer {
    private static let linear: [Double] = (0..<256).map { ColorMath.toLinear(Double($0) / 255) }

    /// Splits a BGRA buffer into `zones` equal columns, averages each in linear light, and
    /// boosts saturation (`s × saturation`, clamped).
    static func reduce(_ pixels: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                       zones: Int, saturation: Double) -> [Color3] {
        guard zones > 0, width > 0, height > 0 else { return [] }
        let bytes = pixels.bindMemory(to: UInt8.self)
        return (0..<zones).map { zone in
            let x0 = zone * width / zones, x1 = max((zone + 1) * width / zones, x0 + 1)
            var sum = Color3.zero
            for y in 0..<height {
                let row = y * bytesPerRow
                for x in x0..<min(x1, width) {
                    let p = row + x * 4
                    sum += Color3(linear[Int(bytes[p + 2])], linear[Int(bytes[p + 1])], linear[Int(bytes[p])])
                }
            }
            let mean = sum / Double((min(x1, width) - x0) * height)
            let srgb = Color3(ColorMath.toSRGB(mean.x), ColorMath.toSRGB(mean.y), ColorMath.toSRGB(mean.z))
            return boost(srgb, saturation)
        }
    }

    static func boost(_ c: Color3, _ saturation: Double) -> Color3 {
        let (h, s, v) = ColorMath.rgbToHSV(r: c.x, g: c.y, b: c.z)
        let (r, g, b) = ColorMath.hsvToRGB(h: h, s: min(s * saturation, 1), v: v)
        return Color3(r, g, b)
    }
}

enum LEDMapping {
    /// Places `zones` on LEDs `start...end`. LEDs outside get the nearest edge color or black.
    static func map(_ zones: [Color3], ledCount: Int, start: Int, end: Int, outside: OutsideRange) -> [Color3] {
        guard ledCount > 0, !zones.isEmpty else { return Array(repeating: .zero, count: max(ledCount, 0)) }
        let start = min(max(start, 0), ledCount - 1), end = min(max(end, start), ledCount - 1)
        let span = end - start + 1
        return (0..<ledCount).map { i in
            if i < start { return outside == .extend ? zones[0] : .zero }
            if i > end { return outside == .extend ? zones[zones.count - 1] : .zero }
            return zones[(i - start) * zones.count / span]
        }
    }
}

/// Per-channel exponential smoothing; α depends on the real frame interval, so the result
/// does not depend on the frame rate.
struct Smoother {
    var tau: Double  // seconds; 0 = off
    private var state: [Color3]?

    init(tau: Double) {
        self.tau = tau
    }

    mutating func apply(_ frame: [Color3], dt: Double) -> [Color3] {
        guard tau > 0, let previous = state, previous.count == frame.count else {
            state = frame
            return frame
        }
        let alpha = 1 - exp(-dt / tau)
        let next = zip(previous, frame).map { $0 + ($1 - $0) * alpha }
        state = next
        return next
    }
}

enum MirrorError: LocalizedError {
    case permissionDenied, displayNotFound

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Screen Recording permission is needed"
        case .displayNotFound: "The display for mirroring is not connected"
        }
    }
}

/// Runs capture and sending. All mutable state is confined to `queue`.
final class MirrorEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "pixelvisor", category: "mirror")

    /// LED colors, about 10 times per second, for the preview.
    var onPreview: (@Sendable ([RGB]) -> Void)?
    /// Capture stopped by the system, for example because the display went away.
    var onStopped: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "pixelvisor.mirror", qos: .userInteractive)
    private var stream: SCStream?
    private var timer: DispatchSourceTimer?
    private var sender: DDPSender?
    private var settings = MirrorSettings()
    private var ledCount = 0
    private var target: [Color3] = []
    private var smoother = Smoother(tau: 0)
    private var lastTick = ContinuousClock.now
    private var lastBytes: [UInt8] = []
    private var lastSentAt: ContinuousClock.Instant?
    private var resumeAt: ContinuousClock.Instant?
    private var ticks = 0

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    func start(settings: MirrorSettings, ledCount: Int, device: Endpoint, ddpPort: Int) async throws {
        stop()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw MirrorError.permissionDenied
        }
        let wanted = Displays.display(uuid: settings.displayUUID) ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == wanted }) else { throw MirrorError.displayNotFound }

        let end = settings.ledEnd.map { min($0, ledCount - 1) } ?? ledCount - 1
        let span = max(end - settings.ledStart + 1, 1)
        let config = SCStreamConfiguration()
        switch settings.style {
        case .zones:
            config.sourceRect = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height) * settings.bandHeight)
            config.width = min(4 * span, 256)
            config.height = 8
        case .average:
            config.width = 32
            config.height = 18
        }
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        config.showsCursor = false
        config.queueDepth = 3

        let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()

        queue.sync {
            self.stream = stream
            self.settings = settings
            self.ledCount = ledCount
            self.target = []
            self.smoother = Smoother(tau: settings.smoothingMs / 1000)
            self.sender = DDPSender(host: device.host, port: ddpPort)
            // After this Mac ended its own stream, the device ignores it until it pauses 1 s.
            self.resumeAt = self.lastSentAt.map { $0 + .seconds(1.1) }
            self.lastTick = .now
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(settings.fps))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        let stream: SCStream? = queue.sync {
            timer?.cancel()
            timer = nil
            sender?.close()
            sender = nil
            defer { self.stream = nil }
            return self.stream
        }
        if let stream { Task { try? await stream.stopCapture() } }
    }

    // MARK: - Queue

    private func tick() {
        let now = ContinuousClock.now
        let dt = Double((now - lastTick).components.attoseconds) / 1e18 + Double((now - lastTick).components.seconds)
        lastTick = now
        guard !target.isEmpty, let sender else { return }
        if let resumeAt, now < resumeAt { return }
        resumeAt = nil

        let end = settings.ledEnd.map { min($0, ledCount - 1) } ?? ledCount - 1
        let mapped = settings.style == .average
            ? LEDMapping.map(target, ledCount: ledCount, start: 0, end: ledCount - 1, outside: .extend)
            : LEDMapping.map(target, ledCount: ledCount, start: settings.ledStart, end: end, outside: settings.outside)
        let smoothed = smoother.apply(mapped, dt: dt)
        var bytes = [UInt8]()
        bytes.reserveCapacity(smoothed.count * 3)
        for c in smoothed {
            bytes.append(Self.byte(c.x))
            bytes.append(Self.byte(c.y))
            bytes.append(Self.byte(c.z))
        }

        // Unchanged frames are repeated once per second so the stream does not time out.
        if bytes != lastBytes || lastSentAt.map({ now - $0 >= .seconds(1) }) ?? true {
            sender.send(bytes)
            lastBytes = bytes
            lastSentAt = now
        }
        ticks += 1
        if ticks % 3 == 0, let onPreview {
            var preview = [RGB]()
            for i in stride(from: 0, to: bytes.count, by: 3) {
                preview.append(RGB(Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])))
            }
            onPreview(preview)
        }
    }

    private static func byte(_ v: Double) -> UInt8 { UInt8(min(max((v * 255).rounded(), 0), 255)) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        let end = settings.ledEnd.map { min($0, ledCount - 1) } ?? ledCount - 1
        let zones = settings.style == .average ? 1 : max(end - settings.ledStart + 1, 1)
        target = ZoneReducer.reduce(UnsafeRawBufferPointer(start: base, count: bytesPerRow * height),
                                    width: width, height: height, bytesPerRow: bytesPerRow,
                                    zones: zones, saturation: settings.saturation)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Self.log.error("capture stopped: \(error.localizedDescription, privacy: .public)")
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.sender?.close()
            self.sender = nil
            self.stream = nil
        }
        onStopped?(error.localizedDescription)
    }
}
