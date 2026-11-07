import Foundation
import Testing
import simd
@testable import Thump

@Suite("Chassis Knock Detector (Empirical & Manual Tests)")
struct KnockDetectorTests {
    @Test("First sample initializes baseline gravity and yields nil")
    func initialization() {
        let detector = ThumpKnockDetector()
        #expect(detector.isInitialized == false)

        let result = detector.process(
            sample: TapSimulationStream.standardGravity,
            threshold: 0.020,
            groupingWindow: 0.60,
            cooldown: 0.052,
            now: 100.0
        )

        #expect(detector.isInitialized == true)
        #expect(result == nil)
    }

    @Test("Non-finite samples (NaN and Inf) are discarded safely without poisoning filters")
    func nonFiniteSampleSafety() {
        let detector = ThumpKnockDetector()
        _ = detector.process(
            sample: TapSimulationStream.standardGravity,
            threshold: 0.020,
            groupingWindow: 0.60,
            cooldown: 0.052,
            now: 100.0
        )

        // Inject NaN and Infinity
        let nanSample = SIMD3<Double>(Double.nan, 0.0, 1.0)
        let infSample = SIMD3<Double>(0.0, Double.infinity, 1.0)

        #expect(detector.process(sample: nanSample, threshold: 0.020, groupingWindow: 0.60, cooldown: 0.052, now: 100.01) == nil)
        #expect(detector.process(sample: infSample, threshold: 0.020, groupingWindow: 0.60, cooldown: 0.052, now: 100.02) == nil)

        // Detector continues functioning normally
        #expect(detector.ambientNoiseEnvelope.isFinite)
    }

    @Test("A single tap alone is discarded after silence timeout (Thump requires at least 2 taps)")
    func singleTapDiscarded() {
        let detector = ThumpKnockDetector()
        var t = TapSimulationStream.emitQuietBaseline(to: detector, startTime: 100.0)

        // Single tap impulse
        t = TapSimulationStream.emitSingleTapImpulse(to: detector, at: t)
        #expect(detector.activeTapCount == 1)

        // Advance past silence timeout (groupingWindow = 0.60s)
        var result: Int? = nil
        for _ in 0..<70 {
            t += 0.01
            let res = detector.process(
                sample: TapSimulationStream.standardGravity,
                threshold: 0.020,
                groupingWindow: 0.60,
                cooldown: 0.052,
                now: t
            )
            if res != nil { result = res }
        }

        #expect(result == nil)
        #expect(detector.activeTapCount == 0) // Cleared
    }

    @Test("A double tap within cadence is recognized and returns 2 taps")
    func doubleTapSuccess() {
        let detector = ThumpKnockDetector()
        var t = TapSimulationStream.emitQuietBaseline(to: detector, startTime: 100.0)

        // Tap #1
        t = TapSimulationStream.emitSingleTapImpulse(to: detector, at: t)
        #expect(detector.activeTapCount == 1)

        // 120ms cadence gap
        for _ in 0..<12 {
            t += 0.01
            _ = detector.process(
                sample: TapSimulationStream.standardGravity,
                threshold: 0.020,
                groupingWindow: 0.60,
                cooldown: 0.052,
                now: t
            )
        }

        // Tap #2
        t = TapSimulationStream.emitSingleTapImpulse(to: detector, at: t)
        #expect(detector.activeTapCount == 2)

        // Silence period (> 0.60s grouping window)
        var completed: Int? = nil
        for _ in 0..<65 {
            t += 0.01
            let res = detector.process(
                sample: TapSimulationStream.standardGravity,
                threshold: 0.020,
                groupingWindow: 0.60,
                cooldown: 0.052,
                now: t
            )
            if res != nil { completed = res }
        }

        #expect(completed == 2)
    }

    @Test("A triple tap within cadence returns 3 taps")
    func tripleTapSuccess() {
        let detector = ThumpKnockDetector()
        var t = TapSimulationStream.emitQuietBaseline(to: detector, startTime: 100.0)

        // 3 taps spaced 120ms apart
        for tapIndex in 1...3 {
            t = TapSimulationStream.emitSingleTapImpulse(to: detector, at: t)
            #expect(detector.activeTapCount == tapIndex)

            for _ in 0..<12 {
                t += 0.01
                _ = detector.process(
                    sample: TapSimulationStream.standardGravity,
                    threshold: 0.020,
                    groupingWindow: 0.60,
                    cooldown: 0.052,
                    now: t
                )
            }
        }

        // Silence period (> 0.60s grouping window)
        var completed: Int? = nil
        for _ in 0..<65 {
            t += 0.01
            let res = detector.process(
                sample: TapSimulationStream.standardGravity,
                threshold: 0.020,
                groupingWindow: 0.60,
                cooldown: 0.052,
                now: t
            )
            if res != nil { completed = res }
        }

        #expect(completed == 3)
    }

    @Test("A quad tap emits faster (0.22s timeout) with 4 taps")
    func quadTapSuccess() {
        let detector = ThumpKnockDetector()
        var t = TapSimulationStream.emitQuietBaseline(to: detector, startTime: 100.0)

        // 4 taps spaced 110ms apart
        for tapIndex in 1...4 {
            t = TapSimulationStream.emitSingleTapImpulse(to: detector, at: t)
            #expect(detector.activeTapCount == tapIndex)

            for _ in 0..<11 {
                t += 0.01
                _ = detector.process(
                    sample: TapSimulationStream.standardGravity,
                    threshold: 0.020,
                    groupingWindow: 0.60,
                    cooldown: 0.052,
                    now: t
                )
            }
        }

        // Quad tap completes quickly after 0.22s silence (25 samples of 0.01s)
        var completed: Int? = nil
        for _ in 0..<26 {
            t += 0.01
            let res = detector.process(
                sample: TapSimulationStream.standardGravity,
                threshold: 0.020,
                groupingWindow: 0.60,
                cooldown: 0.052,
                now: t
            )
            if res != nil { completed = res }
        }

        #expect(completed == 4)
    }

    @Test("Impulses arriving faster than cooldown (< 45ms) are rejected as mechanical chassis ring-down")
    func debounceCooldownRejection() {
        let detector = ThumpKnockDetector()
        var t = TapSimulationStream.emitQuietBaseline(to: detector, startTime: 100.0)

        // Tap #1
        t = TapSimulationStream.emitSingleTapImpulse(to: detector, at: t)
        #expect(detector.activeTapCount == 1)

        // Secondary ringing spike only 20ms after tap #1 (< 45ms cooldown)
        t += 0.020
        _ = detector.process(
            sample: TapSimulationStream.standardGravity + SIMD3<Double>(0.03, 0.03, 0.03),
            threshold: 0.020,
            groupingWindow: 0.60,
            cooldown: 0.052,
            now: t
        )

        // Active tap count remains 1 because bounce was debounced
        #expect(detector.activeTapCount == 1)
    }

    @Test("Active typing locks out detection and purges any in-progress tap sequence")
    func typingSuppression() {
        let detector = ThumpKnockDetector()
        var t = TapSimulationStream.emitQuietBaseline(to: detector, startTime: 100.0)

        // Tap #1
        t = TapSimulationStream.emitSingleTapImpulse(to: detector, at: t)
        #expect(detector.activeTapCount == 1)

        // User starts typing on keyboard
        detector.isTypingOverride = true
        t += 0.22
        _ = detector.process(
            sample: TapSimulationStream.standardGravity,
            threshold: 0.020,
            groupingWindow: 0.60,
            cooldown: 0.052,
            now: t
        )

        // Tap sequence is purged
        #expect(detector.activeTapCount == 0)

        // Subsequent tap while typing remains rejected
        t = TapSimulationStream.emitSingleTapImpulse(to: detector, at: t)
        #expect(detector.activeTapCount == 0)
    }

    @Test("Macroscopic laptop movement (e.g. lifting, adjusting lid) locks out detection")
    func macroscopicHandlingRejection() {
        let detector = ThumpKnockDetector()
        var t = TapSimulationStream.emitQuietBaseline(to: detector, startTime: 100.0)

        // Tap #1
        t = TapSimulationStream.emitSingleTapImpulse(to: detector, at: t)
        #expect(detector.activeTapCount == 1)

        // Massive acceleration departure (lifting laptop off table)
        t += 0.22
        _ = detector.process(
            sample: TapSimulationStream.standardGravity + SIMD3<Double>(0.35, 0.25, 0.40),
            threshold: 0.020,
            groupingWindow: 0.60,
            cooldown: 0.052,
            now: t
        )

        // Sequence must be cleared due to macroscopic movement
        #expect(detector.activeTapCount == 0)
    }

    @Test("Fast chassis tilt rotation rejects taps and purges sequences")
    func fastTiltRotationRejection() {
        let detector = ThumpKnockDetector()
        var t = TapSimulationStream.emitQuietBaseline(to: detector, startTime: 100.0)

        // Rotate chassis by > 15 degrees over 0.17 seconds (> 85 deg/sec)
        let tiltedSample = SIMD3<Double>(0.30, 0.10, 0.94)
        t += 0.17
        _ = detector.process(
            sample: tiltedSample,
            threshold: 0.020,
            groupingWindow: 0.60,
            cooldown: 0.052,
            now: t
        )

        // Try tapping during the rotation lockout
        t = TapSimulationStream.emitSingleTapImpulse(to: detector, base: tiltedSample, at: t)
        #expect(detector.activeTapCount == 0)
    }

    @Test("Dynamic profile auto-adapts surface state between desk and lap")
    func dynamicSurfaceAdaptation() {
        let detector = ThumpKnockDetector()
        var t = 100.0

        // 1. On desk: flat pitch (~0.05 / 0.998)
        for _ in 0..<85 {
            t += 0.01
            _ = detector.process(
                sample: TapSimulationStream.standardGravity,
                threshold: 0.020,
                groupingWindow: 0.60,
                cooldown: 0.052,
                now: t,
                surfaceProfile: .dynamic
            )
        }
        #expect(detector.detectedSurfaceState == "DESK")

        // 2. On lap: incline backward (-5 degrees tilt) with elevated micro-sway
        for i in 0..<90 {
            t += 0.01
            let sway = (Double(i % 5) - 2.0) * 0.005
            _ = detector.process(
                sample: TapSimulationStream.lapGravity + SIMD3<Double>(sway, sway, sway),
                threshold: 0.020,
                groupingWindow: 0.60,
                cooldown: 0.052,
                now: t,
                surfaceProfile: .dynamic
            )
        }
        #expect(detector.detectedSurfaceState == "LAP")
    }

    @Test("Waveform sample callback delivers normalized energy values")
    func waveformSampleCallback() {
        let detector = ThumpKnockDetector()
        var highestEnergy = 0.0
        detector.onWaveformSample = { sample in
            highestEnergy = max(highestEnergy, sample)
        }

        var t = TapSimulationStream.emitQuietBaseline(to: detector, startTime: 100.0)
        _ = TapSimulationStream.emitSingleTapImpulse(to: detector, at: t)

        #expect(highestEnergy > 0.0)
        #expect(highestEnergy <= 1.2)
    }

    @Test("Reset clears all history and resets baseline")
    func detectorReset() {
        let detector = ThumpKnockDetector()
        var t = TapSimulationStream.emitQuietBaseline(to: detector, startTime: 100.0)
        t = TapSimulationStream.emitSingleTapImpulse(to: detector, at: t)
        #expect(detector.activeTapCount == 1)

        detector.reset()

        #expect(detector.isInitialized == false)
        #expect(detector.activeTapCount == 0)
    }
}
