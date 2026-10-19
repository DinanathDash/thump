import Foundation
import Combine
import DroppyKit
import IOKit
import IOKit.hid
import AppKit

@MainActor
public final class ThumpDetector: ObservableObject {
    public let host: DropletHost
    private let actionRunner: ThumpActionRunner
    
    // Status
    @Published public var isListening: Bool = false
    @Published public var isUsingAccelerometer: Bool = false
    
    private var isStarted = false
    public var onThumpDetected: ((String) -> Void)?
    public var onStateChange: ((Bool) -> Void)?
    
    // Detection Objects
    private let accelService = ThumpAccelerometerService()
    private let knockDetector = ThumpKnockDetector()
    
    // UI Visualization
    public var onRawWaveformSample: ((Double) -> Void)?
    @Published public var waveformData: Double = 0.0
    @Published public var waveformHistory: [Double] = Array(repeating: 0.0, count: 120)
    
    final class ThreadSafeConfig {
        let lock = NSLock()
        var threshold: Double = 0.030
        var groupingWindow: Double = 0.65
        var cooldown: Double = 0.070
        var surfaceProfile: ThumpSurfaceProfile = .dynamic
        var overrideThreshold: Double? = nil
        var isVisualizationActive: Bool = false
        var visualizationCount: Int = 0
        var isAppActive: Bool = true
        var lastPublish: TimeInterval = 0
        var pendingSamples: [Double] = []
    }
    private let config = ThreadSafeConfig()
    
    public var overrideThreshold: Double? {
        get { config.lock.lock(); defer { config.lock.unlock() }; return config.overrideThreshold }
        set { config.lock.lock(); defer { config.lock.unlock() }; config.overrideThreshold = newValue }
    }
    
    public var isVisualizationActive: Bool {
        config.lock.lock(); defer { config.lock.unlock() }; return config.isVisualizationActive
    }
    
    private func updateVisualizationState() {
        config.lock.lock()
        let previous = config.isVisualizationActive
        config.isVisualizationActive = (config.visualizationCount > 0) && config.isAppActive
        let current = config.isVisualizationActive
        if !current {
            config.pendingSamples.removeAll(keepingCapacity: false)
        }
        config.lock.unlock()
        
        if previous != current {
            if current {
                ThumpLogger.log("[SENSOR] Live waveform visualization activated (app active & UI visible).")
            } else {
                ThumpLogger.log("[SENSOR] Live waveform visualization paused (app in background or UI closed).")
                DispatchQueue.main.async { [weak self] in
                    self?.waveformHistory = Array(repeating: 0.0, count: 120)
                    self?.waveformData = 0.0
                }
            }
        }
    }
    
    public func beginVisualization() {
        config.lock.lock()
        config.visualizationCount += 1
        config.lock.unlock()
        updateVisualizationState()
    }
    
    public func endVisualization() {
        config.lock.lock()
        config.visualizationCount = max(0, config.visualizationCount - 1)
        config.lock.unlock()
        updateVisualizationState()
    }

    private func handleAppActiveState(isActive: Bool) {
        config.lock.lock()
        config.isAppActive = isActive
        config.lock.unlock()
        updateVisualizationState()
    }
    
    // Test mode overrides (for the Calibration Wizard)
    public var isSuppressingActions: Bool = false
    private var cancellables: Set<AnyCancellable> = []
    
    public init(host: DropletHost, actionRunner: ThumpActionRunner) {
        self.host = host
        self.actionRunner = actionRunner
        
        config.lock.lock()
        config.isAppActive = NSApplication.shared.isActive
        config.lock.unlock()

        updateCache()
        host.preferences.didChange
            .sink { [weak self] _ in
                self?.updateCache()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.handleAppActiveState(isActive: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                self?.handleAppActiveState(isActive: false)
            }
            .store(in: &cancellables)
    }
    
    public var currentEffectiveThreshold: Double {
        config.lock.lock()
        defer { config.lock.unlock() }
        return config.overrideThreshold ?? config.threshold
    }

    private func updateCache() {
        let rawProfile = host.preferences.value(forKey: "thump.surfaceProfile", default: "dynamic")
        let profile = ThumpSurfaceProfile.from(raw: rawProfile)

        let userThreshold = host.preferences.value(forKey: "thump.accelThreshold", default: profile.defaultThreshold)
        let baseThreshold = (userThreshold > 0 && userThreshold <= 0.10) ? userThreshold : profile.defaultThreshold

        let sensitivity = host.preferences.value(forKey: "thump.sensitivityMultiplier", default: 1.0)
        let clampedSensitivity = min(max(sensitivity, 0.50), 1.50)
        let effectiveThreshold = baseThreshold * (1.0 / clampedSensitivity)

        let userWindow = host.preferences.value(forKey: "thump.groupingWindow", default: profile.defaultGroupingWindow)
        let w = (userWindow >= 0.50 && userWindow <= 1.2) ? userWindow : profile.defaultGroupingWindow

        let userCooldown = host.preferences.value(forKey: "thump.cooldown", default: profile.defaultCooldown)
        let c = (userCooldown >= 0.04 && userCooldown <= 0.10) ? userCooldown : profile.defaultCooldown

        config.lock.lock()
        config.surfaceProfile = profile
        config.threshold = effectiveThreshold
        config.groupingWindow = w
        config.cooldown = c
        config.lock.unlock()
    }
    
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        ThumpLogger.log(String(format: "[DETECTOR] start() called. Config: threshold=%.4f, window=%.2fs, cooldown=%.3fs",
              config.threshold, config.groupingWindow, config.cooldown))
        
        if tryStartAccelerometer() {
            ThumpLogger.log("[DETECTOR] Accelerometer started successfully.")
            host.log.info("ThumpDetector: Started using Accelerometer.")
            isUsingAccelerometer = true
            isListening = true
            onStateChange?(true)
            return
        }
        
        ThumpLogger.log("[ERROR] Accelerometer failed to start.")
        host.log.error("ThumpDetector: Failed to start Accelerometer.")
        isStarted = false
        isListening = false
        onStateChange?(false)
    }
    
    public func stop() {
        ThumpLogger.log("[DETECTOR] stop() called.")
        isStarted = false
        isListening = false
        onStateChange?(false)
        accelService.stop()
    }
    
    private func commitTaps(count: Int) {
        guard !isSuppressingActions else {
            ThumpLogger.log("[DETECTOR] Actions suppressed (Calibration Wizard active). Ignoring \(count) taps.")
            return
        }
        ThumpLogger.log("[TAP] commitTaps called for \(count) taps")
        if count >= 2 {
            let taps = min(count, 4)
            if let label = actionRunner.executeAction(forTaps: taps) {
                ThumpLogger.log("[ACTION] Action successfully executed. Label: '\(label)'. Presenting Live Activity HUD.")
                onThumpDetected?(label)
            } else {
                ThumpLogger.log("[WARN] executeAction returned nil for \(taps) taps (action is None or action execution failed).")
            }
        } else {
            ThumpLogger.log("[TAP] commitTaps received < 2 taps (\(count)). Discarding.")
        }
    }
    
    private func tryStartAccelerometer() -> Bool {
        if !accelService.available() { return false }
        
        let config = self.config
        knockDetector.onWaveformSample = { [weak self] sample in
            guard let self else { return }
            
            self.config.lock.lock()
            guard self.config.isVisualizationActive else {
                self.config.lock.unlock()
                return
            }
            
            self.config.pendingSamples.append(sample)
            let now = ProcessInfo.processInfo.systemUptime
            var samplesToPublish: [Double]? = nil
            if now - self.config.lastPublish > 0.016 { // Downsample to ~60 FPS
                samplesToPublish = self.config.pendingSamples
                self.config.pendingSamples.removeAll(keepingCapacity: true)
                self.config.lastPublish = now
            }
            self.config.lock.unlock()
            
            if let newSamples = samplesToPublish, !newSamples.isEmpty {
                let maxSample = newSamples.max() ?? 0.0
                DispatchQueue.main.async {
                    self.waveformData = maxSample
                    self.waveformHistory.append(maxSample)
                    if self.waveformHistory.count > 120 {
                        self.waveformHistory.removeFirst()
                    }
                    self.onRawWaveformSample?(maxSample)
                }
            }
        }
        
        accelService.onSample = { [weak self] sample in
            guard let self = self else { return }
            
            config.lock.lock()
            let t = config.overrideThreshold ?? config.threshold
            let w = config.groupingWindow
            let c = config.cooldown
            let p = config.surfaceProfile
            config.lock.unlock()
            
            if let pattern = self.knockDetector.process(
                sample: SIMD3<Double>(sample.x, sample.y, sample.z),
                threshold: t,
                groupingWindow: w,
                cooldown: c,
                now: sample.timestamp,
                surfaceProfile: p
            ) {
                Task { @MainActor in
                    self.commitTaps(count: pattern)
                }
            }
        }
        
        return accelService.start()
    }
}
