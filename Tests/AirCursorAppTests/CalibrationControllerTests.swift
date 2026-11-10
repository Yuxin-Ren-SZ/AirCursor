import XCTest
@testable import AirCursor
import AirCursorCore

@MainActor
final class CalibrationControllerTests: XCTestCase {
    func testNoSignalCannotStartRecording() {
        let calibration = MotionCalibrationController()
        calibration.begin()
        calibration.startRecording()
        XCTAssertTrue(calibration.isActive)
        XCTAssertFalse(calibration.isRecording)
        XCTAssertEqual(calibration.countdown, 0)
        XCTAssertTrue(calibration.status.contains("Waiting"))
        calibration.finish()
    }

    func testRetryClearsAnalysisErrors() {
        let calibration = MotionCalibrationController()
        calibration.begin()
        calibration.analyze(using: AppSettings(), screenWidth: 1440)
        XCTAssertFalse(calibration.issues.isEmpty)
        calibration.select(.slowPointing)
        XCTAssertTrue(calibration.issues.isEmpty)
        XCTAssertEqual(calibration.phase, .slowPointing)
        XCTAssertNil(calibration.report)
        calibration.finish()
    }

    func testSourceChangeInvalidatesSessionUntilRestart() {
        let calibration = MotionCalibrationController()
        calibration.begin()
        calibration.push(MotionSample(timestamp: 0, yaw: 0, pitch: 0, roll: 0, sourceID: "one"), hostTime: 0)
        calibration.push(MotionSample(timestamp: 0.04, yaw: 0, pitch: 0, roll: 0, sourceID: "two"), hostTime: 0.04)
        XCTAssertFalse(calibration.issues.isEmpty)
        XCTAssertNil(calibration.report)
        calibration.analyze(using: AppSettings(), screenWidth: 1440)
        XCTAssertNil(calibration.report)
        calibration.select(.neutral)
        calibration.startRecording()
        XCTAssertEqual(calibration.countdown, 0)
        calibration.finish()
        XCTAssertTrue(calibration.history.isEmpty)
        XCTAssertTrue(calibration.completed.isEmpty)
        XCTAssertFalse(calibration.live.fresh)
    }

    func testSignalLossStopsPreviewAndMarksReadoutStale() {
        let calibration = MotionCalibrationController()
        calibration.begin()
        calibration.push(MotionSample(timestamp: 0, yaw: 0, pitch: 0, roll: 0), hostTime: 1)
        XCTAssertTrue(calibration.live.fresh)
        calibration.advance(now: 1.4)
        XCTAssertFalse(calibration.live.fresh)
        calibration.finish()
    }

    func testHeadphoneDisconnectInvalidatesCapturedReference() {
        let calibration = MotionCalibrationController()
        calibration.begin()
        calibration.push(MotionSample(timestamp: 0, yaw: 0, pitch: 0, roll: 0), hostTime: 1)
        calibration.connectionInterrupted()
        XCTAssertTrue(calibration.sourceChanged)
        XCTAssertFalse(calibration.issues.isEmpty)
        XCTAssertNil(calibration.report)
        XCTAssertFalse(calibration.readyToApply)
        calibration.finish()
    }

    func testClosingDuringCountdownCannotStartARecordingLater() async throws {
        let calibration = MotionCalibrationController()
        calibration.begin()
        calibration.push(MotionSample(timestamp: 0, yaw: 0, pitch: 0, roll: 0), hostTime: 1)
        calibration.startRecording()
        XCTAssertEqual(calibration.countdown, 2)
        calibration.finish()
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertFalse(calibration.isActive)
        XCTAssertFalse(calibration.isRecording)
        XCTAssertEqual(calibration.countdown, 0)
        XCTAssertTrue(calibration.history.isEmpty)
    }
}
