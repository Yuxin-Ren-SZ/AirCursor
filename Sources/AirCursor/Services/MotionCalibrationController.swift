import AppKit
import Combine
import AirCursorCore

struct CalibrationLiveReadout {
    var yawRate = 0.0, pitchRate = 0.0, roll = 0.0
    var acceleration: Vec3?
    var fresh = false
}

/// Owns one opt-in session. Raw samples never leave this object or get persisted.
/// All preview output is virtual; AppController inhibits real input for the session.
@MainActor
final class MotionCalibrationController: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var phase: CalibrationPhase = .neutral
    @Published private(set) var completed: Set<CalibrationPhase> = []
    @Published private(set) var isRecording = false
    @Published private(set) var countdown = 0
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Ready to personalize head control."
    @Published private(set) var live = CalibrationLiveReadout()
    @Published private(set) var history: [CalibrationLiveReadout] = []
    @Published private(set) var report: CalibrationReport?
    @Published private(set) var issues: [CalibrationIssue] = []
    @Published private(set) var previewPosition = Vec2(260, 110)
    @Published private(set) var previewLeftClicks = 0
    @Published private(set) var previewRightClicks = 0
    @Published private(set) var previewGate: InputGateState = .normal
    @Published private(set) var readyToApply = false
    @Published private(set) var stepFeedback: CalibrationStepFeedback?
    @Published private(set) var display = CalibrationDisplay()
    @Published private(set) var previewMode: CalibrationPreviewMode = .precision
    @Published private(set) var trial = CalibrationTrialMetrics()
    @Published private(set) var previewReason: InputGateReason = .none
    @Published private(set) var feedbackChanges: [String] = []
    @Published private(set) var canUndoFeedback = false

    private var recordings: [CalibrationPhase: CalibrationRecording] = [:]
    private var capture: CalibrationCapture?
    private var countdownTask: Task<Void, Never>?
    private var sourceID: String?
    private(set) var sourceChanged = false
    private var differentiator = MotionDifferentiator()
    private var rollOrigin: Double?
    private var lastHostSample = -Double.infinity
    private var lastPublish = -Double.infinity
    private var previewPipeline: HeadControlPipeline?
    private var previewSmoother = PointerSmoother()
    private var lastPreviewFrame: Double?
    private var neutralSince: Double?
    private var baseline = AppSettings()
    private var feedbackUndo: [CalibrationReport] = []
    private var lastTrialTimestamp: Double?
    private var lastHitTarget: Int?
    var previewGeometry: CalibrationPreviewGeometry { CalibrationPreviewGeometry(display: display, mode: previewMode) }
    var roundNumber: Int { (report?.profile.refinementCount ?? 0) + 1 }
    var recordedNeutralRoll: Double? {
        guard let samples = recordings[.neutral]?.samples, let first = samples.first else { return nil }
        let values = samples.map { AngleMath.degrees(AngleMath.wrappedDelta($0.roll, first.roll)) }.sorted()
        return AngleMath.degrees(first.roll) + values[values.count / 2]
    }

    func begin(using settings: AppSettings = AppSettings(), display: CalibrationDisplay = CalibrationDisplay()) {
        finish()
        baseline = settings
        self.display = display
        isActive = true
        phase = .neutral
        status = "Head control is paused. Use your mouse or keyboard for this guide."
    }

    func finish() {
        countdownTask?.cancel(); countdownTask = nil
        isActive = false; isRecording = false; countdown = 0; progress = 0
        recordings.removeAll(); capture = nil; completed.removeAll()
        sourceID = nil; sourceChanged = false; report = nil; issues = []
        previewPipeline = nil; previewSmoother.reset(); differentiator.reset()
        readyToApply = false; neutralSince = nil
        rollOrigin = nil; live = CalibrationLiveReadout(); history = []; lastHostSample = -.infinity
        lastPublish = -.infinity; previewMode = .precision
        previewGate = .normal; previewReason = .none
        previewLeftClicks = 0; previewRightClicks = 0
        stepFeedback = nil; trial = CalibrationTrialMetrics(); feedbackUndo = []
        feedbackChanges = []; canUndoFeedback = false; lastTrialTimestamp = nil; lastHitTarget = nil
    }

    func select(_ phase: CalibrationPhase) {
        guard !sourceChanged else { return }
        countdownTask?.cancel(); countdown = 0; isRecording = false
        self.phase = phase; progress = completed.contains(phase) ? 1 : 0
        report = nil; previewPipeline = nil; previewSmoother.reset(); capture = nil
        readyToApply = false; neutralSince = nil
        rollOrigin = nil; differentiator.reset()
        issues = []
        stepFeedback = recordings[phase].map { CalibrationAnalyzer.stepFeedback($0, recordings: recordings, baseline: baseline) }
        status = completed.contains(phase) ? "Sample recorded. Repeat it or continue." : phase.instruction
    }

    func startRecording() {
        guard isActive, !sourceChanged, !isRecording, countdown == 0 else { return }
        guard live.fresh else { status = "Waiting for live AirPods motion. Check the connection and sound output."; return }
        countdown = 2
        status = "Return upright. Recording starts in two seconds."
        countdownTask = Task { [weak self] in
            for remaining in [1, 0] {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.isActive else { return }
                self.countdown = remaining
            }
            guard let self, !self.sourceChanged else { return }
            guard self.live.fresh else { self.status = "Motion stopped. Reconnect and record this step again."; return }
            self.capture = CalibrationCapture(phase: self.phase)
            self.recordings[self.phase] = nil
            self.completed.remove(self.phase)
            self.progress = 0; self.rollOrigin = nil
            self.stepFeedback = nil
            self.isRecording = true; self.status = self.phase.instruction
        }
    }

    func analyze(using settings: AppSettings, screenWidth: Double) {
        guard isActive, !isRecording, countdown == 0, !sourceChanged else { return }
        let analysis = CalibrationAnalyzer.analyze(recordings, baseline: settings, screenWidth: screenWidth)
        issues = analysis.issues
        if var report = analysis.report {
            report.profile.display = display
            self.report = report
            feedbackUndo = []; canUndoFeedback = false; feedbackChanges = []
            status = "Try these personal starting points in the preview, then apply when comfortable."
            resetPreview(report)
        } else { report = nil; status = "Some samples need another try. Your settings have not changed." }
    }

    func tuneCurrent(using settings: AppSettings, display: CalibrationDisplay, neutralRoll: Double) {
        guard var profile = settings.calibrationProfile else { return }
        begin(using: settings, display: display)
        profile.display = display
        let report = CalibrationReport(pointer: settings.pointer, gestures: settings.gestures, profile: profile, neutralRoll: neutralRoll)
        self.report = report
        status = "Try your saved controls, give feedback, and update without repeating capture."
        resetPreview(report)
    }

    func setDisplay(_ display: CalibrationDisplay) {
        let previous = self.display
        self.display = display
        if var report, previous != display {
            report.profile.display = display
            let gain = report.pointer.travelGain * display.width / max(320, previous.width)
            if gain.isFinite { report.pointer.travelGain = min(120, max(report.pointer.precisionGain, gain)) }
            self.report = report
            resetPreview(report)
        }
    }

    func setPreviewMode(_ mode: CalibrationPreviewMode) {
        previewMode = mode; previewPosition = Vec2(260,110)
        previewSmoother.reset(); lastPreviewFrame = nil; lastHitTarget = nil
    }

    func applyFeedback(_ feedback: CalibrationFeedback) {
        guard let report, feedback.hasResponse, !sourceChanged else { return }
        feedbackUndo.append(report)
        feedbackUndo = Array(feedbackUndo.suffix(20))
        let updated = CalibrationRefiner.refine(report, feedback: feedback, metrics: trial)
        self.report = updated
        feedbackChanges = updated.profile.refinements.last?.changes ?? []
        canUndoFeedback = true
        resetPreview(updated)
    }

    func undoFeedback() {
        guard let report = feedbackUndo.popLast() else { return }
        self.report = report; canUndoFeedback = !feedbackUndo.isEmpty
        feedbackChanges = ["Restored the previous round's settings. Try them again before applying."]
        resetPreview(report)
    }

    func connectionInterrupted() {
        guard isActive, sourceID != nil else { return }
        sourceChanged = true; isRecording = false
        countdownTask?.cancel(); countdown = 0
        readyToApply = false; neutralSince = nil
        previewSmoother.reset(); previewPipeline = nil; report = nil
        status = "Headphones disconnected during calibration. Restart to avoid mixing sensor references."
        issues = [CalibrationIssue(phase: .neutral, message: status)]
    }

    func editPreview(_ edit: (inout CalibrationReport) -> Void) {
        guard var report else { return }
        edit(&report)
        self.report = report
        resetPreview(report)
    }

    func recenterPreview() {
        previewPosition = Vec2(260, 110)
        previewSmoother.reset(); lastHitTarget = nil
    }

    private func resetPreview(_ report: CalibrationReport) {
        previewPipeline = HeadControlPipeline(pointer: report.pointer, gestures: report.gestures)
        previewPipeline?.gestures.resetTiltBaseline(to: report.neutralRoll)
        previewSmoother.reset(); lastPreviewFrame = nil
        readyToApply = false; neutralSince = nil
        previewPosition = Vec2(260, 110); previewLeftClicks = 0; previewRightClicks = 0
        trial = CalibrationTrialMetrics(); lastTrialTimestamp = nil; lastHitTarget = nil
    }

    func push(_ sample: MotionSample, hostTime: Double) {
        guard isActive else { return }
        guard sample.isFinite else {
            if isRecording { capture?.push(sample) }
            readyToApply = false; neutralSince = nil
            previewSmoother.reset(); previewPipeline?.suspend()
            previewGate = .frozen; previewReason = .invalidSignal
            status = "Invalid sensor data — waiting for a clean signal."
            return
        }
        lastHostSample = hostTime
        if let sourceID, sourceID != sample.sourceID {
            sourceChanged = true; isRecording = false; countdownTask?.cancel(); countdown = 0
            previewSmoother.reset(); previewPipeline = nil
            readyToApply = false; neutralSince = nil
            report = nil; status = "The motion source changed. Restart calibration with the same headphones."
            issues = [CalibrationIssue(phase: .neutral, message: status)]
            return
        }
        sourceID = sample.sourceID
        let rates = differentiator.push(sample)
        rollOrigin = rollOrigin ?? AngleMath.degrees(sample.roll)
        if hostTime - lastPublish >= 0.1 {
            lastPublish = hostTime
            live = CalibrationLiveReadout(yawRate: rates?.yaw ?? 0, pitchRate: rates?.pitch ?? 0,
                roll: AngleMath.wrappedDeltaDegrees(AngleMath.degrees(sample.roll), rollOrigin ?? 0),
                acceleration: sample.userAcceleration, fresh: true)
            history.append(live)
            if history.count > 80 { history.removeFirst(history.count - 80) }
        }
        if isRecording {
            status = phase.instruction
            capture?.push(sample)
            if let capture {
                progress = min(1, capture.recording.elapsed / phase.duration)
                if capture.sourceChanged {
                    isRecording = false; sourceChanged = true
                    status = "The motion source changed. Restart calibration."
                } else if capture.isComplete {
                    recordings[phase] = capture.recording
                    completed.insert(phase); isRecording = false
                    stepFeedback = CalibrationAnalyzer.stepFeedback(capture.recording, recordings: recordings, baseline: baseline)
                    status = "Sample captured. Review its feedback before continuing."
                }
            }
        }
        if var pipeline = previewPipeline {
            let update = pipeline.process(sample, enabled: [.tiltLeft, .tiltRight])
            previewPipeline = pipeline; previewGate = update.gate
            previewReason = update.gateReason
            let dt = sample.timestamp - (lastTrialTimestamp ?? sample.timestamp)
            trial.observe(dt: dt, gate: update.gate, reason: update.gateReason)
            if sample.timestamp > (lastTrialTimestamp ?? -.infinity) { lastTrialTimestamp = sample.timestamp }
            if update.holdingPointer { previewSmoother.reset() }
            previewSmoother.setTarget(update.targetVelocity, at: hostTime)
            if update.gesture?.gesture == .tiltLeft { previewLeftClicks += 1; trial.leftClicks += 1 }
            if update.gesture?.gesture == .tiltRight { previewRightClicks += 1; trial.rightClicks += 1 }
            let neutral = abs(pipeline.gestures.relativeRoll(AngleMath.degrees(sample.roll)))
                < min(pipeline.gestures.settings.angle(for: .tiltLeft), pipeline.gestures.settings.angle(for: .tiltRight)) * 0.5
            let quiet = update.rates.map { max(abs($0.yaw), abs($0.pitch), abs($0.roll)) < 5 } ?? false
            if neutral, quiet, update.allowsAutomaticClicks {
                neutralSince = neutralSince ?? hostTime
                readyToApply = hostTime - (neutralSince ?? hostTime) >= 0.25
            } else { neutralSince = nil; readyToApply = false }
        }
    }

    func advance(now: Double) {
        guard isActive else { return }
        if now - lastHostSample > PointerSmoother.staleAfter, live.fresh {
            live.fresh = false
            previewSmoother.reset()
            previewPipeline?.suspend()
            previewGate = .frozen; previewReason = .stale
            readyToApply = false; neutralSince = nil
            if isRecording { status = "Motion paused — recording resumes when samples return." }
        }
        guard let report else { return }
        let dt = min(max(now - (lastPreviewFrame ?? now), 0), 0.05)
        lastPreviewFrame = now
        let delta = previewSmoother.step(now: now, dt: dt, smoothing: report.pointer.smoothing)
        let geometry = previewGeometry
        previewPosition = geometry.clamp(previewPosition + delta * geometry.scale)
        let targets = geometry.targets
        if let lastHitTarget, previewPosition.distance(to: targets[lastHitTarget]) > 22 { self.lastHitTarget = nil }
        if lastHitTarget == nil, let index = targets.firstIndex(where: { previewPosition.distance(to: $0) <= 13 }) {
            lastHitTarget = index
            if previewMode == .precision, index != 0 && index != 3 { trial.nearTargets += 1 }
            if previewMode == .travel, index == 0 || index == 3 { trial.farTargets += 1 }
        }
    }
}
