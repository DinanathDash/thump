import Foundation
import AppKit
import DroppyKit

public enum ThumpActionType: String, CaseIterable, Identifiable {
    case none = "None"
    case launchApp = "Launch App"
    case runShortcut = "Run Shortcut"
    case appleScript = "AppleScript"
    case shellCommand = "Shell Command"
    case lockScreen = "Lock Screen"
    case screenshot = "Take Screenshot"
    case playPause = "Play / Pause Media"
    case volumeUp = "Volume Up"
    case volumeDown = "Volume Down"
    case muteUnmute = "Mute / Unmute"
    case brightnessUp = "Brightness Up"
    case brightnessDown = "Brightness Down"
    
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
        
        host.log.info("Executing \(type.rawValue) for \(taps) taps: \(payload)")
        
        switch type {
        case .none:
            break
        case .launchApp:
            runShellCommand("open -a \"\(payload)\"")
        case .appleScript:
            runAppleScript(payload)
        case .shellCommand:
            runShellCommand(payload)
        case .runShortcut:
            runShellCommand("shortcuts run \"\(payload)\"")
        case .lockScreen:
            runAppleScript("tell application \"System Events\" to key code 12 using {command down, control down}")
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
        
        return "\(taps) Taps: \(type.rawValue)"
    }
    
    private func runAppleScript(_ script: String) {
        guard !script.isEmpty else { return }
        Task {
            if let appleScript = NSAppleScript(source: script) {
                var errorInfo: NSDictionary? = nil
                appleScript.executeAndReturnError(&errorInfo)
                if let errorInfo = errorInfo {
                    host.log.error("AppleScript error: \(errorInfo)")
                }
            }
        }
    }
    
    private func runShellCommand(_ command: String) {
        guard !command.isEmpty else { return }
        // Escape quotes and backslashes for AppleScript string literal
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedCommand)\""
        runAppleScript(script)
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
        Task {
            guard let cgImage = CGDisplayCreateImage(CGMainDisplayID()) else { return }
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = bitmapRep.representation(using: .png, properties: [:]) else { return }
            
            if let sound = NSSound(named: "Screen Capture") ?? NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen capture.aif", byReference: true) {
                sound.play()
            }
            
            if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
                let filename = "Screenshot \(formatter.string(from: Date())).png"
                let fileURL = desktopURL.appendingPathComponent(filename)
                try? data.write(to: fileURL)
            }
        }
    }
}
