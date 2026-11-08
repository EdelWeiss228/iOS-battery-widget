// IOKit доступен только на macOS
#if os(macOS)
import Foundation
import IOKit.ps

// MARK: - IOKit Battery Reader
// Вынесен в Shared чтобы его видели и macOSApp и macOSWidget таргеты.
// Обёрнут в #if os(macOS) — IOKit.ps не существует на iOS.

public enum IOKitBatteryReader {
    public static func readBatteryLevel() -> Double {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for src in sources {
            if let desc = IOPSGetPowerSourceDescription(info, src)
                .takeUnretainedValue() as? [String: Any] {
                if let capacity = desc[kIOPSCurrentCapacityKey] as? Int,
                   let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    return Double(capacity) / Double(max)
                }
            }
        }
        return 1.0  // Mac mini или нет батареи → считаем полным
    }

    public static func readBatteryState() -> BatteryState {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for src in sources {
            if let desc = IOPSGetPowerSourceDescription(info, src)
                .takeUnretainedValue() as? [String: Any] {
                if let state = desc[kIOPSPowerSourceStateKey] as? String {
                    return state == kIOPSACPowerValue ? .charging : .discharging
                }
            }
        }
        return .unknown
    }
}
#endif
