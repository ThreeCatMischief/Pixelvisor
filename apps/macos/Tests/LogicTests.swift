// Throttler, DDC parsing, brightness curve, mirror processing, color and sleep logic.

import Foundation
import Testing
@testable import Pixelvisor

/// Virtual time: `sleep` advances `now` and records the requested waits.
@MainActor
private final class VirtualClock {
    var now = ContinuousClock.now
    var sleeps: [Duration] = []

    func sleep(_ d: Duration) {
        sleeps.append(d)
        now += d
    }
}

@Suite @MainActor struct PatchThrottling {
    @Test func patchesSubmittedTogetherMergeIntoOne() async {
        var sent: [StatePatch] = []
        let throttler = PatchThrottler { sent.append($0) }
        throttler.submit(StatePatch(brightness: 10))
        throttler.submit(StatePatch(brightness: 20, transitionMs: 150))
        throttler.submit(StatePatch(color: RGB(1, 2, 3)))
        await throttler.idle()
        #expect(sent == [StatePatch(brightness: 20, color: RGB(1, 2, 3), transitionMs: 150)])
    }

    @Test func requestsStartAtLeast100msApartAndTheLastValueIsSent() async {
        let clock = VirtualClock()
        var sent: [StatePatch] = []
        var throttler: PatchThrottler!
        throttler = PatchThrottler(now: { clock.now }, sleep: { clock.sleep($0) }) { patch in
            sent.append(patch)
            if patch.brightness == 1 {  // more input arrives while the first request runs
                throttler.submit(StatePatch(brightness: 2))
                throttler.submit(StatePatch(brightness: 3))
            }
        }
        throttler.submit(StatePatch(brightness: 1))
        await throttler.idle()
        #expect(sent.map(\.brightness) == [1, 3])
        #expect(clock.sleeps == [.milliseconds(100)])
    }

    @Test func noWaitAfterTheIntervalHasPassed() async {
        let clock = VirtualClock()
        var sent = 0
        let throttler = PatchThrottler(now: { clock.now }, sleep: { clock.sleep($0) }) { _ in sent += 1 }
        throttler.submit(StatePatch(on: true))
        await throttler.idle()
        clock.now += .milliseconds(150)
        throttler.submit(StatePatch(on: false))
        await throttler.idle()
        #expect(sent == 2 && clock.sleeps.isEmpty)
    }
}

@Suite struct DDCParsing {
    /// A reply as a display sends it: source 0x6E, length 0x88, opcode 0x02, checksum 0x50 ^ ...
    private func reply(result: UInt8 = 0, vcp: UInt8 = 0x10, max: UInt16 = 100, current: UInt16 = 45) -> [UInt8] {
        var r: [UInt8] = [0x6E, 0x88, 0x02, result, vcp, 0x00, UInt8(max >> 8), UInt8(max & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF), 0]
        r[10] = r[0..<10].reduce(UInt8(0x50)) { $0 ^ $1 }
        return r
    }

    @Test func validReply() {
        let value = DDC.parseReply(reply(), vcp: 0x10)
        #expect(value?.current == 45 && value?.max == 100)
    }

    @Test func badChecksum() {
        var r = reply()
        r[10] ^= 1
        #expect(DDC.parseReply(r, vcp: 0x10) == nil)
    }

    @Test func wrongVCPCode() { #expect(DDC.parseReply(reply(vcp: 0x12), vcp: 0x10) == nil) }
    @Test func errorResult() { #expect(DDC.parseReply(reply(result: 1), vcp: 0x10) == nil) }
    @Test func zeroMaximum() { #expect(DDC.parseReply(reply(max: 0), vcp: 0x10) == nil) }
    @Test func shortReply() { #expect(DDC.parseReply([0x6E, 0x88], vcp: 0x10) == nil) }

    @Test func request() {
        #expect(DDC.request(vcp: 0x10) == [0x82, 0x01, 0x10, 0x6E ^ 0x82 ^ 0x01 ^ 0x10])
    }
}

@Suite struct BrightnessCurves {
    @Test func endpointsFloorAndCeiling() {
        let curve = BrightnessCurve(floor: 0.1, ceiling: 0.9, gamma: 1)
        #expect(curve.output(current: 0, max: 100, level: 1) == 26)
        #expect(curve.output(current: 100, max: 100, level: 1) == 230)
    }

    @Test func defaultsMapFullToFull() {
        #expect(BrightnessCurve().output(current: 100, max: 100, level: 1) == 255)
        #expect(BrightnessCurve().output(current: 0, max: 100, level: 1) == 13)
    }

    @Test func gammaAndLevel() {
        let curve = BrightnessCurve(floor: 0, ceiling: 1, gamma: 2)
        #expect(curve.output(current: 50, max: 100, level: 1) == 64)
        #expect(curve.output(current: 100, max: 100, level: 0.5) == 128)
        #expect(curve.output(current: 50, max: 0, level: 1) == 0)
    }
}

@Suite struct MirrorProcessing {
    private func close(_ a: Color3, _ b: Color3) -> Bool { ((a - b) * (a - b)).sum() < 1e-12 }

    private func reduce(_ pixels: [UInt8], width: Int, height: Int, zones: Int, saturation: Double = 1) -> [Color3] {
        pixels.withUnsafeBytes { ZoneReducer.reduce($0, width: width, height: height, bytesPerRow: width * 4, zones: zones, saturation: saturation) }
    }

    private func bgra(_ colors: [(UInt8, UInt8, UInt8)]) -> [UInt8] { colors.flatMap { [$0.2, $0.1, $0.0, 255] } }

    @Test func solid() {
        let zones = reduce(bgra(Array(repeating: (200, 100, 50), count: 8)), width: 4, height: 2, zones: 2)
        for z in zones { #expect(abs(z.x - 200.0 / 255) < 1e-9 && abs(z.y - 100.0 / 255) < 1e-9) }
    }

    @Test func splitHalves() {
        let zones = reduce(bgra([(255, 0, 0), (255, 0, 0), (0, 0, 255), (0, 0, 255)]), width: 4, height: 1, zones: 2)
        #expect(close(zones[0], Color3(1, 0, 0)) && close(zones[1], Color3(0, 0, 1)))
    }

    @Test func averagesInLinearLight() {
        let mixed = reduce(bgra([(0, 0, 0), (255, 255, 255)]), width: 2, height: 1, zones: 1)[0]
        #expect(abs(mixed.x - ColorMath.toSRGB(0.5)) < 1e-9)  // about 0.735, not 0.5
        #expect(mixed.x > 0.7)
    }

    @Test func saturationBoostIsClamped() {
        let boosted = ZoneReducer.boost(Color3(1, 0.5, 0.5), 3)
        #expect(boosted == Color3(1, 0, 0))
    }

    @Test func mappingRangeExtendAndOff() {
        let zones = [Color3(1, 0, 0), Color3(0, 0, 1)]
        let extend = LEDMapping.map(zones, ledCount: 6, start: 1, end: 4, outside: .extend)
        #expect(extend == [zones[0], zones[0], zones[0], zones[1], zones[1], zones[1]])
        let off = LEDMapping.map(zones, ledCount: 6, start: 1, end: 4, outside: .off)
        #expect(off.first == .zero && off.last == .zero && off[1] == zones[0])
    }

    @Test func mappingSpanOneAndFullStrip() {
        #expect(LEDMapping.map([Color3(1, 1, 1)], ledCount: 3, start: 0, end: 2, outside: .off) == Array(repeating: Color3(1, 1, 1), count: 3))
        let zones = (0..<43).map { Color3(Double($0), 0, 0) }
        #expect(LEDMapping.map(zones, ledCount: 43, start: 0, end: 42, outside: .off) == zones)
    }

    @Test func smootherPassesThroughWithoutTau() {
        var s = Smoother(tau: 0)
        _ = s.apply([.zero], dt: 1 / 30)
        #expect(s.apply([Color3(1, 1, 1)], dt: 1 / 30) == [Color3(1, 1, 1)])
    }

    @Test func smootherIsFrameRateIndependent() {
        var at30 = Smoother(tau: 0.12), at60 = Smoother(tau: 0.12)
        _ = at30.apply([.zero], dt: 0)
        _ = at60.apply([.zero], dt: 0)
        var a: [Color3] = [], b: [Color3] = []
        for _ in 0..<9 { a = at30.apply([Color3(1, 1, 1)], dt: 1.0 / 30) }
        for _ in 0..<18 { b = at60.apply([Color3(1, 1, 1)], dt: 1.0 / 60) }
        #expect(abs(a[0].x - b[0].x) < 1e-9)
    }
}

@Suite struct Colors {
    @Test func kelvinReferencePoints() {
        let k2000 = ColorMath.kelvin(2000), k6500 = ColorMath.kelvin(6500)
        #expect(k2000.r == 255 && (130...145).contains(k2000.g) && k2000.b < 30)
        #expect(k6500.r == 255 && k6500.g > 245 && k6500.b > 240)
        #expect(ColorMath.kelvin(4000).b < ColorMath.kelvin(5000).b)
    }

    @Test func hueSaturationRoundTrip() {
        let c = ColorMath.color(hue: 0.6, saturation: 0.5)
        let hs = ColorMath.hueSaturation(c)
        #expect(abs(hs.hue - 0.6) < 0.01 && abs(hs.saturation - 0.5) < 0.01)
    }
}

@Suite struct SleepHandling {
    @Test func oneOffAndOneOnForASleepSequence() {
        var s = SleepCoordinator()
        let actions = [PowerEvent.screensDidSleep, .locked, .willSleep, .didWake, .screensDidWake, .unlocked].map { s.handle($0) }
        #expect(actions == [.turnOff, nil, nil, nil, nil, .restore])
    }

    @Test func displaySleepAlone() {
        var s = SleepCoordinator()
        #expect(s.handle(.screensDidSleep) == .turnOff)
        #expect(s.handle(.screensDidWake) == .restore)
    }

    @Test func disabledSettingsAreIgnored() {
        var s = SleepCoordinator(offOnSleep: false, offOnLock: true)
        #expect(s.handle(.willSleep) == nil)
        #expect(s.handle(.didWake) == nil)
        #expect(s.handle(.sessionResigned) == .turnOff)
        #expect(s.handle(.sessionActivated) == .restore)
    }
}
