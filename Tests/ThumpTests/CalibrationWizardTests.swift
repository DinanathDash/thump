import Foundation
import Testing
import SwiftUI
import DroppyKit
import DroppyKitHarness
@testable import Thump

@MainActor
@Suite("Calibration Wizard and Collector")
struct CalibrationWizardTests {
    @Test("CalibrationCollector tracks steps and resets current step trials")
    func collectorStepReset() {
        let collector = CalibrationCollector()
        collector.setStep(1)

        // Inject simulated trial
        collector.doubleTapTrials.append(CalibrationCollector.TapTrial(maxPeak: 0.05, interTapIntervals: [0.15]))
        #expect(collector.doubleTapTrials.count == 1)

        // Reset step 1
        collector.resetCurrentStep()
        #expect(collector.doubleTapTrials.isEmpty)

        // Advance to step 2 (triple taps)
        collector.setStep(2)
        collector.tripleTapTrials.append(CalibrationCollector.TapTrial(maxPeak: 0.06, interTapIntervals: [0.14, 0.14]))
        #expect(collector.tripleTapTrials.count == 1)

        collector.resetCurrentStep()
        #expect(collector.tripleTapTrials.isEmpty)

        // Advance to step 3 (quad taps)
        collector.setStep(3)
        collector.quadTapTrials.append(CalibrationCollector.TapTrial(maxPeak: 0.07, interTapIntervals: [0.12, 0.12, 0.12]))
        #expect(collector.quadTapTrials.count == 1)

        collector.resetCurrentStep()
        #expect(collector.quadTapTrials.isEmpty)
    }

    @Test("CalibrationCollector computes calibrated settings within safe limits")
    func computeSettingsLimits() {
        let collector = CalibrationCollector()

        // 1. Empty trials yield sensible baseline defaults
        let defaultSettings = collector.computeSettings()
        #expect(defaultSettings.threshold >= 0.015 && defaultSettings.threshold <= 0.075)
        #expect(defaultSettings.groupingWindow >= 0.60 && defaultSettings.groupingWindow <= 0.85)
        #expect(defaultSettings.cooldown >= 0.055 && defaultSettings.cooldown <= 0.090)

        // 2. Add realistic empirical trials
        collector.doubleTapTrials.append(CalibrationCollector.TapTrial(maxPeak: 0.045, interTapIntervals: [0.13]))
        collector.tripleTapTrials.append(CalibrationCollector.TapTrial(maxPeak: 0.050, interTapIntervals: [0.12, 0.14]))
        collector.quadTapTrials.append(CalibrationCollector.TapTrial(maxPeak: 0.055, interTapIntervals: [0.11, 0.12, 0.13]))

        let computed = collector.computeSettings()
        #expect(computed.threshold > 0.015)
        #expect(computed.threshold < 0.075)
        #expect(computed.groupingWindow >= 0.60)
        #expect(computed.cooldown >= 0.055)
    }

    @Test("CalibrationCollector reset clears all phases and active history")
    func collectorResetAll() {
        let collector = CalibrationCollector()
        collector.doubleTapTrials.append(CalibrationCollector.TapTrial(maxPeak: 0.04, interTapIntervals: [0.15]))
        collector.tripleTapTrials.append(CalibrationCollector.TapTrial(maxPeak: 0.05, interTapIntervals: [0.15, 0.15]))
        collector.quadTapTrials.append(CalibrationCollector.TapTrial(maxPeak: 0.06, interTapIntervals: [0.15, 0.15, 0.15]))

        collector.reset()

        #expect(collector.doubleTapTrials.isEmpty)
        #expect(collector.tripleTapTrials.isEmpty)
        #expect(collector.quadTapTrials.isEmpty)
    }

    @Test("ThumpWaveformView initializes with values and threshold")
    func waveformViewCreation() {
        let view = ThumpWaveformView(
            values: [0.01, 0.02, 0.08, 0.04, 0.01],
            threshold: 0.03
        )
        #expect(view != nil)
    }

    @Test("Calibration Wizard page can be instantiated with detector")
    func wizardInstantiation() {
        let host = makeHarnessHost()
        let runner = ThumpActionRunner(host: host)
        let detector = ThumpDetector(host: host, actionRunner: runner)

        let wizard = ThumpCalibrationWizard(detector: detector)
        #expect(wizard != nil)
    }
}
