import Foundation
import IOKit
import simd

struct TapImpulseRecord: Codable {
    let timestamp: TimeInterval
    let deltaFromPrevMs: Double
    let energy: Double
    let jerk: Double
}

struct TapSequenceRecord: Codable {
    let tapCount: Int
    let totalDurationMs: Double
    let intervalsMs: [Double]
    let peakEnergies: [Double]
}

struct TapRecordingSession: Codable {
    let totalDurationSeconds: Double
    let totalSamples: Int
    let sampleRateHz: Double
    let noiseFloor: Double
    let sequences: [TapSequenceRecord]
    let impulses: [TapImpulseRecord]
}

final class TapRecorderEngine {
    private let accelService = ThumpAccelerometerService()
    private var isRunning = false

    private var sampleCount = 0
    private var startTime: TimeInterval = 0
    private var previousAcceleration = SIMD3<Double>(0, 0, 0)
    private var baselineGravity = SIMD3<Double>(0, 0, 0)
    private var hasBaseline = false

    private var ambientNoiseEnvelope: Double = 0.01

    // Impulse tracking
    private var lastImpulseTime: TimeInterval = 0
    private var recordedImpulses: [TapImpulseRecord] = []
    private var pendingSequenceTaps: [TapImpulseRecord] = []
    private var recordedSequences: [TapSequenceRecord] = []

    func run(durationSeconds: Double, outputJsonPath: String) {
        guard accelService.available() else {
            print("❌ Error: AppleSPU accelerometer is not available on this hardware.")
            exit(1)
        }

        print("\n===================================================================")
        print("   THUMP CHASSIS TAP RECORDER & ANALYZER (Apple Silicon SPU)")
        print("===================================================================")
        print("Session duration: \(Int(durationSeconds)) seconds.")
        print("Instructions:")
        print("  1. Tap naturally on your MacBook palm rest area (left or right side).")
        print("  2. Try a few DOUBLE taps (2 taps).")
        print("  3. Try a few TRIPLE taps (3 taps).")
        print("  4. Try a few QUAD taps (4 taps).")
        print("  5. Pause ~1 second between each sequence.")
        print("-------------------------------------------------------------------")
        print("Starting in:")
        for count in (1...3).reversed() {
            print("  \(count)...", terminator: "")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1.0)
        }
        print(" 🚀 RECORDING NOW! (Start tapping!)")
        print("-------------------------------------------------------------------\n")

        startTime = ProcessInfo.processInfo.systemUptime

        accelService.onSample = { [weak self] sample in
            self?.handleSample(sample)
        }

        guard accelService.start() else {
            print("❌ Error: Failed to start AppleSPU accelerometer service.")
            exit(1)
        }
        isRunning = true

        let runLoop = RunLoop.current
        let endTime = startTime + durationSeconds

        while isRunning && ProcessInfo.processInfo.systemUptime < endTime {
            runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))

            // Check if active sequence has concluded due to silence
            let now = ProcessInfo.processInfo.systemUptime
            if let lastTap = pendingSequenceTaps.last, now - lastTap.timestamp > 0.40 {
                finalizePendingSequence()
            }
        }

        accelService.stop()
        finalizePendingSequence()

        let totalTime = ProcessInfo.processInfo.systemUptime - startTime
        let effectiveHz = Double(sampleCount) / max(totalTime, 0.001)

        print("\n-------------------------------------------------------------------")
        print("🏁 RECORDING COMPLETED in \(String(format: "%.1f", totalTime))s")
        print("Total Samples Processed: \(sampleCount) (~\(String(format: "%.1f", effectiveHz)) Hz)")
        print("Total Impulses Detected: \(recordedImpulses.count)")
        print("Total Sequences Formed:  \(recordedSequences.count)")
        print("-------------------------------------------------------------------")

        printAnalysisAndRecommendations(sampleRateHz: effectiveHz)

        let session = TapRecordingSession(
            totalDurationSeconds: totalTime,
            totalSamples: sampleCount,
            sampleRateHz: effectiveHz,
            noiseFloor: ambientNoiseEnvelope,
            sequences: recordedSequences,
            impulses: recordedImpulses
        )

        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: URL(fileURLWithPath: outputJsonPath))
            print("Saved raw recording data to: \(outputJsonPath)\n")
        }
    }

    private func handleSample(_ sample: ThumpSample) {
        let now = sample.timestamp
        let acc = SIMD3<Double>(sample.x, sample.y, sample.z)
        sampleCount += 1

        if !hasBaseline {
            baselineGravity = acc
            previousAcceleration = acc
            hasBaseline = true
            return
        }

        baselineGravity += (acc - baselineGravity) * 0.05
        let dynamicHighPass = acc - baselineGravity
        let delta = acc - previousAcceleration
        previousAcceleration = acc

        let jerkMagnitude = simd_length(delta)
        let dynamicMagnitude = simd_length(dynamicHighPass)
        let transientEnergy = max(dynamicMagnitude, jerkMagnitude * 0.88)

        // Noise floor tracking
        let capped = min(transientEnergy, 0.08)
        ambientNoiseEnvelope = (ambientNoiseEnvelope * 0.98) + (capped * 0.02)

        // Detect potential tap candidate:
        // Real chassis taps exhibit high instantaneous jerk and low refractory delta
        let lowImpulseCutoff = max(0.035, ambientNoiseEnvelope * 1.8)
        let deltaFromPrevMs = (now - lastImpulseTime) * 1000.0

        // Debounce mechanical ring-down (~45ms)
        if transientEnergy > lowImpulseCutoff, jerkMagnitude > 0.025, deltaFromPrevMs > 45.0 {
            lastImpulseTime = now
            let relativeTimeS = now - startTime

            let impulse = TapImpulseRecord(
                timestamp: now,
                deltaFromPrevMs: deltaFromPrevMs,
                energy: transientEnergy,
                jerk: jerkMagnitude
            )

            recordedImpulses.append(impulse)
            pendingSequenceTaps.append(impulse)

            print(String(format: "  [+%.2fs] 💥 Tap #%d | Energy: %.3f | Jerk: %.3f | Gap: %.0f ms",
                         relativeTimeS,
                         pendingSequenceTaps.count,
                         transientEnergy,
                         jerkMagnitude,
                         deltaFromPrevMs))
            fflush(stdout)
        }
    }

    private func finalizePendingSequence() {
        guard !pendingSequenceTaps.isEmpty else { return }
        let count = pendingSequenceTaps.count
        let first = pendingSequenceTaps.first!.timestamp
        let last = pendingSequenceTaps.last!.timestamp
        let durationMs = (last - first) * 1000.0

        var intervals: [Double] = []
        if count > 1 {
            for i in 1..<count {
                intervals.append((pendingSequenceTaps[i].timestamp - pendingSequenceTaps[i - 1].timestamp) * 1000.0)
            }
        }

        let peaks = pendingSequenceTaps.map(\.energy)
        let sequence = TapSequenceRecord(
            tapCount: count,
            totalDurationMs: durationMs,
            intervalsMs: intervals,
            peakEnergies: peaks
        )
        recordedSequences.append(sequence)

        let intervalStr = intervals.map { String(format: "%.0fms", $0) }.joined(separator: ", ")
        print(String(format: "  👉 SEQUENCE COMPLETED: %d taps in %.0f ms [intervals: %@] (avg peak: %.3f)\n",
                     count,
                     durationMs,
                     intervalStr.isEmpty ? "single" : intervalStr,
                     peaks.reduce(0, +) / Double(max(peaks.count, 1))))
        fflush(stdout)

        pendingSequenceTaps.removeAll()
    }

    private func printAnalysisAndRecommendations(sampleRateHz: Double) {
        guard !recordedSequences.isEmpty else {
            print("\n⚠️  No tap sequences detected. Try tapping a bit firmer next time.")
            return
        }

        let allIntervals = recordedSequences.flatMap(\.intervalsMs)
        let allPeaks = recordedImpulses.map(\.energy)

        let avgInterval = allIntervals.isEmpty ? 160.0 : allIntervals.reduce(0, +) / Double(allIntervals.count)
        let minInterval = allIntervals.min() ?? 100.0
        let maxInterval = allIntervals.max() ?? 250.0

        let avgPeak = allPeaks.isEmpty ? 0.12 : allPeaks.reduce(0, +) / Double(allPeaks.count)
        let minPeak = allPeaks.min() ?? 0.05
        let maxPeak = allPeaks.max() ?? 0.25

        print("\n📊 EMPIRICAL HUMAN TAP CHARACTERISTICS:")
        print("  - Inter-tap Cadence Interval: min=\(String(format: "%.0f", minInterval))ms, avg=\(String(format: "%.0f", avgInterval))ms, max=\(String(format: "%.0f", maxInterval))ms")
        print("  - Tap Impact Force (Energy):   min=\(String(format: "%.3f", minPeak)), avg=\(String(format: "%.3f", avgPeak)), max=\(String(format: "%.3f", maxPeak))")
        print("  - Ambient Noise Floor:         \(String(format: "%.4f", ambientNoiseEnvelope))")

        // Recommended tuning based on real human measurements:
        let recThreshold = max(0.045, min(avgPeak * 0.52, 0.16))
        // Cooldown should be ~60% of minInterval so rapid 4-taps never collide or drop taps
        let recCooldown = max(0.055, min((minInterval * 0.65) / 1000.0, 0.120))
        // Grouping window should be ~1.4x the max normal interval so cadence isn't prematurely sliced
        let recGroupingWindow = max(0.28, min((maxInterval * 1.35) / 1000.0, 0.48))

        print("\n💡 RECOMMENDED CALIBRATED CONFIGURATION:")
        print("  - Threshold:       \(String(format: "%.3f", recThreshold)) (effective sensitivity)")
        print("  - Cooldown:        \(String(format: "%.3f", recCooldown)) s (\(Int(recCooldown * 1000)) ms debounce - prevents dropping fast taps)")
        print("  - Grouping Window: \(String(format: "%.3f", recGroupingWindow)) s (\(Int(recGroupingWindow * 1000)) ms completion timeout)")
        print("-------------------------------------------------------------------\n")
    }
}

@main
struct TapRecorderApp {
    static func main() {
        let defaultPath = "/Users/dinanathdash/.gemini/antigravity-ide/brain/27e51e88-f535-43af-b090-b6e13da34fdf/scratch/tap_recording.json"
        let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultPath
        let duration = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 35.0) : 35.0

        let engine = TapRecorderEngine()
        engine.run(durationSeconds: duration, outputJsonPath: outputPath)
    }
}
