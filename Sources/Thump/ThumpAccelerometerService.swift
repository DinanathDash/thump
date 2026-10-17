import Foundation
import IOKit
import IOKit.hid

// =============================================================================
// ACKNOWLEDGEMENT:
// Low-level Apple Silicon SPU HID usage page IDs and raw IMU packet offsets
// used below were referenced from `nocnoc` (commit: 00b283c2dbab1c975eca07cccbc4d147686db3b2):
// https://github.com/shaircast/nocnoc
// =============================================================================

/// Encapsulates a raw 3-axis accelerometer sample read from the hardware.
public struct ThumpSample: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double
    public let timestamp: TimeInterval

    public init(x: Double, y: Double, z: Double, timestamp: TimeInterval) {
        self.x = x
        self.y = y
        self.z = z
        self.timestamp = timestamp
    }
}

/// Service managing communication with Apple Silicon SPU accelerometer hardware via IOKit HID APIs.
public final class ThumpAccelerometerService {
    // SPU HID hardware parameters
    private static let spuUsagePage = 0xFF00
    private static let spuAccelerometerUsage = 3
    private static let packetByteLength = 22
    private static let payloadStartOffset = 6
    private static let bufferCapacity = 4096
    private static let rawScaleFactor = 65536.0

    /// Callback invoked whenever a new sample is received from the sensor queue.
    public var onSample: ((ThumpSample) -> Void)?

    private let processingQueue = DispatchQueue(label: "com.droppy.thump.accelerometer", qos: .userInteractive)
    private var activeDeviceReferences: [IOHIDDevice] = []
    private var isActive = false

    public init() {}

    deinit {
        stop()
    }

    /// Verifies if a compatible Apple SPU accelerometer device is present on this Mac.
    public func available() -> Bool {
        !discoverAccelerometerServices().isEmpty
    }

    /// Activates sensor reporting and registers input report callbacks.
    public func start() -> Bool {
        guard !isActive else { return true }

        requestDriverState()
        let matchingServices = discoverAccelerometerServices()
        guard !matchingServices.isEmpty else { return false }

        var openedDevices: [IOHIDDevice] = []
        let unretainedSelf = Unmanaged.passUnretained(self).toOpaque()

        for service in matchingServices {
            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
                IOObjectRelease(service)
                continue
            }

            let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess else {
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
                    let instance = Unmanaged<ThumpAccelerometerService>.fromOpaque(context).takeUnretainedValue()
                    instance.processIncomingReport(report, length: reportLength)
                },
                unretainedSelf
            )

            IOHIDDeviceSetCancelHandler(device) {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                reportBuffer.deallocate()
            }

            IOHIDDeviceActivate(device)
            openedDevices.append(device)
            IOObjectRelease(service)
        }

        guard !openedDevices.isEmpty else { return false }
        activeDeviceReferences = openedDevices
        isActive = true
        return true
    }

    /// Deactivates sensor reporting and releases device handles.
    public func stop() {
        guard isActive else { return }
        for device in activeDeviceReferences {
            IOHIDDeviceCancel(device)
        }
        activeDeviceReferences.removeAll()
        isActive = false
    }

    // MARK: - Private Helpers

    private func processIncomingReport(_ report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard isActive, length == Self.packetByteLength else { return }

        let rawX = readLittleEndianInt32(from: report, at: Self.payloadStartOffset)
        let rawY = readLittleEndianInt32(from: report, at: Self.payloadStartOffset + 4)
        let rawZ = readLittleEndianInt32(from: report, at: Self.payloadStartOffset + 8)

        let sample = ThumpSample(
            x: Double(rawX) / Self.rawScaleFactor,
            y: Double(rawY) / Self.rawScaleFactor,
            z: Double(rawZ) / Self.rawScaleFactor,
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        onSample?(sample)
    }

    private func requestDriverState() {
        var iterator: io_iterator_t = 0
        let matchingDictionary = IOServiceMatching("AppleSPUHIDDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator) == KERN_SUCCESS else {
            return
        }

        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, 1000 as CFNumber)
            IOObjectRelease(service)
        }
    }

    private func discoverAccelerometerServices() -> [io_service_t] {
        var iterator: io_iterator_t = 0
        let matchingDictionary = IOServiceMatching("AppleSPUHIDDevice")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator) == KERN_SUCCESS else {
            return []
        }

        defer { IOObjectRelease(iterator) }

        var foundServices: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let usagePage = readPropertyInt(service, key: "PrimaryUsagePage")
            let usage = readPropertyInt(service, key: "PrimaryUsage")

            if usagePage == Self.spuUsagePage, usage == Self.spuAccelerometerUsage {
                foundServices.append(service)
            } else {
                IOObjectRelease(service)
            }
        }
        return foundServices
    }

    private func readPropertyInt(_ service: io_service_t, key: String) -> Int? {
        guard let rawProp = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else {
            return nil
        }
        return (rawProp as? NSNumber)?.intValue
    }

    private func readLittleEndianInt32(from buffer: UnsafeMutablePointer<UInt8>, at offset: Int) -> Int32 {
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { bytes in
            bytes.copyBytes(from: UnsafeRawBufferPointer(start: buffer + offset, count: 4))
        }
        return Int32(bitPattern: UInt32(littleEndian: value))
    }
}
