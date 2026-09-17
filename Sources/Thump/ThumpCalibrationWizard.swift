import SwiftUI
import Combine
import DroppyKit

@MainActor
private final class CalibrationCollector: ObservableObject {
    struct KnockSample {
        let peak: Double
        let timestamp: TimeInterval
    }
    
    var doubleKnocks: [KnockSample] = []
    var tripleKnocks: [KnockSample] = []
    var quadKnocks: [KnockSample] = []
    
    private var pendingPeaks: [KnockSample] = []
    private var lastPeakTime: TimeInterval = 0
    private let peakCooldown: TimeInterval = 0.08
    private let sequenceTimeout: TimeInterval = 0.6
    private var currentStep: Int = 1
    
    func setStep(_ step: Int) {
        self.currentStep = step
        self.pendingPeaks.removeAll()
    }
    
    func reset() {
        doubleKnocks.removeAll()
        tripleKnocks.removeAll()
        quadKnocks.removeAll()
        pendingPeaks.removeAll()
        lastPeakTime = 0
        currentStep = 1
    }
    
    func processWaveformSample(_ magnitude: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        
        // Flush sequence
        if !pendingPeaks.isEmpty, let lastPending = pendingPeaks.last, now - lastPending.timestamp > sequenceTimeout {
            flushPendingPeaks()
        }
        
        // Lower threshold for detecting peaks during calibration (0.03)
        // Divide by 20.0 to counteract the visualization multiplier in ThumpKnockDetector
        let rawMagnitude = magnitude / 20.0
        
        guard rawMagnitude > 0.03, now - lastPeakTime > peakCooldown else { return }
        lastPeakTime = now
        pendingPeaks.append(KnockSample(peak: rawMagnitude, timestamp: now))
    }
    
    private func flushPendingPeaks() {
        guard !pendingPeaks.isEmpty else { return }
        let maxPeak = pendingPeaks.map(\.peak).max() ?? 0
        let firstTimestamp = pendingPeaks.first!.timestamp
        let sequence = KnockSample(peak: maxPeak, timestamp: firstTimestamp)
        
        let intervals = zip(pendingPeaks, pendingPeaks.dropFirst()).map { $1.timestamp - $0.timestamp }
        
        switch currentStep {
        case 1:
            if doubleKnocks.count < 3 { doubleKnocks.append(sequence) }
            interKnockIntervals.append(contentsOf: intervals)
        case 2:
            if tripleKnocks.count < 3 { tripleKnocks.append(sequence) }
            interKnockIntervals.append(contentsOf: intervals)
        case 3:
            if quadKnocks.count < 3 { quadKnocks.append(sequence) }
            interKnockIntervals.append(contentsOf: intervals)
        default: break
        }
        pendingPeaks = []
        objectWillChange.send()
    }
    
    private var interKnockIntervals: [TimeInterval] = []
    
    func computeSettings() -> (threshold: Double, groupingWindow: Double, cooldown: Double) {
        flushPendingPeaks()
        
        let peaks = doubleKnocks.map(\.peak) + tripleKnocks.map(\.peak) + quadKnocks.map(\.peak)
        let avgPeak = peaks.isEmpty ? 0.15 : peaks.reduce(0, +) / Double(peaks.count)
        let threshold = avgPeak * 0.6
        
        let avgInterval = interKnockIntervals.isEmpty ? 0.40 : interKnockIntervals.reduce(0, +) / Double(interKnockIntervals.count)
        let groupingWindow = avgInterval * 1.3
        
        let minInterval = interKnockIntervals.min() ?? 0.12
        let cooldown = minInterval * 0.8
        
        return (
            threshold: max(0.04, min(threshold, 0.25)),
            groupingWindow: max(0.20, min(groupingWindow, 0.90)),
            cooldown: max(0.05, min(cooldown, 0.40))
        )
    }
}

struct ThumpCalibrationWizard: View {
    @ObservedObject var detector: ThumpDetector
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var collector = CalibrationCollector()
    @State private var step: Int = 1
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Accelerometer Calibration")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    cleanupAndDismiss()
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
            .padding(.horizontal, DroppySpacing.xl)
            .padding(.vertical, DroppySpacing.md)
            .background(AdaptiveColors.panelBackgroundAuto)
            
            Divider()
            
            // Content
            VStack(spacing: DroppySpacing.lg) {
                if step == 1 {
                    calibrationStepView(
                        title: "1. Double Taps",
                        subtitle: "Tap twice quickly on the palm rest area.\nRepeat 3 times to measure force and speed.",
                        collected: collector.doubleKnocks.count,
                        required: 3
                    )
                } else if step == 2 {
                    calibrationStepView(
                        title: "2. Triple Taps",
                        subtitle: "Tap three times quickly.\nRepeat 3 times to refine timing.",
                        collected: collector.tripleKnocks.count,
                        required: 3
                    )
                } else if step == 3 {
                    calibrationStepView(
                        title: "3. Quad Taps",
                        subtitle: "Tap four times quickly.\nRepeat 3 times to master your rhythm.",
                        collected: collector.quadKnocks.count,
                        required: 3
                    )
                } else if step == 4 {
                    testStepView
                }
            }
            .padding(DroppySpacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            // Footer
            HStack {
                if step == 4 {
                    Button("Retest") {
                        collector.reset()
                        step = 1
                        collector.setStep(1)
                        detector.overrideThreshold = 0.03
                    }
                    .buttonStyle(DroppyQuietButtonStyle())
                }
                
                Spacer()
                
                if step < 4 {
                    Button("Next") {
                        step += 1
                        collector.setStep(step)
                        if step == 4 {
                            applyComputedSettings()
                        }
                    }
                    .buttonStyle(DroppyAccentButtonStyle())
                    .disabled(!canAdvance)
                } else {
                    Button("Save Configuration") {
                        saveConfiguration()
                        cleanupAndDismiss()
                    }
                    .buttonStyle(DroppyAccentButtonStyle())
                }
            }
            .padding(.horizontal, DroppySpacing.xl)
            .padding(.vertical, DroppySpacing.md)
            .background(AdaptiveColors.panelBackgroundAuto)
        }
        .frame(width: 450, height: 400)
        .onAppear {
            detector.isSuppressingActions = true
            detector.overrideThreshold = 0.03
        }
        .onDisappear {
            detector.isSuppressingActions = false
            detector.overrideThreshold = nil
        }
        .onReceive(detector.$waveformData) { val in
            if step < 4 {
                collector.processWaveformSample(val)
            }
        }
    }
    
    private var canAdvance: Bool {
        if step == 1 { return collector.doubleKnocks.count >= 3 }
        if step == 2 { return collector.tripleKnocks.count >= 3 }
        if step == 3 { return collector.quadKnocks.count >= 3 }
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
                Text("Sensor Output")
                    .font(.caption)
                    .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AdaptiveColors.buttonBackgroundAuto)
                        
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AdaptiveColors.selectionBlueAuto)
                            .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(detector.waveformData))))
                            .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.7), value: detector.waveformData)
                    }
                }
                .frame(height: 16)
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
        }
    }
    
    @ViewBuilder
    private var testStepView: some View {
        VStack(spacing: DroppySpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(AdaptiveColors.selectionBlueAuto)
            
            Text("Calibration Complete")
                .font(.title2.bold())
            
            Text("Your custom profile has been generated. Try tapping now to verify that your taps are reliably recognized.")
                .multilineTextAlignment(.center)
                .foregroundStyle(AdaptiveColors.secondaryTextAuto)
            
            DropletSettingsCard {
                let computed = collector.computeSettings()
                DropletControlRow(title: "Threshold", icon: "hammer") {
                    Text(String(format: "%.2f", computed.threshold))
                        .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                }
                DropletSettingsDivider()
                DropletControlRow(title: "Window", icon: "clock") {
                    Text(String(format: "%.2f s", computed.groupingWindow))
                        .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                }
                DropletSettingsDivider()
                DropletControlRow(title: "Cooldown", icon: "hourglass") {
                    Text(String(format: "%.2f s", computed.cooldown))
                        .foregroundStyle(AdaptiveColors.secondaryTextAuto)
                }
            }
            .padding(.top, DroppySpacing.md)
        }
    }
    
    private func applyComputedSettings() {
        let computed = collector.computeSettings()
        // During step 3, actually use these settings for the user to test
        detector.overrideThreshold = computed.threshold
    }
    
    private func saveConfiguration() {
        let computed = collector.computeSettings()
        UserDefaults.standard.set(computed.threshold, forKey: "thump.accelThreshold")
        UserDefaults.standard.set(computed.groupingWindow, forKey: "thump.groupingWindow")
        UserDefaults.standard.set(computed.cooldown, forKey: "thump.cooldown")
    }
    
    private func cleanupAndDismiss() {
        detector.isSuppressingActions = false
        detector.overrideThreshold = nil
        dismiss()
    }
}
