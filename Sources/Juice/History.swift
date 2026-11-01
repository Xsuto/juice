import Foundation

struct Sample: Codable, Sendable, Equatable {
    var t: Date
    var percent: Int
    /// On AC power (charging or held at a limit). macOS's power log only records this, not "charging".
    var pluggedIn: Bool

    private enum CodingKeys: String, CodingKey {
        case t, percent
        case pluggedIn = "charging"
    }
}

/// Charge level over the last 24 hours, persisted to Application Support.
@MainActor
final class History {
    private(set) var samples: [Sample] = []
    private let url: URL
    private static let keep: TimeInterval = 24 * 3600

    init() {
        let dir = URL.applicationSupportDirectory.appending(path: "Juice", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: "history-v2.json")
        // v1 was filled from truncated power-log lines; start over and refill.
        try? FileManager.default.removeItem(at: dir.appending(path: "history.json"))
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = Self.despike(saved)
        }
    }

    func record(_ s: BatterySnapshot, at now: Date = .now) {
        let sample = Sample(t: now, percent: s.percent, pluggedIn: s.isPluggedIn)
        if let last = samples.last,
           now.timeIntervalSince(last.t) < 60,
           last.percent == sample.percent, last.pluggedIn == sample.pluggedIn {
            return
        }
        samples.append(sample)
        trimAndSave()
    }

    /// Fills the graph from macOS's power log when we don't have our own history yet.
    func backfillFromPowerLog() async {
        let cutoff = Date.now.addingTimeInterval(-Self.keep)
        let firstOwn = samples.first?.t ?? .now
        guard firstOwn.timeIntervalSince(cutoff) > 3600 else { return }

        let logged = await Task.detached(priority: .utility) { Self.parsePowerLog() }.value
        let older = logged.filter { $0.t > cutoff && $0.t < firstOwn.addingTimeInterval(-60) }
        guard !older.isEmpty else { return }
        samples = Self.despike((older + samples).sorted { $0.t < $1.t })
        trimAndSave()
    }

    private func trimAndSave() {
        let cutoff = Date.now.addingTimeInterval(-Self.keep)
        samples.removeAll { $0.t < cutoff }
        if let data = try? JSONEncoder().encode(samples) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// A single reading far from both neighbours is a glitch, not a real change in charge.
    private static func despike(_ samples: [Sample]) -> [Sample] {
        guard samples.count > 2 else { return samples }
        var out = [samples[0]]
        for i in 1..<samples.count - 1 {
            let (a, b, c) = (out.last!.percent, samples[i].percent, samples[i + 1].percent)
            if abs(b - a) > 25, abs(b - c) > 25, (b - a).signum() == (b - c).signum() { continue }
            out.append(samples[i])
        }
        out.append(samples[samples.count - 1])
        return out
    }

    /// Lines look like:
    /// `2026-11-01 11:59:13 +0100 Wake  ... Using BATT (Charge:93%)`
    /// pmset truncates long lines, so "Charge: 93" can appear as "Charge: 9" — require the closing ")".
    private nonisolated static func parsePowerLog() -> [Sample] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        let pattern = /^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}).*Using (Batt|BATT|AC)\s*\(Charge:\s*(\d+)%?\)/
        var out: [Sample] = []
        for line in text.split(separator: "\n") {
            guard let m = line.firstMatch(of: pattern),
                  let date = formatter.date(from: String(m.1)),
                  let percent = Int(m.3)
            else { continue }
            out.append(Sample(t: date, percent: percent, pluggedIn: m.2 == "AC"))
        }
        return out
    }
}
