import Foundation
import Combine
import DroppyKit
import AVFoundation
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
    
    // State
    private var tapCount: Int = 0
    private var lastTapTime: Date = Date.distantPast
    private var tapTimer: Timer?
    
    // Jerk Detection State
    private var lastAccelX: Double = 0
    private var lastAccelY: Double = 0
    private var lastAccelZ: Double = 0
    
    // Engine
    private var audioEngine: AVAudioEngine?
    private var hidDevice: IOHIDDevice?
    
    public init(host: DropletHost, actionRunner: ThumpActionRunner) {
        self.host = host
        self.actionRunner = actionRunner
    }
    
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        
        // Try Accelerometer first
        if tryStartAccelerometer() {
            host.log.info("ThumpDetector: Started using Accelerometer.")
            isUsingAccelerometer = true
            isListening = true
            return
        }
        
        // Fallback to Microphone
        if tryStartMicrophone() {
            host.log.info("ThumpDetector: Started using Microphone fallback.")
            isUsingAccelerometer = false
            isListening = true
            return
        }
        
        host.log.error("ThumpDetector: Failed to start both Accelerometer and Microphone.")
        isStarted = false
        isListening = false
    }
    
    public func stop() {
        isStarted = false
        isListening = false
        
        if let device = hidDevice {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            hidDevice = nil
        }
        
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
    }
    
    private func handleTap() {
        let now = Date()
        let debounceTime: TimeInterval = 0.2
        let tapWindow: TimeInterval = 0.6 // Max time between consecutive taps
        
        // Debounce
        guard now.timeIntervalSince(lastTapTime) > debounceTime else { return }
        
        if now.timeIntervalSince(lastTapTime) > tapWindow {
            tapCount = 1 // Start new sequence
        } else {
            tapCount += 1
        }
        
        lastTapTime = now
        host.log.info("Thump detected! Count: \(tapCount)")
        
        // Reset the timer
        tapTimer?.invalidate()
        let currentCount = tapCount
        tapTimer = Timer.scheduledTimer(withTimeInterval: tapWindow, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.commitTaps(count: currentCount)
            }
        }
    }
    
    private func commitTaps(count: Int) {
        // Reset tap count
        tapCount = 0
        if count >= 2 {
            if let actionName = actionRunner.executeAction(forTaps: min(count, 4)) {
                onThumpDetected?(actionName)
            }
        }
    }
    
    // MARK: - Accelerometer
    private func tryStartAccelerometer() -> Bool {
        let matchingDict = IOServiceMatching("AppleSPUHIDDevice")
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        
        guard result == kIOReturnSuccess && iterator != 0 else { return false }
        
        var device = IOIteratorNext(iterator)
        var found = false
        
        while device != 0 {
            let props = UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>.allocate(capacity: 1)
            IORegistryEntryCreateCFProperties(device, props, kCFAllocatorDefault, 0)
            
            if let dict = props.pointee?.takeRetainedValue() as? [String: Any],
               let usage = dict["PrimaryUsage"] as? Int, usage == 3 {
                
                if let dev = IOHIDDeviceCreate(kCFAllocatorDefault, device) {
                    if IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                        self.hidDevice = dev
                        found = true
                        
                        let reportSize = 22
                        let report = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
                        
                        // Callback needs to route back to class
                        let context = Unmanaged.passUnretained(self).toOpaque()
                        let callback: IOHIDReportCallback = { ctx, result, sender, type, reportId, reportPtr, reportLength in
                            guard let ctx = ctx, reportLength >= 18 else { return }
                            let detector = Unmanaged<ThumpDetector>.fromOpaque(ctx).takeUnretainedValue()
                            
                            let xData = Data(bytes: reportPtr.advanced(by: 6), count: 4)
                            let yData = Data(bytes: reportPtr.advanced(by: 10), count: 4)
                            let zData = Data(bytes: reportPtr.advanced(by: 14), count: 4)
                            
                            let x = Double(Int32(littleEndian: xData.withUnsafeBytes { $0.load(as: Int32.self) })) / 65536.0
                            let y = Double(Int32(littleEndian: yData.withUnsafeBytes { $0.load(as: Int32.self) })) / 65536.0
                            let z = Double(Int32(littleEndian: zData.withUnsafeBytes { $0.load(as: Int32.self) })) / 65536.0
                            
                            let dx = x - detector.lastAccelX
                            let dy = y - detector.lastAccelY
                            let dz = z - detector.lastAccelZ
                            
                            detector.lastAccelX = x
                            detector.lastAccelY = y
                            detector.lastAccelZ = z
                            
                            let jerk = sqrt(dx*dx + dy*dy + dz*dz)
                            
                            if jerk > 0.05 {
                                Task { @MainActor in
                                    detector.handleTap()
                                }
                            }
                        }
                        
                        IOHIDDeviceRegisterInputReportCallback(dev, report, reportSize, callback, context)
                        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                        
                        break
                    }
                }
            }
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }
        
        IOObjectRelease(iterator)
        return found
    }
    
    // MARK: - Microphone
    private func tryStartMicrophone() -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self = self, let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(frameLength))
            let db = 20 * log10(rms)
            
            let sensitivityStr = UserDefaults.standard.string(forKey: "thump.micSensitivity") ?? "Medium"
            let threshold: Float
            switch sensitivityStr {
            case "High": threshold = -35.0
            case "Low": threshold = -15.0
            default: threshold = -25.0
            }
            
            if db > threshold {
                Task { @MainActor in
                    self.handleTap()
                }
            }
        }
        
        do {
            try engine.start()
            self.audioEngine = engine
            return true
        } catch {
            return false
        }
    }
}
