import Foundation
import IOKit.ps
import Observation

@MainActor
@Observable
final class BatteryModel {
    private(set) var snapshot = BatterySnapshot()
    private(set) var samples: [Sample] = []
    private(set) var hungryApps: [AppEnergy] = []
    /// The moment of the last refresh. Views use this instead of Date.now so redraws don't change the graph.
    private(set) var now = Date.now
    /// Bumped each time the popover opens, so the view can replay its one animation.
    private(set) var openCount = 0

    @ObservationIgnored var onChange: (() -> Void)?
    /// Called when the energy list changes, so the panel can resize to fit.
    @ObservationIgnored var onEnergyChange: (() -> Void)?
    @ObservationIgnored private let history = History()
    @ObservationIgnored private let sampler = EnergySampler()
    @ObservationIgnored private var timer: Timer?
    /// Faster energy sampling while the panel is on screen.
    @ObservationIgnored private var openTimer: Timer?
    @ObservationIgnored private var powerSource: CFRunLoopSource?

    init() {
        samples = history.samples
        refresh()
        observePowerSource()

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 5

        Task {
            await history.backfillFromPowerLog()
            samples = history.samples
            _ = await sampler.sample()  // baseline for the first energy delta
        }
    }

    func popoverDidOpen() {
        openCount += 1
        refresh()
        sampleEnergy()
        openTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleEnergy() }
        }
    }

    func popoverDidClose() {
        openTimer?.invalidate()
        openTimer = nil
    }

    private func tick() {
        refresh()
        sampleEnergy()
    }

    private func sampleEnergy() {
        Task {
            let apps = await sampler.sample()
            guard apps != hungryApps else { return }
            let rowsChanged = apps.map(\.id) != hungryApps.map(\.id)
            hungryApps = apps
            if rowsChanged { onEnergyChange?() }
        }
    }

    func refresh() {
        let s = BatteryReader.read()
        now = .now
        if s != snapshot { snapshot = s }
        history.record(s)
        if history.samples != samples { samples = history.samples }
        onChange?()
    }

    private func observePowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let model = Unmanaged<BatteryModel>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { model.refresh() }
        }, context)?.takeRetainedValue() else { return }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }
}
