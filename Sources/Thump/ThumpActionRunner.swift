import Foundation
import DroppyKit

public enum ThumpActionType: String, CaseIterable, Identifiable {
    case none = "None"
    case appleScript = "AppleScript"
    case shellCommand = "Shell Command"
    case runShortcut = "Run Shortcut"
    case screenshot = "Take Screenshot"
    case playPause = "Play / Pause Media"
    case muteUnmute = "Mute / Unmute"
    
    public var id: String { rawValue }
}

@MainActor
public final class ThumpActionRunner {
    private let host: DropletHost
    
    public init(host: DropletHost) {
        self.host = host
    }
    
    public func executeAction(forTaps taps: Int) -> String? {
        let typeRaw = UserDefaults.standard.string(forKey: "thump.actionType.\(taps)") ?? ThumpActionType.none.rawValue
        let payload = UserDefaults.standard.string(forKey: "thump.actionPayload.\(taps)") ?? ""
        
        guard let type = ThumpActionType(rawValue: typeRaw), type != .none else { return nil }
        
        host.log.info("Executing \(type.rawValue) for \(taps) taps: \(payload)")
        
        switch type {
        case .none:
            break
        case .appleScript:
            runAppleScript(payload)
        case .shellCommand:
            runShellCommand(payload)
        case .runShortcut:
            runShellCommand("shortcuts run \"\(payload)\"")
        case .screenshot:
            // Interactive mode (-i) might block the process. Use silent capture to clipboard (-c) or file.
            // Let's use interactive mode but ensure it's detached from the shell by using `open` or running asynchronously.
            // Wait, actually, `screencapture -i` works best if run in a detached process.
            runShellCommand("screencapture -i &")
        case .playPause:
            // Universal play/pause media key
            runAppleScript("tell application \"System Events\" to key code 100")
        case .muteUnmute:
            runAppleScript("set volume output muted not (output muted of (get volume settings))")
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
        Task {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            do {
                try process.run()
            } catch {
                host.log.error("Shell command error: \(error.localizedDescription)")
            }
        }
    }
}
