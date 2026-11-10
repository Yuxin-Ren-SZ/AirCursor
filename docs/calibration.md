# Developer calibration

Enable **Settings → Shortcuts & General → Developer mode**. Open **Developer →
Open guided calibration**, or use **Motion calibration** in the menu bar.

The guide records natural movements, derives personal starting parameters, and
offers a virtual pointer preview. Nothing changes until **Apply personal settings**.
It is opt-in; the ordinary onboarding tour and existing settings stay available.

## What to record

| Step | Valid sensor time | Movement |
| --- | --- | --- |
| Rest | 4 s | Sit naturally, looking ahead |
| Slow pointing | 10 s | Small left/right and up/down turns for fine adjustments |
| Fast pointing | 8 s | Comfortable left/right and up/down turns for screen travel |
| Left click | 10 s | Three small left tilts, each with a brief hold and upright return |
| Right click | 10 s | Three small right tilts, each with a brief hold and upright return |
| Posture | 8 s | Normal sideways, forward/back and up/down adjustments; pauses between movements |

Each capture has a two-second countdown. Start upright, especially for the tilt
steps. A small comfortable motion is the input to calibration; users do not need
to reach the old 18° threshold. There must be three completed tilts in each direction.

The UI displays live yaw/pitch rates, roll, x/y/z acceleration and recent signal
plots. Sensor outages pause capture time. Interrupted, physically implausible,
missing or ambiguous samples produce a retry instead of a fabricated profile.
Switching motion sources invalidates the session and requires restarting it.

## What is learned

Resting attitude deviation estimates the initial Kalman measurement noise, bounded
to 0.03–0.5°. Resting filtered angular speed sets the dead zone, with a 30% margin,
bounded to 0.3–3°/s. This estimates sensor/resting variability, not user intent.

Pointing speed uses the magnitude of the filtered yaw/pitch rate. Both axes must
be represented in the recordings. Active slow/fast speeds are summarized with
robust percentiles. Fast movement must be clearly distinguishable from slow movement.
Normally, precision extends 20% beyond the slow 80th percentile; full travel gain
begins 20% below the typical fast speed. When those bands overlap, narrower 10%
buffers around the typical speeds are used with a smooth transition.

The gain targets approximately 70 screen points/s at the typical slow movement
and 80% of display width/s at the typical fast movement, within conservative gain
bounds. These are starting heuristics, not measured optimal target-acquisition
performance. The preview lets users inspect and adjust the gains. Calibration
uses the Kalman curve, 1× sensitivity and the standard 0.6 acceleration multiplier;
inversion, smoothing and action bindings are retained.

Tilt calibration finds individual excursions from the recorded resting posture,
requires complete returns, and rejects incomplete or extreme movements. The
threshold is normally 65% of the smaller comfortable peaks, providing effort
margin on the easy side. It is also above ordinary pointing roll plus a noise
margin, and bounded to 3–18°. Overlapping pointing and tilt movement requires a
retry. Left/right angle thresholds and hold times can differ. Hold time is 60%
of a lower-quartile observed plateau, bounded to 150–350 ms. Opposite roll sensor
conventions are learned by comparing the two labeled directions.

The runtime uses these per-side thresholds for the half-threshold target lock,
click hold and neutral-return latch. Returning inside the smaller neutral band
prevents asymmetric settings from allowing repeated clicks. The shared angle and
hold remain the average learned values for users who switch back to shared controls.

## Posture adjustment tuning

AirPods report acceleration, not absolute x/y/z position or translation speed.
The guide therefore learns acceleration thresholds, a cautious cursor gain and
recovery time. It does not integrate acceleration into a position estimate.

Calibration uses the same `RepositioningSignal` as live control, including its
bounded rotational allowance and 80 ms energy smoothing. Ordinary rest, pointing
and tilt samples define a background envelope. Posture samples must separate
clearly from that envelope before the guide changes these settings:

- Caution threshold: between buffered ordinary movement and typical active posture movement.
- Freeze threshold: above ordinary raw acceleration, informed by stronger posture movement;
  at least 1.5 times the caution threshold.
- Cautious movement gain: 0.15–0.5, according to the measured separation.
- Quiet recovery time: observed acceleration settling plus an 80 ms margin, bounded to 160–600 ms.

With missing acceleration or overlapping samples, the existing posture settings
are retained and the review explains why. The profile summarizes acceleration
RMS on all three axes for debugging. Rotations and translations remain imperfectly
separable from this sensor alone; repeat real tasks to check false suppression.

## Preview, persistence and safety

During capture and preview, head-controlled pointer events, gestures, dwell clicks,
scrolling and stem actions are inhibited, including a final guard in the event
synthesizer. Existing drags are released; button-up remains allowed. The virtual
preview uses the real motion pipeline and shows click counts and graded suppression,
but emits no system input. Apply requires a fresh, neutral, still preview for 250 ms.
The session's upright reference is used when normal control resumes, preventing a
held tilt from becoming an immediate desktop click. That session reference is not
persisted as a universal neutral pose across headphone reconnects.

Applying saves only the pointer/gesture settings and a short dated profile. One
previous settings/profile snapshot enables **Undo last calibration** in Developer.
Canceling, closing the window, or disabling Developer mode discards recordings and
restores the preceding tracking state. A changed sensor leaves tracking paused.
The application guards input centrally as well as disabling its sampling actions.

Raw motion stays in memory. Each phase is bounded to 6,000 samples; live charts
retain 80 readouts. No files, network requests, new permissions or telemetry are
introduced. Developer mode and the profile decode leniently in older settings;
per-side tilt fields fall back to the existing shared controls when absent.

## Future guide integration

`CalibrationPhase`, `CalibrationCapture` and `CalibrationAnalyzer` are pure core
components. `MotionCalibrationController` owns temporary UI/session state, while
`AppController` owns input inhibition, apply and undo. The six-step flow can be
reused in future onboarding without changing signal analysis or persistence.
Learning is currently explicit per completed session, not passive inference from
unlabeled everyday head movement.

Run `swift test` with a complete Xcode installation. Tests cover the analyzer,
per-side runtime gestures, bad captures, missing acceleration, posture overlap,
profiles/undo serialization, countdown cancellation and source-change invalidation.
