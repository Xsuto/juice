import AppKit
import SwiftUI

/// The whole type scale. Four sizes, each a clear step from the next:
/// display (the time), body (the sentence under it), section (energy, health), caption (graph labels).
enum JuiceType {
    static let display = Font.system(size: 48, weight: .heavy).width(.expanded)
    static let displayUnit = Font.system(size: 24, weight: .semibold)
    static let body = Font.system(size: 14)
    static let section = Font.system(size: 12)
    static let caption = Font.system(size: 11)
}

struct PopoverView: View {
    let model: BatteryModel

    @State private var progress = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var s: BatterySnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
                .padding(.horizontal, 20)
                .padding(.top, 24)

            RunwayChart(
                samples: model.samples, now: model.now, percent: s.percent, pluggedIn: s.isPluggedIn,
                projection: projection, progress: progress
            )
            .frame(height: 128)
            .padding(.top, 16)
            .padding(.trailing, 20)

            if !model.hungryApps.isEmpty {
                Divider().padding(.top, 12)
                energy
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }

            Divider().padding(.top, model.hungryApps.isEmpty ? 12 : 0)
            health
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .frame(width: 296)
        .onChange(of: model.openCount) { replayProjection() }
        .task { replayProjection() }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let minutes = s.isCharging ? s.minutesToFull : (s.isPluggedIn ? nil : s.minutesToEmpty) {
                Duration(minutes: minutes)
            } else {
                Text("\(s.percent)%")
                    .font(JuiceType.display)
                    .monospacedDigit()
            }
            Text(lede)
                .font(JuiceType.body)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One sentence under the big number. Only the percentage and the clock time are emphasised;
    /// the wattage explains them, so it stays in the sentence's own weight.
    private var lede: AttributedString {
        let watts = s.watts.map { "\($0.formatted(.number.precision(.fractionLength(1)))) W" } ?? "an unknown amount"
        let percent = "\(s.percent)%"
        func bold(_ string: String) -> AttributedString {
            var a = AttributedString(string)
            a.foregroundColor = .primary
            a.font = JuiceType.body.weight(.semibold)
            return a
        }
        func plain(_ string: String) -> AttributedString { AttributedString(string) }

        // On the charger, the useful number is what it's pulling from the wall, so it's emphasised too.
        let pulling = s.chargerWatts.map { $0.formatted(.number.precision(.fractionLength(0))) + " W" }
        let charger = s.chargerRating.map { " from the \($0) W charger" } ?? ""
        func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        if s.isCharging {
            var text = bold(percent) + plain(" charged")
            if let pulling { text += plain(", pulling ") + bold(pulling) }
            text += plain(".")
            guard let projection else { return text }
            // Name the slowdown point too: charging tapers after 80%.
            if let knee = projection.kneeTime { text += plain(" 80% by ") + bold(time(knee)) + plain(",") }
            text += plain(projection.kneeTime == nil ? " Full by " : " full by ") + bold(time(projection.end.t)) + plain(".")
            return text
        }
        if s.isPluggedIn {
            guard let pulling else { return plain("Plugged in, not charging. Drawing \(watts).") }
            return plain("Plugged in, not charging. Pulling ") + bold(pulling) + plain(charger + ".")
        }
        guard let m = s.minutesToEmpty else {
            return bold(percent) + plain(" left, drawing \(watts). Working out when it runs out.")
        }
        return bold(percent) + plain(" left, drawing \(watts). Runs out around ") + bold(clock(in: m)) + plain(".")
    }

    private var projection: Projection? {
        if s.isCharging {
            return .charge(from: s.percent, now: model.now, ratePerMinute: s.chargeRatePerMinute, minutesToFull: s.minutesToFull)
        }
        if !s.isPluggedIn, let m = s.minutesToEmpty {
            return .discharge(from: s.percent, now: model.now, minutesToEmpty: m)
        }
        return nil
    }

    private func clock(in minutes: Int) -> String {
        model.now.addingTimeInterval(Double(minutes) * 60).formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Health

    /// A footnote: health changes over months, so it stays small and gray, with a thin bar for shape.
    private var health: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(s.healthPercent.map { "Battery health \($0)%" } ?? "Battery health")
                .foregroundStyle(.secondary)
            HealthMeter(fraction: Double(s.healthPercent ?? 0) / 100)
                .padding(.vertical, 8)
            Text(healthSentence)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(JuiceType.section)
        .monospacedDigit()
    }

    private var healthSentence: String {
        guard let max = s.maxCapacity, let design = s.designCapacity else {
            return "Capacity isn't available on this Mac."
        }
        var text = "Holds \(max.formatted()) of its original \(design.formatted()) mAh"
        if let cycles = s.cycleCount { text += " after \(cycles.formatted()) cycles" }
        return text + "."
    }

    // MARK: - Energy

    private var energy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Using significant energy")
                .foregroundStyle(.secondary)
            ForEach(model.hungryApps) { app in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable().frame(width: 16, height: 16)
                    Text(app.name).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(app.impact.formatted(.number.precision(.fractionLength(0))))% CPU")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help("Average over the last minute, as a share of one CPU core")
                }
            }
        }
        .font(JuiceType.section)
    }

    // MARK: - Motion

    /// The one animation: the projection draws out from "now" each time the popover opens.
    private func replayProjection() {
        guard !reduceMotion else {
            progress = 1
            return
        }
        progress = 0
        withAnimation(.timingCurve(0.3, 0.7, 0.2, 1, duration: 1.1).delay(0.25)) { progress = 1 }
    }
}

/// "7h 12m" with heavy expanded digits and lighter, normal-width units.
private struct Duration: View {
    let minutes: Int
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            digits("\(minutes / 60)")
            unit("h")
            digits(String(format: "%d", minutes % 60))
            unit("m")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(minutes / 60) hours \(minutes % 60) minutes")
    }
    private func digits(_ s: String) -> some View {
        Text(s).font(JuiceType.display).monospacedDigit()
            .tracking(-1)
    }
    // Units stay normal width and lighter, so only the digits carry the weight.
    private func unit(_ s: String) -> some View {
        Text(s).font(JuiceType.displayUnit)
            .foregroundStyle(.secondary)
            .padding(.leading, 3).padding(.trailing, 8)
    }
}

/// Thin capacity bar with a tick at 80%, Apple's replacement threshold.
private struct HealthMeter: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.07))
                Capsule().fill(.secondary).frame(width: geo.size.width * min(1, fraction))
                Rectangle().fill(.tertiary)
                    .frame(width: 1, height: 8)
                    .offset(x: geo.size.width * 0.8)
            }
        }
        .frame(height: 4)
        .help("The tick marks 80%, Apple's threshold for a replacement")
        .accessibilityHidden(true)
    }
}
