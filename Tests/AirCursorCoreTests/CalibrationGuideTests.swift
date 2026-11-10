import XCTest
@testable import AirCursorCore

final class CalibrationGuideTests: XCTestCase {
    func testMotionCuesDemonstrateEveryDirectionAndReturn() {
        let left = CalibrationMotionCue.frame(phase: .leftTilt, elapsed: 1)
        let right = CalibrationMotionCue.frame(phase: .rightTilt, elapsed: 1)
        XCTAssertGreaterThan(left.left.y, left.right.y)
        XCTAssertLessThan(right.left.y, right.right.y)
        for phase in [CalibrationPhase.leftTilt, .rightTilt] {
            for cycle in 0..<3 {
                let returned = CalibrationMotionCue.frame(phase: phase, elapsed: Double(cycle)*phase.duration/3+2.1)
                XCTAssertEqual(returned.left.y, 0, accuracy: 0.001)
                XCTAssertEqual(returned.right.y, 0, accuracy: 0.001)
            }
        }
        for phase in [CalibrationPhase.slowPointing, .fastPointing] {
            let offset = phase == .slowPointing ? 1.15 : 0.4
            let cues = (0..<4).map { CalibrationMotionCue.frame(phase: phase, elapsed: Double($0)*phase.duration/4+offset) }
            XCTAssertLessThan(cues[0].left.x+cues[0].right.x, 0)
            XCTAssertGreaterThan(cues[1].left.x+cues[1].right.x, 0)
            XCTAssertLessThan(cues[2].left.y, 0)
            XCTAssertGreaterThan(cues[3].left.y, 0)
        }
        let cues = (0..<6).map { CalibrationMotionCue.frame(phase: .repositioning, elapsed: Double($0)*2+0.8) }
        XCTAssertLessThan(cues[0].left.x+cues[0].right.x, 0)
        XCTAssertGreaterThan(cues[1].left.x+cues[1].right.x, 0)
        XCTAssertGreaterThan(cues[2].size, 1)
        XCTAssertLessThan(cues[3].size, 1)
        XCTAssertLessThan(cues[4].left.y, 0)
        XCTAssertGreaterThan(cues[5].left.y, 0)
    }

    func testPreviewKeepsFineControlOneToOneAndTravelUniformAcrossDisplays() {
        for display in [CalibrationDisplay(width: 1440,height: 900,pixelWidth: 2880,pixelHeight: 1800,scale: 2),
                        CalibrationDisplay(width: 3440,height: 1440), CalibrationDisplay(width: 900,height: 1600)] {
            let fine = CalibrationPreviewGeometry(display: display, mode: .precision)
            XCTAssertEqual(fine.scale, 1)
            let travel = CalibrationPreviewGeometry(display: display, mode: .travel)
            XCTAssertLessThanOrEqual(travel.size.x, 520)
            XCTAssertLessThanOrEqual(travel.size.y, 220)
            XCTAssertEqual(travel.size.x / travel.size.y, display.width / display.height, accuracy: 0.001)
            XCTAssertEqual(travel.size.x / travel.scale, display.width, accuracy: 0.001)
            for target in travel.targets { XCTAssertEqual(travel.clamp(target), target) }
            let edge = travel.clamp(Vec2(-1000,1000))
            XCTAssertGreaterThan(edge.x, travel.origin.x)
            XCTAssertLessThan(edge.y, travel.origin.y+travel.size.y)
        }
    }
}
