import XCTest
@testable import AirCursorCore

final class GestureTests: XCTestCase {
    private let all = Set(HeadGesture.allCases)

    /// Feeds (pitchRate, yawRate) pairs at 25 Hz and returns every gesture fired.
    private func run(
        _ detector: inout GestureDetector,
        rates: [(pitch: Double, yaw: Double)],
        roll: Double = 0,
        start: Double = 0,
        enabled: Set<HeadGesture>? = nil
    ) -> [GestureEvent] {
        var out: [GestureEvent] = []
        for (i, r) in rates.enumerated() {
            let t = start + Double(i) * 0.04
            let rates = AngularRates(timestamp: t, yaw: r.yaw, pitch: r.pitch, roll: 0)
            if let e = detector.process(rates: rates, rollDegrees: roll, enabled: enabled ?? all) { out.append(e) }
        }
        return out
    }

    func testNodDetected() {
        var d = GestureDetector()
        let events = run(&d, rates: [(0, 0), (-150, 10), (-180, 0), (40, 0), (160, 5), (0, 0)])
        XCTAssertEqual(events.map(\.gesture), [.nod])
        XCTAssertEqual(events.first?.startTime ?? -1, 0.04, accuracy: 1e-9)
    }

    func testNodWorksInEitherDirection() {
        var d = GestureDetector()
        XCTAssertEqual(run(&d, rates: [(160, 0), (-150, 0)]).map(\.gesture), [.nod])
    }

    func testSlowLookDownAndUpIsNotANod() {
        var d = GestureDetector()
        XCTAssertTrue(run(&d, rates: Array(repeating: (-60, 0), count: 10) + Array(repeating: (60, 0), count: 10)).isEmpty)
    }

    func testNodTooSlowToReturnIsIgnored() {
        var d = GestureDetector()
        let rates: [(pitch: Double, yaw: Double)] = [(-150, 0)] + Array(repeating: (0, 0), count: 20) + [(150, 0)]
        // The late "return" starts a new candidate instead of completing a nod.
        XCTAssertTrue(run(&d, rates: rates).isEmpty)
    }

    func testDiagonalMovementIsNotANod() {
        var d = GestureDetector()
        XCTAssertTrue(run(&d, rates: [(-150, 140), (150, -140)], enabled: [.nod]).isEmpty)
    }

    func testShakeDetected() {
        var d = GestureDetector()
        let events = run(&d, rates: [(0, 160), (0, 170), (0, -180), (0, -160), (0, 170), (0, 0)])
        XCTAssertEqual(events.map(\.gesture), [.shake])
    }

    func testSingleQuickTurnIsNotAShake() {
        var d = GestureDetector()
        XCTAssertTrue(run(&d, rates: [(0, 200), (0, 200), (0, -150), (0, 0), (0, 0)]).isEmpty)
    }

    func testDisabledGesturesDoNotFire() {
        var d = GestureDetector()
        XCTAssertTrue(run(&d, rates: [(-150, 0), (150, 0)], enabled: [.shake]).isEmpty)
    }

    func testCooldownPreventsDoubleFire() {
        var d = GestureDetector()
        let nodTwice: [(pitch: Double, yaw: Double)] = [(-150, 0), (150, 0), (-150, 0), (150, 0)]
        XCTAssertEqual(run(&d, rates: nodTwice).count, 1)
    }

    func testTiltFiresOnceAfterHold() {
        var s = GestureSettings()
        s.tiltAngle = 20
        s.tiltHold = 0.3
        var d = GestureDetector(settings: s)
        var events: [GestureEvent] = []
        var t = 0.0
        func feed(_ roll: Double, _ n: Int) {
            for _ in 0..<n {
                if let e = d.process(rates: AngularRates(timestamp: t, yaw: 0, pitch: 0, roll: 0), rollDegrees: roll, enabled: all) {
                    events.append(e)
                }
                t += 0.04
            }
        }
        feed(0, 5)       // establish neutral
        feed(30, 30)     // hold tilt ~1.2 s
        XCTAssertEqual(events.map(\.gesture), [.tiltRight])
        feed(0, 5)       // back to neutral re-arms
        feed(-30, 15)
        XCTAssertEqual(events.map(\.gesture), [.tiltRight, .tiltLeft])
    }

    func testSwapTiltDirection() {
        var s = GestureSettings()
        s.swapTiltDirection = true
        var d = GestureDetector(settings: s)
        var fired: HeadGesture?
        var t = 0.0
        for roll in [0.0] + Array(repeating: 30.0, count: 20) {
            if let e = d.process(rates: AngularRates(timestamp: t, yaw: 0, pitch: 0, roll: 0), rollDegrees: roll, enabled: all) {
                fired = e.gesture
            }
            t += 0.04
        }
        XCTAssertEqual(fired, .tiltLeft)
    }

    func testStaleNeutralRecovers() {
        var d = GestureDetector()
        var t = 0.0
        // Baseline captured at a weird angle (e.g. while inserting the AirPods)…
        _ = d.process(rates: AngularRates(timestamp: t, yaw: 0, pitch: 0, roll: 0), rollDegrees: 50, enabled: all)
        // …then the user sits upright for a while.
        for _ in 0..<150 {
            t += 0.04
            _ = d.process(rates: AngularRates(timestamp: t, yaw: 0, pitch: 0, roll: 0), rollDegrees: 0, enabled: all)
        }
        XCTAssertEqual(d.relativeRoll(0), 0, accuracy: 1)
        // And a real tilt from the new neutral still fires.
        var fired: HeadGesture?
        for _ in 0..<20 {
            t += 0.04
            if let e = d.process(rates: AngularRates(timestamp: t, yaw: 0, pitch: 0, roll: 0), rollDegrees: 30, enabled: all) { fired = e.gesture }
        }
        XCTAssertEqual(fired, .tiltRight)
    }

    func testBriefTiltDoesNotFire() {
        var d = GestureDetector()
        var t = 0.0
        var fired = false
        for roll in [0.0, 0, 30, 30, 0, 0] {
            if d.process(rates: AngularRates(timestamp: t, yaw: 0, pitch: 0, roll: 0), rollDegrees: roll, enabled: all) != nil { fired = true }
            t += 0.04
        }
        XCTAssertFalse(fired)
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
