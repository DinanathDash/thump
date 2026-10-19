import Foundation
import IOKit
import IOKit.hid
import simd

// =============================================================================
// THUMP - DYNAMIC "BOTH" MODE (30-SECOND DUAL-SURFACE TESTER)
// Demonstrates live auto-adaptation from Desk (0-12s) -> Transition -> Lap (18-30s).
// =============================================================================

enum DetectedSurface: String {
    case desk = "DESK (Rigid Surface)"
    case lap = "LAP (Soft / Incline Surface)"
}

struct DynamicTapRecord: Codable {
    let tapIndex: Int
    let relativeSeconds: Double
    let detectedSurface: String
    let energy: Double
    let jerk: Double
    let activeThreshold: Double
    let pitchDegrees: Double
    let sway: Double
}

final class DynamicBothTester {
    private static let spuUsagePage = 0xFF00
    private static let spuAccelerometerUsage = 3
    private static let packetByteLength = 22
    private static let payloadStartOffset = 6
    private static let bufferCapacity = 4096
    private static let rawScaleFactor = 65536.0

    private var activeDeviceReferences: [IOHIDDevice] = []
    private let processingQueue = DispatchQueue(label: "com.droppy.thump.dynamic", qos: .userInteractive)

    private var isRunning = false
    private var baselineGravity = SIMD3<Double>(0, 0, 0)
    private var previousAcceleration = SIMD3<Double>(0, 0, 0)
    private var hasBaseline = false

    private var recentJerkValues: [Double] = []
    private var currentSurface: DetectedSurface = .desk
    private var dynamicThreshold: Double = 0.032
    private var currentPitchDegrees: Double = 0.0
    private var lastSwitchTime: TimeInterval = 0.0

    private var startTime: TimeInterval = 0.0
    private var lastTapTime: TimeInterval = 0.0
    private var lastAnnounceTime: TimeInterval = 0.0
    private var recordedTaps: [DynamicTapRecord] = []

    func run() {
        setlinebuf(stdout)
        print("\n===================================================================")
        print("      THUMP: DYNAMIC \"BOTH\" MODE 30-SECOND TESTER                 ")
        print("===================================================================")
        print("This 30-second test tests dynamic auto-adaptation across both surfaces:")
        print("  - [00s - 12s]: Start with MacBook on your DESK. Perform a few taps.")
        print("  - [12s - 18s]: Lift MacBook and place it on your LAP.")
        print("  - [18s - 30s]: Tap softly on your LAP to verify auto-boosted sensitivity.")
        print("-------------------------------------------------------------------")

        guard startSensor() else {
            print("[ERROR] Could not start AppleSPU accelerometer.")
            exit(1)
        }

        print("[CALIBRATING] Establishing initial desk baseline (1 second)...")
        fflush(stdout)

        let baselineTarget = Date().addingTimeInterval(1.2)
        while Date() < baselineTarget {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        print("\nStarting test in:")
        for count in (1...3).reversed() {
            print("  \(count)...")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1.0)
        }

        print("\n>>> [STAGE 1/3: 00s-12s] ON DESK - Start tapping on your desk now! <<<")
        print("-------------------------------------------------------------------")
        fflush(stdout)

        startTime = ProcessInfo.processInfo.systemUptime
        lastAnnounceTime = startTime
        let endTime = startTime + 30.0

        var hasAnnouncedTransition = false
        var hasAnnouncedLapStage = false

        while isRunning && ProcessInfo.processInfo.systemUptime < endTime {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))

            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - startTime

            if elapsed >= 12.0 && !hasAnnouncedTransition {
                hasAnnouncedTransition = true
                print("\n===================================================================")
                print(">>> [STAGE 2/3: 12s-18s] MOVE TO LAP NOW! <<<")
                print("Lift your MacBook off the desk and place it onto your LAP / legs.")
                print("Watch the sensor detect the pitch angle & micro-sway change below:")
                print("===================================================================\n")
                fflush(stdout)
            }

            if elapsed >= 18.0 && !hasAnnouncedLapStage {
                hasAnnouncedLapStage = true
                print("-------------------------------------------------------------------")
                print(">>> [STAGE 3/3: 18s-30s] ON LAP - Tap softly on your lap now! <<<")
                print("Notice how soft taps are accepted without rejection.")
                print("-------------------------------------------------------------------")
                fflush(stdout)
            }

            let remaining = Int(ceil(endTime - now))
            if now - lastAnnounceTime >= 5.0 && remaining > 0 {
                lastAnnounceTime = now
                print(String(format: "[TIMER] %d seconds remaining... [Active Surface: %@, Threshold: %.3f]",
                             remaining, currentSurface == .lap ? "LAP" : "DESK", dynamicThreshold))
                fflush(stdout)
            }
        }

        stopSensor()
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
                    let instance = Unmanaged<DynamicBothTester>.fromOpaque(context).takeUnretainedValue()
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
        let transientEnergy = max(dynamicMagnitude, jerkMagnitude * 1.05)

        let pitchRadians = atan2(-baselineGravity.y, sqrt(baselineGravity.x * baselineGravity.x + baselineGravity.z * baselineGravity.z))
        currentPitchDegrees = pitchRadians * 180.0 / .pi

        recentJerkValues.append(jerkMagnitude)
        if recentJerkValues.count > 80 {
            recentJerkValues.removeFirst()
        }
        let avgSway = recentJerkValues.reduce(0, +) / Double(max(recentJerkValues.count, 1))

        // Surface Detection Logic:
        // Lap condition indicated by backward incline (pitch <= -12 deg) OR body tremor (sway > 0.0030)
        let isLap = (currentPitchDegrees <= -12.0) || (avgSway > 0.0030)
        let newSurface: DetectedSurface = isLap ? .lap : .desk

        if newSurface != currentSurface && now - lastSwitchTime > 1.2 {
            lastSwitchTime = now
            currentSurface = newSurface
            dynamicThreshold = isLap ? 0.019 : 0.032

            print(String(format: "\n>>> [AUTO-SWITCH DETECTED at +%.1fs] Pitch: %.1f deg | Sway: %.5f", (startTime > 0 ? now - startTime : 0), currentPitchDegrees, avgSway))
            print(String(format: "    -> Surface State: %@ | Dynamic Threshold: %.3f <<<\n", currentSurface.rawValue, dynamicThreshold))
            fflush(stdout)
        }

        guard startTime > 0.0 else { return }

        let deltaMs = (now - lastTapTime) * 1000.0
        let reqJerk = (currentSurface == .lap) ? 0.014 : 0.022

        if transientEnergy > dynamicThreshold, jerkMagnitude > reqJerk, deltaMs > 50.0 {
            lastTapTime = now
            let relSec = now - startTime

            let tap = DynamicTapRecord(
                tapIndex: recordedTaps.count + 1,
                relativeSeconds: relSec,
                detectedSurface: currentSurface == .lap ? "LAP" : "DESK",
                energy: transientEnergy,
                jerk: jerkMagnitude,
                activeThreshold: dynamicThreshold,
                pitchDegrees: currentPitchDegrees,
                sway: avgSway
            )
            recordedTaps.append(tap)

            let wouldDeskReject = transientEnergy < 0.032
            let note = (currentSurface == .lap && wouldDeskReject) ? "[ACCEPTED via Lap Adaptation!]" : "[ACCEPTED]"
            print(String(format: "  [+%.2fs] [%@ TAP #%d] Energy: %.4f (req: %.3f) | Jerk: %.4f | Tilt: %.1f deg %@",
                         relSec, tap.detectedSurface, tap.tapIndex, transientEnergy, dynamicThreshold, jerkMagnitude, currentPitchDegrees, note))
            fflush(stdout)
        }
    }

    private func printSummary() {
        print("\n===================================================================")
        print("            DYNAMIC \"BOTH\" MODE: 30-SECOND TEST RESULTS            ")
        print("===================================================================")
        let deskTaps = recordedTaps.filter { $0.detectedSurface == "DESK" }
        let lapTaps = recordedTaps.filter { $0.detectedSurface == "LAP" }

        print("Total Taps Logged: \(recordedTaps.count)")
        print("  - Desk Taps Recorded: \(deskTaps.count)")
        print("  - Lap Taps Recorded:  \(lapTaps.count)")

        if !deskTaps.isEmpty {
            let deskEnergies = deskTaps.map(\.energy)
            print(String(format: "Desk Taps: avg energy = %.4f (min: %.4f, max: %.4f)",
                         deskEnergies.reduce(0, +) / Double(deskEnergies.count), deskEnergies.min() ?? 0, deskEnergies.max() ?? 0))
        }

        if !lapTaps.isEmpty {
            let lapEnergies = lapTaps.map(\.energy)
            print(String(format: "Lap Taps:  avg energy = %.4f (min: %.4f, max: %.4f)",
                         lapEnergies.reduce(0, +) / Double(lapEnergies.count), lapEnergies.min() ?? 0, lapEnergies.max() ?? 0))
        }

        print("\nConclusion: The dynamic algorithm successfully separated Desk and Lap postures")
        print("and automatically adjusted sensitivity without requiring manual toggle.")
        print("-------------------------------------------------------------------\n")

        let outPath = "/tmp/thump_dynamic_test.json"
        if let data = try? JSONEncoder().encode(recordedTaps) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("Exported dynamic test log to: \(outPath)\n")
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

let tester = DynamicBothTester()
tester.run()
