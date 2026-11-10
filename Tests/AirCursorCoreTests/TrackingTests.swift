import XCTest
@testable import AirCursorCore

final class TrackingTests: XCTestCase {
    private func sample(_ t: Double, yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
                        acceleration: Double? = 0) -> MotionSample {
        MotionSample(timestamp: t, yaw: AngleMath.radians(yaw), pitch: AngleMath.radians(pitch),
                     roll: AngleMath.radians(roll), userAcceleration: acceleration.map { Vec3($0, 0, 0) })
    }

    func testKalmanAttenuatesHighFrequencyStationaryNoise() {
        var estimator = KalmanMotionEstimator(), differentiator = MotionDifferentiator()
        var rawEnergy = 0.0, filteredEnergy = 0.0
        for i in 0..<250 {
            let t = Double(i) / 25
            let s = sample(t, yaw: 0.08 * sin(2 * .pi * 9 * t))
            let raw = differentiator.push(s)
            let filtered = estimator.push(s, settings: KalmanSettings())
            if i > 30 {
                rawEnergy += pow(raw?.yaw ?? 0, 2)
                filteredEnergy += pow(filtered.rates?.yaw ?? 0, 2)
            }
        }
        XCTAssertLessThan(filteredEnergy, rawEnergy * 0.5)
    }

    func testKalmanTracksVariableSampleIntervalsAndStops() {
        var estimator = KalmanMotionEstimator()
        var t = 0.0
        var estimate: MotionEstimate?
        for i in 0..<80 {
            t += i.isMultiple(of: 2) ? 0.03 : 0.05
            estimate = estimator.push(sample(t, yaw: 30*t), settings: KalmanSettings())
        }
        XCTAssertEqual(estimate?.rates?.yaw ?? 0, 30, accuracy: 0.1)
        let angle = 30*t
        for _ in 0..<8 {
            t += 0.04
            estimate = estimator.push(sample(t, yaw: angle), settings: KalmanSettings())
        }
        XCTAssertEqual(estimate?.rates?.yaw ?? 99, 0, accuracy: 0.5)
        XCTAssertTrue(estimate?.rateStandardDeviation.isFinite ?? false)
    }

    func testKalmanWrapAndAbsoluteOrientationDoNotChangeRate() {
        var a = KalmanMotionEstimator(), b = KalmanMotionEstimator()
        for i in 0..<80 {
            let t = Double(i) * 0.04
            let e1 = a.push(sample(t, yaw: 20*t), settings: KalmanSettings())
            let wrapped = AngleMath.wrappedDeltaDegrees(179 + 20*t, 0)
            let e2 = b.push(sample(t, yaw: wrapped), settings: KalmanSettings())
            if i > 10 { XCTAssertEqual(e1.rates?.yaw ?? 0, e2.rates?.yaw ?? 0, accuracy: 1e-7) }
        }
    }

    func testSingleSensorSpikeIsRejectedWithoutAReverseJump() {
        var estimator = KalmanMotionEstimator()
        for i in 0..<20 { _ = estimator.push(sample(Double(i)*0.04), settings: KalmanSettings()) }
        let spike = estimator.push(sample(0.8, yaw: 90), settings: KalmanSettings())
        XCTAssertFalse(spike.accepted)
        XCTAssertNil(spike.rates)
        let recovered = estimator.push(sample(0.84), settings: KalmanSettings())
        XCTAssertTrue(recovered.accepted)
        XCTAssertEqual(recovered.rates?.yaw ?? 99, 0, accuracy: 0.1)
    }

    func testSustainedPoseChangeRecoversWithoutEmittingRejectedDisplacement() {
        var estimator = KalmanMotionEstimator()
        _ = estimator.push(sample(0), settings: KalmanSettings())
        for i in 1...3 {
            let result = estimator.push(sample(Double(i)*0.04, yaw: 90), settings: KalmanSettings())
            XCTAssertNil(result.rates)
            XCTAssertFalse(result.accepted)
        }
        let result = estimator.push(sample(0.16, yaw: 90), settings: KalmanSettings())
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.rates?.yaw ?? 99, 0, accuracy: 0.1)
    }

    func testStationaryCalibrationLearnsNoiseButNotContinuousTurns() {
        var estimator = KalmanMotionEstimator()
        for i in 0..<250 {
            _ = estimator.push(sample(Double(i)*0.04, yaw: i.isMultiple(of: 2) ? 0.01 : -0.01), settings: KalmanSettings())
        }
        XCTAssertLessThan(estimator.measurementNoise, 0.06)
        let noise = estimator.measurementNoise
        for i in 250..<300 {
            _ = estimator.push(sample(Double(i)*0.04, yaw: Double(i-250)*2), settings: KalmanSettings())
        }
        XCTAssertEqual(estimator.measurementNoise, noise, accuracy: 0.001)
    }

    func testRepositioningIsGradedAndRequiresQuietRecovery() {
        var gate = RepositioningGate()
        let settings = RepositioningSettings()
        XCTAssertEqual(gate.update(time: 0, acceleration: Vec3(0,0,0), reliable: true, settings: settings), .normal)
        XCTAssertEqual(gate.update(time: 0.04, acceleration: Vec3(0.08,0,0), reliable: true, settings: settings), .cautious)
        for i in 2...10 {
            _ = gate.update(time: Double(i)*0.04, acceleration: Vec3(0.25,0,0), reliable: true, settings: settings)
        }
        XCTAssertEqual(gate.state, .frozen)
        _ = gate.update(time: 0.44, acceleration: Vec3(0,0,0), reliable: true, settings: settings)
        XCTAssertEqual(gate.state, .frozen)
        for i in 12...45 {
            _ = gate.update(time: Double(i)*0.04, acceleration: Vec3(0,0,0), reliable: true, settings: settings)
        }
        XCTAssertEqual(gate.state, .normal)
    }

    func testSmallHeadAccelerationDoesNotFreezeAndMissingAccelerationIsSupported() {
        var gate = RepositioningGate()
        for i in 0..<25 {
            _ = gate.update(time: Double(i)*0.04, acceleration: Vec3(0.02,0,0), reliable: true, settings: RepositioningSettings())
        }
        XCTAssertEqual(gate.state, .normal)
        _ = gate.update(time: 1, acceleration: nil, reliable: true, settings: RepositioningSettings())
        XCTAssertEqual(gate.state, .normal)
        XCTAssertFalse(gate.accelerationAvailable)
    }

    func testInvalidSignalsFreezeEvenWhenPostureSuppressionIsDisabled() {
        var gate = RepositioningGate(), settings = RepositioningSettings()
        settings.enabled = false
        XCTAssertEqual(gate.update(time: 0, acceleration: Vec3(1,0,0), reliable: true, settings: settings), .normal)
        XCTAssertEqual(gate.update(time: 0.04, acceleration: Vec3(.nan,0,0), reliable: true, settings: settings), .frozen)
    }

    func testRadialMappingPreservesDiagonalDirectionAndOffersFasterTravel() {
        var response = PointerResponse(), settings = PointerSettings()
        settings.deadzone = 0
        let diagonal = response.velocity(rates: AngularRates(timestamp: 0, yaw: 12, pitch: 9, roll: 0), settings: settings)
        XCTAssertEqual(diagonal.x / diagonal.y, 12.0/9.0, accuracy: 1e-8)
        let slow = response.velocity(rates: AngularRates(timestamp: 0, yaw: 2, pitch: 0, roll: 0), settings: settings)
        let fast = response.velocity(rates: AngularRates(timestamp: 0, yaw: 60, pitch: 0, roll: 0), settings: settings)
        XCTAssertGreaterThan(abs(fast.x)/60, abs(slow.x)/2 * 3)
    }

    func testRadialDeadzoneHysteresisAndZeroDeadzone() {
        var response = PointerResponse(), settings = PointerSettings()
        settings.adaptiveDeadzone = false
        func rate(_ yaw: Double) -> AngularRates { AngularRates(timestamp: 0, yaw: yaw, pitch: 0, roll: 0) }
        XCTAssertEqual(response.velocity(rates: rate(1), settings: settings), .zero)
        XCTAssertGreaterThan(response.velocity(rates: rate(1.4), settings: settings).length, 0)
        XCTAssertGreaterThan(response.velocity(rates: rate(1), settings: settings).length, 0)
        XCTAssertEqual(response.velocity(rates: rate(0.7), settings: settings), .zero)
        settings.deadzone = 0
        XCTAssertGreaterThan(response.velocity(rates: rate(0.05), settings: settings).length, 0)
    }

    func testHeldTiltFiresOnceAndPointerStaysLockedUntilReturnSettles() {
        var pipeline = HeadControlPipeline()
        var events: [HeadGesture] = []
        var t = 0.0
        func feed(_ roll: Double) -> HeadControlUpdate {
            defer { t += 0.04 }
            let update = pipeline.process(sample(t, roll: roll), enabled: [.tiltLeft, .tiltRight])
            if let event = update.gesture { events.append(event.gesture) }
            return update
        }
        for _ in 0..<10 { _ = feed(0) }
        for roll in stride(from: 0.0, through: 24, by: 3) { _ = feed(roll) }
        for _ in 0..<160 {
            let update = feed(24)
            XCTAssertTrue(update.holdingPointer)
            XCTAssertEqual(update.targetVelocity, .zero)
        }
        XCTAssertEqual(events, [.tiltRight])
        for roll in stride(from: 24.0, through: 0, by: -3) { _ = feed(roll) }
        for _ in 0..<15 { _ = feed(0) }
        XCTAssertFalse(feed(0).holdingPointer)
        for roll in stride(from: 0.0, through: -24, by: -3) { _ = feed(roll) }
        for _ in 0..<15 { _ = feed(-24) }
        XCTAssertEqual(events, [.tiltRight, .tiltLeft])
    }

    func testRepositioningCancelsTiltUntilNeutralInsteadOfDelayingTheClick() {
        var pipeline = HeadControlPipeline()
        var events: [HeadGesture] = []
        for i in 0..<100 {
            let roll: Double = i < 5 ? 0 : i < 13 ? Double(i-5)*3 : i < 65 ? 24 : 0
            let accel = i >= 9 && i < 20 ? 0.09 : 0.0
            let update = pipeline.process(sample(Double(i)*0.04, roll: roll, acceleration: accel), enabled: [.tiltRight])
            if let event = update.gesture { events.append(event.gesture) }
            if update.gate != .normal { XCTAssertNil(update.gesture); XCTAssertFalse(update.allowsAutomaticClicks) }
        }
        XCTAssertTrue(events.isEmpty)
    }

    func testPipelineStopsOnGapAndRecoveryHasNoCatchUpMotion() {
        var pipeline = HeadControlPipeline()
        for i in 0..<20 { _ = pipeline.process(sample(Double(i)*0.04, yaw: Double(i)), enabled: []) }
        var update = pipeline.process(sample(2, yaw: 80), enabled: [])
        XCTAssertEqual(update.gate, .frozen)
        XCTAssertEqual(update.targetVelocity, .zero)
        for i in 1..<30 { update = pipeline.process(sample(2 + Double(i)*0.04, yaw: 80), enabled: []) }
        XCTAssertEqual(update.gate, .normal)
        XCTAssertEqual(update.targetVelocity, .zero)
    }

    func testNonFiniteAndOutOfOrderSamplesNeverReachPointerOrClicks() {
        var pipeline = HeadControlPipeline()
        _ = pipeline.process(sample(1), enabled: [.tiltRight])
        for s in [sample(0.9, roll: 30), sample(1.04, yaw: .nan), sample(1.08, acceleration: .infinity)] {
            let update = pipeline.process(s, enabled: [.tiltRight])
            XCTAssertEqual(update.gate, .frozen)
            XCTAssertEqual(update.targetVelocity, .zero)
            XCTAssertNil(update.gesture)
        }
    }

    func testSourceChangeDoesNotProduceCursorJump() {
        var pipeline = HeadControlPipeline()
        _ = pipeline.process(sample(0), enabled: [])
        var other = sample(0.04, yaw: 45)
        other.sourceID = "external-head-tracker"
        let update = pipeline.process(other, enabled: [])
        XCTAssertEqual(update.targetVelocity, .zero)
        XCTAssertEqual(update.gate, .frozen)
    }

    func testLegacyModeRetainsOriginalMapping() {
        var settings = PointerSettings()
        settings.filterMode = .legacy
        var pipeline = HeadControlPipeline(pointer: settings)
        _ = pipeline.process(sample(0), enabled: [])
        let update = pipeline.process(sample(0.04, yaw: 1), enabled: [])
        let expected = PointerMapper.cursorVelocity(rates: AngularRates(timestamp: 0.04, yaw: 25, pitch: 0, roll: 0), settings: settings)
        XCTAssertEqual(update.targetVelocity.x, expected.x, accuracy: 1e-8)
    }

    func testTiltDefaultsAndV3StockMigration() throws {
        let fresh = AppSettings()
        XCTAssertEqual(fresh.actions[.tiltLeft], .leftClick)
        XCTAssertEqual(fresh.actions[.tiltRight], .rightClick)
        XCTAssertEqual(fresh.actions[.nod], .none)
        XCTAssertFalse(fresh.dwell.enabled)
        let json = #"{"version":3,"actions":{"stemSingle":"leftClick","stemDouble":"rightClick","stemTriple":"toggleScrollMode","nod":"leftClick","shake":"toggleTracking","tiltLeft":"none","tiltRight":"none","dwell":"leftClick"},"dwell":{"enabled":true},"pointer":{"deadzone":3,"smoothing":0.55,"sensitivity":2}}"#
        let migrated = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).migrated()
        XCTAssertEqual(migrated.actions, ActionMap())
        XCTAssertFalse(migrated.dwell.enabled)
        XCTAssertEqual(migrated.pointer.deadzone, fresh.pointer.deadzone)
        XCTAssertEqual(migrated.pointer.sensitivity, 2)
        XCTAssertEqual(migrated.version, 4)
        XCTAssertEqual(migrated.migrated(), migrated)
    }

    func testMigrationPreservesCustomizedBindingsAndTuning() throws {
        let json = #"{"version":3,"actions":{"nod":"rightClick","tiltLeft":"back","tiltRight":"forward"},"dwell":{"enabled":true},"pointer":{"deadzone":5,"smoothing":0.7}}"#
        let migrated = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).migrated()
        XCTAssertEqual(migrated.actions[.nod], .rightClick)
        XCTAssertEqual(migrated.actions[.tiltLeft], .back)
        XCTAssertTrue(migrated.dwell.enabled)
        XCTAssertEqual(migrated.pointer.deadzone, 5)
        XCTAssertEqual(migrated.pointer.smoothing, 0.7)
    }

    func testOldCustomMapDoesNotAcquireNewTiltActionsForMissingKeys() throws {
        let json = #"{"version":3,"actions":{"nod":"rightClick"},"dwell":{"enabled":true}}"#
        let migrated = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).migrated()
        XCTAssertEqual(migrated.actions[.nod], .rightClick)
        XCTAssertEqual(migrated.actions[.tiltLeft], .none)
        XCTAssertEqual(migrated.actions[.tiltRight], .none)
        XCTAssertTrue(migrated.dwell.enabled)
    }

    func testNewSettingsDecodeLenientlyAndRoundTrip() throws {
        let json = #"{"pointer":{"filterMode":"future","filter":{"measurementNoise":0.2},"repositioning":{"enabled":false,"settleTime":"wrong"}}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.pointer.filterMode, .kalman)
        XCTAssertEqual(settings.pointer.filter.measurementNoise, 0.2)
        XCTAssertEqual(settings.pointer.filter.processAcceleration, 100)
        XCTAssertFalse(settings.pointer.repositioning.enabled)
        XCTAssertEqual(settings.pointer.repositioning.settleTime, 0.25)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testMotionReplayIsDeterministicAndDoesNotSynthesizeActions() {
        let samples = (0..<100).map { sample(Double($0)*0.04, yaw: 0.08*sin(Double($0)*2)) }
        let a = MotionReplay.run(samples, pointer: PointerSettings(), gestures: GestureSettings(), enabled: [.tiltLeft, .tiltRight])
        let b = MotionReplay.run(samples, pointer: PointerSettings(), gestures: GestureSettings(), enabled: [.tiltLeft, .tiltRight])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.sampleCount, 100)
        XCTAssertLessThan(a.filteredRateRMS, a.rawRateRMS)
        XCTAssertTrue(a.gestures.isEmpty)
    }

    func testFastHeadTurnsRemainUsableAndPauseResetDoesNotRepeatShake() {
        var pipeline = HeadControlPipeline()
        var events = 0
        for i in 0..<75 {
            let t = Double(i)*0.04
            let yaw = i < 5 ? 0 : i < 55 ? 15*sin(2 * .pi * (t-0.2)/0.45) : 0
            let update = pipeline.process(sample(t, yaw: yaw), enabled: [.shake])
            if update.gesture?.gesture == .shake {
                events += 1
                pipeline.reset(preservingGestures: true)
            }
        }
        XCTAssertEqual(events, 1)
    }

    func testSuspendingDuringTiltCannotFireADelayedClick() {
        var pipeline = HeadControlPipeline()
        for i in 0..<15 {
            _ = pipeline.process(sample(Double(i)*0.04, roll: i < 7 ? 0 : Double(i-7)*3), enabled: [.tiltRight])
        }
        pipeline.suspend()
        for i in 15..<90 {
            let update = pipeline.process(sample(Double(i)*0.04, roll: 24), enabled: [.tiltRight])
            XCTAssertNil(update.gesture)
        }
    }

    func testCanceledTiltDoesNotAnchorAgainAfterPhysicalMouseTakeover() {
        var pipeline = HeadControlPipeline()
        for i in 0..<15 {
            _ = pipeline.process(sample(Double(i)*0.04, roll: i < 7 ? 0 : Double(i-7)*3), enabled: [.tiltRight])
        }
        pipeline.cancelGestures()
        for i in 15..<35 {
            let update = pipeline.process(sample(Double(i)*0.04, roll: 24), enabled: [.tiltRight])
            XCTAssertNil(update.tiltStartTime)
            XCTAssertNil(update.gesture)
            XCTAssertTrue(update.holdingPointer)
        }
    }

    func testOrdinaryRotationalAccelerationDoesNotCancelTiltClick() {
        var pipeline = HeadControlPipeline()
        var events: [HeadGesture] = []
        for i in 0..<45 {
            let roll = i < 10 ? 0.0 : min(24, Double(i-9)*3)
            let acceleration = (10...18).contains(i) ? 0.07 : 0.0
            let update = pipeline.process(sample(Double(i)*0.04, roll: roll, acceleration: acceleration), enabled: [.tiltRight])
            if let event = update.gesture { events.append(event.gesture) }
        }
        XCTAssertEqual(events, [.tiltRight])
    }

    func testStrongAccelerationStillFreezesDuringFastRotation() {
        var gate = RepositioningGate()
        for i in 0..<10 {
            _ = gate.update(time: Double(i)*0.04, acceleration: Vec3(0.3,0,0), reliable: true,
                            angularSpeed: 120, settings: RepositioningSettings())
        }
        XCTAssertEqual(gate.state, .frozen)
    }
}
