import SwiftUI
import DroppyKit

struct ThumpSettingsPane: View {
    @ObservedObject var droplet: ThumpDroplet
    let context: SettingsPaneContext
    
    @State private var showingWizard = false
    
    // Accel Config (for displaying current status)
    @AppStorage("thump.accelThreshold") private var accelThreshold: Double = 0.15
    @AppStorage("thump.groupingWindow") private var groupingWindow: Double = 0.8
    @AppStorage("thump.cooldown") private var cooldown: Double = 0.3
    
    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xl) {
            
            VStack(alignment: .leading, spacing: DroppySpacing.md) {
                Text("Calibration")
                    .font(.headline)
                    .foregroundStyle(AdaptiveColors.primaryTextAuto)
                    
                DropletSettingsCard {
                    DropletToggleRow(title: "Enable Thump", isOn: Binding(
                        get: { droplet.isListening },
                        set: { if $0 { droplet.detector?.start() } else { droplet.detector?.stop() } }
                    ))
                    
                    if droplet.isListening {
                        DropletSettingsDivider()
                        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                            Text("Live Sensor Activity")
                                .font(.subheadline)
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            
                            if let detector = droplet.detector {
                                LiveSensorView(detector: detector)
                            } else {
                                Text("Sensor inactive")
                                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                            }
                        }
                        .padding(DroppySpacing.md)
                        
                        DropletSettingsDivider()
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Threshold: \(String(format: "%.2f", accelThreshold))")
                                Text("Window: \(String(format: "%.1f s", groupingWindow))")
                                Text("Cooldown: \(String(format: "%.1f s", cooldown))")
                            }
                            .font(.footnote)
                            .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                            
                            Spacer()
                            
                            Button("Run Calibration Wizard") {
                                showingWizard = true
                            }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        }
                        .padding(DroppySpacing.md)
                    }
                }
            }
            
            if droplet.isListening {
                VStack(alignment: .leading, spacing: DroppySpacing.md) {
                    Text("Actions")
                        .font(.headline)
                        .foregroundStyle(AdaptiveColors.primaryTextAuto)
                        
                    DropletSettingsCard {
                        if let host = droplet.host {
                            ActionConfigRow(host: host, taps: 2, title: "Double Tap")
                            DropletSettingsDivider()
                            ActionConfigRow(host: host, taps: 3, title: "Triple Tap")
                            DropletSettingsDivider()
                            ActionConfigRow(host: host, taps: 4, title: "Quad Tap")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingWizard) {
            if let detector = droplet.detector {
                ThumpCalibrationWizard(detector: detector)
            }
        }
    }
}

private struct ActionConfigRow: View {
    let host: DropletHost
    let taps: Int
    let title: String
    
    var body: some View {
        VStack(spacing: 0) {
            DropletControlRow(title: title, icon: "hand.tap") {
                Picker("Action Type", selection: Binding(
                    get: { host.preferences.value(forKey: "thump.actionType.\(taps)", default: ThumpActionType.none.rawValue) },
                    set: { new in
                        host.preferences.setValue(new, forKey: "thump.actionType.\(taps)")
                        requestPermission(for: new)
                    }
                )) {
                    ForEach(ThumpActionType.allCases) { type in
                        Text(type.rawValue).tag(type.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            
            let actionType = host.preferences.value(forKey: "thump.actionType.\(taps)", default: ThumpActionType.none.rawValue)
            if actionType == ThumpActionType.appleScript.rawValue || actionType == ThumpActionType.shellCommand.rawValue {
                DropletSettingsDivider()
                DropletControlRow(title: "Command / Script") {
                    TextField("Enter script...", text: Binding(
                        get: { host.preferences.value(forKey: "thump.actionPayload.\(taps)", default: "") },
                        set: { host.preferences.setValue($0, forKey: "thump.actionPayload.\(taps)") }
                    ), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                }
            } else if actionType == ThumpActionType.runShortcut.rawValue {
                DropletSettingsDivider()
                DropletControlRow(title: "Shortcut Name") {
                    TextField("Enter name...", text: Binding(
                        get: { host.preferences.value(forKey: "thump.actionPayload.\(taps)", default: "") },
                        set: { host.preferences.setValue($0, forKey: "thump.actionPayload.\(taps)") }
                    ))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }
    
    private func requestPermission(for action: String) {
        Task {
            if action == ThumpActionType.screenshot.rawValue {
                _ = await host.permissions.request(.screenCapture)
            } else if action == ThumpActionType.playPause.rawValue || action == ThumpActionType.muteUnmute.rawValue {
                _ = await host.permissions.request(.accessibility)
            } else if action == ThumpActionType.appleScript.rawValue {
                _ = await host.permissions.request(.appleEvents)
            }
        }
    }
}

private struct LiveSensorView: View {
    @ObservedObject var detector: ThumpDetector
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(AdaptiveColors.buttonBackgroundAuto)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(AdaptiveColors.selectionBlueAuto)
                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(detector.waveformData))))
                    .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.6), value: detector.waveformData)
            }
        }
        .frame(height: 12)
    }
}
