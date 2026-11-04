import XCTest
@testable import AirCursorCore

final class PointerTests: XCTestCase {
    func testDeadzoneHoldsStill() {
        var s = PointerSettings()
        s.deadzone = 5
        XCTAssertEqual(PointerMapper.axisSpeed(4.9, settings: s), 0)
        XCTAssertEqual(PointerMapper.axisSpeed(-4.9, settings: s), 0)
        XCTAssertGreaterThan(PointerMapper.axisSpeed(6, settings: s), 0)
    }

    func testSpeedIsSymmetricAndMonotonic() {
        let s = PointerSettings()
        var previous = 0.0
        for rate in stride(from: 5.0, through: 300, by: 5) {
            let v = PointerMapper.axisSpeed(rate, settings: s)
            XCTAssertEqual(v, -PointerMapper.axisSpeed(-rate, settings: s), accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(v, previous)
            previous = v
        }
    }

    func testSensitivityScalesLinearly() {
        var s = PointerSettings()
        let base = PointerMapper.axisSpeed(40, settings: s)
        s.sensitivity = 2
        XCTAssertEqual(PointerMapper.axisSpeed(40, settings: s), base * 2, accuracy: 1e-9)
    }

    func testDirectionsAndInversion() {
        var s = PointerSettings()
        s.deadzone = 0
        // Turn left (+yaw) → cursor left (−x). Look up (+pitch) → cursor up (−y).
        let rates = AngularRates(timestamp: 0, yaw: 30, pitch: 30, roll: 0)
        let v = PointerMapper.cursorVelocity(rates: rates, settings: s)
        XCTAssertLessThan(v.x, 0)
        XCTAssertLessThan(v.y, 0)

        s.invertHorizontal = true
        s.invertVertical = true
        let inv = PointerMapper.cursorVelocity(rates: rates, settings: s)
        XCTAssertEqual(inv.x, -v.x, accuracy: 1e-9)
        XCTAssertEqual(inv.y, -v.y, accuracy: 1e-9)
    }

    func testDifferentiatorHandlesWrapAround() {
        var d = MotionDifferentiator()
        XCTAssertNil(d.push(MotionSample(timestamp: 0, yaw: .pi - 0.01, pitch: 0, roll: 0)))
        let r = d.push(MotionSample(timestamp: 0.04, yaw: -.pi + 0.01, pitch: 0, roll: 0))
        // 0.02 rad over 0.04 s ≈ 28.6 deg/s, not a huge negative spin.
        XCTAssertEqual(r?.yaw ?? 0, AngleMath.degrees(0.02) / 0.04, accuracy: 1e-6)
    }

    func testDifferentiatorRejectsGaps() {
        var d = MotionDifferentiator()
        _ = d.push(MotionSample(timestamp: 0, yaw: 0, pitch: 0, roll: 0))
        XCTAssertNil(d.push(MotionSample(timestamp: 1.0, yaw: 1, pitch: 0, roll: 0)))
        XCTAssertNotNil(d.push(MotionSample(timestamp: 1.04, yaw: 1.01, pitch: 0, roll: 0)))
    }

    func testSmootherConvergesAndStopsWhenStale() {
        var s = PointerSmoother()
        s.setTarget(Vec2(1000, 0), at: 0)
        var t = 0.0
        for _ in 0..<12 { t += 1.0 / 120; _ = s.step(now: t, dt: 1.0 / 120, smoothing: 0.5) }
        XCTAssertEqual(s.velocity.x, 1000, accuracy: 30)

        // No new samples → decays to a full stop.
        for _ in 0..<120 { t += 1.0 / 120; _ = s.step(now: t, dt: 1.0 / 120, smoothing: 0.5) }
        XCTAssertEqual(s.velocity, .zero)
    }

    func testSmootherZeroSmoothingIsImmediate() {
        var s = PointerSmoother()
        s.setTarget(Vec2(120, -60), at: 0)
        let delta = s.step(now: 0.01, dt: 0.01, smoothing: 0)
        XCTAssertEqual(delta.x, 1.2, accuracy: 1e-9)
        XCTAssertEqual(delta.y, -0.6, accuracy: 1e-9)
    }

    func testCursorHistoryLookup() {
        var h = CursorHistory(capacity: 4)
        XCTAssertNil(h.position(at: 1))
        for i in 0..<6 { h.append(Vec2(Double(i), 0), at: Double(i)) }
        // Capacity 4 keeps t = 2...5.
        XCTAssertEqual(h.position(at: 3.5)?.x, 3)
        XCTAssertEqual(h.position(at: 100)?.x, 5)
        XCTAssertEqual(h.position(at: -1)?.x, 2)
    }
}
