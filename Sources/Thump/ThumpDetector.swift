import Foundation
import Combine
import DroppyKit
import IOKit
import IOKit.hid

@MainActor
public final class ThumpDetector: ObservableObject {
    private let host: DropletHost
    private let actionRunner: ThumpActionRunner
    
    // Status
    @Published public var isListening: Bool = false
    @Published public var isUsingAccelerometer: Bool = false
    
    private var isStarted = false
    public var onThumpDetected: ((String) -> Void)?
    
    // Detection Objects
    private let accelService = ThumpAccelerometerService()
    private let knockDetector = ThumpKnockDetector()
    
    // UI Visualization
    @Published public var waveformData: Double = 0.0
    
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
            return
        }
        
        host.log.error("ThumpDetector: Failed to start Accelerometer.")
        isStarted = false
        isListening = false
    }
    
    public func stop() {
        isStarted = false
        isListening = false
        accelService.stop()
    }
    
    private func commitTaps(count: Int) {
        guard !isSuppressingActions else { return }
        if count >= 2 {
            if let actionName = actionRunner.executeAction(forTaps: min(count, 4)) {
                onThumpDetected?(actionName)
            }
        }
    }
    
    private func tryStartAccelerometer() -> Bool {
        if !accelService.available() { return false }
        
        // Setup detector callbacks
        knockDetector.onWaveformSample = { [weak self] sample in
            DispatchQueue.main.async {
                self?.waveformData = sample
            }
        }
        
        accelService.onSample = { [weak self] sample in
            guard let self = self else { return }
            
            // Read settings from UserDefaults or use defaults
            // We increase default threshold to 0.15 to prevent false positives
            let userThreshold = UserDefaults.standard.double(forKey: "thump.accelThreshold") > 0 ? UserDefaults.standard.double(forKey: "thump.accelThreshold") : 0.15
            let threshold = self.overrideThreshold ?? userThreshold
            let groupingWindow = UserDefaults.standard.double(forKey: "thump.groupingWindow") > 0 ? UserDefaults.standard.double(forKey: "thump.groupingWindow") : 0.8
            let cooldown = UserDefaults.standard.double(forKey: "thump.cooldown") > 0 ? UserDefaults.standard.double(forKey: "thump.cooldown") : 0.3
            
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
