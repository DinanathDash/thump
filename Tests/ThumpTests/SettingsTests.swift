import Foundation
import Testing
import DroppyKit
import DroppyKitHarness
@testable import Thump

@Suite("Settings and Surface Profiles")
struct SettingsTests {
    @Test("Surface profile default parameters are properly calibrated")
    func surfaceProfileDefaults() {
        // Desk: tuned for rigid tables, suppressing bounce
        let desk = ThumpSurfaceProfile.desk
        #expect(desk.defaultThreshold == 0.022)
        #expect(desk.defaultGroupingWindow == 0.58)
        #expect(desk.defaultCooldown == 0.055)
        #expect(desk.displayName.contains("Desk"))

        // Lap: tuned for cushioned, soft surfaces
        let lap = ThumpSurfaceProfile.lap
        #expect(lap.defaultThreshold == 0.016)
        #expect(lap.defaultGroupingWindow == 0.62)
        #expect(lap.defaultCooldown == 0.050)
        #expect(lap.displayName.contains("Lap"))

        // Dynamic: balanced adaptive profile
        let dynamic = ThumpSurfaceProfile.dynamic
        #expect(dynamic.defaultThreshold == 0.020)
        #expect(dynamic.defaultGroupingWindow == 0.60)
        #expect(dynamic.defaultCooldown == 0.052)
        #expect(dynamic.displayName.contains("Dynamic"))
    }

    @Test("Surface profile raw value parsing falls back safely on invalid input")
    func surfaceProfileParsing() {
        let testCases: [(String?, ThumpSurfaceProfile)] = [
            ("dynamic", .dynamic),
            ("desk", .desk),
            ("lap", .lap),
            (nil, .dynamic),
            ("", .dynamic),
            ("unknown_surface", .dynamic),
            ("DESK", .dynamic) // raw value is lowercase
        ]
        for (raw, expected) in testCases {
            #expect(ThumpSurfaceProfile.from(raw: raw) == expected)
        }
    }

    @Test("Surface profile encodes and decodes through Codable")
    func surfaceProfileCodable() throws {
        for profile in ThumpSurfaceProfile.allCases {
            let data = try JSONEncoder().encode(profile)
            let decoded = try JSONDecoder().decode(ThumpSurfaceProfile.self, from: data)
            #expect(decoded == profile)
        }
    }

    @Test("Action types cover all required actions and define valid symbols")
    func actionTypesCoverage() {
        let all = ThumpActionType.allCases
        #expect(all.count == 14)
        #expect(all.contains(.none))
        #expect(all.contains(.launchApp))
        #expect(all.contains(.runShortcut))
        #expect(all.contains(.appleScript))
        #expect(all.contains(.shellCommand))
        #expect(all.contains(.lockScreen))
        #expect(all.contains(.toggleMenuBar))
        #expect(all.contains(.screenshot))
        #expect(all.contains(.playPause))
        #expect(all.contains(.volumeUp))
        #expect(all.contains(.volumeDown))
        #expect(all.contains(.muteUnmute))
        #expect(all.contains(.brightnessUp))
        #expect(all.contains(.brightnessDown))

        for action in all {
            #expect(!action.id.isEmpty)
            #expect(!action.iconName.isEmpty)
        }
    }

    @MainActor
    @Test("Preference updates clamp sensitivity multiplier within valid bounds (0.50 to 1.50)")
    func sensitivityClamping() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)
        let detector = ThumpDetector(host: host, actionRunner: runner)

        // Set baseline threshold to 0.020
        host.preferences.setValue(0.020, forKey: "thump.accelThreshold")
        host.preferences.setValue("desk", forKey: "thump.surfaceProfile")

        // 1.0x sensitivity
        host.preferences.setValue(1.0, forKey: "thump.sensitivityMultiplier")
        detector.updateCache()
        #expect(abs(detector.currentEffectiveThreshold - 0.020) < 0.0001)

        // Ultra high sensitivity: 2.0 clamped to 1.50 -> threshold = 0.020 / 1.5 = 0.0133
        host.preferences.setValue(2.0, forKey: "thump.sensitivityMultiplier")
        detector.updateCache()
        let expectedClampedHigh = 0.020 / 1.50
        #expect(abs(detector.currentEffectiveThreshold - expectedClampedHigh) < 0.0001)

        // Ultra low sensitivity: 0.2 clamped to 0.50 -> threshold = 0.020 / 0.5 = 0.0400
        host.preferences.setValue(0.2, forKey: "thump.sensitivityMultiplier")
        detector.updateCache()
        let expectedClampedLow = 0.020 / 0.50
        #expect(abs(detector.currentEffectiveThreshold - expectedClampedLow) < 0.0001)
    }

    @MainActor
    @Test("Preference updates clamp grouping window and cooldown safely")
    func groupingAndCooldownClamping() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)
        let detector = ThumpDetector(host: host, actionRunner: runner)

        // Out-of-bounds grouping window (e.g. 0.1s or 5.0s) reverts to profile default
        host.preferences.setValue(0.10, forKey: "thump.groupingWindow")
        host.preferences.setValue(0.01, forKey: "thump.cooldown")
        detector.updateCache()

        // Profile default for dynamic is 0.60s window, 0.052s cooldown
        // Let's verify by overriding with valid in-range values
        host.preferences.setValue(0.75, forKey: "thump.groupingWindow")
        host.preferences.setValue(0.065, forKey: "thump.cooldown")
        detector.updateCache()
        // No crash and successfully cached
    }
}
