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
    case toggleMenuBar = "Toggle menu bar"
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
        
        ThumpLogger.log("[ACTION] executeAction invoked for \(taps) taps (preference: '\(typeRaw)', payload: '\(payload)')")
        
        guard let type = ThumpActionType(rawValue: typeRaw), type != .none else {
            ThumpLogger.log("[WARN] Action for \(taps) taps is 'None'. Open Droplet Settings to assign an action to \(taps) taps.")
            return nil
        }
        
        ThumpLogger.log("[ACTION] Executing action '\(type.rawValue)' for \(taps) taps")
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
        case .toggleMenuBar:
            toggleSystemMenuBar()
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

    private func toggleSystemMenuBar() {
        let globalDomain = kCFPreferencesAnyApplication
        let user = kCFPreferencesCurrentUser
        let host = kCFPreferencesAnyHost
        
        // Read current state from NSGlobalDomain
        let currentHide = (CFPreferencesCopyValue("_HIHideMenuBar" as CFString, globalDomain, user, host) as? Bool) ?? false
        let currentFS = (CFPreferencesCopyValue("AppleMenuBarVisibleInFullscreen" as CFString, globalDomain, user, host) as? Bool) ?? true
        
        // If visible in any mode, toggle to "Always" (hide on desktop & in fullscreen).
        // If hidden everywhere, toggle to "Never" (show on desktop & in fullscreen).
        let shouldHideEverywhere = (!currentHide || currentFS)
        
        let newHideDesktop = shouldHideEverywhere
        let newVisibleFS = !shouldHideEverywhere
        
        ThumpLogger.log("Toggling menu bar: currently (desktopHide=\(currentHide), fsVisible=\(currentFS)) -> new (desktopHide=\(newHideDesktop), fsVisible=\(newVisibleFS)) [Mode: \(shouldHideEverywhere ? "Always" : "Never")]")
        
        CFPreferencesSetValue("_HIHideMenuBar" as CFString, newHideDesktop as CFPropertyList, globalDomain, user, host)
        CFPreferencesSetValue("AppleMenuBarVisibleInFullscreen" as CFString, newVisibleFS as CFPropertyList, globalDomain, user, host)
        CFPreferencesSynchronize(globalDomain, user, host)
        
        // Post the exact distributed notifications macOS ControlCenterSettings uses
        let center = DistributedNotificationCenter.default()
        center.postNotificationName(Notification.Name("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
        center.postNotificationName(Notification.Name("AppleInterfaceFullScreenMenuBarVisibilityChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
    }
    
    private func runProcess(executable: String, arguments: [String], timeout: TimeInterval = 5.0) {
        guard !executable.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        
        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe
        
        do {
            try process.run()
            ThumpLogger.log("[PROCESS] Started process: \(executable) with \(arguments.count) argument(s)")
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                guard let process = process else { return }
                if process.isRunning {
                    process.terminate()
                    ThumpLogger.log("[ERROR] Process \(executable) timed out after \(timeout)s")
                    Task { @MainActor in
                        self.host.log.error("Process \(executable) timed out and was terminated.")
                    }
                }
            }
            process.terminationHandler = { proc in
                let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errString = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationStatus != 0 {
                    ThumpLogger.log("[ERROR] Process '\(executable)' exited with status \(proc.terminationStatus). Error: \(errString.isEmpty ? "None" : errString)")
                } else {
                    ThumpLogger.log("[PROCESS] Process '\(executable)' completed successfully with status 0.")
                }
            }
        } catch {
            ThumpLogger.log("[ERROR] Failed to launch process \(executable): \(error.localizedDescription)")
            host.log.error("Process execution error: \(error.localizedDescription)")
        }
    }
    
    private func simulateMediaKey(keyCode: Int32) {
        ThumpLogger.log("[ACTION] Simulating media key code: \(keyCode)")
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
        ThumpLogger.log("[ACTION] Capturing screenshot via /usr/sbin/screencapture")
        if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
            let filename = "Screenshot \(formatter.string(from: Date())).png"
            let fileURL = desktopURL.appendingPathComponent(filename)
            
            runProcess(executable: "/usr/sbin/screencapture", arguments: [fileURL.path])
        }
    }
}
