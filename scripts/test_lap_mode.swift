import Foundation
import IOKit
import IOKit.hid
import simd

// =============================================================================
// THUMP - LAP MODE (30-SECOND SOFT SURFACE TAP PROFILER)
// Measures freeform tap impulses, cadences, and dampening on your lap for 30s.
// =============================================================================

struct LapTapRecord: Codable {
    let tapIndex: Int
    let timestamp: TimeInterval
    let relativeSeconds: Double
    let deltaMs: Double
    let energy: Double
    let jerk: Double
    let tiltDegrees: Double
    let microSway: Double
}

struct LapSequenceRecord: Codable {
    let tapCount: Int
    let durationMs: Double
    let intervalsMs: [Double]
    let peakEnergies: [Double]
}

final class LapModeTester {
    private static let spuUsagePage = 0xFF00
    private static let spuAccelerometerUsage = 3
    private static let packetByteLength = 22
    private static let payloadStartOffset = 6
    private static let bufferCapacity = 4096
    private static let rawScaleFactor = 65536.0

    private var activeDeviceReferences: [IOHIDDevice] = []
    private let processingQueue = DispatchQueue(label: "com.droppy.thump.laptest", qos: .userInteractive)

    private var isRunning = false
    private var baselineGravity = SIMD3<Double>(0, 0, 0)
    private var previousAcceleration = SIMD3<Double>(0, 0, 0)
    private var hasBaseline = false

    private var startTime: TimeInterval = 0.0
    private var lastTapTime: TimeInterval = 0.0
    private var lastTimerAnnounceTime: TimeInterval = 0.0
    private var recordedTaps: [LapTapRecord] = []
    private var activeSequenceTaps: [LapTapRecord] = []
    private var completedSequences: [LapSequenceRecord] = []

    private var baselineSamples = 0
    private var swayAccumulator = 0.0
    private var measuredSway = 0.0
    private var recentJerkValues: [Double] = []

    func run() {
        setlinebuf(stdout)
        print("\n===================================================================")
        print("      THUMP: LAP MODE (SOFT SURFACE) 30-SECOND PROFILER           ")
        print("===================================================================")
        print("This test runs for 30 SECONDS while your MacBook is on your lap.")
        print("During this time, tap freely:")
        print("  - Try Double taps (2), Triple taps (3), and Quad taps (4)")
        print("  - Tap on the LEFT palm rest, RIGHT palm rest, or center edges")
        print("  - Soft clothing/skin absorbs vibration: tap naturally")
        print("-------------------------------------------------------------------")

        guard startSensor() else {
            print("[ERROR] Could not start AppleSPU accelerometer.")
            exit(1)
        }

        print("[CALIBRATING] Measuring lap posture & body tremor (1.5 seconds)...")
        fflush(stdout)

        let baselineTarget = Date().addingTimeInterval(1.5)
        while Date() < baselineTarget {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        if baselineSamples > 0 {
            measuredSway = swayAccumulator / Double(baselineSamples)
        }

        let pitchRadians = atan2(-baselineGravity.y, sqrt(baselineGravity.x * baselineGravity.x + baselineGravity.z * baselineGravity.z))
        let pitchDegrees = pitchRadians * 180.0 / .pi
        print(String(format: "[BASELINE] Lap Incline: %.1f deg | Micro-Sway Tremor: %.5f", pitchDegrees, measuredSway))
        if pitchDegrees < -6.0 || pitchDegrees > 6.0 {
            print(String(format: "[CONFIRMED] Natural lap tilt detected (%.1f deg incline).", pitchDegrees))
        }

        print("\nStarting 30-second recording in:")
        for count in (1...3).reversed() {
            print("  \(count)...")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1.0)
        }

        print("\n>>> [RECORDING ACTIVE: 30 SECONDS] Start tapping on your lap now! <<<")
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

            // Finalize sequence if silence > 0.40s
            if let lastTap = activeSequenceTaps.last, now - lastTap.timestamp > 0.40 {
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
                    let instance = Unmanaged<LapModeTester>.fromOpaque(context).takeUnretainedValue()
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

        let transientEnergy = jerkMagnitude >= 0.012
            ? max(jerkMagnitude * 1.05, min(dynamicMagnitude, 0.070))
            : (jerkMagnitude * 0.4)

        if startTime == 0.0 {
            baselineSamples += 1
            swayAccumulator += jerkMagnitude
            return
        }

        recentJerkValues.append(jerkMagnitude)
        if recentJerkValues.count > 60 {
            recentJerkValues.removeFirst()
        }
        let currentSway = recentJerkValues.reduce(0, +) / Double(max(recentJerkValues.count, 1))

        let pitchRadians = atan2(-baselineGravity.y, sqrt(baselineGravity.x * baselineGravity.x + baselineGravity.z * baselineGravity.z))
        let pitchDegrees = pitchRadians * 180.0 / .pi

        let deltaMs = (now - lastTapTime) * 1000.0

        // Soft lap detection floor: 0.012 energy & 0.011 jerk
        if transientEnergy > 0.012, jerkMagnitude > 0.011, deltaMs > 50.0 {
            lastTapTime = now
            let relSec = now - startTime

            let tap = LapTapRecord(
                tapIndex: recordedTaps.count + 1,
                timestamp: now,
                relativeSeconds: relSec,
                deltaMs: deltaMs,
                energy: transientEnergy,
                jerk: jerkMagnitude,
                tiltDegrees: pitchDegrees,
                microSway: currentSway
            )
            recordedTaps.append(tap)
            activeSequenceTaps.append(tap)

            print(String(format: "  [+%.2fs] [LAP TAP #%d] Energy: %.4f | Jerk: %.4f | Cadence: %.0f ms | Tilt: %.1f deg",
                         relSec, tap.tapIndex, transientEnergy, jerkMagnitude, deltaMs, pitchDegrees))
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
        let sequence = LapSequenceRecord(
            tapCount: count,
            durationMs: durationMs,
            intervalsMs: intervals,
            peakEnergies: peaks
        )
        completedSequences.append(sequence)

        let intervalStr = intervals.map { String(format: "%.0fms", $0) }.joined(separator: ", ")
        let avgPeak = peaks.reduce(0, +) / Double(max(peaks.count, 1))

        print(String(format: "  >>> [LAP SEQUENCE #%d] %d taps in %.0f ms [cadence: %@] | avg peak: %.4f <<<\n",
                     completedSequences.count, count, durationMs, intervalStr.isEmpty ? "single tap" : intervalStr, avgPeak))
        fflush(stdout)

        activeSequenceTaps.removeAll()
    }

    private func printSummary() {
        print("\n===================================================================")
        print("               LAP MODE: 30-SECOND TEST RESULTS                    ")
        print("===================================================================")
        print("Total Impulses Detected: \(recordedTaps.count)")
        print("Total Sequences Formed:  \(completedSequences.count)")

        guard !recordedTaps.isEmpty else {
            print("\n[WARN] No taps were detected during the 30-second window on lap.")
            print("Try running again and tapping with slightly firmer contact.")
            return
        }

        let allEnergies = recordedTaps.map(\.energy)
        let minEnergy = allEnergies.min() ?? 0.015
        let maxEnergy = allEnergies.max() ?? 0.05
        let avgEnergy = allEnergies.reduce(0, +) / Double(allEnergies.count)

        let allIntervals = completedSequences.flatMap(\.intervalsMs)
        let minInterval = allIntervals.min() ?? 120.0
        let maxInterval = allIntervals.max() ?? 320.0
        let avgInterval = allIntervals.isEmpty ? 190.0 : allIntervals.reduce(0, +) / Double(allIntervals.count)

        print("\n[EMPIRICAL MEASUREMENTS (ON LAP)]:")
        print(String(format: "  - Tap Impact Energy: min=%.4f, avg=%.4f, max=%.4f", minEnergy, avgEnergy, maxEnergy))
        print(String(format: "  - Tap Cadence Gap:   min=%.0f ms, avg=%.0f ms, max=%.0f ms", minInterval, avgInterval, maxInterval))
        print(String(format: "  - Body Micro-Sway:   %.5f", measuredSway))

        // Suggested tuning for Lap mode:
        // Set threshold at 72% of minimum observed tap energy, clamped 0.014 to 0.024
        let recommendedThreshold = max(0.015, min(minEnergy * 0.72, 0.022))
        let recommendedCooldown = max(0.050, min((minInterval * 0.65) / 1000.0, 0.075))
        let recommendedWindow = max(0.60, min((maxInterval * 1.35) / 1000.0, 0.85))

        print("\n[CALIBRATED PRESET RECOMMENDATION FOR LAP]:")
        print(String(format: "  - Default Threshold:   %.3f (cushioned sensitivity boost)", recommendedThreshold))
        print(String(format: "  - Default Window:      %.2f s", recommendedWindow))
        print(String(format: "  - Default Cooldown:    %.3f s (%d ms)", recommendedCooldown, Int(recommendedCooldown * 1000)))
        print("-------------------------------------------------------------------\n")

        let outPath = "/tmp/thump_lap_test.json"
        if let data = try? JSONEncoder().encode(recordedTaps) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("Exported full 30s lap tap log to: \(outPath)\n")
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

let tester = LapModeTester()
tester.run()
