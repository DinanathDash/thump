import Foundation
import simd
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Detects physical tap impulses on the MacBook chassis using real-time
/// acceleration derivative analysis (jerk filtering) and adaptive noise profiling.
public final class ThumpKnockDetector {
    /// Callback delivering normalized transient energy levels (0.0 to 1.2) for HUD and settings visualizers.
    public var onWaveformSample: ((Double) -> Void)?

    // MARK: - State Tracking

    private var baselineGravity = SIMD3<Double>(0, 0, 0)
    private var previousAcceleration = SIMD3<Double>(0, 0, 0)
    private var isInitialized = false

    /// Running estimate of ambient chassis vibrations (fans, typing, desk movement).
    private var ambientNoiseEnvelope: Double = 0.01

    /// Detected tap timestamps in the current rhythmic sequence.
    private var recordedTapTimestamps: [TimeInterval] = []
    private var lastRegisteredTapTime: TimeInterval = -100.0
    private var previousSampleTime: TimeInterval = 0.0

    /// Lockout timestamp to suppress false positives during macroscopic laptop movement.
    private var macroscopicMotionLockoutUntil: TimeInterval = 0.0
    private var lastLoggedPeakTime: TimeInterval = 0.0

    /// Rolling window of recent jerk samples to estimate body tremor / micro-sway on lap.
    private var rollingJerkSway: [Double] = []
    private var detectedSurfaceState: String = "DESK"
    private var lastSurfaceLogTime: TimeInterval = 0.0

    // MARK: - Lifecycle

    public init() {}

    /// Resets all internal filters and tap history.
    public func reset() {
        baselineGravity = SIMD3<Double>(0, 0, 0)
        previousAcceleration = SIMD3<Double>(0, 0, 0)
        isInitialized = false
        ambientNoiseEnvelope = 0.01
        recordedTapTimestamps.removeAll()
        lastRegisteredTapTime = -100.0
        previousSampleTime = 0.0
        macroscopicMotionLockoutUntil = 0.0
        lastLoggedPeakTime = 0.0
        rollingJerkSway.removeAll()
        detectedSurfaceState = "DESK"
        lastSurfaceLogTime = 0.0
    }

    // MARK: - Real-Time Processing

    /// Evaluates an incoming accelerometer sample and returns the tap count (2, 3, or 4)
    /// once a tap sequence completes after silence.
    public func process(
        sample: SIMD3<Double>,
        threshold: Double,
        groupingWindow: Double,
        cooldown: Double,
        now: TimeInterval,
        surfaceProfile: ThumpSurfaceProfile = .dynamic
    ) -> Int? {
        if !isInitialized {
            baselineGravity = sample
            previousAcceleration = sample
            previousSampleTime = now
            isInitialized = true
            ThumpLogger.log(String(format: "ThumpKnockDetector initialized with baseline G=%.3f", simd_length(sample)))
            return nil
        }

        // 1. Estimate gravity baseline via low-pass tracking
        baselineGravity += (sample - baselineGravity) * 0.06
        let dynamicHighPass = sample - baselineGravity

        // 2. Compute instantaneous jerk (rate of acceleration change)
        let delta = sample - previousAcceleration
        previousAcceleration = sample

        let jerkMagnitude = simd_length(delta)
        let dynamicMagnitude = simd_length(dynamicHighPass)

        // Rolling sway / tremor variance tracking (sliding window of 80 samples ~0.8s)
        rollingJerkSway.append(jerkMagnitude)
        if rollingJerkSway.count > 80 {
            rollingJerkSway.removeFirst()
        }
        let avgSway = rollingJerkSway.reduce(0, +) / Double(max(rollingJerkSway.count, 1))

        // Chassis pitch incline (degrees): negative values indicate backward tilt toward user
        let pitchRadians = atan2(-baselineGravity.y, sqrt(baselineGravity.x * baselineGravity.x + baselineGravity.z * baselineGravity.z))
        let pitchDegrees = pitchRadians * 180.0 / .pi

        // Evaluate whether active conditions match a lap (soft / cushioned / tilted)
        let isLapCondition: Bool
        switch surfaceProfile {
        case .lap:
            isLapCondition = true
        case .desk:
            isLapCondition = false
        case .dynamic:
            // Dynamic auto-adaptation based on real empirical MacBook measurements:
            // On Desk: pitch is -0.9° to +1.2°.
            // On Lap: pitch is -3.5° to -8.2° (backward incline) and micro-sway is elevated.
            isLapCondition = (pitchDegrees <= -3.5) || (avgSway > 0.0028)
        }

        let newSurfaceLabel = isLapCondition ? "LAP" : "DESK"
        if newSurfaceLabel != detectedSurfaceState && (now - lastSurfaceLogTime > 2.0) {
            detectedSurfaceState = newSurfaceLabel
            lastSurfaceLogTime = now
            ThumpLogger.log(String(format: "[SURFACE] Condition adapted to: %@ (pitch=%.1f deg, sway=%.5f, profile=%@)",
                                  newSurfaceLabel, pitchDegrees, avgSway, surfaceProfile.rawValue))
        }

        // 3. Transient tap energy metric
        // Gated at 0.012 to capture both left and right palm-rest taps equally.
        let transientEnergy = jerkMagnitude >= 0.012 
            ? max(jerkMagnitude * 1.05, min(dynamicMagnitude, 0.065))
            : (jerkMagnitude * 0.4)

        // Emit visualization sample (scaled for UI responsiveness)
        onWaveformSample?(min(max(transientEnergy * 18.0, 0.0), 1.2))

        // 4. Sequence state tracking
        let isSequenceActive = !recordedTapTimestamps.isEmpty && (now - (recordedTapTimestamps.last ?? 0) <= max(0.70, groupingWindow))

        // 5. Active typing suppression
        // When typing on the keyboard, keycaps vibrate the chassis at 0.015-0.025.
        // CGEventSource checks system-wide keyboard activity without requiring permissions.
        var isTyping = false
        #if os(macOS)
        let secondsSinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if secondsSinceKey >= 0.0 && secondsSinceKey < 0.28 {
            isTyping = true
        }
        #endif

        // 6. Macroscopic handling detection (e.g. lifting, adjusting display lid, carrying laptop)
        // Only active when idle (not during an active sequence or immediately following a tap).
        let dynamicHighPassMagnitude = simd_length(dynamicHighPass)
        let totalGOffset = abs(simd_length(sample) - 1.0)
        let isRingDown = (now - lastRegisteredTapTime < 0.25)
        if !isSequenceActive && !isRingDown {
            let isLargeMotion = (dynamicHighPassMagnitude > 0.45 && jerkMagnitude < 0.020) || (totalGOffset > 0.40 && jerkMagnitude < 0.020)
            if isLargeMotion {
                macroscopicMotionLockoutUntil = max(macroscopicMotionLockoutUntil, now + 0.20)
            }
        }

        // 7. Update ambient environmental noise floor (only during quiet baseline)
        if !isSequenceActive && transientEnergy < threshold * 0.75 {
            ambientNoiseEnvelope = (ambientNoiseEnvelope * 0.98) + (transientEnergy * 0.02)
        }

        // Surface-adapted baseline threshold:
        // On a lap, clothing/legs absorb shock, so threshold is scaled down to 0.016.
        let baseEffectiveThreshold: Double
        if isLapCondition {
            baseEffectiveThreshold = max(0.015, min(threshold * 0.78, 0.018))
        } else {
            baseEffectiveThreshold = max(0.020, threshold)
        }
        let adaptiveThreshold = max(baseEffectiveThreshold, (ambientNoiseEnvelope * 1.8) + 0.003)

        // 8. Impulse verification (continuation taps in an active sequence use a refined gate)
        let currentCooldown = isSequenceActive ? max(0.045, min(cooldown, 0.060)) : (isLapCondition ? max(0.048, min(cooldown, 0.060)) : cooldown)
        let isRefractoryCleared = now - lastRegisteredTapTime >= currentCooldown
        let isMotionCleared = (isSequenceActive || now >= macroscopicMotionLockoutUntil) && !isTyping

        let requiredThreshold = isSequenceActive ? max(isLapCondition ? 0.015 : 0.018, baseEffectiveThreshold * 0.80) : adaptiveThreshold
        let requiredJerk = isSequenceActive ? (isLapCondition ? 0.011 : 0.013) : (isLapCondition ? 0.012 : 0.014)

        let exceedsThreshold = transientEnergy > requiredThreshold
        let isTransientSpike = jerkMagnitude > requiredJerk

        // Diagnostic logging whenever a noticeable impulse/vibration occurs
        if (transientEnergy >= 0.012 || jerkMagnitude >= 0.012), (now - lastLoggedPeakTime > 0.040) {
            lastLoggedPeakTime = now
            let passed = exceedsThreshold && isRefractoryCleared && isMotionCleared && isTransientSpike
            var reasons: [String] = []
            if !exceedsThreshold { reasons.append(String(format: "energy %.4f <= req %.4f", transientEnergy, requiredThreshold)) }
            if !isTransientSpike { reasons.append(String(format: "jerk %.4f <= req %.4f", jerkMagnitude, requiredJerk)) }
            if !isRefractoryCleared { reasons.append(String(format: "cooldown (%.0fms < %.0fms)", (now - lastRegisteredTapTime) * 1000, currentCooldown * 1000)) }
            if now < macroscopicMotionLockoutUntil { reasons.append("motion locked") }
            if isTyping { reasons.append("typing active") }

            let resultStr = passed ? "ACCEPTED" : "REJECTED [\(reasons.joined(separator: ", "))]"
            ThumpLogger.log(String(format: "[IMPULSE] [%@] Peak: energy=%.4f (req=%.4f), jerk=%.4f (req=%.4f), G=%.2f -> %@",
                  detectedSurfaceState, transientEnergy, requiredThreshold, jerkMagnitude, requiredJerk, simd_length(sample), resultStr))
        }

        if exceedsThreshold && isRefractoryCleared && isMotionCleared && isTransientSpike {
            recordedTapTimestamps.append(now)
            lastRegisteredTapTime = now
            let delta = recordedTapTimestamps.count > 1 ? String(format: " (+%.0fms)", (now - (recordedTapTimestamps.dropLast().last ?? now)) * 1000) : ""
            ThumpLogger.log(String(format: "[TAP] [%@] Tap #%d registered%@. Total in active sequence: %d",
                  detectedSurfaceState, recordedTapTimestamps.count, delta, recordedTapTimestamps.count))
        }


        // 7. Check if sequence is complete
        var completedSequence: Int? = nil
        if let latestTap = recordedTapTimestamps.last {
            let silence = now - latestTap
            let count = recordedTapTimestamps.count

            // If 4 taps (the maximum supported action) are reached, emit quickly after 0.22s silence.
            // For 2 or 3 taps, wait for the user-configured grouping window of silence.
            let timeout: Double
            if count >= 4 {
                timeout = 0.22
            } else {
                timeout = max(0.35, groupingWindow)
            }

            if silence >= timeout {
                recordedTapTimestamps.removeAll()
                if count >= 2 {
                    completedSequence = min(count, 4)
                    ThumpLogger.log(String(format: "[SEQUENCE] Tap sequence completed with %d tap(s) (silence=%.2fs >= timeout=%.2fs). Forwarding to action runner.",
                          count, silence, timeout))
                } else {
                    ThumpLogger.log(String(format: "[SEQUENCE] Tap sequence ended with only %d tap (silence=%.2fs >= timeout=%.2fs). Discarded: Thump requires at least 2 taps (Double tap) to trigger an action.",
                          count, silence, timeout))
                }
            }
        }

        // Purge expired tap timestamps if grouping cadence was interrupted
        recordedTapTimestamps.removeAll { now - $0 > max(3.0, groupingWindow * 3.0) }

        return completedSequence
    }
}
