import SwiftUI
import DroppyKit
import AppKit
import UniformTypeIdentifiers

struct ThumpSettingsPane: View {
    @ObservedObject var droplet: ThumpDroplet
    let context: SettingsPaneContext
    
    @Environment(\.dropletSettingsPageOpener) private var opener
    @State private var showingWizard = false
    @State private var redrawCounter = 0
    @State private var isExportingLogs = false
    var body: some View {
        let _ = redrawCounter
        DropletSettingsPane {
            let available = ThumpAccelerometerService().available()
            let hasCalibrated = droplet.host?.preferences.value(forKey: "thump.hasCalibrated", default: false) ?? false

            DropletSettingsSection(header: { Text("Calibration") }) {
                DropletSettingsCard {
                    if available {
                        DropletToggleRow(title: "Enable thump", isOn: Binding(
                            get: { droplet.isListening },
                            set: { if $0 { droplet.detector?.start() } else { droplet.detector?.stop() } }
                        ))
                    } else {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.body)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Chassis Accelerometer Unavailable")
                                    .font(.subheadline.weight(.semibold))
                                Text("This Mac does not have a supported Apple Silicon internal accelerometer (Apple SPU). Thump requires hardware motion sensors to detect chassis taps.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, DroppySpacing.xs)
                    }
                    
                    if droplet.isListening {
                        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                            Text("Live sensor activity")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            
                            ZStack {
                                VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                                    if let detector = droplet.detector {
                                        LiveSensorView(detector: detector)
                                    } else {
                                        Text("Sensor inactive")
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    let rawProfile = droplet.host?.preferences.value(forKey: "thump.surfaceProfile", default: ThumpSurfaceProfile.dynamic.rawValue) ?? ThumpSurfaceProfile.dynamic.rawValue
                                    let activeProfile = ThumpSurfaceProfile.from(raw: rawProfile)
                                    let accelThreshold = droplet.host?.preferences.value(forKey: "thump.accelThreshold", default: activeProfile.defaultThreshold) ?? activeProfile.defaultThreshold
                                    let sensitivity = droplet.host?.preferences.value(forKey: "thump.sensitivityMultiplier", default: 1.0) ?? 1.0
                                    let effectiveThreshold = accelThreshold * (1.0 / min(max(sensitivity, 0.50), 1.50))
                                    let groupingWindow = droplet.host?.preferences.value(forKey: "thump.groupingWindow", default: activeProfile.defaultGroupingWindow) ?? activeProfile.defaultGroupingWindow
                                    let cooldown = droplet.host?.preferences.value(forKey: "thump.cooldown", default: activeProfile.defaultCooldown) ?? activeProfile.defaultCooldown
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Profile: \(activeProfile.displayName)")
                                        Text("Sensitivity: \(Int(round(sensitivity * 100)))%")
                                        Text("Threshold: \(String(format: "%.3f", effectiveThreshold))")
                                        Text("Window: \(String(format: "%.2f s", groupingWindow))")
                                        Text("Cooldown: \(String(format: "%.2f s", cooldown))")
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, DroppySpacing.sm)
                                }
                                .blur(radius: hasCalibrated ? 0 : 8)
                                .allowsHitTesting(hasCalibrated)

                                if !hasCalibrated {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(.ultraThinMaterial)
                                            .opacity(0.88)

                                        VStack(spacing: 8) {
                                            Image(systemName: "slider.horizontal.3")
                                                .font(.system(size: 20, weight: .medium))
                                                .foregroundStyle(.secondary)

                                            Text("Calibration Required")
                                                .font(.subheadline.weight(.semibold))

                                            Text("Calibrate sensor to detect taps accurately on this Mac.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .multilineTextAlignment(.center)
                                                .padding(.horizontal, 20)

                                            Button("Start Calibration Wizard") {
                                                if let opener = opener {
                                                    opener(page: "calibration", title: "Calibration")
                                                } else {
                                                    showingWizard = true
                                                }
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.regular)
                                            .padding(.top, 2)
                                        }
                                        .padding(.vertical, 14)
                                        .padding(.horizontal, 12)
                                    }
                                }
                            }
                        }
                    } else if available {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text("Thump is stopped.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, DroppySpacing.xs)
                    }
                }
            }
            
            if available && droplet.isListening {
                DropletSettingsSection(header: { Text("Operating surface") }) {
                    DropletSettingsCard {
                        let rawProfile = droplet.host?.preferences.value(forKey: "thump.surfaceProfile", default: ThumpSurfaceProfile.dynamic.rawValue) ?? ThumpSurfaceProfile.dynamic.rawValue
                        let currentProfile = ThumpSurfaceProfile.from(raw: rawProfile)

                        DropletControlRow(
                            title: "Surface profile",
                            infoTip: currentProfile.summaryDescription
                        ) {
                            Picker("Surface profile", selection: Binding(
                                get: {
                                    let _ = redrawCounter
                                    return droplet.host?.preferences.value(forKey: "thump.surfaceProfile", default: ThumpSurfaceProfile.dynamic.rawValue) ?? ThumpSurfaceProfile.dynamic.rawValue
                                },
                                set: { newRaw in
                                    droplet.host?.preferences.setValue(newRaw, forKey: "thump.surfaceProfile")
                                    let newProfile = ThumpSurfaceProfile.from(raw: newRaw)
                                    let hasCal = droplet.host?.preferences.value(forKey: "thump.hasCalibrated", default: false) ?? false
                                    if !hasCal {
                                        droplet.host?.preferences.setValue(newProfile.defaultThreshold, forKey: "thump.accelThreshold")
                                        droplet.host?.preferences.setValue(newProfile.defaultGroupingWindow, forKey: "thump.groupingWindow")
                                        droplet.host?.preferences.setValue(newProfile.defaultCooldown, forKey: "thump.cooldown")
                                    }
                                    redrawCounter += 1
                                }
                            )) {
                                ForEach(ThumpSurfaceProfile.allCases) { profile in
                                    Label(profile.displayName, systemImage: profile.iconName).tag(profile.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }

                        DropletSettingsDivider()

                        let sensitivityVal = droplet.host?.preferences.value(forKey: "thump.sensitivityMultiplier", default: 1.0) ?? 1.0
                        let sensitivityBinding = Binding<Double>(
                            get: {
                                let val = droplet.host?.preferences.value(forKey: "thump.sensitivityMultiplier", default: 1.0) ?? 1.0
                                return min(max(val * 100.0, 50.0), 150.0)
                            },
                            set: { newPercent in
                                let multiplier = newPercent / 100.0
                                droplet.host?.preferences.setValue(multiplier, forKey: "thump.sensitivityMultiplier")
                                redrawCounter += 1
                            }
                        )

                        DropletControlRow(
                            title: "Tap sensitivity",
                            infoTip: "Adjusts the physical knock force required. Higher values make Thump respond to lighter taps, while lower values require firmer knocks."
                        ) {
                            HStack(spacing: 10) {
                                Slider(
                                    value: sensitivityBinding,
                                    in: 50.0...150.0,
                                    step: 5.0
                                )
                                .labelsHidden()
                                .frame(minWidth: 100, maxWidth: 140)

                                DropletValuePill(text: "\(Int(round(sensitivityVal * 100)))%")
                            }
                        }
                    }
                }

                if hasCalibrated {
                    DropletSettingsSection(header: { Text("Calibration Wizard") }) {
                        DropletSettingsCard {
                            DropletSettingsPageLink(
                                "Recalibrate tap sensor",
                                subtitle: "Calibrated for this Mac. Tap to recalibrate force and rhythm.",
                                page: "calibration"
                            ) {
                                ThumpWizardIcon()
                            }
                        }
                    }
                }
            }
            
            DropletSettingsSection(header: { Text("Actions") }) {
                DropletSettingsCard {
                    if let host = droplet.host {
                        if !available {
                            Text("Actions cannot trigger on this Mac because hardware motion sensors are unavailable.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, DroppySpacing.xs)
                        } else {
                            ActionConfigRow(host: host, taps: 2, title: "Double tap", globalRedraw: $redrawCounter)
                            ActionConfigRow(host: host, taps: 3, title: "Triple tap", globalRedraw: $redrawCounter)
                            ActionConfigRow(host: host, taps: 4, title: "Quad tap", globalRedraw: $redrawCounter)
                        }
                    }
                }
            }

            DropletSettingsSection(header: { Text("Diagnostics") }) {
                DropletSettingsCard {
                    DropletControlRow(
                        title: "Export diagnostic logs",
                        infoTip: "Generates a compressed archive containing Thump sensor, impulse, and action logs."
                    ) {
                        HStack(spacing: 8) {
                            Button(isExportingLogs ? "Exporting…" : "Export…") {
                                exportLogs()
                            }
                            .disabled(isExportingLogs)

                            Button("Reveal") {
                                ThumpLogExporter.showLogsInFinder()
                            }
                        }
                    }
                }
            }
            
            DropletSettingsSection(header: { Text("Credits") }) {
                DropletSettingsCard {
                    DropletControlRow(
                        title: "Based on nocnoc by rayinclay",
                        infoTip: "Thump references Apple Silicon SPU accelerometer hardware parameters from nocnoc."
                    ) {
                        Button("License") {
                            if let url = URL(string: "https://gitlab.com/droppyformac1/droplets/-/blob/main/droplets/thump/ACKNOWLEDGEMENTS.md") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            redrawCounter += 1
            droplet.detector?.beginVisualization()
        }
        .onDisappear {
            droplet.detector?.endVisualization()
        }
        .sheet(isPresented: $showingWizard) {
            if let detector = droplet.detector {
                ThumpCalibrationWizard(detector: detector)
            }
        }
        .onChange(of: showingWizard) {
            redrawCounter += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            redrawCounter += 1
        }
    }

    private func exportLogs() {
        isExportingLogs = true
        Task {
            defer { isExportingLogs = false }
            do {
                let tempZipURL = try await ThumpLogExporter.exportLogs()
                defer {
                    try? FileManager.default.removeItem(at: tempZipURL)
                }

                let panel = NSSavePanel()
                panel.title = "Export Thump Logs"
                panel.nameFieldStringValue = tempZipURL.lastPathComponent
                panel.allowedContentTypes = [.zip]
                panel.canCreateDirectories = true

                if panel.runModal() == .OK, let destinationURL = panel.url {
                    let fileManager = FileManager.default
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: tempZipURL, to: destinationURL)
                }
            } catch {
                ThumpLogger.error("Failed to export logs: \(error.localizedDescription)")
            }
        }
    }
}

struct ActionConfigRow: View {
    let host: DropletHost
    let taps: Int
    let title: String
    @Binding var globalRedraw: Int
    
    @ViewBuilder
    var body: some View {
        let _ = globalRedraw
        DropletControlRow(title: title, icon: "hand.tap") {
            Picker("", selection: Binding(
                get: {
                    let raw = host.preferences.value(forKey: "thump.actionType.\(taps)", default: ThumpActionType.none.rawValue)
                    return ThumpActionType(rawValue: raw)?.rawValue ?? ThumpActionType.none.rawValue
                },
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
                    Label(type.rawValue, systemImage: type.iconName).tag(type.rawValue)
                }
            }
        }
        
        let rawActionType = host.preferences.value(forKey: "thump.actionType.\(taps)", default: ThumpActionType.none.rawValue)
        let actionType = ThumpActionType(rawValue: rawActionType)?.rawValue ?? ThumpActionType.none.rawValue
        if actionType == ThumpActionType.appleScript.rawValue || actionType == ThumpActionType.shellCommand.rawValue {
            DropletControlRow(title: "Command / script", icon: actionType == ThumpActionType.appleScript.rawValue ? "applescript" : "terminal") {
                TextField("", text: Binding(
                    get: { host.preferences.value(forKey: "thump.actionPayload.\(taps)", default: "") },
                    set: { host.preferences.setValue($0, forKey: "thump.actionPayload.\(taps)") }
                ), prompt: Text("Enter script..."), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
            }
        } else if actionType == ThumpActionType.runShortcut.rawValue {
            DropletControlRow(title: "Shortcut name", icon: "square.2.layers.3d") {
                TextField("", text: Binding(
                    get: { host.preferences.value(forKey: "thump.actionPayload.\(taps)", default: "") },
                    set: { host.preferences.setValue($0, forKey: "thump.actionPayload.\(taps)") }
                ), prompt: Text("Enter name..."))
                    .textFieldStyle(.roundedBorder)
            }
        } else if actionType == ThumpActionType.launchApp.rawValue {
            DropletControlRow(title: "App name", icon: "arrow.up.forward.app") {
                TextField("", text: Binding(
                    get: { host.preferences.value(forKey: "thump.actionPayload.\(taps)", default: "") },
                    set: { host.preferences.setValue($0, forKey: "thump.actionPayload.\(taps)") }
                ), prompt: Text("e.g. Spotify"))
                    .textFieldStyle(.roundedBorder)
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
            } else if [ThumpActionType.appleScript.rawValue, ThumpActionType.shellCommand.rawValue, ThumpActionType.runShortcut.rawValue, ThumpActionType.launchApp.rawValue, ThumpActionType.toggleMenuBar.rawValue].contains(action) {
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

struct ThumpWizardIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.blue.opacity(0.7), Color.blue.opacity(0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(.white)
                .font(.system(size: 14, weight: .semibold))
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        }
        .frame(width: 28, height: 28)
    }
}

private struct LiveSensorView: View {
    @ObservedObject var detector: ThumpDetector
    
    var body: some View {
        ThumpWaveformView(values: detector.waveformHistory, threshold: detector.currentEffectiveThreshold)
            .frame(height: 50)
    }
}
