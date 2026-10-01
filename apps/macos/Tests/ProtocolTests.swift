// Models, patches and DDP against protocol/fixtures, shared with the firmware tests.

import Foundation
import Testing
@testable import Pixelvisor

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("protocol/fixtures")

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(name))
}

private func json(_ data: Data) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

private func hex(_ s: String) -> [UInt8] {
    stride(from: 0, to: s.count, by: 2).map { i in
        let start = s.index(s.startIndex, offsetBy: i)
        return UInt8(s[start..<s.index(start, offsetBy: 2)], radix: 16)!
    }
}

@Suite struct ModelDecoding {
    @Test func info() throws {
        let info = try PixelvisorAPI.decoder.decode(DeviceInfo.self, from: fixture("info.json"))
        #expect(info.api == 1 && info.ledCount == 43 && info.ddp.port == 4048 && info.uptimeS == 86400)
    }

    @Test func state() throws {
        let state = try PixelvisorAPI.decoder.decode(LightState.self, from: fixture("state.json"))
        #expect(state.mode == .solid && state.color == RGB(255, 170, 90))
        #expect(state.effect == EffectState(id: "breathe", speed: 128, color2: .black))
        #expect(state.realtime == RealtimeState(active: false, source: nil))
    }

    @Test func config() throws {
        let config = try PixelvisorAPI.decoder.decode(DeviceConfig.self, from: fixture("config.json"))
        #expect(config.dataPin == 4 && config.colorOrder == "GRB" && config.gamma == 2.2 && config.rebootRequired == false)
    }

    @Test func effects() throws {
        let effects = try PixelvisorAPI.decoder.decode([EffectInfo].self, from: fixture("effects.json"))
        #expect(effects.map(\.id) == ["breathe", "rainbow", "gradient", "scan"])
        #expect(effects[3].uses("color2") && !effects[1].uses("color"))
    }
}

@Suite struct Patches {
    @Test func encodesOnlySetFieldsInSnakeCase() throws {
        let patch = StatePatch(brightness: 90, effect: EffectPatch(speed: 10), transitionMs: 150)
        let body = try json(PixelvisorAPI.encoder.encode(patch))
        #expect(body.count == 3)
        #expect(body["transition_ms"] as? Int == 150)
        #expect((body["effect"] as? [String: Any])?.count == 1)
        let config = try json(PixelvisorAPI.encoder.encode(ConfigPatch(ledCount: 60, maxCurrentMa: 0)))
        #expect(config["led_count"] as? Int == 60 && config["max_current_ma"] as? Int == 0 && config.count == 2)
    }

    @Test func mergeKeepsLaterValuesFieldByField() {
        var patch = StatePatch(brightness: 10, color: RGB(1, 2, 3), effect: EffectPatch(id: "scan"))
        patch.merge(StatePatch(brightness: 20, effect: EffectPatch(speed: 5)))
        #expect(patch == StatePatch(brightness: 20, color: RGB(1, 2, 3), effect: EffectPatch(id: "scan", speed: 5)))
    }

    /// The optimistic update must match what the firmware does with each valid patch.
    @Test func applyingMatchesFirmwareForValidFixtures() throws {
        let file = try json(fixture("state_patches.json"))
        var baseObject = file["base"] as! [String: Any]
        baseObject["rev"] = 0
        baseObject["realtime"] = ["active": false, "source": NSNull()]
        let base = try PixelvisorAPI.decoder.decode(LightState.self, from: JSONSerialization.data(withJSONObject: baseObject))
        for case let c as [String: Any] in file["cases"] as! [Any] where c["valid"] as? Bool == true {
            let patch = try PixelvisorAPI.decoder.decode(StatePatch.self, from: JSONSerialization.data(withJSONObject: c["patch"]!))
            let result = try json(PixelvisorAPI.encoder.encode(base.applying(patch)))
            for (key, value) in c["expect"] as! [String: Any] {
                #expect(NSDictionary(dictionary: [key: result[key] ?? NSNull()]).isEqual(to: [key: value]), "\(c["name"]!): \(key)")
            }
        }
    }
}

@Suite struct DDPEncoding {
    @Test func matchesFixture() throws {
        let file = try json(fixture("ddp.json"))
        let full = (file["cases"] as! [[String: Any]]).first { $0["name"] as? String == "full frame" }!
        let packet = DDP.packet(sequence: 1, rgb: [255, 0, 0, 0, 255, 0, 0, 0, 255])
        #expect([UInt8](packet) == hex(full["packet"] as! String))
    }

    @Test func sequenceCyclesOneToFifteen() {
        var s: UInt8 = 0
        var seen: [UInt8] = []
        for _ in 0..<16 {
            s = DDP.next(s)
            seen.append(s)
        }
        #expect(seen == Array(1...15) + [1])
    }

    @Test func lengthIsBigEndian() {
        let packet = [UInt8](DDP.packet(sequence: 1, rgb: [UInt8](repeating: 0, count: 480 * 3)))
        #expect(packet[8] == 0x05 && packet[9] == 0xA0)
    }
}

@Suite struct Endpoints {
    @Test func parses() {
        #expect(Endpoint("192.168.1.42:8080") == Endpoint(host: "192.168.1.42", port: 8080))
        #expect(Endpoint("pixelvisor.local") == Endpoint(host: "pixelvisor.local", port: 80))
        #expect(Endpoint("") == nil)
        #expect(Endpoint("host:99999") == nil)
    }
}
