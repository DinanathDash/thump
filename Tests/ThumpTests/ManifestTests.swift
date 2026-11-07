import Foundation
import Testing
import DroppyKit
@testable import Thump

@Suite("Manifest and Capabilities")
struct ManifestTests {
    private func manifestJSON() throws -> [String: Any] {
        let currentFileURL = URL(fileURLWithPath: #filePath)
        let rootURL = currentFileURL
            .deletingLastPathComponent() // ThumpTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Project root
        let dropletURL = rootURL.appendingPathComponent("droplet.json")
        let data = try Data(contentsOf: dropletURL)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func capabilities() throws -> [String] {
        try manifestJSON()["capabilities"] as? [String] ?? []
    }

    private func surfaces() throws -> [String] {
        try manifestJSON()["surfaces"] as? [String] ?? []
    }

    private func keywords() throws -> [String] {
        try manifestJSON()["keywords"] as? [String] ?? []
    }

    @Test("droplet.json contains expected identifier and naming")
    func manifestMetadata() throws {
        let json = try manifestJSON()
        #expect(json["id"] as? String == "thump")
        #expect(json["name"] as? String == "Thump")
        #expect(json["version"] as? String == "1.0.1")
        #expect(json["minMacOS"] as? String == "26.0")
        #expect(json["minAppVersion"] as? String == "16.0.1")
    }

    @Test("droplet.json requests required capabilities for tap actions")
    func requiredCapabilities() throws {
        let caps = try capabilities()
        #expect(caps.contains("accessibility"))
        #expect(caps.contains("apple-events"))
        #expect(caps.contains("screen-capture"))
    }

    @Test("droplet.json specifies all advertised surface interfaces")
    func advertisedSurfaces() throws {
        let surfs = try surfaces()
        #expect(surfs.contains("shelf-widget"))
        #expect(surfs.contains("settings-pane"))
        #expect(surfs.contains("live-activity"))
    }

    @Test("droplet.json specifies kit ABI and minAPI")
    func kitVersion() throws {
        let json = try manifestJSON()
        let kit = json["kit"] as? [String: Any]
        #expect(kit?["abi"] as? Int == 1)
        #expect(kit?["minAPI"] as? String == "1.20.1")
    }

    @Test("droplet.json contains relevant search keywords")
    func keywordsPresent() throws {
        let keys = try keywords()
        #expect(keys.contains("accelerometer"))
        #expect(keys.contains("actions"))
        #expect(keys.contains("shortcuts"))
        #expect(keys.contains("menu bar"))
        #expect(keys.contains("palm rest"))
    }

    @Test("droplet.json contains creator information")
    func creatorInformation() throws {
        let json = try manifestJSON()
        let creator = json["creator"] as? [String: Any]
        #expect(creator?["name"] as? String == "Dinanath Dash")
        #expect(creator?["gitlab"] as? String == "DinanathDash")
    }

    @MainActor
    @Test("ThumpDroplet advertises shelf widget with expected metrics")
    func shelfWidgetDescriptor() {
        let droplet = ThumpDroplet()
        let descriptors = droplet.widgetDescriptors
        #expect(descriptors.count == 1)
        let desc = descriptors.first
        #expect(desc?.id == ThumpDroplet.widgetID)
        #expect(desc?.title == "Thump")
        #expect(desc?.systemImage == "hand.tap.fill")
        #expect(desc?.layoutTraits.preferredSoloWidth == 380)
        #expect(desc?.layoutTraits.preferredPairedWidth == 190)
    }
}
