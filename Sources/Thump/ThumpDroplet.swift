import Foundation
import Combine
import DroppyKit
import SwiftUI
import AppKit

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(ThumpPrincipal)
public final class ThumpPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { ThumpDroplet() }
}

// =============================================================================
// THUMP - CHASSIS TAP DETECTOR DROPLET
// =============================================================================

@MainActor
public final class ThumpDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "thump"
    public static let widgetID = ShelfWidgetID("thump")

    public var host: DropletHost?
    @Published public var detector: ThumpDetector?
    public var actionRunner: ThumpActionRunner?

    /// Optional test factory for creating custom/mocked ThumpDetector.
    public var makeDetector: ((DropletHost, ThumpActionRunner) -> ThumpDetector)?
    
    // Live Activity publisher
    @Published private var liveActivitySubject: LiveActivityState? = nil
    @Published public var lastTapLabel: String?
    
    @Published public var isListening: Bool = false
    
    private var dismissalTask: Task<Void, Never>?
    
    public func activate(host: DropletHost) throws {
        self.host = host
        host.log.info("Thump activated")
        
        let runner = ThumpActionRunner(host: host)
        self.actionRunner = runner
        
        let detector: ThumpDetector
        if let make = makeDetector {
            detector = make(host, runner)
        } else {
            detector = ThumpDetector(host: host, actionRunner: runner)
        }

        detector.onThumpDetected = { [weak self] actionName in
            self?.presentTapFeedback(for: actionName.lowercased())
        }
        detector.onStateChange = { [weak self] listening in
            self?.isListening = listening
            self?.host?.preferences.setValue(listening, forKey: "thump.isListening")
        }
        self.detector = detector
        
        let wasListening = host.preferences.value(forKey: "thump.isListening", default: false)
        let anyAction = hasAnyAction()
        ThumpLogger.log("ThumpDroplet activated. wasListening=\(wasListening), hasAnyAction=\(anyAction)")
        if wasListening && anyAction {
            detector.start()
        } else {
            if wasListening && !anyAction {
                ThumpLogger.log("[WARN] Thump preference has isListening=true, but no actions are assigned. Set an action in Droplet Settings to start.")
            }
            self.isListening = false
        }
    }

    public func hasAnyAction() -> Bool {
        guard let host = host else { return false }
        return (2...4).contains { taps in
            host.preferences.value(forKey: "thump.actionType.\(taps)", default: "None") != "None"
        }
    }

    public func deactivate() {
        dismissalTask?.cancel()
        liveActivitySubject = nil
        detector?.stop()
        detector = nil
        actionRunner = nil
        host = nil
    }

    public func toggleListening() {
        if isListening {
            detector?.stop()
        } else {
            detector?.start()
        }
    }
    
    public func showLiveActivity(for actionName: String) {
        presentTapFeedback(for: actionName)
    }

    public func presentTapFeedback(for actionName: String) {
        self.lastTapLabel = actionName
        
        // 1. Present native DroppyKit 1.23 HUD strip
        let hudRequest = DropletHUDRequest(
            id: "thump.detected",
            duration: 1.5,
            priority: .normal,
            accessibilityLabel: "Thump: \(actionName)"
        ) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        } trailing: {
            Text(actionName)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        }
        host?.hud.present(hudRequest)

        // 2. Publish Live Activity state with DroppyKit 1.23 priority band
        liveActivitySubject = LiveActivityState(
            priority: .status,
            kind: .custom,
            accessibilityTitle: "Thump detected",
            accessibilityValue: { actionName }
        )
        
        dismissalTask?.cancel()
        dismissalTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self.liveActivitySubject = nil
        }
    }
}

// MARK: - Shelf widget

extension ThumpDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "thump",
                title: "Thump",
                systemImage: "hand.tap.fill",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 380,
                    preferredPairedWidth: 190,
                    contentHeight: .fixed(58)
                )
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(ThumpWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

private struct ThumpWidget: View {
    @ObservedObject var droplet: ThumpDroplet
    let context: ShelfWidgetContext

    private var hasAnyAction: Bool {
        droplet.hasAnyAction()
    }

    var body: some View {
        if !hasAnyAction {
            Button(action: {
                droplet.host?.workspace.openSettings()
            }) {
                Text("Tap to assign actions")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .padding(context.contentInsets)
        } else {
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                HStack(spacing: DroppySpacing.xsm) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text("Thump")
                        .font(.system(size: 12, weight: .semibold))
                    
                    Spacer(minLength: 0)
                    
                    if droplet.isListening {
                        Text("Listening")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    } else {
                        Text("Stopped")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                    
                    if !context.isCompact {
                        Button {
                            droplet.toggleListening()
                        } label: {
                            Image(systemName: droplet.isListening ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(DroppyWashCircleButtonStyle(
                            diameter: context.washControlSize,
                            tone: droplet.isListening ? .accent(.green) : .neutral,
                            usesAdaptiveForegrounds: context.usesAdaptiveForegrounds
                        ))
                        .help(droplet.isListening ? "Stop" : "Start")
                    }
                }
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(context.contentInsets)
        }
    }
}

// MARK: - Settings Pane
extension ThumpDroplet: SettingsPagesProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(ThumpSettingsPane(droplet: self, context: context))
    }
    
    public func makeSettingsPage(id: String, context: SettingsPaneContext) -> AnyView? {
        if id == "calibration" {
            if let detector = detector {
                return AnyView(ThumpCalibrationWizard(detector: detector))
            } else {
                return AnyView(Text("Sensor inactive").frame(maxWidth: .infinity, maxHeight: .infinity))
            }
        }
        return nil
    }
}

// MARK: - Live Activity
extension ThumpDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        $liveActivitySubject.eraseToAnyPublisher()
    }
    
    public func makeCompactLeading() -> AnyView {
        AnyView(
            Image(systemName: "hand.tap.fill")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        )
    }

    public func makeCompactLeading(context: CompactLiveActivityContext) -> AnyView {
        makeCompactLeading()
    }
    
    public func makeCompactTrailing() -> AnyView {
        AnyView(
            Text(lastTapLabel ?? "")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .id(lastTapLabel)
        )
    }

    public func makeCompactTrailing(context: CompactLiveActivityContext) -> AnyView {
        makeCompactTrailing()
    }
    
    public func makeCompanionCompact(context: CompactLiveActivityContext) -> AnyView {
        AnyView(
            Image(systemName: "hand.tap.fill")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        )
    }
    
    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(EmptyView())
    }
}

// MARK: - MCP Tools

extension ThumpDroplet: MCPToolProviding {
    public var mcpTools: [DropletMCPTool] {
        [
            DropletMCPTool(
                name: "get_status",
                title: "Get Thump status",
                summary: "Returns Thump's current state: listening status, hardware sensor availability, calibrated profile, and configured actions for 2, 3, and 4 taps."
            ),
            DropletMCPTool(
                name: "toggle_listening",
                title: "Toggle listening state",
                summary: "Toggles tap detection on or off."
            ),
            DropletMCPTool(
                name: "set_listening",
                title: "Set listening state",
                summary: "Starts or stops listening for chassis taps. Takes {\"enabled\": true|false}.",
                inputSchemaJSON: #"{"type":"object","properties":{"enabled":{"type":"boolean"}},"required":["enabled"]}"#
            ),
            DropletMCPTool(
                name: "trigger_tap_action",
                title: "Trigger tap action",
                summary: "Simulates and executes the action assigned to a given number of taps (2 for double, 3 for triple, 4 for quad tap), displaying native HUD feedback. Takes {\"taps\": 2}.",
                inputSchemaJSON: #"{"type":"object","properties":{"taps":{"type":"integer","minimum":2,"maximum":4}},"required":["taps"]}"#
            ),
            DropletMCPTool(
                name: "get_calibration_profile",
                title: "Get calibration profile",
                summary: "Returns the active accelerometer surface profile (dynamic, desk, lap), sensitivity multiplier, and effective thresholds."
            )
        ]
    }

    public func performMCPTool(named name: String, argumentsJSON: String) async throws -> String {
        switch name {
        case "get_status":
            let available = ThumpAccelerometerService().available()
            let hasCalibrated = host?.preferences.value(forKey: "thump.hasCalibrated", default: false) ?? false
            let rawProfile = host?.preferences.value(forKey: "thump.surfaceProfile", default: ThumpSurfaceProfile.dynamic.rawValue) ?? ThumpSurfaceProfile.dynamic.rawValue
            let profile = ThumpSurfaceProfile.from(raw: rawProfile)
            let sensitivity = host?.preferences.value(forKey: "thump.sensitivityMultiplier", default: 1.0) ?? 1.0

            var actions: [String: String] = [:]
            for taps in 2...4 {
                let type = host?.preferences.value(forKey: "thump.actionType.\(taps)", default: "None") ?? "None"
                let payload = host?.preferences.value(forKey: "thump.actionPayload.\(taps)", default: "") ?? ""
                actions["\(taps)_taps"] = payload.isEmpty ? type : "\(type) (\(payload))"
            }

            let result: [String: Any] = [
                "is_listening": isListening,
                "sensor_available": available,
                "has_calibrated": hasCalibrated,
                "surface_profile": profile.displayName,
                "sensitivity_percentage": Int(round(sensitivity * 100)),
                "assigned_actions": actions
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
            return String(decoding: data, as: UTF8.self)

        case "toggle_listening":
            toggleListening()
            let result: [String: Any] = [
                "status": "ok",
                "is_listening": isListening
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
            return String(decoding: data, as: UTF8.self)

        case "set_listening":
            struct SetArgs: Decodable {
                let enabled: Bool
            }
            let args = try JSONDecoder().decode(SetArgs.self, from: Data(argumentsJSON.utf8))
            if args.enabled != isListening {
                toggleListening()
            }
            let result: [String: Any] = [
                "status": "ok",
                "is_listening": isListening
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
            return String(decoding: data, as: UTF8.self)

        case "trigger_tap_action":
            struct TriggerArgs: Decodable {
                let taps: Int
            }
            let args = try JSONDecoder().decode(TriggerArgs.self, from: Data(argumentsJSON.utf8))
            guard (2...4).contains(args.taps) else {
                throw NSError(domain: "ThumpMCP", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid taps count (\(args.taps)). Supported values: 2, 3, or 4."
                ])
            }
            let actionName = actionRunner?.executeAction(forTaps: args.taps)
            if let action = actionName {
                presentTapFeedback(for: action.lowercased())
            }
            let result: [String: Any] = [
                "status": actionName != nil ? "triggered" : "no_action_assigned",
                "taps": args.taps,
                "action": actionName ?? "None"
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
            return String(decoding: data, as: UTF8.self)

        case "get_calibration_profile":
            let rawProfile = host?.preferences.value(forKey: "thump.surfaceProfile", default: ThumpSurfaceProfile.dynamic.rawValue) ?? ThumpSurfaceProfile.dynamic.rawValue
            let profile = ThumpSurfaceProfile.from(raw: rawProfile)
            let accelThreshold = host?.preferences.value(forKey: "thump.accelThreshold", default: profile.defaultThreshold) ?? profile.defaultThreshold
            let sensitivity = host?.preferences.value(forKey: "thump.sensitivityMultiplier", default: 1.0) ?? 1.0
            let effectiveThreshold = accelThreshold * (1.0 / min(max(sensitivity, 0.50), 1.50))
            let groupingWindow = host?.preferences.value(forKey: "thump.groupingWindow", default: profile.defaultGroupingWindow) ?? profile.defaultGroupingWindow
            let cooldown = host?.preferences.value(forKey: "thump.cooldown", default: profile.defaultCooldown) ?? profile.defaultCooldown

            let result: [String: Any] = [
                "profile": profile.displayName,
                "accel_threshold": accelThreshold,
                "sensitivity_multiplier": sensitivity,
                "effective_threshold": effectiveThreshold,
                "grouping_window_seconds": groupingWindow,
                "cooldown_seconds": cooldown
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
            return String(decoding: data, as: UTF8.self)

        default:
            throw NSError(domain: "ThumpMCP", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Unknown MCP tool named '\(name)'."
            ])
        }
    }
}

// MARK: - Bundle & Links

private final class ThumpBundleToken {}

extension Bundle {
    /// The `.droplet` bundle: Thump's identity, version, icon and resources.
    public nonisolated static let thump = Bundle(for: ThumpBundleToken.self)
}

/// Links for Thump documentation, repository, and legal notices.
public enum ThumpLinks {
    public static let source = "https://gitlab.com/droppyformac1/droplets/-/tree/main/droplets/thump"
    public static let license = "https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/thump/NOTICE.md"

    @MainActor
    public static func openAcknowledgements() {
        if let url = Bundle.thump.url(forResource: "Acknowledgements", withExtension: "txt", subdirectory: "Assets/Legal") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: license) {
            NSWorkspace.shared.open(url)
        }
    }
}
