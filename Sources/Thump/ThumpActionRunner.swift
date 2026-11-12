import Foundation
import AppKit
import DroppyKit

public enum ThumpActionType: String, CaseIterable, Identifiable, Sendable {
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

    public var iconName: String {
        switch self {
        case .none:
            return "slash.circle"
        case .launchApp:
            return "arrow.up.forward.app"
        case .runShortcut:
            return "square.3.layers.3d.bottom.filled"
        case .appleScript:
            return "applescript"
        case .shellCommand:
            return "terminal"
        case .lockScreen:
            return "lock"
        case .toggleMenuBar:
            return "menubar.rectangle"
        case .screenshot:
            return "camera.viewfinder"
        case .playPause:
            return "playpause"
        case .volumeUp:
            return "speaker.wave.3"
        case .volumeDown:
            return "speaker.wave.1"
        case .muteUnmute:
            return "speaker.slash"
        case .brightnessUp:
            return "sun.max"
        case .brightnessDown:
            return "sun.min"
        }
    }
}

@MainActor
public final class ThumpActionRunner {
    private let host: DropletHost
    
    /// Test hooks to intercept system side-effects without firing actual OS commands or events.
    public var processRunner: ((_ executable: String, _ arguments: [String]) -> Void)?
    public var mediaKeySimulator: ((_ keyCode: Int32) -> Void)?
    public var menuBarToggler: (() -> Void)?
    public var screenshotTaker: (() -> Void)?

    public init(host: DropletHost) {
        self.host = host
    }
    
    public func executeAction(forTaps taps: Int) -> String? {
        guard (2...4).contains(taps) else {
            ThumpLogger.log("[WARN] executeAction invoked with invalid tap count \(taps). Only 2...4 taps are supported.")
            return nil
        }

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
            if let processRunner {
                processRunner("/usr/bin/open", ["-a", payload])
            } else {
                runProcess(executable: "/usr/bin/open", arguments: ["-a", payload])
            }
        case .appleScript:
            if let processRunner {
                processRunner("/usr/bin/osascript", ["-e", payload])
            } else {
                runProcess(executable: "/usr/bin/osascript", arguments: ["-e", payload])
            }
        case .shellCommand:
            if let processRunner {
                processRunner("/bin/zsh", ["-c", payload])
            } else {
                runProcess(executable: "/bin/zsh", arguments: ["-c", payload])
            }
        case .runShortcut:
            if let processRunner {
                processRunner("/usr/bin/shortcuts", ["run", payload])
            } else {
                runProcess(executable: "/usr/bin/shortcuts", arguments: ["run", payload])
            }
        case .lockScreen:
            let script = "tell application \"System Events\" to key code 12 using {command down, control down}"
            if let processRunner {
                processRunner("/usr/bin/osascript", ["-e", script])
            } else {
                runProcess(executable: "/usr/bin/osascript", arguments: ["-e", script])
            }
        case .toggleMenuBar:
            if let menuBarToggler {
                menuBarToggler()
            } else {
                toggleSystemMenuBar()
            }
        case .screenshot:
            if let screenshotTaker {
                screenshotTaker()
            } else {
                takeScreenshot()
            }
        case .playPause:
            if let mediaKeySimulator {
                mediaKeySimulator(16)
            } else {
                playPauseMedia()
            }
        case .volumeUp:
            if let mediaKeySimulator {
                mediaKeySimulator(0) // NX_KEYTYPE_SOUND_UP
            } else {
                simulateMediaKey(keyCode: 0)
            }
        case .volumeDown:
            if let mediaKeySimulator {
                mediaKeySimulator(1) // NX_KEYTYPE_SOUND_DOWN
            } else {
                simulateMediaKey(keyCode: 1)
            }
        case .muteUnmute:
            if let mediaKeySimulator {
                mediaKeySimulator(7) // NX_KEYTYPE_MUTE
            } else {
                simulateMediaKey(keyCode: 7)
            }
        case .brightnessUp:
            if let mediaKeySimulator {
                mediaKeySimulator(2) // NX_KEYTYPE_BRIGHTNESS_UP
            } else {
                simulateMediaKey(keyCode: 2)
            }
        case .brightnessDown:
            if let mediaKeySimulator {
                mediaKeySimulator(3) // NX_KEYTYPE_BRIGHTNESS_DOWN
            } else {
                simulateMediaKey(keyCode: 3)
            }
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
        
        ThumpLogger.log("[ACTION] Toggling menu bar: currently (desktopHide=\(currentHide), fsVisible=\(currentFS)) -> new (desktopHide=\(newHideDesktop), fsVisible=\(newVisibleFS)) [Mode: \(shouldHideEverywhere ? "Always" : "Never")]")
        
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
        // droppykit-lint: allow process: actions execute with a 5s deadline and termination handler
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
        // droppykit-lint: allow synthetic-input: media keys simulate system volume and play/pause HID events
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
        // droppykit-lint: allow synthetic-input: media keys simulate system volume and play/pause HID events
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
            
            if let processRunner {
                processRunner("/usr/sbin/screencapture", [fileURL.path])
            } else {
                runProcess(executable: "/usr/sbin/screencapture", arguments: [fileURL.path])
            }
        }
    }
}
