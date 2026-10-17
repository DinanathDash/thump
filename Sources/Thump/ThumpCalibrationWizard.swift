import SwiftUI
import Combine
import DroppyKit

@MainActor
private final class CalibrationCollector: ObservableObject {
    struct TapImpulse: Sendable {
        let peakMagnitude: Double
        let timestamp: TimeInterval
    }

    struct TapTrial: Sendable {
        let maxPeak: Double
        let interTapIntervals: [TimeInterval]
    }

    var doubleTapTrials: [TapTrial] = []
    var tripleTapTrials: [TapTrial] = []
    var quadTapTrials: [TapTrial] = []

    private var activePeaks: [TapImpulse] = []
    private var lastPeakTimestamp: TimeInterval = 0
    private let debounceInterval: TimeInterval = 0.055
    private let trialCompletionSilence: TimeInterval = 0.70
    private var currentPhase: Int = 1

    @Published var feedbackNotice: String? = nil

    func setStep(_ step: Int) {
        self.currentPhase = step
        self.activePeaks.removeAll()
        self.feedbackNotice = nil
    }

    func reset() {
        doubleTapTrials.removeAll()
        tripleTapTrials.removeAll()
        quadTapTrials.removeAll()
        activePeaks.removeAll()
        feedbackNotice = nil
        lastPeakTimestamp = 0
        currentPhase = 1
    }

    func resetCurrentStep() {
        switch currentPhase {
        case 1: doubleTapTrials.removeAll()
        case 2: tripleTapTrials.removeAll()
        case 3: quadTapTrials.removeAll()
        default: break
        }
        feedbackNotice = nil
    }

    func processWaveformSample(_ magnitude: Double) {
        let now = ProcessInfo.processInfo.systemUptime

        // Check if trailing silence indicates completion of the active tap sequence
        if !activePeaks.isEmpty, let lastPeak = activePeaks.last, now - lastPeak.timestamp > trialCompletionSilence {
            finalizeTrial()
        }

        // Normalized transient energy from ThumpKnockDetector
        let unscaledMagnitude = magnitude / 18.0

        guard unscaledMagnitude > 0.024, now - lastPeakTimestamp > debounceInterval else { return }
        lastPeakTimestamp = now
        activePeaks.append(TapImpulse(peakMagnitude: unscaledMagnitude, timestamp: now))
    }

    private func finalizeTrial() {
        guard !activePeaks.isEmpty else { return }
        let highestPeak = activePeaks.map(\.peakMagnitude).max() ?? 0.1
        var intervals: [TimeInterval] = []
        if activePeaks.count > 1 {
            for i in 1..<activePeaks.count {
                intervals.append(activePeaks[i].timestamp - activePeaks[i - 1].timestamp)
            }
        }

        let tapCount = activePeaks.count
        var targetCount = 0
        switch currentPhase {
        case 1: targetCount = 2
        case 2: targetCount = 3
        case 3: targetCount = 4
        default: break
        }

        if targetCount > 0 {
            if tapCount < targetCount {
                feedbackNotice = "Detected \(tapCount) taps. Needed \(targetCount)."
            } else if tapCount > targetCount {
                feedbackNotice = "Detected \(tapCount) taps. Needed \(targetCount)."
            } else {
                feedbackNotice = nil
                let trial = TapTrial(maxPeak: highestPeak, interTapIntervals: intervals)
                var justFinished = false
                switch currentPhase {
                case 1:
                    if doubleTapTrials.count < 3 {
                        doubleTapTrials.append(trial)
                        if doubleTapTrials.count == 3 { justFinished = true }
                    }
                case 2:
                    if tripleTapTrials.count < 3 {
                        tripleTapTrials.append(trial)
                        if tripleTapTrials.count == 3 { justFinished = true }
                    }
                case 3:
                    if quadTapTrials.count < 3 {
                        quadTapTrials.append(trial)
                        if quadTapTrials.count == 3 { justFinished = true }
                    }
                default: break
                }
                
                if justFinished {
                    let phase = currentPhase
                    onStepCompleted?(phase)
                }
            }
        }

        activePeaks.removeAll()
        objectWillChange.send()
    }

    var onStepCompleted: ((Int) -> Void)?

    func computeSettings() -> (threshold: Double, groupingWindow: Double, cooldown: Double) {
        finalizeTrial()

        let allTrials = doubleTapTrials + tripleTapTrials + quadTapTrials
        let peaks = allTrials.map(\.maxPeak)
        let averagePeak = peaks.isEmpty ? 0.05 : peaks.reduce(0, +) / Double(peaks.count)

        // Recommended sensitivity: 65% of average user impact force (clamped 0.025 to 0.080)
        let calculatedThreshold = averagePeak * 0.65

        let intervals = allTrials.flatMap(\.interTapIntervals)
        let averageInterval = intervals.isEmpty ? 0.35 : intervals.reduce(0, +) / Double(intervals.count)
        let maxInterval = intervals.max() ?? 0.40
        let minimumInterval = intervals.min() ?? 0.20

        // Grouping window accommodates natural cadence pauses with comfortable margin (clamped 0.60s to 0.85s)
        let calculatedWindow = max(averageInterval * 1.55, maxInterval + 0.20)

        // Cooldown prevents tap ring-down while permitting rapid double-taps (clamped 0.06s to 0.10s)
        let calculatedCooldown = minimumInterval * 0.40

        return (
            threshold: max(0.025, min(calculatedThreshold, 0.080)),
            groupingWindow: max(0.60, min(calculatedWindow, 0.85)),
            cooldown: max(0.06, min(calculatedCooldown, 0.10))
        )
    }
}

public struct ThumpCalibrationWizard: View {
    let detector: ThumpDetector
    @Environment(\.dismiss) private var dismiss

    @StateObject private var collector = CalibrationCollector()
    @State private var step: Int = 1

    public init(detector: ThumpDetector) {
        self.detector = detector
    }

    public var body: some View {
        DropletSettingsPage {
            DropletSettingsSection(header: { Text("Wizard step \(step) of 4") }) {
                DropletSettingsCard {
                    if step == 1 {
                        calibrationStepView(
                            title: "Double taps",
                            subtitle: "Tap twice quickly on the palm rest area.\nRepeat 3 times to measure force and speed.",
                            collected: collector.doubleTapTrials.count,
                            required: 3
                        )
                    } else if step == 2 {
                        calibrationStepView(
                            title: "Triple taps",
                            subtitle: "Tap three times quickly.\nRepeat 3 times to refine timing.",
                            collected: collector.tripleTapTrials.count,
                            required: 3
                        )
                    } else if step == 3 {
                        calibrationStepView(
                            title: "Quad taps",
                            subtitle: "Tap four times quickly.\nRepeat 3 times to finalize cadence.",
                            collected: collector.quadTapTrials.count,
                            required: 3
                        )
                    } else {
                        testStepView
                    }

                    // Navigation Controls
                    HStack {
                        if step > 1 {
                            Button("Back") {
                                withAnimation {
                                    step -= 1
                                    collector.setStep(step)
                                }
                            }
                            .buttonStyle(.bordered)
                        }

                        Button("Reset step") {
                            withAnimation {
                                collector.resetCurrentStep()
                            }
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        if step < 4 {
                            Button("Next") {
                                withAnimation {
                                    step += 1
                                    collector.setStep(step)
                                    if step == 4 {
                                        applyComputedSettings()
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canAdvance)
                        } else {
                            Button("Save configuration") {
                                saveConfiguration()
                                detector.host.workspace.goBackInSettings()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.top, DroppySpacing.lg)
                }
            }
        }
        .onAppear {
            detector.isSuppressingActions = true
            detector.overrideThreshold = 0.025
            detector.beginVisualization()

            collector.onStepCompleted = { completedPhase in
                guard step == completedPhase && step < 4 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard step == completedPhase && step < 4 else { return }
                    withAnimation {
                        step += 1
                        collector.setStep(step)
                        if step == 4 {
                            applyComputedSettings()
                        }
                    }
                }
            }

            detector.onRawWaveformSample = { val in
                if step < 4 {
                    collector.processWaveformSample(val)
                }
            }
        }
        .onDisappear {
            collector.onStepCompleted = nil
            detector.isSuppressingActions = false
            detector.overrideThreshold = nil
            detector.endVisualization()
            detector.onRawWaveformSample = nil
        }
    }

    private var canAdvance: Bool {
        if step == 1 { return collector.doubleTapTrials.count >= 3 }
        if step == 2 { return collector.tripleTapTrials.count >= 3 }
        if step == 3 { return collector.quadTapTrials.count >= 3 }
        return true
    }

    @ViewBuilder
    private func calibrationStepView(title: String, subtitle: String, collected: Int, required: Int) -> some View {
        VStack(spacing: DroppySpacing.md) {
            Text(title)
                .font(.title2.bold())

            Text(subtitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(AdaptiveColors.secondaryTextAuto)

            // Live Graph
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                Text("Sensor output")
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.secondaryTextAuto)

                WizardLiveGraph(detector: detector)
            }
            .padding(.top, DroppySpacing.md)

            // Progress Dots
            HStack(spacing: DroppySpacing.sm) {
                ForEach(0..<required, id: \.self) { i in
                    Circle()
                        .fill(i < collected ? AdaptiveColors.selectionBlueAuto : AdaptiveColors.buttonBackgroundAuto)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.top, DroppySpacing.lg)

            if let warning = collector.feedbackNotice {
                VStack(spacing: DroppySpacing.sm) {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
                .padding(.top, DroppySpacing.sm)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var testStepView: some View {
        VStack(spacing: DroppySpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(AdaptiveColors.selectionBlueAuto)

            Text("Calibration complete")
                .font(.title2.bold())

            Text("Your custom profile has been generated. Try tapping now to verify that your taps are reliably recognized.")
                .multilineTextAlignment(.center)
                .foregroundStyle(AdaptiveColors.secondaryTextAuto)

            DropletSettingsCard {
                let computed = collector.computeSettings()
                DropletControlRow(title: "Threshold", icon: "hammer") {
                    Text(String(format: "%.2f", computed.threshold))
                        .foregroundStyle(.secondary)
                }
                DropletControlRow(title: "Window", icon: "clock") {
                    Text(String(format: "%.2f s", computed.groupingWindow))
                        .foregroundStyle(.secondary)
                }
                DropletControlRow(title: "Cooldown", icon: "hourglass") {
                    Text(String(format: "%.2f s", computed.cooldown))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, DroppySpacing.md)
        }
    }

    private func applyComputedSettings() {
        let computed = collector.computeSettings()
        detector.overrideThreshold = computed.threshold
    }

    private func saveConfiguration() {
        let computed = collector.computeSettings()
        detector.host.preferences.setValue(computed.threshold, forKey: "thump.accelThreshold")
        detector.host.preferences.setValue(computed.groupingWindow, forKey: "thump.groupingWindow")
        detector.host.preferences.setValue(computed.cooldown, forKey: "thump.cooldown")
    }
}

private struct WizardLiveGraph: View {
    @ObservedObject var detector: ThumpDetector

    var body: some View {
        ThumpWaveformView(values: detector.waveformHistory, threshold: detector.overrideThreshold ?? 0.035)
            .frame(height: 64)
    }
}

/// Dynamic, responsive visualizer for accelerometer impulses.
public struct ThumpWaveformView: View {
    public let values: [Double]
    public let threshold: Double

    public init(values: [Double], threshold: Double) {
        self.values = values
        self.threshold = threshold
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let horizontalInset: CGFloat = 4

            ZStack {
                // Background card
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AdaptiveColors.buttonBackgroundAuto.opacity(0.85))

                // Threshold guide line
                let thresholdNormalized = min(max(threshold * 3.5, 0.05), 0.95)
                let thresholdY = height * (1.0 - thresholdNormalized)

                Path { path in
                    path.move(to: CGPoint(x: horizontalInset, y: thresholdY))
                    path.addLine(to: CGPoint(x: width - horizontalInset, y: thresholdY))
                }
                .stroke(
                    Color.orange.opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                )

                // Impulse curve
                if values.count > 1 {
                    let availableWidth = max(width - (horizontalInset * 2), 1)
                    let step = availableWidth / CGFloat(max(values.count - 1, 1))

                    Path { path in
                        for (i, val) in values.enumerated() {
                            let x = horizontalInset + CGFloat(i) * step
                            let clampedMagnitude = min(max(val * 2.8, 0.0), 1.0)
                            let y = height - (CGFloat(clampedMagnitude) * (height - 8)) - 4

                            if i == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(
                        LinearGradient(
                            colors: [AdaptiveColors.selectionBlueAuto, AdaptiveColors.selectionBlueAuto.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
