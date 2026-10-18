import Foundation
import Combine
import DroppyKit
import IOKit
import IOKit.hid

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
        var overrideThreshold: Double? = nil
        var isVisualizationActive: Bool = false
        var visualizationCount: Int = 0
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
    
    public func beginVisualization() {
        config.lock.lock()
        config.visualizationCount += 1
        config.isVisualizationActive = config.visualizationCount > 0
        config.lock.unlock()
    }
    
    public func endVisualization() {
        config.lock.lock()
        config.visualizationCount = max(0, config.visualizationCount - 1)
        config.isVisualizationActive = config.visualizationCount > 0
        config.lock.unlock()
    }
    
    // Test mode overrides (for the Calibration Wizard)
    public var isSuppressingActions: Bool = false
    private var cancellables: Set<AnyCancellable> = []
    
    public init(host: DropletHost, actionRunner: ThumpActionRunner) {
        self.host = host
        self.actionRunner = actionRunner
        
        updateCache()
        host.preferences.didChange
            .sink { [weak self] _ in
                self?.updateCache()
            }
            .store(in: &cancellables)
    }
    
    private func updateCache() {
        let userThreshold = host.preferences.value(forKey: "thump.accelThreshold", default: 0.030)
        let t = (userThreshold > 0 && userThreshold <= 0.10) ? userThreshold : 0.030
        
        let userWindow = host.preferences.value(forKey: "thump.groupingWindow", default: 0.65)
        let w = (userWindow >= 0.55 && userWindow <= 1.2) ? userWindow : 0.65
        
        let userCooldown = host.preferences.value(forKey: "thump.cooldown", default: 0.065)
        let c = (userCooldown >= 0.04 && userCooldown <= 0.10) ? userCooldown : 0.065
        
        config.lock.lock()
        config.threshold = t
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
            config.lock.lock()
            let isActive = config.isVisualizationActive
            
            var samplesToPublish: [Double]? = nil
            if isActive {
                config.pendingSamples.append(sample)
                let now = ProcessInfo.processInfo.systemUptime
                if now - config.lastPublish > 0.016 {
                    samplesToPublish = config.pendingSamples
                    config.pendingSamples.removeAll(keepingCapacity: true)
                    config.lastPublish = now
                }
            } else {
                config.pendingSamples.removeAll(keepingCapacity: false)
            }
            
            config.lock.unlock()
            
            DispatchQueue.main.async {
                self?.onRawWaveformSample?(sample)
            }
            
            if let newSamples = samplesToPublish, !newSamples.isEmpty {
                // Max-pool downsampling: preserve the highest peak but only append 1 point per frame
                // This locks the graph speed to exactly the UI frame rate (60 FPS) and prevents it from zooming by.
                let maxSample = newSamples.max() ?? 0.0
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.waveformData = maxSample
                    self.waveformHistory.append(maxSample)
                    if self.waveformHistory.count > 120 {
                        self.waveformHistory.removeFirst()
                    }
                }
            }
        }
        
        accelService.onSample = { [weak self] sample in
            guard let self = self else { return }
            
            config.lock.lock()
            let t = config.overrideThreshold ?? config.threshold
            let w = config.groupingWindow
            let c = config.cooldown
            config.lock.unlock()
            
            if let pattern = self.knockDetector.process(
                sample: SIMD3<Double>(sample.x, sample.y, sample.z),
                threshold: t,
                groupingWindow: w,
                cooldown: c,
                now: sample.timestamp
            ) {
                Task { @MainActor in
                    self.commitTaps(count: pattern)
                }
            }
        }
        
        return accelService.start()
    }
}
