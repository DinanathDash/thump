import Foundation
import Testing
import DroppyKit
import DroppyKitHarness
import SwiftUI
@testable import Thump

@MainActor
@Suite("Droplet Lifecycle and Surfaces")
struct DropletLifecycleTests {
    @Test("Droplet activation starts detector only when wasListening=true and actions are assigned")
    func activationWithAndWithoutActions() throws {
        let host = makeHarnessHost()
        let droplet = ThumpDroplet()
        let mockAccel = MockAccelerometerService()

        droplet.makeDetector = { h, runner in
            ThumpDetector(host: h, actionRunner: runner, accelerometer: mockAccel)
        }

        // 1. wasListening=true but no actions assigned -> should not start detector
        host.preferences.setValue(true, forKey: "thump.isListening")
        host.preferences.setValue("None", forKey: "thump.actionType.2")
        host.preferences.setValue("None", forKey: "thump.actionType.3")
        host.preferences.setValue("None", forKey: "thump.actionType.4")

        try droplet.activate(host: host)
        #expect(droplet.isListening == false)
        #expect(mockAccel.isRunning == false)

        droplet.deactivate()

        // 2. wasListening=true and action assigned -> should start detector
        host.preferences.setValue(true, forKey: "thump.isListening")
        host.preferences.setValue(ThumpActionType.lockScreen.rawValue, forKey: "thump.actionType.2")
        try droplet.activate(host: host)
        #expect(droplet.isListening == true)
        #expect(mockAccel.isRunning == true)

        droplet.deactivate()
    }

    @Test("toggleListening starts and stops detector and persists preference")
    func toggleListening() throws {
        let host = makeHarnessHost()
        let droplet = ThumpDroplet()
        let mockAccel = MockAccelerometerService()

        droplet.makeDetector = { h, runner in
            ThumpDetector(host: h, actionRunner: runner, accelerometer: mockAccel)
        }

        host.preferences.setValue(ThumpActionType.lockScreen.rawValue, forKey: "thump.actionType.2")
        try droplet.activate(host: host)

        #expect(droplet.isListening == false)

        droplet.toggleListening()
        #expect(droplet.isListening == true)
        #expect(host.preferences.value(forKey: "thump.isListening", default: false) == true)

        droplet.toggleListening()
        #expect(droplet.isListening == false)
        #expect(host.preferences.value(forKey: "thump.isListening", default: true) == false)

        droplet.deactivate()
    }

    @Test("Shelf widget view can be created")
    func makeWidgetView() throws {
        let host = makeHarnessHost()
        let droplet = ThumpDroplet()
        try droplet.activate(host: host)

        let context = ShelfWidgetContext(availableSize: CGSize(width: 380, height: 58))
        let _ = droplet.makeWidgetView(ShelfWidgetID("thump"), context: context)

        droplet.deactivate()
    }

    @Test("Settings pane and calibration page are provided")
    func settingsPageProviding() throws {
        let host = makeHarnessHost()
        let droplet = ThumpDroplet()
        try droplet.activate(host: host)

        let context = SettingsPaneContext(presentation: .harness, preferredContentWidth: 400)
        let _ = droplet.makeSettingsPane(context: context)

        let calibrationPage = droplet.makeSettingsPage(id: "calibration", context: context)
        #expect(calibrationPage != nil)

        let unknownPage = droplet.makeSettingsPage(id: "unknown_page_id", context: context)
        #expect(unknownPage == nil)

        droplet.deactivate()
    }

    @Test("Live activity views and presentation with CompactLiveActivityContext")
    func liveActivityPresentation() throws {
        let recorder = HarnessRecorder()
        let host = makeHarnessHost(recorder: recorder)
        let droplet = ThumpDroplet()
        try droplet.activate(host: host)

        droplet.presentTapFeedback(for: "2 taps")

        #expect(droplet.lastTapLabel == "2 taps")

        // 1. Verify native DroppyKit 1.23 HUD strip presentation
        #expect(recorder.currentHUD?.id == "thump.detected")
        #expect(recorder.currentHUD?.accessibilityLabel == "Thump: 2 taps")
        #expect(recorder.currentHUD?.priority == .normal)

        // 2. Compact live activity row items
        let _ = droplet.makeCompactLeading()
        let _ = droplet.makeCompactTrailing()

        let compactContext = CompactLiveActivityContext(
            surface: .builtInNotch,
            seat: .compact,
            slotSize: CGSize(width: 60, height: 32)
        )
        let _ = droplet.makeCompactLeading(context: compactContext)
        let _ = droplet.makeCompactTrailing(context: compactContext)
        let _ = droplet.makeCompanionCompact(context: compactContext)

        // 3. showLiveActivity backward-compatibility forwarder
        droplet.showLiveActivity(for: "3 taps")
        #expect(droplet.lastTapLabel == "3 taps")
        #expect(recorder.currentHUD?.accessibilityLabel == "Thump: 3 taps")

        droplet.deactivate()
    }

    @Test("MCP tools provide expected tools and execute actions")
    func mcpToolsExecution() async throws {
        let recorder = HarnessRecorder()
        let host = makeHarnessHost(recorder: recorder)
        let droplet = ThumpDroplet()
        try droplet.activate(host: host)

        let tools = droplet.mcpTools
        #expect(tools.count == 5)
        let toolNames = Set(tools.map(\.name))
        #expect(toolNames.contains("get_status"))
        #expect(toolNames.contains("toggle_listening"))
        #expect(toolNames.contains("set_listening"))
        #expect(toolNames.contains("trigger_tap_action"))
        #expect(toolNames.contains("get_calibration_profile"))

        // 1. get_status
        let statusJSON = try await droplet.performMCPTool(named: "get_status", argumentsJSON: "{}")
        #expect(statusJSON.contains("is_listening"))
        #expect(statusJSON.contains("sensor_available"))

        // 2. toggle_listening
        let toggleJSON = try await droplet.performMCPTool(named: "toggle_listening", argumentsJSON: "{}")
        #expect(toggleJSON.contains("\"status\" : \"ok\""))

        // 3. set_listening
        let setJSON = try await droplet.performMCPTool(named: "set_listening", argumentsJSON: #"{"enabled": false}"#)
        #expect(droplet.isListening == false)
        #expect(setJSON.contains("\"status\" : \"ok\""))

        // 4. trigger_tap_action
        host.preferences.setValue(ThumpActionType.lockScreen.rawValue, forKey: "thump.actionType.2")
        let triggerJSON = try await droplet.performMCPTool(named: "trigger_tap_action", argumentsJSON: #"{"taps": 2}"#)
        #expect(triggerJSON.contains("\"status\" : \"triggered\""))
        #expect(triggerJSON.contains("2"))
        #expect(recorder.currentHUD?.accessibilityLabel == "Thump: 2 taps")

        // 5. get_calibration_profile
        let profileJSON = try await droplet.performMCPTool(named: "get_calibration_profile", argumentsJSON: "{}")
        #expect(profileJSON.contains("effective_threshold"))
        #expect(profileJSON.contains("grouping_window_seconds"))

        // 6. unknown tool throws error
        await #expect(throws: Error.self) {
            _ = try await droplet.performMCPTool(named: "non_existent_tool", argumentsJSON: "{}")
        }

        // 7. invalid tap count throws error
        await #expect(throws: Error.self) {
            _ = try await droplet.performMCPTool(named: "trigger_tap_action", argumentsJSON: #"{"taps": 5}"#)
        }

        droplet.deactivate()
    }
}
