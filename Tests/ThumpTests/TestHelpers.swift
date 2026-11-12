import Foundation
import DroppyKit
import DroppyKitHarness
import simd
@testable import Thump

/// Builds a test DropletHost using DroppyKitHarness mock services with all declared capabilities granted.
@MainActor
func makeHarnessHost(recorder: HarnessRecorder = HarnessRecorder()) -> DropletHost {
    let id = ThumpDroplet.id
    let capabilities: Set<DropletPermission> = [.accessibility, .appleEvents, .screenCapture, .hud]
    recorder.grantedCapabilities = capabilities
    return DropletHost(
        grantedCapabilities: capabilities,
        preferences: HarnessPreferencesService(dropletID: id, recorder: recorder),
        environment: HarnessEnvironmentService(appVersion: "16.0.1", dropletID: id),
        log: HarnessLogService(recorder: recorder),
        installState: HarnessInstallStateService(),
        hud: HarnessHUDService(recorder: recorder),
        shelf: HarnessShelfService(recorder: recorder),
        liveActivity: HarnessLiveActivityService(recorder: recorder),
        notchSurface: HarnessNotchSurfaceService(recorder: recorder, dropletID: id),
        shortcuts: HarnessShortcutsService(recorder: recorder),
        workspace: HarnessWorkspaceService(recorder: recorder),
        feedback: HarnessFeedbackService(recorder: recorder),
        permissions: HarnessPermissionsService(recorder: recorder)
    )
}

/// Mock accelerometer provider that allows injecting synthetic accelerometer streams in tests.
public final class MockAccelerometerService: ThumpAccelerometerProviding, @unchecked Sendable {
    public var onSample: ((ThumpSample) -> Void)?
    public var isAvailable: Bool = true
    public private(set) var isRunning: Bool = false
    public private(set) var startCalls: Int = 0
    public private(set) var stopCalls: Int = 0

    public init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    public func available() -> Bool {
        isAvailable
    }

    public func start() -> Bool {
        startCalls += 1
        guard isAvailable else { return false }
        isRunning = true
        return true
    }

    public func stop() {
        stopCalls += 1
        isRunning = false
    }

    public func emit(sample: ThumpSample) {
        onSample?(sample)
    }

    public func emit(x: Double, y: Double, z: Double, timestamp: TimeInterval) {
        onSample?(ThumpSample(x: x, y: y, z: z, timestamp: timestamp))
    }
}

/// Generates simulated realistic accelerometer samples modeled on empirical MacBook tap measurements.
public struct TapSimulationStream {
    public static let standardGravity = SIMD3<Double>(0.0, 0.05, 0.998) // Baseline horizontal resting on desk
    public static let lapGravity = SIMD3<Double>(0.0, -0.09, 0.995) // Resting on lap with ~ -5° pitch incline

    /// Simulates resting baseline samples at ~100Hz (dt = 0.01s).
    public static func emitQuietBaseline(
        to detector: ThumpKnockDetector,
        base: SIMD3<Double> = standardGravity,
        sampleCount: Int = 20,
        startTime: TimeInterval = 100.0,
        dt: TimeInterval = 0.01,
        noiseAmplitude: Double = 0.001
    ) -> TimeInterval {
        var t = startTime
        for i in 0..<sampleCount {
            let noise = (Double(i % 5) - 2.0) * noiseAmplitude
            let sample = SIMD3<Double>(base.x + noise, base.y + noise, base.z + noise)
            _ = detector.process(
                sample: sample,
                threshold: 0.020,
                groupingWindow: 0.60,
                cooldown: 0.052,
                now: t
            )
            t += dt
        }
        return t
    }

    /// Simulates a single sharp physical tap impulse lasting ~20ms (2-3 samples).
    public static func emitSingleTapImpulse(
        to detector: ThumpKnockDetector,
        base: SIMD3<Double> = standardGravity,
        at time: TimeInterval,
        peakForce: Double = 0.035,
        threshold: Double = 0.020,
        groupingWindow: Double = 0.60,
        cooldown: Double = 0.052,
        surface: ThumpSurfaceProfile = .dynamic
    ) -> TimeInterval {
        var t = time
        // Rise sample
        _ = detector.process(
            sample: base + SIMD3<Double>(peakForce * 0.5, peakForce * 0.4, peakForce),
            threshold: threshold,
            groupingWindow: groupingWindow,
            cooldown: cooldown,
            now: t,
            surfaceProfile: surface
        )
        t += 0.008

        // Peak jerk sample
        _ = detector.process(
            sample: base + SIMD3<Double>(-peakForce * 0.4, -peakForce * 0.3, -peakForce * 0.8),
            threshold: threshold,
            groupingWindow: groupingWindow,
            cooldown: cooldown,
            now: t,
            surfaceProfile: surface
        )
        t += 0.008

        // Ring-down sample
        _ = detector.process(
            sample: base + SIMD3<Double>(0.002, -0.002, 0.005),
            threshold: threshold,
            groupingWindow: groupingWindow,
            cooldown: cooldown,
            now: t,
            surfaceProfile: surface
        )
        t += 0.008

        return t
    }
}
