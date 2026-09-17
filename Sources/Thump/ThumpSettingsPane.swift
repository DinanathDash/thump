import SwiftUI
import DroppyKit

struct ThumpSettingsPane: View {
    @ObservedObject var droplet: ThumpDroplet
    let context: SettingsPaneContext
    
    @State private var showingWizard = false
    @State private var redrawCounter = 0
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
                            let accelThreshold = droplet.host?.preferences.value(forKey: "thump.accelThreshold", default: 0.15) ?? 0.15
                            let groupingWindow = droplet.host?.preferences.value(forKey: "thump.groupingWindow", default: 0.8) ?? 0.8
                            let cooldown = droplet.host?.preferences.value(forKey: "thump.cooldown", default: 0.3) ?? 0.3
                            
                            VStack(alignment: .leading, spacing: 4) {
                                let _ = redrawCounter
                                Text("Threshold: \(String(format: "%.2f", accelThreshold))")
                                Text("Window: \(String(format: "%.2f s", groupingWindow))")
                                Text("Cooldown: \(String(format: "%.2f s", cooldown))")
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
                            ActionConfigRow(host: host, taps: 2, title: "Double Tap", globalRedraw: $redrawCounter)
                            DropletSettingsDivider()
                            ActionConfigRow(host: host, taps: 3, title: "Triple Tap", globalRedraw: $redrawCounter)
                            DropletSettingsDivider()
                            ActionConfigRow(host: host, taps: 4, title: "Quad Tap", globalRedraw: $redrawCounter)
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
        .onChange(of: showingWizard) { _ in
            redrawCounter += 1
        }
    }
}

struct ActionConfigRow: View {
    let host: DropletHost
    let taps: Int
    let title: String
    @Binding var globalRedraw: Int
    
    var body: some View {
        VStack(spacing: 0) {
            let _ = globalRedraw // create dependency on globalRedraw
            DropletControlRow(title: title, icon: "hand.tap") {
                Picker("Action Type", selection: Binding(
                    get: { host.preferences.value(forKey: "thump.actionType.\(taps)", default: ThumpActionType.none.rawValue) },
                    set: { new in
                        if new != ThumpActionType.none.rawValue {
                            for other in 2...4 {
                                if other != taps {
                                    if host.preferences.value(forKey: "thump.actionType.\(other)", default: ThumpActionType.none.rawValue) == new {
                                        host.preferences.setValue(ThumpActionType.none.rawValue, forKey: "thump.actionType.\(other)")
                                    }
                                }
                            }
                        }
                        host.preferences.setValue(new, forKey: "thump.actionType.\(taps)")
                        globalRedraw += 1
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
            } else if actionType == ThumpActionType.launchApp.rawValue {
                DropletSettingsDivider()
                DropletControlRow(title: "App Name") {
                    TextField("e.g. Spotify", text: Binding(
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
            var perm: DropletPermission?
            if action == ThumpActionType.screenshot.rawValue {
                perm = .screenCapture
            } else if [ThumpActionType.playPause.rawValue, ThumpActionType.muteUnmute.rawValue, ThumpActionType.lockScreen.rawValue, ThumpActionType.brightnessUp.rawValue, ThumpActionType.brightnessDown.rawValue, ThumpActionType.volumeUp.rawValue, ThumpActionType.volumeDown.rawValue].contains(action) {
                perm = .accessibility
            } else if [ThumpActionType.appleScript.rawValue, ThumpActionType.shellCommand.rawValue, ThumpActionType.runShortcut.rawValue, ThumpActionType.launchApp.rawValue].contains(action) {
                perm = .appleEvents
            }
            if let perm = perm {
                let status = host.permissions.status(for: perm)
                if status == .notDetermined {
                    _ = await host.permissions.request(perm)
                }
            }
        }
    }
}

private struct LiveSensorView: View {
    @ObservedObject var detector: ThumpDetector
    
    var body: some View {
        ThumpWaveformView(values: detector.waveformHistory, threshold: detector.host.preferences.value(forKey: "thump.accelThreshold", default: 0.15))
            .frame(height: 50)
    }
}
