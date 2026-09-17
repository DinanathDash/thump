import SwiftUI
import DroppyKit

struct ThumpSettingsPane: View {
    @ObservedObject var droplet: ThumpDroplet
    let context: SettingsPaneContext
    
    // Status
    @State private var micStatus: DropletPermissionStatus = .notDetermined
    
    // Settings
    @AppStorage("thump.micSensitivity") private var micSensitivity: String = "Medium"
    
    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xl) {
            
            VStack(alignment: .leading, spacing: DroppySpacing.md) {
                Text("Detection")
                    .font(.headline)
                    .foregroundStyle(AdaptiveColors.primaryTextAuto)
                    
                DropletSettingsCard {
                    DropletControlRow(
                        title: "Microphone",
                        icon: "mic",
                        infoTip: "Required to detect thumps via audio if the accelerometer is unavailable."
                    ) {
                        if micStatus == .granted {
                            Text("Granted")
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        } else if micStatus == .denied {
                            Button("Settings") {
                                droplet.host?.permissions.openSystemSettings(for: .microphone)
                            }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                        } else {
                            Button("Request") {
                                Task {
                                    _ = await droplet.host?.permissions.request(.microphone)
                                    await checkPermissions()
                                }
                            }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                        }
                    }
                    
                    DropletSettingsDivider()
                    
                    DropletControlRow(
                        title: "Microphone Sensitivity",
                        icon: "waveform",
                        infoTip: "Adjust if Thump triggers too often or too rarely."
                    ) {
                        Picker("Sensitivity", selection: $micSensitivity) {
                            Text("High (Easier)").tag("High")
                            Text("Medium").tag("Medium")
                            Text("Low (Harder)").tag("Low")
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: DroppySpacing.md) {
                Text("Actions")
                    .font(.headline)
                    .foregroundStyle(AdaptiveColors.primaryTextAuto)
                    
                DropletSettingsCard {
                    ActionConfigRow(taps: 2, title: "Double Tap")
                    DropletSettingsDivider()
                    ActionConfigRow(taps: 3, title: "Triple Tap")
                    DropletSettingsDivider()
                    ActionConfigRow(taps: 4, title: "Quad Tap")
                }
            }
        }
        .task {
            await checkPermissions()
        }
    }
    
    private func checkPermissions() async {
        if let h = droplet.host {
            micStatus = h.permissions.status(for: .microphone)
        }
    }
}

private struct ActionConfigRow: View {
    let taps: Int
    let title: String
    
    @AppStorage var actionType: String
    @AppStorage var actionPayload: String
    
    init(taps: Int, title: String) {
        self.taps = taps
        self.title = title
        self._actionType = AppStorage(wrappedValue: ThumpActionType.none.rawValue, "thump.actionType.\(taps)")
        self._actionPayload = AppStorage(wrappedValue: "", "thump.actionPayload.\(taps)")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            DropletControlRow(title: title, icon: "hand.tap") {
                Picker("Action Type", selection: $actionType) {
                    ForEach(ThumpActionType.allCases) { type in
                        Text(type.rawValue).tag(type.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            
            if actionType == ThumpActionType.appleScript.rawValue || actionType == ThumpActionType.shellCommand.rawValue {
                DropletSettingsDivider()
                DropletControlRow(title: "Command / Script") {
                    TextField("Enter script...", text: $actionPayload, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                }
            } else if actionType == ThumpActionType.runShortcut.rawValue {
                DropletSettingsDivider()
                DropletControlRow(title: "Shortcut Name") {
                    TextField("Enter name...", text: $actionPayload)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }
}
