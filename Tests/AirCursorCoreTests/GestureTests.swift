import XCTest
@testable import AirCursorCore

final class GestureTests: XCTestCase {
    private let all = Set(HeadGesture.allCases)
    private let hz = 25.0

    /// Feeds angle tracks (degrees) at 25 Hz; returns every gesture fired.
    private func feed(
        _ d: inout GestureDetector,
        pitch: [Double],
        yaw: [Double]? = nil,
        roll: [Double]? = nil,
        start: Double = 0,
        enabled: Set<HeadGesture>? = nil
    ) -> [GestureEvent] {
        var out: [GestureEvent] = []
        for i in pitch.indices {
            let s = MotionSample(
                timestamp: start + Double(i) / hz,
                yaw: AngleMath.radians(yaw?[i] ?? 0),
                pitch: AngleMath.radians(pitch[i]),
                roll: AngleMath.radians(roll?[i] ?? 0)
            )
            if let e = d.process(s, enabled: enabled ?? all) { out.append(e) }
        }
        return out
    }

    /// Flat, then a smooth dip of `depth` degrees lasting `duration` seconds, then flat.
    private func dip(_ depth: Double, over duration: Double, lead: Int = 5, tail: Int = 8) -> [Double] {
        let n = max(2, Int(duration * hz))
        let curve = (0...n).map { i in depth * sin(.pi * Double(i) / Double(n)) }
        return Array(repeating: 0, count: lead) + curve + Array(repeating: 0, count: tail)
    }

    func testNaturalNodDetected() {
        var d = GestureDetector()
        let events = feed(&d, pitch: dip(-12, over: 0.4))
        XCTAssertEqual(events.map(\.gesture), [.nod])
        XCTAssertEqual(events.first?.magnitude ?? 0, 12, accuracy: 1)
        // Starts at (or just before) the beginning of the dip, for cursor restore.
        XCTAssertLessThanOrEqual(events.first?.startTime ?? 99, 5 / hz + 0.01)
    }

    func testGentleNodDetected() {
        var d = GestureDetector()
        XCTAssertEqual(feed(&d, pitch: dip(-7, over: 0.5)).map(\.gesture), [.nod])
    }

    func testUpwardNodDetected() {
        var d = GestureDetector()
        XCTAssertEqual(feed(&d, pitch: dip(10, over: 0.4)).map(\.gesture), [.nod])
    }

    func testTinyJitterIsNotANod() {
        var d = GestureDetector()
        XCTAssertTrue(feed(&d, pitch: dip(-3, over: 0.3)).isEmpty)
    }

    func testSlowLookDownAndBackIsNotANod() {
        var d = GestureDetector()
        XCTAssertTrue(feed(&d, pitch: dip(-15, over: 2.0)).isEmpty)
    }

    func testLookingDownAndStayingIsNotANod() {
        var d = GestureDetector()
        let pitch = Array(repeating: 0.0, count: 5) + (0...10).map { -1.5 * Double($0) } + Array(repeating: -15.0, count: 30)
        XCTAssertTrue(feed(&d, pitch: pitch).isEmpty)
    }

    func testDiagonalMoveIsNotANod() {
        var d = GestureDetector()
        let pitch = dip(-10, over: 0.4)
        let yaw = pitch.indices.map { Double($0) * 1.5 }   // sweeping sideways ~37°/s
        XCTAssertTrue(feed(&d, pitch: pitch, yaw: yaw, enabled: [.nod]).isEmpty)
    }

    func testNodWithReboundFiresOnce() {
        var d = GestureDetector()
        // Real nods often overshoot upward on the way back before settling.
        let nod = dip(-12, over: 0.4, tail: 0) + dip(6, over: 0.3, lead: 0)
        XCTAssertEqual(feed(&d, pitch: nod).count, 1)
    }

    func testDisabledGesturesDoNotFire() {
        var d = GestureDetector()
        XCTAssertTrue(feed(&d, pitch: dip(-12, over: 0.4), enabled: [.shake]).isEmpty)
    }

    func testShakeDetected() {
        var d = GestureDetector()
        let n = Int(0.8 * hz)
        let yaw = Array(repeating: 0.0, count: 4) + (0...n).map { 15 * sin(2 * .pi * Double($0) / (0.5 * hz)) } + Array(repeating: 0.0, count: 4)
        let events = feed(&d, pitch: Array(repeating: 0, count: yaw.count), yaw: yaw)
        XCTAssertEqual(events.map(\.gesture), [.shake])
    }

    func testSingleLookAsideAndBackIsNotAShake() {
        var d = GestureDetector()
        let yaw = dip(-25, over: 0.6)
        XCTAssertTrue(feed(&d, pitch: Array(repeating: 0, count: yaw.count), yaw: yaw).isEmpty)
    }

    func testYawWrapAroundIsContinuous() {
        var d = GestureDetector()
        // Hovering around ±180° must not look like a 360° swing.
        let yaw = (0..<30).map { i in i % 2 == 0 ? 179.0 : -179.0 }
        XCTAssertTrue(feed(&d, pitch: Array(repeating: 0, count: yaw.count), yaw: yaw).isEmpty)
    }

    // MARK: Tilt

    private func tiltRun(_ d: inout GestureDetector, rolls: [Double], start: Double = 0) -> [GestureEvent] {
        feed(&d, pitch: Array(repeating: 0, count: rolls.count), roll: rolls, start: start)
    }

    func testTiltFiresOnceAfterHold() {
        var s = GestureSettings()
        s.tiltAngle = 20
        s.tiltHold = 0.3
        var d = GestureDetector(settings: s)
        var events = tiltRun(&d, rolls: Array(repeating: 0, count: 5) + Array(repeating: 30, count: 30))
        XCTAssertEqual(events.map(\.gesture), [.tiltRight])
        events += tiltRun(&d, rolls: Array(repeating: 0, count: 5) + Array(repeating: -30, count: 15), start: 35 / hz)
        XCTAssertEqual(events.map(\.gesture), [.tiltRight, .tiltLeft])
    }

    func testSwapTiltDirection() {
        var s = GestureSettings()
        s.swapTiltDirection = true
        var d = GestureDetector(settings: s)
        XCTAssertEqual(tiltRun(&d, rolls: [0] + Array(repeating: 30, count: 20)).map(\.gesture), [.tiltLeft])
    }

    func testBriefTiltDoesNotFire() {
        var d = GestureDetector()
        XCTAssertTrue(tiltRun(&d, rolls: [0, 0, 30, 30, 0, 0]).isEmpty)
    }

    func testStaleNeutralRecovers() {
        var d = GestureDetector()
        // Neutral captured at a weird angle (e.g. while inserting the AirPods)…
        _ = tiltRun(&d, rolls: [50])
        // …then the user sits upright for a while.
        _ = tiltRun(&d, rolls: Array(repeating: 0, count: 150), start: 1 / hz)
        XCTAssertEqual(d.relativeRoll(0), 0, accuracy: 1)
        // A real tilt from the new neutral still fires.
        let events = tiltRun(&d, rolls: Array(repeating: 30, count: 20), start: 151 / hz)
        XCTAssertEqual(events.map(\.gesture), [.tiltRight])
    }
}

final class DwellTests: XCTestCase {
    private func settings() -> DwellSettings {
        var s = DwellSettings()
        s.enabled = true
        s.duration = 1.0
        s.radius = 10
        return s
    }

    func testFiresOnceAfterMovingThenResting() {
        var d = DwellDetector(settings: settings())
        _ = d.update(position: Vec2(0, 0), time: 0)
        _ = d.update(position: Vec2(50, 0), time: 0.1)   // movement arms it
        var fires = 0
        var t = 0.1
        while t < 4 {
            t += 1.0 / 60
            if d.update(position: Vec2(52, 1), time: t).fired { fires += 1 }
        }
        XCTAssertEqual(fires, 1)
    }

    func testDoesNotFireWithoutMovement() {
        var d = DwellDetector(settings: settings())
        var t = 0.0
        while t < 3 {
            XCTAssertFalse(d.update(position: Vec2(5, 5), time: t).fired)
            t += 0.05
        }
    }

    func testContinuousMovementNeverFires() {
        var d = DwellDetector(settings: settings())
        var t = 0.0
        var x = 0.0
        while t < 3 {
            XCTAssertFalse(d.update(position: Vec2(x, 0), time: t).fired)
            t += 0.05
            x += 15
        }
    }

    func testProgressRevealsAndResetDisarms() {
        var d = DwellDetector(settings: settings())
        _ = d.update(position: .zero, time: 0)
        _ = d.update(position: Vec2(40, 0), time: 0)
        XCTAssertNil(d.update(position: Vec2(40, 0), time: 0.1).progress)
        XCTAssertEqual(d.update(position: Vec2(40, 0), time: 0.5).progress ?? 0, 0.5, accuracy: 1e-9)
        d.reset()
        XCTAssertFalse(d.update(position: Vec2(40, 0), time: 2).fired)
    }
}

final class SettingsTests: XCTestCase {
    func testRoundTrip() throws {
        var s = AppSettings()
        s.pointer.sensitivity = 2.5
        s.actions[.nod] = .doubleClick
        s.dwell.enabled = true
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), s)
    }

    func testMissingAndUnknownKeysFallBackToDefaults() throws {
        let json = #"{"pointer":{"sensitivity":3},"actions":{"nod":"rightClick","bogus":"leftClick","shake":"notAnAction"},"futureKey":1}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.pointer.sensitivity, 3)
        XCTAssertEqual(s.pointer.deadzone, PointerSettings().deadzone)
        XCTAssertEqual(s.actions[.nod], .rightClick)
        XCTAssertEqual(s.actions[.shake], ActionMap.defaults[.shake])
        XCTAssertEqual(s.gestures, GestureSettings())
    }

    func testActionMapQueries() {
        var m = ActionMap()
        XCTAssertTrue(m.headGestureCanToggleTracking)  // shake by default
        XCTAssertFalse(m.stemCanToggleTracking)
        m[.shake] = .none
        m[.nod] = .none
        XCTAssertFalse(m.headGestureCanToggleTracking)
        XCTAssertFalse(m.enabledHeadGestures.contains(.nod))
        m[.stemTriple] = .toggleTracking
        XCTAssertTrue(m.stemCanToggleTracking)
    }
}
