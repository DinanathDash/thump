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
    @Published public var waveformData: Double = 0.0
    @Published public var waveformHistory: [Double] = Array(repeating: 0.0, count: 50)
    
    // Test mode overrides (for the Calibration Wizard)
    public var overrideThreshold: Double?
    public var isSuppressingActions: Bool = false
    
    public init(host: DropletHost, actionRunner: ThumpActionRunner) {
        self.host = host
        self.actionRunner = actionRunner
    }
    
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        
        if tryStartAccelerometer() {
            host.log.info("ThumpDetector: Started using Accelerometer.")
            isUsingAccelerometer = true
            isListening = true
            onStateChange?(true)
            return
        }
        
        host.log.error("ThumpDetector: Failed to start Accelerometer.")
        isStarted = false
        isListening = false
        onStateChange?(false)
    }
    
    public func stop() {
        isStarted = false
        isListening = false
        onStateChange?(false)
        accelService.stop()
    }
    
    private func commitTaps(count: Int) {
        guard !isSuppressingActions else { return }
        if count >= 2 {
            let taps = min(count, 4)
            let _ = actionRunner.executeAction(forTaps: taps)
            let label = "\(taps) Taps"
            onThumpDetected?(label)
        }
    }
    
    private func tryStartAccelerometer() -> Bool {
        if !accelService.available() { return false }
        
        // Setup detector callbacks
        knockDetector.onWaveformSample = { [weak self] sample in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.waveformData = sample
                self.waveformHistory.append(sample)
                if self.waveformHistory.count > 50 {
                    self.waveformHistory.removeFirst()
                }
            }
        }
        
        accelService.onSample = { [weak self] sample in
            guard let self = self else { return }
            
            // Read settings from host.preferences
            let userThreshold = self.host.preferences.value(forKey: "thump.accelThreshold", default: 0.15)
            let threshold = self.overrideThreshold ?? (userThreshold > 0 ? userThreshold : 0.15)
            
            let userWindow = self.host.preferences.value(forKey: "thump.groupingWindow", default: 0.8)
            let groupingWindow = userWindow > 0 ? userWindow : 0.8
            
            let userCooldown = self.host.preferences.value(forKey: "thump.cooldown", default: 0.3)
            let cooldown = userCooldown > 0 ? userCooldown : 0.3
            
            if let pattern = self.knockDetector.process(
                sample: SIMD3<Double>(sample.x, sample.y, sample.z),
                threshold: threshold,
                groupingWindow: groupingWindow,
                cooldown: cooldown,
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
