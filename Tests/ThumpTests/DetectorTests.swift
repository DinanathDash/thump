import Foundation
import Testing
import DroppyKit
import DroppyKitHarness
@testable import Thump

@MainActor
@Suite("Detector and Accelerometer Integration")
struct DetectorTests {
    @Test("Detector starts and stops accelerometer service successfully")
    func detectorLifecycle() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)
        let mockAccel = MockAccelerometerService(isAvailable: true)
        let detector = ThumpDetector(host: host, actionRunner: runner, accelerometer: mockAccel)

        var reportedState: Bool? = nil
        detector.onStateChange = { listening in
            reportedState = listening
        }

        #expect(detector.isListening == false)
        #expect(mockAccel.isRunning == false)

        detector.start()

        #expect(detector.isListening == true)
        #expect(detector.isUsingAccelerometer == true)
        #expect(mockAccel.isRunning == true)
        #expect(mockAccel.startCalls == 1)
        #expect(reportedState == true)

        detector.stop()

        #expect(detector.isListening == false)
        #expect(mockAccel.isRunning == false)
        #expect(mockAccel.stopCalls == 1)
        #expect(reportedState == false)
    }

    @Test("Detector fails gracefully when accelerometer is unavailable")
    func accelerometerUnavailable() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)
        let mockAccel = MockAccelerometerService(isAvailable: false)
        let detector = ThumpDetector(host: host, actionRunner: runner, accelerometer: mockAccel)

        var reportedState: Bool? = nil
        detector.onStateChange = { listening in
            reportedState = listening
        }

        detector.start()

        #expect(detector.isListening == false)
        #expect(mockAccel.isRunning == false)
        #expect(reportedState == false)
    }

    @Test("Streaming mock accelerometer samples through detector commits detected taps")
    func streamingSamplesTriggerCommit() async throws {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)
        let mockAccel = MockAccelerometerService(isAvailable: true)
        let detector = ThumpDetector(host: host, actionRunner: runner, accelerometer: mockAccel)

        // Set action for 2 taps
        host.preferences.setValue(ThumpActionType.playPause.rawValue, forKey: "thump.actionType.2")

        var simulatedMediaKey: Int32 = -1
        runner.mediaKeySimulator = { key in
            simulatedMediaKey = key
        }

        var detectedLabel: String? = nil
        detector.onThumpDetected = { label in
            detectedLabel = label
        }

        detector.start()

        // 1. Send quiet baseline
        var t = 100.0
        for _ in 0..<15 {
            t += 0.01
            mockAccel.emit(x: 0.0, y: 0.05, z: 0.998, timestamp: t)
        }

        // 2. First tap impulse
        mockAccel.emit(x: 0.02, y: 0.02, z: 1.035, timestamp: t); t += 0.008
        mockAccel.emit(x: -0.02, y: -0.02, z: 0.965, timestamp: t); t += 0.008
        mockAccel.emit(x: 0.001, y: 0.001, z: 0.999, timestamp: t); t += 0.008

        // Cadence gap 120ms
        for _ in 0..<12 {
            t += 0.01
            mockAccel.emit(x: 0.0, y: 0.05, z: 0.998, timestamp: t)
        }

        // 3. Second tap impulse
        mockAccel.emit(x: 0.02, y: 0.02, z: 1.035, timestamp: t); t += 0.008
        mockAccel.emit(x: -0.02, y: -0.02, z: 0.965, timestamp: t); t += 0.008
        mockAccel.emit(x: 0.001, y: 0.001, z: 0.999, timestamp: t); t += 0.008

        // Silence timeout (> 0.60s grouping window)
        for _ in 0..<70 {
            t += 0.01
            mockAccel.emit(x: 0.0, y: 0.05, z: 0.998, timestamp: t)
        }

        try await Task.sleep(nanoseconds: 60_000_000)

        #expect(simulatedMediaKey == 16) // NX_KEYTYPE_PLAY
        #expect(detectedLabel == "2 taps")

        detector.stop()
    }

    @Test("Action suppression (Calibration Wizard active) prevents firing actions")
    func actionSuppressionMode() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)
        let detector = ThumpDetector(host: host, actionRunner: runner)

        var actionExecuted = false
        runner.mediaKeySimulator = { _ in actionExecuted = true }
        host.preferences.setValue(ThumpActionType.volumeUp.rawValue, forKey: "thump.actionType.2")

        detector.isSuppressingActions = true
        detector.commitTaps(count: 2)

        #expect(actionExecuted == false)

        detector.isSuppressingActions = false
        detector.commitTaps(count: 2)

        #expect(actionExecuted == true)
    }

    @Test("Visualization lifecycle reference counting and active state")
    func visualizationReferenceCounting() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)
        let detector = ThumpDetector(host: host, actionRunner: runner)

        detector.beginVisualization()
        detector.beginVisualization()
        #expect(detector.isVisualizationActive == true)

        detector.endVisualization()
        #expect(detector.isVisualizationActive == true)

        detector.endVisualization()
        #expect(detector.isVisualizationActive == false)
    }
}
