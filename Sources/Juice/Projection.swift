import Foundation

/// A predicted path for the charge level, drawn dashed after "now".
struct Projection: Equatable {
    struct Point: Equatable {
        var t: Date
        var percent: Double
    }

    var points: [Point]
    /// When charging crosses 80% and slows down. nil when discharging or already past it.
    var kneeTime: Date?

    var end: Point { points[points.count - 1] }

    /// Percent at a time on the path, interpolating between points.
    func percent(at date: Date) -> Double? {
        guard let first = points.first, date >= first.t, date <= end.t else { return nil }
        for (a, b) in zip(points, points.dropFirst()) where date <= b.t {
            let span = b.t.timeIntervalSince(a.t)
            let f = span > 0 ? date.timeIntervalSince(a.t) / span : 1
            return a.percent + (b.percent - a.percent) * f
        }
        return end.percent
    }

    /// The path cut off at a fraction of its duration, for the draw-on animation.
    func truncated(_ progress: Double) -> [Point] {
        guard let first = points.first, progress < 1 else { return points }
        let cutoff = first.t.addingTimeInterval(end.t.timeIntervalSince(first.t) * max(0, progress))
        var out = points.filter { $0.t < cutoff }
        if let p = percent(at: cutoff) { out.append(Point(t: cutoff, percent: p)) }
        return out
    }

    // MARK: - Models

    /// Straight line to empty at macOS's estimate.
    static func discharge(from percent: Int, now: Date, minutesToEmpty: Int) -> Projection {
        Projection(points: [Point(t: now, percent: Double(percent)),
                            Point(t: now.addingTimeInterval(Double(minutesToEmpty) * 60), percent: 0)])
    }

    static let knee = 80.0

    /// Lithium-ion charging: constant current (fast, roughly linear) up to ~80%,
    /// then constant voltage, where current tapers and each percent takes longer.
    ///
    /// - The fast phase uses the measured rate: power going into the battery over its capacity.
    /// - The taper is exponential, timed to end at macOS's own time-to-full, since the battery
    ///   gauge knows its taper better than we do. Without that estimate, the taper continues
    ///   smoothly from the fast phase's rate.
    static func charge(from percent: Int, now: Date, ratePerMinute: Double?, minutesToFull: Int?) -> Projection? {
        let p0 = Double(percent)
        let apple = minutesToFull.map(Double.init)

        // Without a measured rate, assume the fast phase takes ~40% of Apple's total.
        guard let rate = ratePerMinute ?? apple.map({ max(0.05, (knee - p0) / ($0 * 0.4)) }), rate > 0 else { return nil }

        let fastMinutes = p0 < knee ? (knee - p0) / rate : 0
        let taperStart = max(p0, knee)
        let gap = 100 - taperStart            // percent still to go in the taper
        let target = 1.0                      // the taper "finishes" when 1% is left
        let taperMinutes: Double
        if let apple, apple > fastMinutes + 1 {
            taperMinutes = apple - fastMinutes
        } else {
            // Continue at the fast rate's slope: dp/dt = k·(100 − p), so k = rate / gap.
            taperMinutes = log(gap / target) / (rate / gap)
        }
        let k = log(gap / target) / taperMinutes

        var points = [Point(t: now, percent: p0)]
        let kneeTime = now.addingTimeInterval(fastMinutes * 60)
        if fastMinutes > 0 { points.append(Point(t: kneeTime, percent: knee)) }
        let steps = 24
        for i in 1...steps {
            let minutes = taperMinutes * Double(i) / Double(steps)
            let p = i == steps ? 100 : 100 - gap * exp(-k * minutes)
            points.append(Point(t: kneeTime.addingTimeInterval(minutes * 60), percent: p))
        }
        return Projection(points: points, kneeTime: fastMinutes > 0 ? kneeTime : nil)
    }
}
