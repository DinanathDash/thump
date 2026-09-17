import Foundation
import simd

private struct RecentSample {
    let timestamp: TimeInterval
    let filteredMagnitude: Double
    let highPassMagnitude: Double
    let jerkMagnitude: Double
    let lowPass: SIMD3<Double>
    let lowFrequencyStep: Double
}

final class ThumpKnockDetector {
    private static let preImpactQuietWindow: TimeInterval = 0.28
    private static let motionWindow: TimeInterval = 0.40
    private static let impulseWindow: TimeInterval = 0.14
    private static let historyWindow: TimeInterval = 1.5
    private static let quietTailExclusion: TimeInterval = 0.03
    private static let motionTailExclusion: TimeInterval = 0.07
    private static let motionLockoutDuration: TimeInterval = 0.9

    private var lowPass = SIMD3<Double>(repeating: 0)
    private var previousSample = SIMD3<Double>(repeating: 0)
    private var previousLowPass = SIMD3<Double>(repeating: 0)
    private var lastPeak: Double = 0
    private var hasInitialized = false
    private var recentKnockTimes: [TimeInterval] = []
    private var lastAcceptedImpactTime: TimeInterval = -.infinity
    private var lastTimestamp: TimeInterval?
    private var noiseFloor: Double = 0.01
    private var motionLockoutUntil: TimeInterval = -.infinity
    private var history: [RecentSample] = []
    
    // For visualization
    var onWaveformSample: ((Double) -> Void)?

    func reset() {
        lowPass = SIMD3<Double>(repeating: 0)
        previousSample = SIMD3<Double>(repeating: 0)
        previousLowPass = SIMD3<Double>(repeating: 0)
        lastPeak = 0
        hasInitialized = false
        recentKnockTimes.removeAll()
        lastAcceptedImpactTime = -.infinity
        lastTimestamp = nil
        noiseFloor = 0.01
        motionLockoutUntil = -.infinity
        history.removeAll()
    }

    func process(sample: SIMD3<Double>, threshold: Double, groupingWindow: Double, cooldown: Double, now: TimeInterval) -> Int? {
        if !hasInitialized {
            lowPass = sample
            previousSample = sample
            previousLowPass = sample
            hasInitialized = true
            lastTimestamp = now
        }

        let sampleRate: Double
        if let lastTimestamp {
            let deltaTime = max(now - lastTimestamp, 0.000_1)
            sampleRate = 1 / deltaTime
        } else {
            sampleRate = 0
        }
        self.lastTimestamp = now

        lowPass += (sample - lowPass) * 0.08
        let lowFrequencyStep = simd_length(lowPass - previousLowPass)
        previousLowPass = lowPass
        let highPass = sample - lowPass
        let jerk = sample - previousSample
        previousSample = sample

        let highPassMagnitude = simd_length(highPass)
        let jerkMagnitude = simd_length(jerk)
        let filteredMagnitude = max(highPassMagnitude, jerkMagnitude * 0.92)
        
        // Pass waveform data for UI visualization (clamped 0 to 1.2)
        onWaveformSample?(min(max(filteredMagnitude * 20.0, 0), 1.2))

        appendHistory(
            RecentSample(
                timestamp: now,
                filteredMagnitude: filteredMagnitude,
                highPassMagnitude: highPassMagnitude,
                jerkMagnitude: jerkMagnitude,
                lowPass: lowPass,
                lowFrequencyStep: lowFrequencyStep
            ),
            now: now
        )

        let adaptiveThreshold = updateAdaptiveThreshold(baseThreshold: threshold, signal: filteredMagnitude)
        let sequenceIsOpen = (recentKnockTimes.last.map { now - $0 <= groupingWindow } ?? false)
        let quietWindow = recentSamples(within: Self.preImpactQuietWindow, now: now, excludingTail: Self.quietTailExclusion)
        let quietAverage = averageFilteredMagnitude(in: quietWindow)
        let quietMax = quietWindow.map(\.filteredMagnitude).max() ?? 0
        let motionContext = recentSamples(
            within: Self.motionWindow,
            now: now,
            excludingTail: Self.motionTailExclusion
        )
        let lowFrequencyMotion = averageLowFrequencyStep(in: motionContext)
        let orientationDrift = orientationDrift(in: motionContext, currentLowPass: lowPass)

        if shouldEnterMotionLockout(
            lowFrequencyMotion: lowFrequencyMotion,
            orientationDrift: orientationDrift,
            threshold: adaptiveThreshold,
            sequenceIsOpen: sequenceIsOpen
        ) {
            motionLockoutUntil = max(motionLockoutUntil, now + Self.motionLockoutDuration)
        }

        let isInMotionLockout = now < motionLockoutUntil
        let impulseDuration = durationAboveThreshold(
            in: recentSamples(within: Self.impulseWindow, now: now),
            threshold: adaptiveThreshold * 0.55,
            fallbackSampleInterval: sampleRate > 0 ? 1 / sampleRate : 0.01
        )

        let baselineQuiet = quietAverage < adaptiveThreshold * 0.75 && quietMax < adaptiveThreshold * 1.2
        let isSharpImpulse = jerkMagnitude > adaptiveThreshold * 0.40 || jerkMagnitude > highPassMagnitude * 0.60
        let briefImpulse = impulseDuration <= (sequenceIsOpen ? 0.25 : 0.20)
        let passesSequenceGate = sequenceIsOpen || baselineQuiet

        if filteredMagnitude > adaptiveThreshold,
           now - lastAcceptedImpactTime >= cooldown,
           !isInMotionLockout,
           passesSequenceGate,
           isSharpImpulse,
           briefImpulse
        {
            recentKnockTimes.append(now)
            lastAcceptedImpactTime = now
            lastPeak = filteredMagnitude
        }

        var emittedPattern: Int? = nil

        // FIRST: emission check (silence >= groupingWindow)
        if let lastKnockTime = recentKnockTimes.last,
           now - lastKnockTime >= groupingWindow,
           !recentKnockTimes.isEmpty
        {
            emittedPattern = min(recentKnockTimes.count, 4) // max 4 taps
            recentKnockTimes.removeAll()
        }

        // THEN: stale entries cleanup (only matters when no emission happened)
        recentKnockTimes = recentKnockTimes.filter { now - $0 <= groupingWindow * 3.0 }

        return emittedPattern
    }

    private func appendHistory(_ sample: RecentSample, now: TimeInterval) {
        history.append(sample)
        history.removeAll { now - $0.timestamp > Self.historyWindow }
    }

    private func recentSamples(
        within duration: TimeInterval,
        now: TimeInterval,
        excludingTail tail: TimeInterval = 0
    ) -> ArraySlice<RecentSample> {
        history.filter { sample in
            let age = now - sample.timestamp
            return age <= duration && age >= tail
        }[...]
    }

    private func updateAdaptiveThreshold(baseThreshold: Double, signal: Double) -> Double {
        let cappedSignal = min(signal, max(baseThreshold * 0.9, noiseFloor * 2.5))
        noiseFloor = (noiseFloor * 0.97) + (cappedSignal * 0.03)
        return max(baseThreshold, (noiseFloor * 3.2) + 0.015)
    }

    private func averageFilteredMagnitude(in samples: ArraySlice<RecentSample>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0) { $0 + $1.filteredMagnitude }
        return sum / Double(samples.count)
    }

    private func averageLowFrequencyStep(in samples: ArraySlice<RecentSample>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0) { $0 + $1.lowFrequencyStep }
        return sum / Double(samples.count)
    }

    private func orientationDrift(in samples: ArraySlice<RecentSample>, currentLowPass: SIMD3<Double>) -> Double {
        guard let earliest = samples.first else { return 0 }
        return simd_length(currentLowPass - earliest.lowPass)
    }

    private func shouldEnterMotionLockout(
        lowFrequencyMotion: Double,
        orientationDrift: Double,
        threshold: Double,
        sequenceIsOpen: Bool
    ) -> Bool {
        if sequenceIsOpen {
            return false
        }

        let lowFrequencyLimit = max(0.015, threshold * 0.25)
        let orientationLimit = max(0.120, threshold * 1.00)
        return lowFrequencyMotion > lowFrequencyLimit || orientationDrift > orientationLimit
    }

    private func durationAboveThreshold(
        in samples: ArraySlice<RecentSample>,
        threshold: Double,
        fallbackSampleInterval: Double
    ) -> Double {
        guard !samples.isEmpty else { return 0 }

        var total: Double = 0
        let sampleArray = Array(samples)

        for (index, sample) in sampleArray.enumerated() {
            guard sample.filteredMagnitude > threshold else { continue }

            let delta: Double
            if index > 0 {
                delta = max(sample.timestamp - sampleArray[index - 1].timestamp, 0)
            } else {
                delta = fallbackSampleInterval
            }

            total += delta
        }

        return total
    }
}
