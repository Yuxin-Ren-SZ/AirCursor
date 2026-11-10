import Foundation

public enum CalibrationAnalyzer {
    private struct Track {
        var rates: [AngularRates] = []
        var rawAcceleration: [Double] = []
        var residualAcceleration: [Double] = []
        var recoveryTimes: [Double] = []
        var accelerationCount = 0
        var axisEnergy = Vec3(0,0,0)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = Double(sorted.count - 1) * min(1, max(0, fraction))
        let low = Int(index), high = min(sorted.count-1, Int(ceil(index)))
        return sorted[low] + (sorted[high] - sorted[low]) * (index - Double(low))
    }

    private static func medianAngle(_ radians: [Double]) -> Double {
        guard let first = radians.first else { return 0 }
        return AngleMath.degrees(first) + percentile(radians.map { AngleMath.degrees(AngleMath.wrappedDelta($0, first)) }, 0.5)
    }

    private static func track(_ samples: [MotionSample], filter: KalmanSettings) -> Track {
        var result = Track(), differentiator = MotionDifferentiator(), estimator = KalmanMotionEstimator()
        var signal = RepositioningSignal(), previous: MotionSample?, lastActive: Double?
        for sample in samples {
            let raw = differentiator.push(sample)
            let estimate = estimator.push(sample, settings: filter)
            if let rates = estimate.rates, estimate.accepted { result.rates.append(rates) }
            defer { previous = sample }
            guard let a = sample.userAcceleration, a.isFinite else { continue }
            let dt = sample.timestamp - (previous?.timestamp ?? sample.timestamp)
            guard dt >= 0, dt <= MotionDifferentiator.maxInterval else { signal = RepositioningSignal(); continue }
            let speed = max(sample.rotationRate.map { AngleMath.degrees($0.length) } ?? 0,
                            raw.map { hypot(hypot($0.yaw, $0.pitch), $0.roll) } ?? 0)
            let feature = signal.update(magnitude: a.length, angularSpeed: speed, dt: dt)
            result.accelerationCount += 1
            result.rawAcceleration.append(a.length)
            result.residualAcceleration.append(feature.residual)
            result.axisEnergy.x += a.x*a.x; result.axisEnergy.y += a.y*a.y; result.axisEnergy.z += a.z*a.z
            if feature.residual > 0.04 { lastActive = sample.timestamp }
            else if feature.rms < 0.025, let last = lastActive {
                result.recoveryTimes.append(sample.timestamp - last)
                lastActive = nil
            }
        }
        return result
    }

    private struct Tilt {
        var peak: Double
        var sign: Double
        var hold: Double
    }

    private static func tilts(_ samples: [MotionSample], neutral: Double, noise: Double) -> [Tilt] {
        guard !samples.isEmpty else { return [] }
        let onset = max(2, noise * 3)
        var segment: [(Double, Double)] = [], result: [Tilt] = []
        for sample in samples {
            let roll = AngleMath.wrappedDeltaDegrees(AngleMath.degrees(sample.roll), neutral)
            if abs(roll) >= onset || (!segment.isEmpty && abs(roll) >= onset * 0.5) {
                segment.append((sample.timestamp, roll))
            } else if !segment.isEmpty {
                let peak = segment.max { abs($0.1) < abs($1.1) }?.1 ?? 0
                let top = segment.filter { $0.1 * (peak > 0 ? 1 : -1) >= abs(peak) * 0.65 }
                let hold = (top.last?.0 ?? 0) - (top.first?.0 ?? 0)
                if abs(peak) >= 3.5, abs(peak) <= 40, hold >= 0.12 {
                    result.append(Tilt(peak: abs(peak), sign: peak > 0 ? 1 : -1, hold: hold))
                }
                segment.removeAll(keepingCapacity: true)
            }
        }
        // An unfinished held tilt is deliberately excluded: neutral return is required.
        return result
    }

    public static func analyze(_ recordings: [CalibrationPhase: CalibrationRecording], baseline: AppSettings,
                               screenWidth: Double = 1440, date: Date = Date()) -> CalibrationAnalysis {
        var issues: [CalibrationIssue] = []
        let sources = Set(recordings.values.flatMap { $0.samples.map(\.sourceID) })
        for phase in CalibrationPhase.allCases {
            guard let recording = recordings[phase], recording.samples.count >= 40,
                  recording.elapsed >= phase.duration * 0.9 else {
                issues.append(CalibrationIssue(phase: phase, message: "Record the full step with live motion data.")); continue
            }
            if recording.gaps > 1 || recording.rejectedSamples > max(3, recording.samples.count / 20)
                || recording.samples.contains(where: { !$0.isFinite }) || sources.count != 1 {
                issues.append(CalibrationIssue(phase: phase, message: "The signal was interrupted or changed. Repeat this step with the same headphones."))
            }
        }
        guard issues.isEmpty else { return CalibrationAnalysis(report: nil, issues: issues) }
        let rest = recordings[.neutral]?.samples ?? []
        let restYaw = medianAngle(rest.map(\.yaw)), restPitch = medianAngle(rest.map(\.pitch))
        let yawNoise = percentile(rest.map { abs(AngleMath.wrappedDeltaDegrees(AngleMath.degrees($0.yaw), restYaw)) }, 0.5)
        let pitchNoise = percentile(rest.map { abs(AngleMath.wrappedDeltaDegrees(AngleMath.degrees($0.pitch), restPitch)) }, 0.5)
        let restRoll = medianAngle(rest.map(\.roll))
        let rollNoise = percentile(rest.map { abs(AngleMath.wrappedDeltaDegrees(AngleMath.degrees($0.roll), restRoll)) }, 0.95)
        var pointer = baseline.pointer, gestures = baseline.gestures
        pointer.filterMode = .kalman
        pointer.filter.measurementNoise = bounded(max(yawNoise, pitchNoise) * 1.4826, 0.15, 0.03, 0.5)
        var tracks: [CalibrationPhase: Track] = [:]
        for phase in CalibrationPhase.allCases { tracks[phase] = track(recordings[phase]?.samples ?? [], filter: pointer.filter) }
        let restRates = tracks[.neutral]?.rates.map { hypot($0.yaw, $0.pitch) } ?? []
        if percentile(restRates, 0.95) > 6 || rollNoise > 2 || percentile(tracks[.neutral]?.rawAcceleration ?? [], 0.95) > 0.06 {
            issues.append(CalibrationIssue(phase: .neutral, message: "The resting sample includes deliberate movement. Repeat while looking ahead comfortably."))
        }
        let noiseRate = percentile(restRates, 0.95)
        pointer.deadzone = bounded(noiseRate * 1.3, 1.2, 0.3, 3)
        let activeFloor = max(0.25, pointer.deadzone * 1.2)
        func speeds(_ phase: CalibrationPhase) -> [Double] {
            (tracks[phase]?.rates ?? []).map { hypot($0.yaw, $0.pitch) }.filter { $0 > activeFloor }
        }
        let slow = speeds(.slowPointing), fast = speeds(.fastPointing)
        for phase in [CalibrationPhase.slowPointing, .fastPointing] {
            let rates = tracks[phase]?.rates ?? []
            let active = phase == .slowPointing ? slow : fast
            let yaw = rates.filter { abs($0.yaw) > activeFloor }.count
            let pitch = rates.filter { abs($0.pitch) > activeFloor }.count
            if active.count < 25 || yaw < 10 || pitch < 10 {
                issues.append(CalibrationIssue(phase: phase, message: "Include both left/right turns and up/down turns, with pauses between them."))
            }
        }
        let slowReference = percentile(slow, 0.6), fastReference = percentile(fast, 0.6)
        if fastReference < max(slowReference * 1.5, slowReference + max(1, noiseRate * 2)) {
            issues.append(CalibrationIssue(phase: .fastPointing, message: "The slow and fast samples are too similar. Repeat at your comfortable screen-crossing pace."))
        }
        // Leave a 20% precision buffer and begin fast travel 20% before the typical
        // fast movement. If bands overlap, retain a smooth minimum-width transition.
        var slowEdge = percentile(slow, 0.8) * 1.2
        var fastEdge = fastReference * 0.8
        if fastEdge <= slowEdge {
            slowEdge = slowReference * 1.1
            fastEdge = fastReference * 0.9
        }
        fastEdge = max(slowEdge + 0.5, fastEdge)
        pointer.precisionSpeed = bounded(slowEdge - pointer.deadzone * 0.65, 5, 0.5, 100)
        pointer.transitionSpeed = bounded(fastEdge - slowEdge, 35, 0.5, 120)
        pointer.sensitivity = 1
        pointer.acceleration = 0.6
        pointer.precisionGain = bounded(90 / max(1, slowReference - pointer.deadzone * 0.65), 18, 4, 60)
        pointer.travelGain = bounded(bounded(screenWidth, 1440, 320, 12000) * 0.6 / max(5, fastReference - pointer.deadzone * 0.65), 48,
                                     max(16, pointer.precisionGain * 1.25), 120)

        let left = tilts(recordings[.leftTilt]?.samples ?? [], neutral: restRoll, noise: rollNoise)
        let right = tilts(recordings[.rightTilt]?.samples ?? [], neutral: restRoll, noise: rollNoise)
        let leftSign = percentile(left.map(\.sign), 0.5), rightSign = percentile(right.map(\.sign), 0.5)
        let leftValid = left.filter { $0.sign == leftSign }, rightValid = right.filter { $0.sign == rightSign }
        for (phase, moves) in [(CalibrationPhase.leftTilt, leftValid), (.rightTilt, rightValid)] {
            if moves.count < 3 {
                issues.append(CalibrationIssue(phase: phase, message: "Record three comfortable tilts with a brief hold and a full upright return each time."))
            }
        }
        if !leftValid.isEmpty, !rightValid.isEmpty, leftSign == rightSign {
            issues.append(CalibrationIssue(phase: .rightTilt, message: "Both samples tilted the same way. Repeat the right-ear-toward-shoulder movement."))
        }
        let pointing = (recordings[.slowPointing]?.samples ?? []) + (recordings[.fastPointing]?.samples ?? [])
        let incidentalRoll = percentile(pointing.map { abs(AngleMath.wrappedDeltaDegrees(AngleMath.degrees($0.roll), restRoll)) }, 0.98)
        let minimumTilt = max(3, incidentalRoll + max(1, rollNoise * 2))
        if minimumTilt > 18 {
            issues.append(CalibrationIssue(phase: .slowPointing, message: "Ordinary pointing includes too much sideways lean for a safe small-tilt threshold. Repeat pointing with a more neutral roll."))
        }
        func tiltThreshold(_ moves: [Tilt], phase: CalibrationPhase) -> Double {
            let easyPeak = percentile(moves.map(\.peak), 0.2)
            if !moves.isEmpty, minimumTilt > easyPeak * 0.85 {
                issues.append(CalibrationIssue(phase: phase, message: "These tilts overlap ordinary pointing roll. Repeat with a clearer comfortable tilt, or repeat the pointing steps with less sideways lean."))
            }
            return bounded(max(minimumTilt, easyPeak * 0.65), 6, 3, 18)
        }
        gestures.leftTiltAngle = tiltThreshold(leftValid, phase: .leftTilt)
        gestures.rightTiltAngle = tiltThreshold(rightValid, phase: .rightTilt)
        gestures.leftTiltHold = bounded(percentile(leftValid.map(\.hold), 0.25) * 0.6, 0.2, 0.15, 0.35)
        gestures.rightTiltHold = bounded(percentile(rightValid.map(\.hold), 0.25) * 0.6, 0.2, 0.15, 0.35)
        gestures.tiltAngle = (gestures.angle(for: .tiltLeft) + gestures.angle(for: .tiltRight)) / 2
        gestures.tiltHold = (gestures.hold(for: .tiltLeft) + gestures.hold(for: .tiltRight)) / 2
        gestures.swapTiltDirection = leftSign > 0
        guard issues.isEmpty else { return CalibrationAnalysis(report: nil, issues: issues) }

        let ordinary = [CalibrationPhase.neutral, .slowPointing, .fastPointing, .leftTilt, .rightTilt]
        let ordinaryResidual = ordinary.flatMap { tracks[$0]?.residualAcceleration ?? [] }
        let ordinaryRaw = ordinary.flatMap { tracks[$0]?.rawAcceleration ?? [] }
        let posture = tracks[.repositioning] ?? Track()
        let coverage = Double(ordinaryResidual.count) / Double(max(1, ordinary.reduce(0) { $0 + (recordings[$1]?.samples.count ?? 0) }))
        let usualHigh = percentile(ordinaryResidual, 0.99)
        let postureActive = posture.residualAcceleration.filter { $0 > max(0.025, usualHigh * 1.3) }
        let postureReference = percentile(postureActive, 0.5)
        let lower = max(0.06, usualHigh * 1.5 + 0.01)
        let rawUpper = percentile(ordinaryRaw, 0.99)
        let outsidePostureRange = lower > 0.3 || rawUpper * 1.5 > 0.8
        var notes: [String] = [], postureLearned = false
        if coverage >= 0.8, posture.accelerationCount >= 40, postureActive.count >= 20,
           postureReference > lower * 1.3, !outsidePostureRange {
            pointer.repositioning.cautionAcceleration = bounded((lower + postureReference * 0.8) / 2, 0.06, 0.06, 0.3)
            pointer.repositioning.freezeAcceleration = bounded(max(rawUpper * 1.5,
                percentile(posture.rawAcceleration, 0.7), pointer.repositioning.cautionAcceleration * 2), 0.24, 0.18, 0.8)
            pointer.repositioning.cautiousGain = bounded(0.55 + usualHigh / max(postureReference, 0.01), 0.6, 0.55, 0.8)
            if !posture.recoveryTimes.isEmpty {
                pointer.repositioning.settleTime = bounded(percentile(posture.recoveryTimes, 0.5) * 0.3, 0.1, 0.06, 0.12)
            }
            postureLearned = true
        } else {
            notes.append(coverage < 0.8 ? "Acceleration was unavailable. Existing posture settings were retained."
                : outsidePostureRange ? "Recorded acceleration exceeded the automatic tuning range. Existing posture settings were retained."
                : "Posture movement was not distinct enough from normal head motion. Existing posture settings were retained; repeat posture capture to try again.")
        }
        let n = Double(max(1, posture.accelerationCount))
        let axisRMS = Vec3(sqrt(posture.axisEnergy.x/n), sqrt(posture.axisEnergy.y/n), sqrt(posture.axisEnergy.z/n))
        let profile = CalibrationProfile(date: date, sourceID: sources.first ?? "headphones",
            sampleCount: recordings.values.reduce(0) { $0 + $1.samples.count }, slowSpeed: slowReference, fastSpeed: fastReference,
            precisionMaximumSpeed: slowEdge, travelMinimumSpeed: fastEdge,
            leftTiltPeak: percentile(leftValid.map(\.peak), 0.5), rightTiltPeak: percentile(rightValid.map(\.peak), 0.5),
            minimumTiltAngle: minimumTilt,
            repositioningLearned: postureLearned, postureAccelerationRMS: axisRMS, notes: notes,
            ordinaryResidualUpperBound: usualHigh, ordinaryRawUpperBound: rawUpper)
        return CalibrationAnalysis(report: CalibrationReport(pointer: pointer, gestures: gestures, profile: profile, neutralRoll: restRoll), issues: [])
    }

    public static func stepFeedback(_ recording: CalibrationRecording, recordings: [CalibrationPhase: CalibrationRecording],
                                    baseline: AppSettings) -> CalibrationStepFeedback {
        let rest = recordings[.neutral]?.samples ?? []
        let restRoll = medianAngle(rest.map(\.roll))
        let rollNoise = percentile(rest.map { abs(AngleMath.wrappedDeltaDegrees(AngleMath.degrees($0.roll), restRoll)) }, 0.95)
        var filter = baseline.pointer.filter
        if !rest.isEmpty {
            let yaw = medianAngle(rest.map(\.yaw)), pitch = medianAngle(rest.map(\.pitch))
            let yawNoise = percentile(rest.map { abs(AngleMath.wrappedDeltaDegrees(AngleMath.degrees($0.yaw), yaw)) }, 0.5)
            let pitchNoise = percentile(rest.map { abs(AngleMath.wrappedDeltaDegrees(AngleMath.degrees($0.pitch), pitch)) }, 0.5)
            filter.measurementNoise = bounded(max(yawNoise, pitchNoise) * 1.4826, 0.15, 0.03, 0.5)
        }
        let measured = track(recording.samples, filter: filter)
        let speeds = measured.rates.map { hypot($0.yaw, $0.pitch) }
        let clean = recording.samples.count >= 40 && recording.elapsed >= recording.phase.duration * 0.9
            && recording.gaps <= 1 && recording.rejectedSamples <= max(3, recording.samples.count/20)
            && recording.samples.allSatisfy(\.isFinite) && Set(recording.samples.map(\.sourceID)).count == 1
        guard clean else { return CalibrationStepFeedback(title: "Signal interrupted", detail: "Repeat this sample with a steady connection.", needsRepeat: true) }
        switch recording.phase {
        case .neutral:
            let roll = medianAngle(recording.samples.map(\.roll))
            let spread = percentile(recording.samples.map { abs(AngleMath.wrappedDeltaDegrees(AngleMath.degrees($0.roll), roll)) }, 0.95)
            let still = percentile(speeds, 0.95) <= 6 && spread <= 2 && percentile(measured.rawAcceleration, 0.95) <= 0.06
            return CalibrationStepFeedback(title: still ? "Resting sample captured" : "Try resting again",
                detail: String(format: "Resting angular speed %.1f°/s; sideways variation %.1f°. %@", percentile(speeds, 0.95), spread,
                               still ? "This sets your movement noise margin." : "Look ahead naturally without deliberate turns."), needsRepeat: !still)
        case .slowPointing, .fastPointing:
            let restRates = track(rest, filter: filter).rates.map { hypot($0.yaw, $0.pitch) }
            let noise = percentile(restRates, 0.95)
            let floor = max(0.25, bounded(noise * 1.3, 1.2, 0.3, 3) * 1.2)
            let active = measured.rates.filter { hypot($0.yaw, $0.pitch) > floor }
            let both = active.count >= 25 && active.filter { abs($0.yaw) > floor }.count >= 10 && active.filter { abs($0.pitch) > floor }.count >= 10
            let rate = percentile(active.map { hypot($0.yaw, $0.pitch) }, 0.6)
            if recording.phase == .fastPointing, let slow = recordings[.slowPointing], both {
                let slowRate = percentile(track(slow.samples, filter: filter).rates.map { hypot($0.yaw, $0.pitch) }.filter { $0 > floor }, 0.6)
                if rate < max(slowRate * 1.5, slowRate + max(1, noise * 2)) {
                    return CalibrationStepFeedback(title: "Try a clearer travel pace", detail: "Fast and slow movement were too similar. Use your comfortable screen-crossing pace, then repeat.", needsRepeat: true)
                }
            }
            return CalibrationStepFeedback(title: both ? "\(recording.phase == .slowPointing ? "Slow" : "Fast") movement measured" : "Include both directions",
                detail: String(format: "Typical movement %.1f°/s. %@", rate, both ? "You will try the cursor response and adjust its range in the feedback rounds." : "Turn left/right and up/down, then repeat this step."), needsRepeat: !both)
        case .leftTilt, .rightTilt:
            let moves = tilts(recording.samples, neutral: restRoll, noise: rollNoise)
            let peak = percentile(moves.map(\.peak), 0.5)
            let sign = percentile(moves.map(\.sign), 0.5)
            let valid = moves.filter { $0.sign == sign }.count >= 3
            if recording.phase == .rightTilt, let left = recordings[.leftTilt] {
                let leftMoves = tilts(left.samples, neutral: restRoll, noise: rollNoise)
                if !leftMoves.isEmpty, sign == percentile(leftMoves.map(\.sign), 0.5) {
                    return CalibrationStepFeedback(title: "Both tilts went the same way", detail: "Repeat with your right ear toward your right shoulder.", needsRepeat: true)
                }
            }
            return CalibrationStepFeedback(title: valid ? "\(moves.count) completed tilts" : "Three upright returns needed",
                detail: String(format: "Typical tilt %.1f°. %@", peak, valid ? "The click threshold will leave an effort buffer; test it in preview." : "Tilt comfortably, hold briefly, and return upright three times."), needsRepeat: !valid)
        case .repositioning:
            let analysis = analyze(recordings, baseline: baseline)
            if let report = analysis.report {
                return CalibrationStepFeedback(title: report.profile.repositioningLearned ? "Posture sample distinguished" : "Posture sample overlaps normal motion",
                    detail: report.profile.repositioningLearned ? String(format: "Slowdown starts above %.3f g with sustained evidence. Quiet recovery is about %.0f ms. You can report false pauses in preview.", report.pointer.repositioning.cautionAcceleration, report.pointer.repositioning.settleTime*1000)
                    : report.profile.notes.joined(separator: " "), needsRepeat: false)
            }
            return CalibrationStepFeedback(title: "Posture sample captured", detail: "Review will identify any earlier samples that need another try.", needsRepeat: false)
        }
    }
}
