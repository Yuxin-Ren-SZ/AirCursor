import XCTest
@testable import AirCursorCore

final class CalibrationTests: XCTestCase {
    private func recording(_ phase: CalibrationPhase, oppositeRoll: Bool = false,
                           acceleration: Bool = true, postureDistinct: Bool = true) -> CalibrationRecording {
        let index = CalibrationPhase.allCases.firstIndex(of: phase) ?? 0
        let offset = Double(index) * 20
        let count = Int(phase.duration * 25)
        let samples: [MotionSample] = (0...count).map { i in
            let t = Double(i) / 25
            var yaw = 0.008*sin(2 * .pi * 8*t), pitch = 0.006*sin(2 * .pi * 6*t), roll = 0.0
            var a = Vec3(0.005 + 0.003*abs(sin(t)), 0.001, 0.001)
            switch phase {
            case .neutral: break
            case .slowPointing:
                if t < 5 { yaw += 4*sin(2 * .pi*t/4) }
                else { pitch += 3*sin(2 * .pi*(t-5)/4) }
                roll = 0.15*sin(t)
            case .fastPointing:
                if t < 4 { yaw += 10*sin(2 * .pi*t/1.3) }
                else { pitch += 8*sin(2 * .pi*(t-4)/1.1) }
                roll = 0.2*sin(t)
            case .leftTilt, .rightTilt:
                let local = t - 1
                if local >= 0, local < 8.4 {
                    let cycle = local.truncatingRemainder(dividingBy: 2.8)
                    let peak = phase == .leftTilt ? 7.0 : 10.0
                    let shape = cycle < 0.35 ? cycle/0.35 : cycle < 0.7 ? 1 : cycle < 1.05 ? (1.05-cycle)/0.35 : 0
                    let sign = (phase == .leftTilt ? -1.0 : 1.0) * (oppositeRoll ? -1 : 1)
                    roll = peak * max(0, shape) * sign
                }
            case .repositioning:
                if postureDistinct, t > 0.8, t < 6.5, t.truncatingRemainder(dividingBy: 1.6) < 0.6 {
                    a = Vec3(0.14 + 0.04*sin(t*7), 0.1*cos(t*5), 0.08*sin(t*6))
                }
            }
            return MotionSample(timestamp: offset+t, yaw: AngleMath.radians(yaw), pitch: AngleMath.radians(pitch),
                                roll: AngleMath.radians(roll), userAcceleration: acceleration ? a : nil,
                                sourceID: "calibration-headphones")
        }
        return CalibrationRecording(phase: phase, samples: samples, elapsed: phase.duration)
    }

    private func session(acceleration: Bool = true, postureDistinct: Bool = true) -> [CalibrationPhase: CalibrationRecording] {
        Dictionary(uniqueKeysWithValues: CalibrationPhase.allCases.map {
            ($0, recording($0, acceleration: acceleration, postureDistinct: postureDistinct))
        })
    }

    func testCompleteSessionLearnsComfortableAsymmetricTiltsAndBufferedSpeedBands() {
        let result = CalibrationAnalyzer.analyze(session(), baseline: AppSettings(), date: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(result.issues.isEmpty, result.issues.map(\.message).joined(separator: "; "))
        XCTAssertNotNil(result.report)
        guard let report = result.report else { return }
        XCTAssertLessThan(report.gestures.angle(for: .tiltLeft), 7)
        XCTAssertLessThan(report.gestures.angle(for: .tiltRight), 10)
        XCTAssertGreaterThan(report.gestures.angle(for: .tiltRight), report.gestures.angle(for: .tiltLeft))
        XCTAssertGreaterThan(report.profile.precisionMaximumSpeed, report.profile.slowSpeed)
        XCTAssertLessThan(report.profile.travelMinimumSpeed, report.profile.fastSpeed)
        XCTAssertGreaterThan(report.pointer.travelGain, report.pointer.precisionGain)
        XCTAssertGreaterThan(report.pointer.transitionSpeed, 0)
        XCTAssertFalse(report.gestures.swapTiltDirection)
        XCTAssertTrue(report.profile.repositioningLearned)
        XCTAssertGreaterThan(report.profile.postureAccelerationRMS.y, 0)
        XCTAssertGreaterThan(report.profile.postureAccelerationRMS.z, 0)
    }

    func testProfileFitsSlowAndFastSampleSpeedsToDifferentCursorGains() {
        let result = CalibrationAnalyzer.analyze(session(), baseline: AppSettings())
        guard let report = result.report else { XCTAssertNotNil(result.report); return }
        var response = PointerResponse()
        let slow = response.velocity(rates: AngularRates(timestamp: 0, yaw: report.profile.slowSpeed, pitch: 0, roll: 0), settings: report.pointer)
        let fast = response.velocity(rates: AngularRates(timestamp: 0, yaw: report.profile.fastSpeed, pitch: 0, roll: 0), settings: report.pointer)
        XCTAssertGreaterThan(abs(slow.x), 30)
        XCTAssertLessThan(abs(slow.x), 140)
        XCTAssertGreaterThan(abs(fast.x), 700)
    }

    func testMissingOrIncompleteRecordingsDoNotGenerateSettings() {
        var data = session()
        data[.slowPointing] = nil
        var result = CalibrationAnalyzer.analyze(data, baseline: AppSettings())
        XCTAssertNil(result.report)
        XCTAssertTrue(result.issues.contains { $0.phase == .slowPointing })
        data = session()
        data[.rightTilt]?.elapsed = 1
        result = CalibrationAnalyzer.analyze(data, baseline: AppSettings())
        XCTAssertNil(result.report)
        XCTAssertTrue(result.issues.contains { $0.phase == .rightTilt })
    }

    func testSimilarSlowAndFastMovementsAskForAnotherFastSample() {
        var data = session()
        var slowAsFast = recording(.slowPointing)
        slowAsFast.phase = .fastPointing
        slowAsFast.elapsed = CalibrationPhase.fastPointing.duration
        data[.fastPointing] = slowAsFast
        let result = CalibrationAnalyzer.analyze(data, baseline: AppSettings())
        XCTAssertNil(result.report)
        XCTAssertTrue(result.issues.contains { $0.phase == .fastPointing })
    }

    func testNoisyRestIsRejectedInsteadOfRaisingThresholdsToHideIt() {
        var data = session()
        let samples = data[.neutral]?.samples ?? []
        data[.neutral]?.samples = samples.enumerated().map { i, sample in
            var copy = sample
            copy.roll = AngleMath.radians(i.isMultiple(of: 2) ? 5 : -5)
            return copy
        }
        let result = CalibrationAnalyzer.analyze(data, baseline: AppSettings())
        XCTAssertNil(result.report)
        XCTAssertTrue(result.issues.contains { $0.phase == .neutral })
    }

    func testIncompleteTiltAndWrongDirectionAreRejected() {
        var data = session()
        let samples = data[.leftTilt]?.samples ?? []
        data[.leftTilt]?.samples = samples.map { sample in
            var copy = sample; copy.roll = 0; return copy
        }
        var result = CalibrationAnalyzer.analyze(data, baseline: AppSettings())
        XCTAssertNil(result.report)
        XCTAssertTrue(result.issues.contains { $0.phase == .leftTilt })
        data = session()
        data[.rightTilt] = recording(.rightTilt, oppositeRoll: true)
        result = CalibrationAnalyzer.analyze(data, baseline: AppSettings())
        XCTAssertNil(result.report)
        XCTAssertTrue(result.issues.contains { $0.phase == .rightTilt })
    }

    func testOppositeSensorRollConventionIsLearnedFromBothSides() {
        var data = session()
        data[.leftTilt] = recording(.leftTilt, oppositeRoll: true)
        data[.rightTilt] = recording(.rightTilt, oppositeRoll: true)
        let result = CalibrationAnalyzer.analyze(data, baseline: AppSettings())
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertTrue(result.report?.gestures.swapTiltDirection ?? false)
    }

    func testMissingAccelerationKeepsPostureSettingsAndStillCalibratesPointingAndClicks() {
        var baseline = AppSettings()
        baseline.pointer.repositioning.cautionAcceleration = 0.08
        baseline.pointer.repositioning.cautiousGain = 0.45
        let result = CalibrationAnalyzer.analyze(session(acceleration: false), baseline: baseline)
        XCTAssertNotNil(result.report)
        XCTAssertEqual(result.report?.pointer.repositioning, baseline.pointer.repositioning)
        XCTAssertFalse(result.report?.profile.repositioningLearned ?? true)
        XCTAssertTrue(result.report?.profile.notes.first?.contains("unavailable") ?? false)
    }

    func testOverlappingPostureSamplesKeepExistingParameters() {
        var baseline = AppSettings()
        baseline.pointer.repositioning.settleTime = 0.5
        let result = CalibrationAnalyzer.analyze(session(postureDistinct: false), baseline: baseline)
        XCTAssertNotNil(result.report)
        XCTAssertEqual(result.report?.pointer.repositioning, baseline.pointer.repositioning)
        XCTAssertFalse(result.report?.profile.repositioningLearned ?? true)
    }

    func testSensorChangeAndCorruptSamplesCannotGenerateAProfile() {
        var data = session()
        data[.leftTilt]?.samples[0].sourceID = "different-headphones"
        var result = CalibrationAnalyzer.analyze(data, baseline: AppSettings())
        XCTAssertNil(result.report)
        data = session()
        data[.neutral]?.samples[0].yaw = .nan
        result = CalibrationAnalyzer.analyze(data, baseline: AppSettings())
        XCTAssertNil(result.report)
    }

    func testInterruptedSamplesAskToRepeatTheAffectedStep() {
        var data = session()
        data[.fastPointing]?.gaps = 3
        let result = CalibrationAnalyzer.analyze(data, baseline: AppSettings())
        XCTAssertNil(result.report)
        XCTAssertTrue(result.issues.contains { $0.phase == .fastPointing })
    }

    func testCaptureCountsValidSensorTimeAndDoesNotFinishAcrossAStall() {
        var capture = CalibrationCapture(phase: .neutral)
        capture.push(MotionSample(timestamp: 0, yaw: 0, pitch: 0, roll: 0))
        capture.push(MotionSample(timestamp: 10, yaw: 0, pitch: 0, roll: 0))
        XCTAssertEqual(capture.recording.elapsed, 0)
        XCTAssertFalse(capture.isComplete)
        XCTAssertEqual(capture.recording.gaps, 1)
        for i in 1...101 { capture.push(MotionSample(timestamp: 10+Double(i)*0.04, yaw: 0, pitch: 0, roll: 0)) }
        XCTAssertTrue(capture.isComplete)
        XCTAssertGreaterThanOrEqual(capture.recording.elapsed, 4)
    }

    func testCaptureDropsInvalidSpikesAndOutOfOrderSamples() {
        var capture = CalibrationCapture(phase: .neutral)
        capture.push(MotionSample(timestamp: 1, yaw: 0, pitch: 0, roll: 0))
        capture.push(MotionSample(timestamp: 0.9, yaw: 0, pitch: 0, roll: 0))
        capture.push(MotionSample(timestamp: 1.04, yaw: .nan, pitch: 0, roll: 0))
        capture.push(MotionSample(timestamp: 1.08, yaw: .pi, pitch: 0, roll: 0))
        XCTAssertEqual(capture.recording.rejectedSamples, 3)
        XCTAssertEqual(capture.recording.samples.count, 1)
        capture.push(MotionSample(timestamp: 1.12, yaw: 0, pitch: 0, roll: 0))
        XCTAssertEqual(capture.recording.elapsed, 0.12, accuracy: 1e-8)
    }

    func testCaptureRefusesToMixDevices() {
        var capture = CalibrationCapture(phase: .neutral)
        capture.push(MotionSample(timestamp: 0, yaw: 0, pitch: 0, roll: 0, sourceID: "one"))
        capture.push(MotionSample(timestamp: 0.04, yaw: 0, pitch: 0, roll: 0, sourceID: "two"))
        XCTAssertTrue(capture.sourceChanged)
        XCTAssertEqual(capture.recording.samples.count, 1)
    }

    func testCalibratedSmallTiltsActuallyFireOncePerNeutralReturn() {
        let analysis = CalibrationAnalyzer.analyze(session(), baseline: AppSettings())
        guard let report = analysis.report else { XCTAssertNotNil(analysis.report); return }
        var detector = GestureDetector(settings: report.gestures)
        var events: [HeadGesture] = []
        for sample in recording(.leftTilt).samples {
            if let event = detector.process(sample, enabled: [.tiltLeft, .tiltRight]) { events.append(event.gesture) }
        }
        XCTAssertEqual(events, [.tiltLeft, .tiltLeft, .tiltLeft])
        detector.reset(); events = []
        for sample in recording(.rightTilt).samples {
            if let event = detector.process(sample, enabled: [.tiltLeft, .tiltRight]) { events.append(event.gesture) }
        }
        XCTAssertEqual(events, [.tiltRight, .tiltRight, .tiltRight])
    }

    func testPersonalProfileAndUndoSnapshotRoundTripWithoutRawData() throws {
        let baseline = AppSettings()
        let analysis = CalibrationAnalyzer.analyze(session(), baseline: baseline)
        guard let report = analysis.report else { XCTAssertNotNil(analysis.report); return }
        var settings = baseline
        settings.developerModeEnabled = true
        settings.pointer = report.pointer; settings.gestures = report.gestures; settings.calibrationProfile = report.profile
        settings.calibrationBackup = CalibrationBackup(pointer: baseline.pointer, gestures: baseline.gestures, profile: nil)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.calibrationBackup?.pointer, baseline.pointer)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("userAcceleration"))
        XCTAssertFalse(json.contains("timestamp"))
        XCTAssertFalse(json.contains("recordings"))
    }

    func testExistingSettingsKeepSharedTiltBehaviorAndDeveloperModeIsOptIn() throws {
        let data = Data(#"{"version":4,"gestures":{"tiltAngle":12,"tiltHold":0.3},"pointer":{"precisionGain":20}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data).migrated()
        XCTAssertFalse(settings.developerModeEnabled)
        XCTAssertNil(settings.calibrationProfile)
        XCTAssertNil(settings.calibrationBackup)
        XCTAssertEqual(settings.gestures.angle(for: .tiltLeft), 12)
        XCTAssertEqual(settings.gestures.angle(for: .tiltRight), 12)
        XCTAssertEqual(settings.gestures.hold(for: .tiltLeft), 0.3)
        XCTAssertEqual(settings.pointer.precisionSpeed, 5)
        XCTAssertEqual(settings.pointer.precisionGain, 20)
    }

    func testAsymmetricThresholdsRequireReturnInsideTheSmallerNeutralBand() {
        var settings = GestureSettings()
        settings.leftTiltAngle = 4; settings.rightTiltAngle = 10
        settings.leftTiltHold = 0.15; settings.rightTiltHold = 0.3
        var detector = GestureDetector(settings: settings)
        var events: [HeadGesture] = []
        var t = 0.0
        func feed(_ roll: Double, count: Int) {
            for _ in 0..<count {
                if let event = detector.process(MotionSample(timestamp: t, yaw: 0, pitch: 0, roll: AngleMath.radians(roll)), enabled: [.tiltLeft, .tiltRight]) { events.append(event.gesture) }
                t += 0.04
            }
        }
        feed(0, count: 8); feed(-5, count: 12); feed(-3, count: 10); feed(-5, count: 10)
        XCTAssertEqual(events, [.tiltLeft])
        feed(0, count: 10); feed(11, count: 15)
        XCTAssertEqual(events, [.tiltLeft, .tiltRight])
    }

    func testLargePointingRollCannotBeClampedIntoAnUnsafeClickThreshold() {
        var data = session()
        for phase in [CalibrationPhase.slowPointing, .fastPointing] {
            let samples = data[phase]?.samples ?? []
            data[phase]?.samples = samples.map { sample in
                var copy = sample; copy.roll = AngleMath.radians(24); return copy
            }
        }
        let result = CalibrationAnalyzer.analyze(data, baseline: AppSettings())
        XCTAssertNil(result.report)
        XCTAssertTrue(result.issues.contains { $0.phase == .slowPointing })
    }

    func testOutOfRangeAccelerationRetainsPostureSettingsInsteadOfClampingBelowNormalMotion() {
        var data = session()
        for phase in [CalibrationPhase.slowPointing, .fastPointing, .repositioning] {
            let samples = data[phase]?.samples ?? []
            data[phase]?.samples = samples.map { sample in
                var copy = sample; copy.userAcceleration = Vec3(phase == .repositioning ? 1.2 : 0.5, 0, 0); return copy
            }
        }
        let baseline = AppSettings()
        let result = CalibrationAnalyzer.analyze(data, baseline: baseline)
        XCTAssertNotNil(result.report)
        XCTAssertFalse(result.report?.profile.repositioningLearned ?? true)
        XCTAssertEqual(result.report?.pointer.repositioning, baseline.pointer.repositioning)
    }

    func testTiltCanBeginImmediatelyAfterCountdownWithoutBiasingNeutral() {
        var data = session()
        for phase in [CalibrationPhase.leftTilt, .rightTilt] {
            let samples = data[phase]?.samples ?? []
            data[phase]?.samples = samples.enumerated().map { index, sample in
                var copy = sample
                copy.roll = samples[min(index + 25, samples.count - 1)].roll
                return copy
            }
        }
        let result = CalibrationAnalyzer.analyze(data, baseline: AppSettings())
        XCTAssertTrue(result.issues.isEmpty, result.issues.map(\.message).joined(separator: "; "))
        XCTAssertNotNil(result.report)
        XCTAssertEqual(result.report?.gestures.leftTiltAngle ?? 0, 4.55, accuracy: 0.1)
    }
}
