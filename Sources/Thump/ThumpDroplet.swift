import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(ThumpPrincipal)
public final class ThumpPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { ThumpDroplet() }
}

/// Thump.
@MainActor
public final class ThumpDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "thump"

    public var host: DropletHost?
    @Published var detector: ThumpDetector?
    private var actionRunner: ThumpActionRunner?
    
    // Live Activity publisher
    @Published private var liveActivitySubject: LiveActivityState? = nil
    @Published private var lastTapLabel: String = "Tap!"
    
    @Published public var isListening: Bool = false
    
    private var dismissalTask: Task<Void, Never>?
    
    public func activate(host: DropletHost) throws {
        self.host = host
        host.log.info("Thump activated")
        
        let runner = ThumpActionRunner(host: host)
        self.actionRunner = runner
        
        let detector = ThumpDetector(host: host, actionRunner: runner)
        detector.onThumpDetected = { [weak self] actionName in
            self?.showLiveActivity(for: actionName.lowercased())
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

    private func hasAnyAction() -> Bool {
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
    
    private func showLiveActivity(for actionName: String) {
        self.lastTapLabel = actionName
        liveActivitySubject = LiveActivityState(priority: 0, accessibilityTitle: "Thump detected")
        
        dismissalTask?.cancel()
        dismissalTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
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
        guard let host = droplet.host else { return false }
        return (2...4).contains { taps in
            host.preferences.value(forKey: "thump.actionType.\(taps)", default: "None") != "None"
        }
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
                        .buttonStyle(DroppyCircleButtonStyle(size: 20))
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
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        )
    }
    
    public func makeCompactTrailing() -> AnyView {
        AnyView(
            Text(lastTapLabel)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .id(lastTapLabel)
                .transition(DroppyTransition.compactContent)
        )
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
