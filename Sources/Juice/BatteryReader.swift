import Foundation
import IOKit
import IOKit.ps

struct BatterySnapshot: Sendable, Equatable {
    var percent = 0
    var isCharging = false
    var isPluggedIn = false
    /// macOS's own smoothed estimate. nil while it's still calculating or when plugged in.
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    /// Whole-system power draw in watts.
    var watts: Double?
    /// What the Mac is pulling from the charger, in watts (system use plus charging). nil on battery.
    var chargerWatts: Double?
    /// The connected charger's rating, e.g. 67 for a 67 W adapter.
    var chargerRating: Int?
    var voltage: Double?
    var cycleCount: Int?
    var designCapacity: Int?
    var maxCapacity: Int?

    /// How fast the battery is filling, in percent per minute: power going into the battery
    /// (charger input minus what the Mac uses, less ~8% conversion loss) over its capacity in Wh.
    var chargeRatePerMinute: Double? {
        guard isCharging, let chargerWatts, let watts, let voltage, let maxCapacity, maxCapacity > 0 else { return nil }
        let intoBattery = (chargerWatts - watts) * 0.92
        guard intoBattery > 0.5 else { return nil }
        let wattHours = Double(maxCapacity) * voltage / 1000
        return intoBattery / wattHours * 100 / 60
    }

    var healthPercent: Int? {
        guard let designCapacity, let maxCapacity, designCapacity > 0 else { return nil }
        return Int((Double(maxCapacity) / Double(designCapacity) * 100).rounded(.down))
    }
}

enum BatteryReader {
    static func read() -> BatterySnapshot {
        var s = BatterySnapshot()
        readPowerSources(into: &s)
        readSmartBattery(into: &s)
        return s
    }

    /// Public IOPowerSources API: percent, charging state and macOS's time estimates.
    private static func readPowerSources(into s: inout BatterySnapshot) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            s.percent = max > 0 ? current * 100 / max : current
            s.isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
            s.isPluggedIn = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            if s.isCharging, let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0 {
                s.minutesToFull = t
            }
        }

        let estimate = IOPSGetTimeRemainingEstimate()
        if estimate > 0 { s.minutesToEmpty = Int(estimate / 60) }
    }

    /// The battery driver's IOKit registry entry: capacities, cycles and power telemetry.
    private static func readSmartBattery(into s: inout BatterySnapshot) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else { return }

        s.cycleCount = int(dict["CycleCount"])
        if let mV = int(dict["Voltage"]), mV > 0 { s.voltage = Double(mV) / 1000 }

        // Recent macOS versions moved the mAh values into the nested BatteryData dictionary.
        let batteryData = dict["BatteryData"] as? [String: Any] ?? [:]
        s.designCapacity = int(batteryData["DesignCapacity"]) ?? int(dict["DesignCapacity"])
        s.maxCapacity = int(batteryData["NominalChargeCapacity"]) ?? int(dict["NominalChargeCapacity"]) ?? int(dict["AppleRawMaxCapacity"])

        // SystemLoad is the whole Mac's draw in mW; on AC, SystemPowerIn is what the adapter delivers.
        let telemetry = dict["PowerTelemetryData"] as? [String: Any] ?? [:]
        if let powerIn = int(telemetry["SystemPowerIn"]), powerIn > 0, s.isPluggedIn {
            s.chargerWatts = Double(powerIn) / 1000
        }
        if let adapter = dict["AdapterDetails"] as? [String: Any], let rating = int(adapter["Watts"]), rating > 0, s.isPluggedIn {
            s.chargerRating = rating
        }
        if let load = int(telemetry["SystemLoad"]), load > 0 {
            s.watts = Double(load) / 1000
        } else if let mV = int(dict["Voltage"]), let mA = int(dict["Amperage"]) {
            s.watts = abs(Double(mV) * Double(mA)) / 1_000_000
        }
    }

    /// Registry numbers are 64-bit; signed values like Amperage are stored as their unsigned bit pattern.
    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber).map { Int($0.int64Value) }
    }
}
