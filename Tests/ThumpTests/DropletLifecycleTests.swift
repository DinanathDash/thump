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
        let view = droplet.makeWidgetView(ShelfWidgetID("thump"), context: context)
        #expect(view != nil)

        droplet.deactivate()
    }

    @Test("Settings pane and calibration page are provided")
    func settingsPageProviding() throws {
        let host = makeHarnessHost()
        let droplet = ThumpDroplet()
        try droplet.activate(host: host)

        let context = SettingsPaneContext(presentation: .harness, preferredContentWidth: 400)
        let settingsPane = droplet.makeSettingsPane(context: context)
        #expect(settingsPane != nil)

        let calibrationPage = droplet.makeSettingsPage(id: "calibration", context: context)
        #expect(calibrationPage != nil)

        let unknownPage = droplet.makeSettingsPage(id: "unknown_page_id", context: context)
        #expect(unknownPage == nil)

        droplet.deactivate()
    }

    @Test("Live activity views and presentation")
    func liveActivityPresentation() throws {
        let host = makeHarnessHost()
        let droplet = ThumpDroplet()
        try droplet.activate(host: host)

        droplet.showLiveActivity(for: "2 taps")

        let leading = droplet.makeCompactLeading()
        #expect(leading != nil)

        let trailing = droplet.makeCompactTrailing()
        #expect(trailing != nil)

        droplet.deactivate()
    }
}
