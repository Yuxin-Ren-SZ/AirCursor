# Motion processing and tuning

The default controls are yaw/pitch pointing and roll tilts for left/right clicks.
Hover and nod clicks are off by default; stem controls and shake-to-pause remain.
Version 4 migrates the old stock action bindings to tilt clicks, retaining customized
bindings and non-default tuning. Settings decode missing or mistyped fields leniently.

## Signal acquisition and estimation

`HeadphoneMotionService` forwards CoreMotion attitude, quaternion, device-frame
rotation rate (rad/s), gravity and gravity-compensated user acceleration (g). The
app receives approximately 25 samples/s; it does not request a particular frequency.
CoreMotion has already processed the IMU readings. These are not raw ADC samples.

`KalmanMotionEstimator` has an independent `[angle, angular velocity]` state for
each attitude axis, observing attitude in degrees. The transition is constant
angular velocity. Process covariance comes from uncertain angular acceleration:

```
F = [[1, dt], [0, 1]]
Q = accelerationStdDev² × [[dt⁴/4, dt³/2], [dt³/2, dt²]]
H = [1, 0]
R = attitudeNoiseStdDev²
```

| Parameter | Default |
| --- | --- |
| Starting attitude noise standard deviation | 0.15° |
| Process angular acceleration standard deviation | 100°/s² |
| Initial angular rate standard deviation | 20°/s |
| Valid interval between observations | 2–250 ms |
| Outlier threshold | Larger of 12° or 6 predicted standard deviations |
| Physical angular-rate limit | 720°/s |
| Sustained discontinuity recovery | Reseed after 3 rejected observations; emit no catch-up displacement |

Angle innovations wrap across ±180°. Covariance uses a scalar-observation Joseph
update. Above 10°/s, process acceleration uncertainty increases with observed angular
speed, up to seven times its resting value, to follow deliberate quick turns. During
stillness, 50 consecutive quiet samples enable noise learning with
a 2-second time constant. Quiet requires all attitude changes below 5°/s,
acceleration below 0.025 g and, when present, gyro magnitude below 5°/s. Estimated
noise is bounded to 0.03–0.5°. Successive-angle differences estimate stationary
variance, so this is an approximation for CoreMotion's correlated observations.
It requires real-device validation, not an assumption of Gaussian independent noise.

Device-frame gyro readings are retained for stillness checks and future coordinate
validation. They are not directly substituted for Euler-angle derivatives or fused
as an independent attitude sensor. Quaternion orientation is captured and validated;
this version still maps yaw/pitch rather than implementing a full orientation EKF.

There is no general band-pass filter: removing low frequencies would remove slow,
intentional pointing. Kalman estimation attenuates noise, while a dead zone controls
resting input. Additional smoothing should remain light to avoid excess lag.

## Repositioning gate

The gate is separate from Kalman estimation. Acceleration suggests body movement;
it cannot measure position or detect constant-speed translation, and rotation can
also accelerate the earbuds. Kalman covariance is not an intent probability.

| State | Entry / behavior |
| --- | --- |
| Normal | Full movement and configured gestures |
| Cautious | Residual acceleration magnitude or smoothed RMS ≥0.045 g; movement gain ×0.35, head gestures and hover clicks canceled |
| Frozen | Acceleration ≥0.18 g for 120 ms, or a ≥0.65 g impact; zero motion output, cancel gestures and release drag |
| Invalid signal | Nonfinite data, out-of-order timestamps, gaps or rejected attitude also freeze output |
| Recovery | Raw acceleration <60% of caution threshold and RMS <80%, then quiet for 250 ms |

Ordinary rotation receives a bounded acceleration allowance (up to 0.09 g at 60°/s).
Its angular-speed envelope decays over 120 ms to include braking. This helps avoid
canceling a tilt click because of the tilt's own acceleration. It can also miss body
movement concurrent with rotation; it is not an estimate of translational acceleration.
Strong-movement and impact checks use the original acceleration without this allowance.
Residual acceleration energy uses exponential smoothing with an 80 ms time constant.
Jerk above 4 g/s also enters caution when acceleration exceeds 80% of the caution
threshold. The effective freeze threshold is at least 1.5 times the caution
threshold. The immediate impact threshold is at least three times the freeze
threshold. Missing acceleration allows attitude-only operation and is visible in
Diagnostics. Invalid observations still freeze input when posture suppression is off.

The estimator continues updating during suppression. There is no accumulated
movement to replay. Tilt candidates are canceled, requiring neutral before a new
click. Manual stem actions and hotkeys remain available. A 120 ms delivery timeout
clears motion output, cancels pending clicks and releases drag.

## Pointing and clicking

| Parameter | Default |
| --- | --- |
| Radial dead zone | 1.2°/s; may rise to at most twice the configured value from resting noise |
| Hysteresis | Activate above full threshold, deactivate below 65% |
| Precision gain | 14 screen points/degree |
| Travel gain | 56 screen points/degree at default acceleration 0.6 |
| Gain transition | Smoothstep from 5°/s to 40°/s after the soft dead zone |
| Extra smoothing | 0.18 retention per 1/60 s, corrected for actual frame duration |
| Output timer / maximum frame interval | 120 Hz / 50 ms |
| Tilt angle / hold | 18° / 250 ms |
| Likely-tilt threshold | Half the tilt angle (9°) |
| Neutral return | Below half threshold; then yaw/pitch settles below 15°/s for 120 ms before pointing resumes |

One gain scales both pointer axes, preserving direction on diagonals. Acceleration
controls the difference between precision and travel gains; zero makes gain linear.
Sensitivity scales the entire curve. The Original mode retains differentiation and
the old per-axis gain curve; safety gates and tilt controls remain active. Both
modes use the selected dead zone and extra smoothing, so use 3°/s and 0.55 when
comparing with the old default tuning.

A likely tilt restores the buffered position 60 ms before its onset and locks it
through the click and return. A progress ring shows the hold. A held tilt never
repeats after neutral has been established. The original four-second recovery for
a startup neutral captured while inserting the earbuds is retained. External mouse
movement cancels the pending gesture and adopts the physical pointer position.

## Validation and measurement

Run `swift test` with a complete Xcode installation. Core tests cover noise
attenuation, variable sampling, wrap-around, starts/stops, spikes, discontinuities,
graded suppression, neutral-return clicking, recovery and settings migration.

Settings → Pointer → Compare recent motion replays the latest 250 observations
entirely in memory and reports raw/filtered angular-speed RMS. This measures jitter
only when the head was resting. It does not establish pointing accuracy or latency.
The buffer is never persisted or uploaded. Replaying does not synthesize input.

For device tuning, compare resting jitter, slow target acquisition, fast traversal,
stopping overshoot, both tilt clicks, and seated posture adjustments. Check false
suppression during ordinary turns. Adjust noise/process settings and gains
separately. The supplied defaults are starting values; synthetic tests cannot
establish an improvement in real-world accuracy.

## Future sources

`HeadMotionSource` and `GazeSource` separate acquisition from control. Motion samples
identify their source; switching sources resets derivative/estimator continuity.
`GazeObservation` carries monotonic time, display identity, normalized absolute
position, positional standard deviation and source identity. Head motion is relative;
gaze is absolute, so combining them needs an explicit calibrated policy. No camera
capture, permissions or automatic gaze fusion are enabled by these contracts.
