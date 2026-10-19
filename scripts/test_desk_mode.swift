import Foundation
import IOKit
import IOKit.hid
import simd

// =============================================================================
// THUMP - DESK MODE (30-SECOND EMPIRICAL TAP PROFILER)
// Measures freeform tap impulses, cadences, and energy on a desk for 30s.
// =============================================================================

struct TapRecord: Codable {
    let tapIndex: Int
    let timestamp: TimeInterval
    let relativeSeconds: Double
    let deltaMs: Double
    let energy: Double
    let jerk: Double
    let tiltDegrees: Double
}

struct SequenceRecord: Codable {
    let tapCount: Int
    let durationMs: Double
    let intervalsMs: [Double]
    let peakEnergies: [Double]
}

final class DeskModeTester {
    private static let spuUsagePage = 0xFF00
    private static let spuAccelerometerUsage = 3
    private static let packetByteLength = 22
    private static let payloadStartOffset = 6
    private static let bufferCapacity = 4096
    private static let rawScaleFactor = 65536.0

    private var activeDeviceReferences: [IOHIDDevice] = []
    private let processingQueue = DispatchQueue(label: "com.droppy.thump.desktest", qos: .userInteractive)

    private var isRunning = false
    private var baselineGravity = SIMD3<Double>(0, 0, 0)
    private var previousAcceleration = SIMD3<Double>(0, 0, 0)
    private var hasBaseline = false

    private var startTime: TimeInterval = 0.0
    private var lastTapTime: TimeInterval = 0.0
    private var lastTimerAnnounceTime: TimeInterval = 0.0
    private var recordedTaps: [TapRecord] = []
    private var activeSequenceTaps: [TapRecord] = []
    private var completedSequences: [SequenceRecord] = []
    private var baselineSamples = 0
    private var baselineNoiseFloor = 0.0
    private var noiseAccumulator = 0.0

    func run() {
        setlinebuf(stdout)
        print("\n===================================================================")
        print("      THUMP: DESK MODE (HARD SURFACE) 30-SECOND PROFILER          ")
        print("===================================================================")
        print("This test runs for 30 SECONDS while your MacBook is on a desk/table.")
        print("During this time, tap freely:")
        print("  - Try Double taps (2), Triple taps (3), and Quad taps (4)")
        print("  - Tap on the LEFT palm rest, RIGHT palm rest, or center edges")
        print("  - Try your natural tap force, gentle taps, and firm taps")
        print("-------------------------------------------------------------------")

        guard startSensor() else {
            print("[ERROR] Could not start AppleSPU accelerometer.")
            exit(1)
        }

        print("[CALIBRATING] Establishing baseline stability (1 second)...")
        fflush(stdout)

        let baselineTarget = Date().addingTimeInterval(1.2)
        while Date() < baselineTarget {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        if baselineSamples > 0 {
            baselineNoiseFloor = noiseAccumulator / Double(baselineSamples)
        }

        let pitchRadians = atan2(-baselineGravity.y, sqrt(baselineGravity.x * baselineGravity.x + baselineGravity.z * baselineGravity.z))
        let pitchDegrees = pitchRadians * 180.0 / .pi
        print(String(format: "[BASELINE] Desk Pitch: %.1f deg | Noise Floor: %.5f", pitchDegrees, baselineNoiseFloor))
        if abs(pitchDegrees) > 12.0 {
            print("[WARN] Incline is > 12 deg. Ensure MacBook is resting on a flat desk.")
        } else {
            print("[CONFIRMED] MacBook is flat and stable.")
        }

        print("\nStarting 30-second recording in:")
        for count in (1...3).reversed() {
            print("  \(count)...")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1.0)
        }

        print("\n>>> [RECORDING ACTIVE: 30 SECONDS] Start tapping now! <<<")
        print("-------------------------------------------------------------------")
        fflush(stdout)

        startTime = ProcessInfo.processInfo.systemUptime
        lastTimerAnnounceTime = startTime
        let endTime = startTime + 30.0

        while isRunning && ProcessInfo.processInfo.systemUptime < endTime {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))

            let now = ProcessInfo.processInfo.systemUptime
            let remaining = Int(ceil(endTime - now))

            // Timer countdown every 5 seconds
            if now - lastTimerAnnounceTime >= 5.0 && remaining > 0 {
                lastTimerAnnounceTime = now
                print(String(format: "[TIMER] %d seconds remaining... (taps recorded so far: %d)", remaining, recordedTaps.count))
                fflush(stdout)
            }

            // Finalize sequence if silence > 0.38s
            if let lastTap = activeSequenceTaps.last, now - lastTap.timestamp > 0.38 {
                finalizeActiveSequence()
            }
        }

        stopSensor()
        finalizeActiveSequence()
        printSummary()
    }

    private func startSensor() -> Bool {
        var iter: io_iterator_t = 0
        let driverDict = IOServiceMatching("AppleSPUHIDDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, driverDict, &iter) == KERN_SUCCESS else {
            return false
        }
        if iter != 0 { IOObjectRelease(iter) }

        let matchDict: [String: Any] = [
            kIOHIDDeviceUsagePageKey: Self.spuUsagePage,
            kIOHIDDeviceUsageKey: Self.spuAccelerometerUsage
        ]
        var deviceIter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict as CFDictionary, &deviceIter) == KERN_SUCCESS else {
            return false
        }

        var matchingServices: [io_service_t] = []
        while case let service = IOIteratorNext(deviceIter), service != 0 {
            matchingServices.append(service)
        }
        IOObjectRelease(deviceIter)

        guard !matchingServices.isEmpty else { return false }

        let unretainedSelf = Unmanaged.passUnretained(self).toOpaque()
        for service in matchingServices {
            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
                IOObjectRelease(service)
                continue
            }
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                IOObjectRelease(service)
                continue
            }

            let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferCapacity)
            IOHIDDeviceSetDispatchQueue(device, processingQueue)
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                device,
                reportBuffer,
                Self.bufferCapacity,
                { context, _, _, _, _, report, reportLength, _ in
                    guard let context else { return }
                    let instance = Unmanaged<DeskModeTester>.fromOpaque(context).takeUnretainedValue()
                    instance.processReport(report, length: reportLength)
                },
                unretainedSelf
            )
            IOHIDDeviceSetCancelHandler(device) {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                reportBuffer.deallocate()
            }
            IOHIDDeviceActivate(device)
            activeDeviceReferences.append(device)
            IOObjectRelease(service)
        }

        isRunning = !activeDeviceReferences.isEmpty
        return isRunning
    }

    private func stopSensor() {
        isRunning = false
        for device in activeDeviceReferences {
            IOHIDDeviceCancel(device)
        }
        activeDeviceReferences.removeAll()
    }

    private func processReport(_ report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length == Self.packetByteLength else { return }
        let rawX = readInt32(from: report, at: Self.payloadStartOffset)
        let rawY = readInt32(from: report, at: Self.payloadStartOffset + 4)
        let rawZ = readInt32(from: report, at: Self.payloadStartOffset + 8)

        let sample = SIMD3<Double>(
            Double(rawX) / Self.rawScaleFactor,
            Double(rawY) / Self.rawScaleFactor,
            Double(rawZ) / Self.rawScaleFactor
        )
        let now = ProcessInfo.processInfo.systemUptime

        handleSample(sample, now: now)
    }

    private func handleSample(_ sample: SIMD3<Double>, now: TimeInterval) {
        if !hasBaseline {
            baselineGravity = sample
            previousAcceleration = sample
            hasBaseline = true
            return
        }

        baselineGravity += (sample - baselineGravity) * 0.05
        let delta = sample - previousAcceleration
        previousAcceleration = sample

        let jerkMagnitude = simd_length(delta)
        let dynamicHighPass = sample - baselineGravity
        let dynamicMagnitude = simd_length(dynamicHighPass)

        // Capture full transient impulse (using 0.014 threshold to balance left/right asymmetry)
        let transientEnergy = jerkMagnitude >= 0.014
            ? max(jerkMagnitude * 1.05, min(dynamicMagnitude, 0.070))
            : (jerkMagnitude * 0.4)

        // Baseline measurement phase
        if startTime == 0.0 {
            baselineSamples += 1
            noiseAccumulator += jerkMagnitude
            return
        }

        let pitchRadians = atan2(-baselineGravity.y, sqrt(baselineGravity.x * baselineGravity.x + baselineGravity.z * baselineGravity.z))
        let pitchDegrees = pitchRadians * 180.0 / .pi

        let deltaMs = (now - lastTapTime) * 1000.0

        // Empirical detection floor: 0.015 energy & 0.014 jerk
        if transientEnergy > 0.015, jerkMagnitude > 0.014, deltaMs > 50.0 {
            lastTapTime = now
            let relSec = now - startTime

            let tap = TapRecord(
                tapIndex: recordedTaps.count + 1,
                timestamp: now,
                relativeSeconds: relSec,
                deltaMs: deltaMs,
                energy: transientEnergy,
                jerk: jerkMagnitude,
                tiltDegrees: pitchDegrees
            )
            recordedTaps.append(tap)
            activeSequenceTaps.append(tap)

            print(String(format: "  [+%.2fs] [TAP #%d] Energy: %.4f | Jerk: %.4f | Cadence: %.0f ms",
                         relSec, tap.tapIndex, transientEnergy, jerkMagnitude, deltaMs))
            fflush(stdout)
        }
    }

    private func finalizeActiveSequence() {
        guard !activeSequenceTaps.isEmpty else { return }
        let count = activeSequenceTaps.count
        let first = activeSequenceTaps.first!.timestamp
        let last = activeSequenceTaps.last!.timestamp
        let durationMs = (last - first) * 1000.0

        var intervals: [Double] = []
        if count > 1 {
            for i in 1..<count {
                intervals.append((activeSequenceTaps[i].timestamp - activeSequenceTaps[i - 1].timestamp) * 1000.0)
            }
        }

        let peaks = activeSequenceTaps.map(\.energy)
        let sequence = SequenceRecord(
            tapCount: count,
            durationMs: durationMs,
            intervalsMs: intervals,
            peakEnergies: peaks
        )
        completedSequences.append(sequence)

        let intervalStr = intervals.map { String(format: "%.0fms", $0) }.joined(separator: ", ")
        let avgPeak = peaks.reduce(0, +) / Double(max(peaks.count, 1))

        print(String(format: "  >>> [SEQUENCE #%d] %d taps in %.0f ms [cadence: %@] | avg peak: %.4f <<<\n",
                     completedSequences.count, count, durationMs, intervalStr.isEmpty ? "single tap" : intervalStr, avgPeak))
        fflush(stdout)

        activeSequenceTaps.removeAll()
    }

    private func printSummary() {
        print("\n===================================================================")
        print("               DESK MODE: 30-SECOND TEST RESULTS                   ")
        print("===================================================================")
        print("Total Impulses Detected: \(recordedTaps.count)")
        print("Total Sequences Formed:  \(completedSequences.count)")

        guard !recordedTaps.isEmpty else {
            print("\n[WARN] No taps were detected during the 30-second window.")
            print("Try running again and tapping with slightly firmer contact.")
            return
        }

        let allEnergies = recordedTaps.map(\.energy)
        let minEnergy = allEnergies.min() ?? 0.02
        let maxEnergy = allEnergies.max() ?? 0.08
        let avgEnergy = allEnergies.reduce(0, +) / Double(allEnergies.count)

        let allIntervals = completedSequences.flatMap(\.intervalsMs)
        let minInterval = allIntervals.min() ?? 120.0
        let maxInterval = allIntervals.max() ?? 280.0
        let avgInterval = allIntervals.isEmpty ? 180.0 : allIntervals.reduce(0, +) / Double(allIntervals.count)

        print("\n[EMPIRICAL MEASUREMENTS]:")
        print(String(format: "  - Tap Impact Energy: min=%.4f, avg=%.4f, max=%.4f", minEnergy, avgEnergy, maxEnergy))
        print(String(format: "  - Tap Cadence Gap:   min=%.0f ms, avg=%.0f ms, max=%.0f ms", minInterval, avgInterval, maxInterval))
        print(String(format: "  - Baseline Noise:    %.5f", baselineNoiseFloor))

        // Suggested tuning for Desk mode:
        // Set threshold at 65% of minimum observed tap energy (or 55% of average), clamped 0.022 to 0.038
        let recommendedThreshold = max(0.022, min(minEnergy * 0.75, 0.036))
        let recommendedCooldown = max(0.055, min((minInterval * 0.65) / 1000.0, 0.080))
        let recommendedWindow = max(0.55, min((maxInterval * 1.35) / 1000.0, 0.75))

        print("\n[CALIBRATED PRESET RECOMMENDATION FOR DESK]:")
        print(String(format: "  - Default Threshold:   %.3f", recommendedThreshold))
        print(String(format: "  - Default Window:      %.2f s", recommendedWindow))
        print(String(format: "  - Default Cooldown:    %.3f s (%d ms)", recommendedCooldown, Int(recommendedCooldown * 1000)))
        print("-------------------------------------------------------------------\n")

        let outPath = "/tmp/thump_desk_test.json"
        if let data = try? JSONEncoder().encode(recordedTaps) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("Exported full 30s tap log to: \(outPath)\n")
        }
    }

    private func readInt32(from buffer: UnsafeMutablePointer<UInt8>, at offset: Int) -> Int32 {
        let b0 = UInt32(buffer[offset])
        let b1 = UInt32(buffer[offset + 1]) << 8
        let b2 = UInt32(buffer[offset + 2]) << 16
        let b3 = UInt32(buffer[offset + 3]) << 24
        return Int32(bitPattern: b0 | b1 | b2 | b3)
    }
}

let tester = DeskModeTester()
tester.run()
