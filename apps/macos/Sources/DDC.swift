// Reads the brightness setting (VCP 0x10) of an external display over DDC/CI through
// IOAVService, which exists only on Apple Silicon.
//
// Byte layout, checksums and timing follow MonitorControl's Arm64DDC.swift
// (https://github.com/MonitorControl/MonitorControl, MIT License,
// Copyright (c) 2019-2023 MonitorControl contributors). See NOTICE.

import AppKit
import IOKit

enum DDCUnavailable: String, Error, Sendable {
    case unsupportedSystem = "DDC needs Apple Silicon"
    case noExternalDisplay = "No external display found"
    case noResponse = "The display does not answer DDC (dock, adapter or HDMI port?)"
}

enum DDC {
    static let luminance: UInt8 = 0x10

    /// Parses an 11-byte "VCP feature reply". Nil on a bad checksum, result code or VCP code,
    /// or when the display reports a maximum of 0.
    static func parseReply(_ reply: [UInt8], vcp: UInt8) -> (current: Int, max: Int)? {
        guard reply.count == 11 else { return nil }
        let checksum = reply[0..<10].reduce(UInt8(0x50)) { $0 ^ $1 }
        guard checksum == reply[10], reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else { return nil }
        let max = Int(reply[6]) << 8 | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        guard max > 0 else { return nil }
        return (current, max)
    }

    /// The "Get VCP feature" request as written to I²C address 0x37, data address 0x51.
    static func request(vcp: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, vcp, 0]
        packet[3] = packet[0..<3].reduce(UInt8(0x6E)) { $0 ^ $1 }
        return packet
    }
}

/// IOAVService access. All I/O runs on one serial queue, never on the main actor.
final class DDCReader: @unchecked Sendable {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let queue = DispatchQueue(label: "pixelvisor.ddc")
    private let create: CreateFn?
    private let write: I2CFn?
    private let read: I2CFn?
    private var services: [CGDirectDisplayID: CFTypeRef] = [:]  // queue only

    init() {
        let handle = dlopen(nil, RTLD_NOW)
        func symbol<T>(_ name: String, as: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        create = symbol("IOAVServiceCreateWithService", as: CreateFn.self)
        write = symbol("IOAVServiceWriteI2C", as: I2CFn.self)
        read = symbol("IOAVServiceReadI2C", as: I2CFn.self)
    }

    var isSupported: Bool {
        #if arch(arm64)
            create != nil && write != nil && read != nil
        #else
            false
        #endif
    }

    /// Forgets the display-to-service mapping; call after a display reconfiguration.
    func reset() {
        queue.async { self.services = [:] }
    }

    func readBrightness(display: CGDirectDisplayID) async -> Result<(current: Int, max: Int), DDCUnavailable> {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readSync(display)) }
        }
    }

    private func readSync(_ display: CGDirectDisplayID) -> Result<(current: Int, max: Int), DDCUnavailable> {
        guard isSupported, let write, let read else { return .failure(.unsupportedSystem) }
        if services[display] == nil { mapServices() }
        guard let service = services[display] else { return .failure(.noExternalDisplay) }

        for _ in 0..<3 {
            var packet = DDC.request(vcp: DDC.luminance)
            var reply = [UInt8](repeating: 0, count: 11)
            if write(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess {
                usleep(40_000)
                if read(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
                   let value = DDC.parseReply(reply, vcp: DDC.luminance) {
                    return .success(value)
                }
            }
            usleep(50_000)
        }
        return .failure(.noResponse)
    }

    /// Pairs external `DCPAVServiceProxy` entries with external displays in registry order.
    private func mapServices() {
        guard let create else { return }
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var found: [CFTypeRef] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if location == "External", let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                found.append(service)
            }
        }
        let displays = Displays.external()
        services = Dictionary(uniqueKeysWithValues: zip(displays, found).map { ($0, $1) })
    }
}

enum Displays {
    static func online() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func external() -> [CGDirectDisplayID] { online().filter { CGDisplayIsBuiltin($0) == 0 } }

    /// Stable key for stored settings; display IDs change across reboots and reconnects.
    static func uuid(_ display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    static func display(uuid: String?) -> CGDirectDisplayID? {
        online().first { Displays.uuid($0) == uuid }
    }

    @MainActor static func name(_ display: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
        return screen?.localizedName ?? "Display \(display)"
    }
}
