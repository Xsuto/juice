import Darwin
import Foundation

struct AppEnergy: Identifiable, Sendable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    /// Activity Monitor's "Energy Impact" score, averaged over the window.
    let impact: Double
}

/// Approximates macOS's "Using Significant Energy" list.
///
/// Energy Impact is a weighted sum of CPU time and wake-ups, using the constants in
/// /usr/share/pmenergy (on Apple Silicon, default.plist: 1 per CPU-second, 0.0002 per wake-up),
/// which makes it essentially "% of one core". Helper processes are grouped into their app,
/// and the score is averaged over the last minute so a brief spike doesn't count.
/// Apps with no running processes are dropped immediately, whatever their recent average.
actor EnergySampler {
    static let threshold = 10.0
    private static let window: TimeInterval = 60
    private static let wakeupCost = 0.0002

    private var lastCost: [pid_t: Double] = [:]
    private var lastTime: ContinuousClock.Instant?
    private var history: [(seconds: Double, perApp: [String: Double])] = []
    private let nsPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    func sample() -> [AppEnergy] {
        let now = ContinuousClock.now
        var costs: [pid_t: Double] = [:]
        var perApp: [String: Double] = [:]
        var running: Set<String> = []

        for pid in Self.allPIDs() {
            guard let c = cost(of: pid) else { continue }
            costs[pid] = c
            guard let app = Self.appBundle(for: pid) else { continue }
            running.insert(app)
            guard let previous = lastCost[pid], c >= previous else { continue }
            perApp[app, default: 0] += c - previous
        }

        defer { lastCost = costs; lastTime = now }
        guard let lastTime else { return [] }
        history.append(((now - lastTime) / .seconds(1), perApp))
        while history.dropFirst().reduce(0, { $0 + $1.seconds }) >= Self.window { history.removeFirst() }

        let seconds = history.reduce(0) { $0 + $1.seconds }
        guard seconds > 0 else { return [] }
        var total: [String: Double] = [:]
        for entry in history {
            for (app, c) in entry.perApp where running.contains(app) { total[app, default: 0] += c }
        }

        return total
            .map { path, c in
                AppEnergy(path: path,
                          name: URL(filePath: path).deletingPathExtension().lastPathComponent,
                          impact: c / seconds * 100)
            }
            .filter { $0.impact >= Self.threshold }
            .sorted { $0.impact > $1.impact }
            .prefix(3)
            .map { $0 }
    }

    /// Cumulative cost in CPU-seconds. Works for our own user's processes without root.
    private func cost(of pid: pid_t) -> Double? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard result == 0 else { return nil }
        // CPU times are in Mach ticks on Apple Silicon, not nanoseconds.
        let cpu = Double(info.ri_user_time + info.ri_system_time) * nsPerTick / 1e9
        let wakeups = Double(info.ri_pkg_idle_wkups + info.ri_interrupt_wkups)
        return cpu + wakeups * Self.wakeupCost
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(0, filled))))
    }

    /// Maps helper processes (e.g. "Brave Browser Helper (Renderer)") to their outermost .app.
    private static func appBundle(for pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"),
              let range = path.range(of: ".app/")
        else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}
