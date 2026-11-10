import XCTest
@testable import AirCursor
import AirCursorCore

@MainActor
final class CalibrationControllerTests: XCTestCase {
    private func savedSettings() throws -> AppSettings {
        let json = #"{"version":5,"calibrationProfile":{"date":0,"sourceID":"headphones","sampleCount":1000,"slowSpeed":10,"fastSpeed":40,"precisionMaximumSpeed":12,"travelMinimumSpeed":32,"leftTiltPeak":7,"rightTiltPeak":9,"minimumTiltAngle":3,"repositioningLearned":true,"postureAccelerationRMS":{"x":0.1,"y":0.1,"z":0.1},"notes":[],"algorithmVersion":2}}"#
        return try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    func testSavedProfileSupportsRepeatedFeedbackAndUndoWithoutCapture() throws {
        let settings = try savedSettings()
        let calibration = MotionCalibrationController()
        calibration.tuneCurrent(using: settings, display: CalibrationDisplay(), neutralRoll: 0)
        XCTAssertNotNil(calibration.report)
        XCTAssertTrue(calibration.completed.isEmpty)
        for i in 0..<20 {
            calibration.push(MotionSample(timestamp: Double(i)*0.04, yaw: 0, pitch: 0, roll: 0), hostTime: Double(i)*0.04)
        }
        XCTAssertTrue(calibration.readyToApply)
        XCTAssertGreaterThan(calibration.trial.duration, 0)
        var feedback = CalibrationFeedback(); feedback.slow = .tooLittle; feedback.fast = .tooMuch
        calibration.applyFeedback(feedback)
        let firstGain = calibration.report?.pointer.precisionGain
        XCTAssertEqual(calibration.roundNumber, 2)
        XCTAssertFalse(calibration.readyToApply)
        XCTAssertEqual(calibration.trial.duration, 0)
        XCTAssertTrue(calibration.canUndoFeedback)
        calibration.applyFeedback(feedback)
        XCTAssertEqual(calibration.roundNumber, 3)
        calibration.undoFeedback()
        XCTAssertEqual(calibration.report?.pointer.precisionGain, firstGain)
        calibration.undoFeedback()
        XCTAssertEqual(calibration.report?.pointer, settings.pointer)
        XCTAssertEqual(calibration.report?.gestures, settings.gestures)
        XCTAssertFalse(calibration.canUndoFeedback)
        calibration.finish()
        XCTAssertNil(calibration.report)
        XCTAssertTrue(calibration.feedbackChanges.isEmpty)
    }

    func testDisplayAndModeChangesRescalePreviewAndResetReadiness() throws {
        let settings = try savedSettings()
        let calibration = MotionCalibrationController()
        calibration.tuneCurrent(using: settings, display: CalibrationDisplay(width: 1440,height: 900), neutralRoll: 0)
        calibration.setDisplay(CalibrationDisplay(id: "external",width: 2880,height: 1800,pixelWidth: 5760,pixelHeight: 3600,scale: 2))
        XCTAssertEqual(calibration.report?.pointer.travelGain, settings.pointer.travelGain*2)
        XCTAssertEqual(calibration.report?.pointer.precisionGain, settings.pointer.precisionGain)
        XCTAssertEqual(calibration.report?.profile.display?.id, "external")
        calibration.setPreviewMode(.travel)
        XCTAssertLessThan(calibration.previewGeometry.scale, 1)
        calibration.setPreviewMode(.precision)
        XCTAssertEqual(calibration.previewGeometry.scale, 1)
        XCTAssertFalse(calibration.readyToApply)
        calibration.finish()
    }

    func testRestartResetsReadoutClockAndStalePreviewExplainsItsStop() throws {
        let calibration = MotionCalibrationController()
        let sample = MotionSample(timestamp: 0, yaw: 0, pitch: 0, roll: 0)
        calibration.begin(); calibration.push(sample, hostTime: 100)
        calibration.tuneCurrent(using: try savedSettings(), display: CalibrationDisplay(), neutralRoll: 0)
        calibration.push(sample, hostTime: 1)
        XCTAssertTrue(calibration.live.fresh)
        calibration.advance(now: 1.4)
        XCTAssertEqual(calibration.previewReason, .stale)
        XCTAssertEqual(calibration.previewGate, .frozen)
        XCTAssertFalse(calibration.readyToApply)
        calibration.finish()
    }

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
