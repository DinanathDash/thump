import Foundation
import AppKit
import DroppyKit

public enum ThumpActionType: String, CaseIterable, Identifiable {
    case none = "None"
    case launchApp = "Launch app"
    case runShortcut = "Run shortcut"
    case appleScript = "AppleScript"
    case shellCommand = "Shell command"
    case lockScreen = "Lock screen"
    case screenshot = "Take screenshot"
    case playPause = "Play / pause media"
    case volumeUp = "Volume up"
    case volumeDown = "Volume down"
    case muteUnmute = "Mute / unmute"
    case brightnessUp = "Brightness up"
    case brightnessDown = "Brightness down"
    
    public var id: String { rawValue }
}

@MainActor
public final class ThumpActionRunner {
    private let host: DropletHost
    
    public init(host: DropletHost) {
        self.host = host
    }
    
    public func executeAction(forTaps taps: Int) -> String? {
        let typeRaw = host.preferences.value(forKey: "thump.actionType.\(taps)", default: ThumpActionType.none.rawValue)
        let payload = host.preferences.value(forKey: "thump.actionPayload.\(taps)", default: "")
        
        guard let type = ThumpActionType(rawValue: typeRaw), type != .none else { return nil }
        
        host.log.info("Executing \(type.rawValue) for \(taps) taps")
        
        switch type {
        case .none:
            break
        case .launchApp:
            runProcess(executable: "/usr/bin/open", arguments: ["-a", payload])
        case .appleScript:
            runProcess(executable: "/usr/bin/osascript", arguments: ["-e", payload])
        case .shellCommand:
            runProcess(executable: "/bin/zsh", arguments: ["-c", payload])
        case .runShortcut:
            runProcess(executable: "/usr/bin/shortcuts", arguments: ["run", payload])
        case .lockScreen:
            runProcess(executable: "/usr/bin/osascript", arguments: ["-e", "tell application \"System Events\" to key code 12 using {command down, control down}"])
        case .screenshot:
            takeScreenshot()
        case .playPause:
            playPauseMedia()
        case .volumeUp:
            simulateMediaKey(keyCode: 0) // NX_KEYTYPE_SOUND_UP
        case .volumeDown:
            simulateMediaKey(keyCode: 1) // NX_KEYTYPE_SOUND_DOWN
        case .muteUnmute:
            simulateMediaKey(keyCode: 7) // NX_KEYTYPE_MUTE
        case .brightnessUp:
            simulateMediaKey(keyCode: 2) // NX_KEYTYPE_BRIGHTNESS_UP
        case .brightnessDown:
            simulateMediaKey(keyCode: 3) // NX_KEYTYPE_BRIGHTNESS_DOWN
        }
        
        return "\(taps) taps"
    }
    
    private func runProcess(executable: String, arguments: [String], timeout: TimeInterval = 5.0) {
        guard !executable.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        
        do {
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                guard let process = process else { return }
                if process.isRunning {
                    process.terminate()
                    Task { @MainActor in
                        self.host.log.error("Process \(executable) timed out and was terminated.")
                    }
                }
            }
        } catch {
            host.log.error("Process execution error: \(error.localizedDescription)")
        }
    }
    
    private func simulateMediaKey(keyCode: Int32) {
        let data1 = Int((keyCode << 16) | (0xa << 8))
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
        
        let data1Up = Int((keyCode << 16) | (0xb << 8))
        let eventUp = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1Up,
            data2: -1
        )
        eventUp?.cgEvent?.post(tap: .cghidEventTap)
    }
    
    private func playPauseMedia() {
        // 16 is NX_KEYTYPE_PLAY
        simulateMediaKey(keyCode: 16)
    }
    
    private func takeScreenshot() {
        if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
            let filename = "Screenshot \(formatter.string(from: Date())).png"
            let fileURL = desktopURL.appendingPathComponent(filename)
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = [fileURL.path]
            try? process.run()
        }
    }
}
