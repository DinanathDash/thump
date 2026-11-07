import Foundation
import Testing
import DroppyKit
import DroppyKitHarness
@testable import Thump

@MainActor
@Suite("Action Runner")
struct ActionRunnerTests {
    @Test("executeAction returns nil when action is None or tap count is out of range")
    func returnsNilForNoneOrInvalidRange() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)

        // Invalid tap counts outside 2...4
        #expect(runner.executeAction(forTaps: 1) == nil)
        #expect(runner.executeAction(forTaps: 5) == nil)

        // None action for 2 taps
        host.preferences.setValue("None", forKey: "thump.actionType.2")
        #expect(runner.executeAction(forTaps: 2) == nil)
    }

    @Test("executeAction dispatches Launch App with open command")
    func launchAppAction() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)

        var executedExecutable = ""
        var executedArgs: [String] = []
        runner.processRunner = { exe, args in
            executedExecutable = exe
            executedArgs = args
        }

        host.preferences.setValue(ThumpActionType.launchApp.rawValue, forKey: "thump.actionType.2")
        host.preferences.setValue("Safari", forKey: "thump.actionPayload.2")

        let label = runner.executeAction(forTaps: 2)
        #expect(label == "2 taps")
        #expect(executedExecutable == "/usr/bin/open")
        #expect(executedArgs == ["-a", "Safari"])
    }

    @Test("executeAction dispatches Run Shortcut command")
    func runShortcutAction() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)

        var executedExecutable = ""
        var executedArgs: [String] = []
        runner.processRunner = { exe, args in
            executedExecutable = exe
            executedArgs = args
        }

        host.preferences.setValue(ThumpActionType.runShortcut.rawValue, forKey: "thump.actionType.3")
        host.preferences.setValue("My Morning Routine", forKey: "thump.actionPayload.3")

        let label = runner.executeAction(forTaps: 3)
        #expect(label == "3 taps")
        #expect(executedExecutable == "/usr/bin/shortcuts")
        #expect(executedArgs == ["run", "My Morning Routine"])
    }

    @Test("executeAction dispatches Shell Command via /bin/zsh")
    func shellCommandAction() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)

        var executedExecutable = ""
        var executedArgs: [String] = []
        runner.processRunner = { exe, args in
            executedExecutable = exe
            executedArgs = args
        }

        host.preferences.setValue(ThumpActionType.shellCommand.rawValue, forKey: "thump.actionType.4")
        host.preferences.setValue("echo 'hello'", forKey: "thump.actionPayload.4")

        let label = runner.executeAction(forTaps: 4)
        #expect(label == "4 taps")
        #expect(executedExecutable == "/bin/zsh")
        #expect(executedArgs == ["-c", "echo 'hello'"])
    }

    @Test("executeAction dispatches AppleScript via /usr/bin/osascript")
    func appleScriptAction() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)

        var executedExecutable = ""
        var executedArgs: [String] = []
        runner.processRunner = { exe, args in
            executedExecutable = exe
            executedArgs = args
        }

        let script = "display notification \"Hello from Thump!\""
        host.preferences.setValue(ThumpActionType.appleScript.rawValue, forKey: "thump.actionType.2")
        host.preferences.setValue(script, forKey: "thump.actionPayload.2")

        let label = runner.executeAction(forTaps: 2)
        #expect(label == "2 taps")
        #expect(executedExecutable == "/usr/bin/osascript")
        #expect(executedArgs == ["-e", script])
    }

    @Test("executeAction dispatches Lock Screen")
    func lockScreenAction() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)

        var executedExecutable = ""
        var executedArgs: [String] = []
        runner.processRunner = { exe, args in
            executedExecutable = exe
            executedArgs = args
        }

        host.preferences.setValue(ThumpActionType.lockScreen.rawValue, forKey: "thump.actionType.2")
        let label = runner.executeAction(forTaps: 2)

        #expect(label == "2 taps")
        #expect(executedExecutable == "/usr/bin/osascript")
        #expect(executedArgs.contains("-e"))
    }

    @Test("executeAction invokes toggle menu bar handler")
    func toggleMenuBarAction() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)

        var toggled = false
        runner.menuBarToggler = {
            toggled = true
        }

        host.preferences.setValue(ThumpActionType.toggleMenuBar.rawValue, forKey: "thump.actionType.3")
        let label = runner.executeAction(forTaps: 3)

        #expect(label == "3 taps")
        #expect(toggled == true)
    }

    @Test("executeAction invokes screenshot handler")
    func screenshotAction() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)

        var tookScreenshot = false
        runner.screenshotTaker = {
            tookScreenshot = true
        }

        host.preferences.setValue(ThumpActionType.screenshot.rawValue, forKey: "thump.actionType.2")
        let label = runner.executeAction(forTaps: 2)

        #expect(label == "2 taps")
        #expect(tookScreenshot == true)
    }

    @Test("executeAction simulates media keys for volume, brightness, and playback", arguments: [
        (ThumpActionType.playPause, Int32(16)),
        (ThumpActionType.volumeUp, Int32(0)),
        (ThumpActionType.volumeDown, Int32(1)),
        (ThumpActionType.muteUnmute, Int32(7)),
        (ThumpActionType.brightnessUp, Int32(2)),
        (ThumpActionType.brightnessDown, Int32(3))
    ])
    func mediaKeyActions(action: ThumpActionType, expectedKeyCode: Int32) {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)

        var simulatedKey: Int32 = -1
        runner.mediaKeySimulator = { key in
            simulatedKey = key
        }

        host.preferences.setValue(action.rawValue, forKey: "thump.actionType.2")
        let label = runner.executeAction(forTaps: 2)

        #expect(label == "2 taps")
        #expect(simulatedKey == expectedKeyCode)
    }
}
