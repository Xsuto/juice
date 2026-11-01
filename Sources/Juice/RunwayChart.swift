import Charts
import SwiftUI

/// The past 12 hours drawn solid, then a dashed projection from now to empty (or to full while charging).
/// Labels are placed by hand rather than with chart annotations, so they never drift or clip.
struct RunwayChart: View {
    let now: Date
    let percent: Int
    /// Predicted path after now: straight to empty, or curved to full while charging. nil if unknown.
    let projection: Projection?
    /// 0…1, animates the projection drawing out from "now".
    let progress: Double

    // Derived once per update rather than on every access.
    private let start: Date
    private let end: Date
    private let past: [Sample]
    private let pluggedRuns: [(Date, Date)]

    init(samples: [Sample], now: Date, percent: Int, pluggedIn: Bool,
         projection: Projection?, progress: Double) {
        self.now = now
        self.percent = percent
        self.projection = projection
        self.progress = progress
        start = now.addingTimeInterval(-12 * 3600)
        end = min(max(projection?.end.t ?? now, now.addingTimeInterval(3600)), now.addingTimeInterval(12 * 3600))
        let start = start
        past = samples.filter { $0.t >= start } + [Sample(t: now, percent: percent, pluggedIn: pluggedIn)]
        pluggedRuns = Self.runs(in: past)
    }

    @State private var hover: HoverPoint?

    private struct HoverPoint: Equatable {
        var date: Date
        var percent: Double
        var pluggedIn: Bool
        var projected: Bool
    }

    private static let ink = Color.primary
    private static let topRoom: CGFloat = 26   // space above 100% for the "now" and hover labels
    private static let axisHeight: CGFloat = 18

    private var projectedPath: [Projection.Point] { projection?.truncated(progress) ?? [] }

    var body: some View {
        VStack(spacing: 4) {
            chart
            axis.frame(height: Self.axisHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            ForEach(pluggedRuns, id: \.0) { run in
                RectangleMark(xStart: .value("t", run.0), xEnd: .value("t", run.1),
                              yStart: .value("p", 0), yEnd: .value("p", 100))
                    .foregroundStyle(Color.green.opacity(0.16))
            }

            ForEach(past, id: \.t) { s in
                AreaMark(x: .value("t", s.t), y: .value("p", s.percent), series: .value("s", "past"))
                    .foregroundStyle(.linearGradient(colors: [Self.ink.opacity(0.10), Self.ink.opacity(0)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", s.t), y: .value("p", s.percent), series: .value("s", "past"))
                    .foregroundStyle(Self.ink)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            ForEach(projectedPath, id: \.t) { p in
                LineMark(x: .value("t", p.t), y: .value("p", p.percent), series: .value("s", "projection"))
                    .foregroundStyle(Self.ink.opacity(0.42))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 5]))
                    .interpolationMethod(.monotone)
            }
            if progress >= 1, let e = projection?.end {
                PointMark(x: .value("t", e.t), y: .value("p", e.percent))
                    .symbol {
                        Circle().fill(.background)
                            .overlay(Circle().strokeBorder(Self.ink.opacity(0.6), lineWidth: 1.5))
                            .frame(width: 8, height: 8)
                    }
            }

            RuleMark(x: .value("t", now), yStart: .value("p", 0), yEnd: .value("p", 100))
                .foregroundStyle(Self.ink.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1))
            PointMark(x: .value("t", now), y: .value("p", percent))
                .symbol { dot(10) }

            if let hover {
                RuleMark(x: .value("t", hover.date), yStart: .value("p", 0), yEnd: .value("p", 100))
                    .foregroundStyle(Self.ink.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("t", hover.date), y: .value("p", hover.percent))
                    .symbol { dot(8) }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.padding(.top, Self.topRoom) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let plotFrame = proxy.plotFrame {
                    let plot = geo[plotFrame]
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                guard case .active(let location) = phase,
                                      let date: Date = proxy.value(atX: location.x - plot.minX)
                                else { if hover != nil { hover = nil }; return }
                                let p = point(at: date)
                                if p != hover { hover = p }
                            }

                        if let hover, let x = proxy.position(forX: hover.date) {
                            Text(hoverLabel(hover))
                                .font(JuiceType.caption.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.background, in: .capsule)
                                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                                .fixedSize()
                                .clamped(x: plot.minX + x, y: plot.minY - Self.topRoom / 2)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
    }

    private func dot(_ size: CGFloat) -> some View {
        Circle().fill(Self.ink)
            .overlay(Circle().stroke(.background, lineWidth: 2))
            .frame(width: size, height: size)
    }

    // MARK: - Axis

    /// Drawn outside the chart so the end label can sit flush right instead of being clipped.
    private var axis: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(visibleAxisDates(width: geo.size.width), id: \.self) { date in
                    Text(axisLabel(date))
                        .font(JuiceType.caption).monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .clamped(x: xPosition(date, width: geo.size.width), y: geo.size.height / 2)
                }
            }
        }
    }

    private func xPosition(_ date: Date, width: CGFloat) -> CGFloat {
        width * date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }

    /// "Now" and the end label always win; hour ticks are dropped if they'd sit within 44pt of another label.
    private func visibleAxisDates(width: CGFloat) -> [Date] {
        let all = axisDates
        var kept = all.filter { $0 == now || (projection != nil && $0 == end) }
        for date in all where !kept.contains(date) {
            let x = xPosition(date, width: width)
            if kept.allSatisfy({ abs(xPosition($0, width: width) - x) >= 44 }) { kept.append(date) }
        }
        return kept
    }

    private var axisDates: [Date] {
        let cal = Calendar.current
        var dates: [Date] = []
        // Every 4 hours on the hour.
        var t = cal.nextDate(after: start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? start
        while t < end {
            if cal.component(.hour, from: t) % 4 == 0, t.timeIntervalSince(start) > 2700 {
                dates.append(t)
            }
            t = t.addingTimeInterval(3600)
        }
        dates.append(now)
        if projection != nil { dates.append(end) }
        return dates
    }

    private func axisLabel(_ date: Date) -> String {
        date == now ? "Now" : date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Data

    /// Contiguous stretches on AC power, for the green bands.
    private static func runs(in past: [Sample]) -> [(Date, Date)] {
        var runs: [(Date, Date)] = []
        var runStart: Date?
        for (i, s) in past.enumerated() {
            if s.pluggedIn, runStart == nil { runStart = s.t }
            let next = i + 1 < past.count ? past[i + 1] : nil
            if let rs = runStart, !(next?.pluggedIn ?? false) {
                runs.append((rs, next?.t ?? s.t))
                runStart = nil
            }
        }
        return runs
    }

    private func point(at date: Date) -> HoverPoint? {
        if date <= now {
            guard let s = past.min(by: { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) }) else { return nil }
            return HoverPoint(date: s.t, percent: Double(s.percent), pluggedIn: s.pluggedIn, projected: false)
        }
        guard let p = projection?.percent(at: date) else { return nil }
        return HoverPoint(date: date, percent: p, pluggedIn: false, projected: true)
    }

    private func hoverLabel(_ h: HoverPoint) -> String {
        let time = h.date.formatted(date: .omitted, time: .shortened)
        let p = Int(h.percent.rounded())
        if h.projected { return "\(time)  about \(p)%" }
        return h.pluggedIn ? "\(time)  \(p)%, plugged in" : "\(time)  \(p)%"
    }

    private var accessibilityText: String {
        var text = "Charge over the last 12 hours, now \(percent)%."
        if let projection {
            let time = projection.end.t.formatted(date: .omitted, time: .shortened)
            text += projection.end.percent == 0 ? " Projected empty around \(time)." : " Projected full around \(time)."
        }
        return text
    }
}

private extension View {
    /// Centers the view on (x, y) within the parent, nudged so it never pokes past either edge.
    func clamped(x: CGFloat, y: CGFloat) -> some View {
        ClampedPosition(x: x, y: y) { self }
    }
}

/// A layout (not measured @State) so positioning can't feed back into another layout pass.
private struct ClampedPosition: Layout {
    let x: CGFloat, y: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let cx = min(max(x, size.width / 2), bounds.width - size.width / 2)
            view.place(at: CGPoint(x: bounds.minX + cx, y: bounds.minY + y), anchor: .center, proposal: .unspecified)
        }
    }
}
