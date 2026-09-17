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
    
    public func activate(host: DropletHost) throws {
        self.host = host
        host.log.info("Thump activated")
        
        let runner = ThumpActionRunner(host: host)
        self.actionRunner = runner
        
        let detector = ThumpDetector(host: host, actionRunner: runner)
        detector.onThumpDetected = { [weak self] actionName in
            self?.showLiveActivity(for: actionName)
        }
        self.detector = detector
        
        detector.start()
    }

    public func deactivate() {
        detector?.stop()
        detector = nil
        actionRunner = nil
        host = nil
    }

    /// What the widget's control does. Replace it with the real action.
    public func refresh() {
        if detector?.isListening == true {
            detector?.stop()
        } else {
            detector?.start()
        }
    }
    
    private func showLiveActivity(for actionName: String) {
        liveActivitySubject = LiveActivityState(priority: 0, accessibilityTitle: "Thump detected")
        
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
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

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 12, weight: .medium))
                Text("Thump")
                    .font(.system(size: 12, weight: .semibold))
                
                Spacer(minLength: 0)
                
                if let isListening = droplet.detector?.isListening {
                    Text(isListening ? "Listening" : "Stopped")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isListening ? AdaptiveColors.notchSurfacePrimaryText : AdaptiveColors.notchSurfaceSecondaryText)
                }
                
                if !context.isCompact {
                    Button {
                        droplet.refresh()
                    } label: {
                        Image(systemName: droplet.detector?.isListening == true ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20))
                    .help(droplet.detector?.isListening == true ? "Stop" : "Start")
                }
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            if !context.isCompact {
                Text(droplet.detector?.isUsingAccelerometer == true ? "Sensor: Accelerometer" : "Sensor: Microphone")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Settings Pane
extension ThumpDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(ThumpSettingsPane(droplet: self, context: context))
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
            Text("Thump!")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .padding(.trailing, 8)
        )
    }
    
    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(EmptyView())
    }
}
