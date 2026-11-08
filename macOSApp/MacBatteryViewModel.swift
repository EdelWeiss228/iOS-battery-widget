import Foundation
import AppKit
import IOKit.ps
import Combine
import WidgetKit
import IOBluetooth
import ObjectiveC.runtime

@MainActor
final class MacBatteryViewModel: ObservableObject {
    @Published var local: DeviceBatteryInfo
    @Published var remoteDevices: [DeviceBatteryInfo] = []
    /// Headphones connected to this Mac. The system Bluetooth reporter knows
    /// their battery even when the headset uses a proprietary protocol; the
    /// reading is mirrored to the cloud so the iPhone widget can show it too.
    @Published var accessoryDevices: [DeviceBatteryInfo] = []

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var accessoryRefreshInFlight = false
    private var accessoryRefreshStartedAt: Date?
    private var accessoryRefreshGeneration = 0
    /// Menu-bar apps are eligible for App Nap. Without this token macOS can
    /// suspend the refresh timer after the app has been idle for a while,
    /// leaving yesterday's iPhone/accessory values in the widget.
    private var activityToken: NSObjectProtocol?

    init() {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep,
                      .suddenTerminationDisabled,
                      .automaticTerminationDisabled],
            reason: "Keep BatteryWidget device and accessory values fresh"
        )

        local = DeviceBatteryInfo(
            id: BatterySharedStore.deviceID(for: .mac),
            deviceType: .mac,
            deviceName: Host.current().localizedName ?? "Mac",
            batteryLevel: MacBatteryViewModel.readBatteryLevel(),
            batteryState: MacBatteryViewModel.readBatteryState()
        )

        BatterySyncManager.shared.start(localInfo: local)
        saveToSharedDefaults()
        refreshAccessories()

        BatterySyncManager.shared.$remoteDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                self?.remoteDevices = devices
                self?.saveToSharedDefaults()
                WidgetCenter.shared.reloadAllTimelines()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        startTimer()
    }

    var allDevices: [DeviceBatteryInfo] {
        // The Mac is the only device that can read its Bluetooth accessories.
        // Do not keep an accessory from the cloud in the Mac widget after it
        // has disconnected: only currently reported accessories are valid here.
        let connectedAccessoryIDs = Set(accessoryDevices.map(\.id))
        let visibleRemoteDevices = remoteDevices.filter { device in
            switch device.deviceType {
            case .mac, .iPhone:
                return true
            case .airPods, .appleWatch, .other:
                // Ignore an invalid cloud zero while this Mac has a real
                // reading for the same accessory.
                return connectedAccessoryIDs.contains(device.id)
                    && device.hasBatteryReading
                    && device.batteryLevel > 0.001
            }
        }

        return BatterySharedStore.deduplicated(
            [local] + accessoryDevices + visibleRemoteDevices
        )
    }

    /// The menu bar icon represents this Mac. The ring panel separately shows
    /// the iPhone and headphones.
    var primaryDevice: DeviceBatteryInfo {
        local
    }

    // Иконка для menu bar (100, 75, 50, 25, 0)
    var batteryIcon: Int {
        let lvl = primaryDevice.batteryLevel
        if lvl > 0.88 { return 100 }
        if lvl > 0.63 { return 75 }
        if lvl > 0.38 { return 50 }
        if lvl > 0.13 { return 25 }
        return 0
    }

    func refresh() {
        local.batteryLevel = MacBatteryViewModel.readBatteryLevel()
        local.batteryState = MacBatteryViewModel.readBatteryState()
        local.timestamp    = .now
        BatterySyncManager.shared.update(localInfo: local)
        saveToSharedDefaults()
        WidgetCenter.shared.reloadAllTimelines()
        refreshAccessories()
    }

    private func saveToSharedDefaults() {
        BatterySharedStore.saveSharedDevices(allDevices)
    }

    /// Reading `system_profiler` can take a moment, so it runs off the main
    /// actor. The macOS app is intentionally not sandboxed: inside App Sandbox
    /// the Bluetooth reporter returns an empty controller, and there is no
    /// public IOBluetooth battery API.
    private func refreshAccessories() {
        // If a previous system_profiler/IOBluetooth call got stuck while the
        // Mac slept, don't let one stale Task block accessory updates forever.
        if accessoryRefreshInFlight,
           let started = accessoryRefreshStartedAt,
           Date().timeIntervalSince(started) < 30 {
            return
        }

        accessoryRefreshInFlight = true
        accessoryRefreshStartedAt = .now
        accessoryRefreshGeneration += 1
        let generation = accessoryRefreshGeneration

        Task {
            let readings = await Task.detached(priority: .utility) {
                BluetoothBatteryReader.freshConnectedDevices()
            }.value

            guard self.accessoryRefreshGeneration == generation else {
                return
            }
            self.accessoryRefreshInFlight = false
            self.accessoryRefreshStartedAt = nil
            guard let readings else {
                // A probe failure is not proof that an accessory disconnected.
                // Keep the last good readings instead of publishing tombstones.
                return
            }
            self.applyAccessories(readings)
        }
    }

    private func applyAccessories(_ readings: [DeviceBatteryInfo]) {
        // Only a positive value from the Mac's Bluetooth reader is a real
        // reading. Connected-but-unreadable accessories are handled like
        // disconnected ones below.
        let devices = readings.filter {
            $0.hasBatteryReading && $0.batteryLevel > 0.001
        }
        let connectedIDs = Set(devices.map(\.id))

        // Keep the newest record for every Bluetooth ID we have ever seen. It
        // is used only to preserve the accessory's name/type in a tombstone.
        var knownByID: [String: DeviceBatteryInfo] = [:]
        let local = BatterySharedStore.loadSharedDevices()
        let cloud = BatterySharedStore.loadCloudDevices()
        for device in local + cloud
            where device.id.hasPrefix("bluetooth-") {
            if let old = knownByID[device.id], old.timestamp >= device.timestamp {
                continue
            }
            knownByID[device.id] = device
        }

        // A disconnected or unreadable Mac accessory must not leave its last
        // known percentage in the cloud. Publish an explicit “unavailable”
        // tombstone — not a fake 0 % reading — so every widget hides it.
        for (id, previous) in knownByID
            where !connectedIDs.contains(id) && previous.hasBatteryReading {
            let tombstone = DeviceBatteryInfo(
                id: id,
                deviceType: previous.deviceType,
                deviceName: previous.deviceName,
                batteryLevel: 0,
                batteryState: .unknown,
                isBatteryReadingAvailable: false
            )
            _ = BatterySharedStore.publishCloud(tombstone)
        }

        accessoryDevices = devices
        for device in devices {
            _ = BatterySharedStore.publishCloud(device)
        }

        BatterySyncManager.shared.refreshCloud()
        saveToSharedDefaults()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func startTimer() {
        let refreshTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer.tolerance = 5
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
    }

    // MARK: - IOKit Battery Reading

    static func readBatteryLevel() -> Double { IOKitBatteryReader.readBatteryLevel() }
    static func readBatteryState() -> BatteryState { IOKitBatteryReader.readBatteryState() }
}

// MARK: - Bluetooth accessory battery

/// The macOS Bluetooth stack already receives battery reports from connected
/// headsets and watches (including third-party models such as Redmi Buds and
/// CMF Watch). Public APIs do not expose that value directly, but
/// `system_profiler` does. The app is not sandboxed so this process can see the
/// Bluetooth controller.
enum BluetoothBatteryReader {
    /// A fresh process gets a fresh IOBluetooth device cache. In long-running
    /// apps the private battery properties can stay at zero until the process
    /// is restarted, so the menu-bar app asks a short-lived copy of itself for
    /// the readings. If that probe fails, the previous readings are kept; a
    /// failure is not evidence that an accessory disconnected.
    static func freshConnectedDevices() -> [DeviceBatteryInfo]? {
        if CommandLine.arguments.contains("--bluetooth-probe") {
            return connectedDevices()
        }

        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--bluetooth-probe"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)

        do {
            try process.run()
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return try JSONDecoder().decode([DeviceBatteryInfo].self, from: data)
        } catch {
            timeout.cancel()
            return nil
        }
    }

    static func connectedDevices() -> [DeviceBatteryInfo] {
        // `system_profiler` is the same source the system Batteries widget
        // uses on macOS. The private IOBluetooth getters are a fast fallback for
        // headsets that don't make it into the profiler output.
        var merged: [String: DeviceBatteryInfo] = [:]
        let profilerData = runSystemProfiler()
        let profiled = profilerData.map(parse) ?? []
        for device in profiled {
            merged[device.id] = device
        }
        let direct = directDevices()
        for device in direct {
            if let existing = merged[device.id], existing.batteryLevel > 0 {
                continue
            }
            merged[device.id] = device
        }

        return merged.values.sorted { $0.deviceName < $1.deviceName }
    }

    /// Split out so it can be exercised with a saved `system_profiler` sample
    /// without opening a Bluetooth connection.
    static func parse(_ data: Data) -> [DeviceBatteryInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var devices: [String: DeviceBatteryInfo] = [:]

        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }

            for entry in connected {
                for (name, value) in entry {
                    guard let details = value as? [String: Any] else { continue }
                    guard isAccessory(name: name, details: details) else { continue }

                    guard let battery = batteryPercent(from: details) else {
                        // Connected but no usable battery reading. Do not turn
                        // this into a fake 0 % record.
                        continue
                    }

                    let address = (details["device_address"] as? String ?? name)
                        .lowercased()
                        .replacingOccurrences(of: ":", with: "-")
                    let id = "bluetooth-\(address)"

                    devices[id] = DeviceBatteryInfo(
                        id: id,
                        deviceType: deviceType(name: name, details: details),
                        deviceName: name,
                        batteryLevel: Double(battery) / 100.0,
                        batteryState: .discharging,
                        isBatteryReadingAvailable: true
                    )
                }
            }
        }

        return devices.values.sorted { $0.deviceName < $1.deviceName }
    }

    /// Private `IOBluetoothDevice` properties are populated when a headset is
    /// connected to this Mac. They are used only as a fallback for the
    /// system-profiler path; the personal (non-App-Store) build is allowed to
    /// read them.
    private static func directDevices() -> [DeviceBatteryInfo] {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        var devices: [String: DeviceBatteryInfo] = [:]
        for device in paired {
            guard device.isConnected() else { continue }
            let name = (device.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "Bluetooth device"

            guard isHeadset(device) || isAccessory(name: name, details: [:]),
                  let battery = directBatteryPercent(from: device)
            else { continue }

            let address = (device.addressString ?? name)
                .lowercased()
                .replacingOccurrences(of: ":", with: "-")
            let id = "bluetooth-\(address)"

            devices[id] = DeviceBatteryInfo(
                id: id,
                deviceType: deviceType(name: name, details: [:]),
                deviceName: name,
                batteryLevel: Double(battery) / 100.0,
                batteryState: .discharging,
                isBatteryReadingAvailable: true
            )
        }

        return devices.values.sorted { $0.deviceName < $1.deviceName }
    }

    private static func directBatteryPercent(from device: IOBluetoothDevice) -> Int? {
        if let combined = validPercent(byteValue(device, "batteryPercentCombined")) {
            return combined
        }
        if let single = validPercent(byteValue(device, "batteryPercentSingle")) {
            return single
        }

        let left = validPercent(byteValue(device, "batteryPercentLeft"))
        let right = validPercent(byteValue(device, "batteryPercentRight"))
        if let left, let right {
            return Int((Double(left + right) / 2.0).rounded())
        }
        if let single = left ?? right {
            return single
        }

        if let caseLevel = validPercent(byteValue(device, "batteryPercentCase")) {
            return caseLevel
        }

        // Some headsets only expose the HFP 0–5 battery indicator. Convert it
        // to the same 0–100 scale as the other readings.
        if let headset = longValue(device, "headsetBattery") {
            if (6...100).contains(headset) { return Int(headset) }
            // 0 is the “unknown” value of the HFP indicator; it must not be
            // mistaken for a real 0 % battery.
            if (1...5).contains(headset) { return Int(headset) * 20 }
        }

        return nil
    }

    private static func validPercent(_ value: Int?) -> Int? {
        guard let value, value > 0, (0...100).contains(value) else { return nil }
        return value
    }

    private static func isHeadset(_ device: IOBluetoothDevice) -> Bool {
        boolValue(device, "isHeadsetDevice") || boolValue(device, "isHeadsetAudioGateway")
    }

    private typealias ByteGetter = @convention(c) (AnyObject, Selector) -> UInt8
    private typealias LongGetter = @convention(c) (AnyObject, Selector) -> Int64
    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool

    private static func byteValue(_ object: NSObject, _ name: String) -> Int? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector)
        else { return nil }
        let getter = unsafeBitCast(method_getImplementation(method), to: ByteGetter.self)
        return Int(getter(object, selector))
    }

    private static func longValue(_ object: NSObject, _ name: String) -> Int64? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector)
        else { return nil }
        let getter = unsafeBitCast(method_getImplementation(method), to: LongGetter.self)
        return getter(object, selector)
    }

    private static func boolValue(_ object: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector)
        else { return false }
        let getter = unsafeBitCast(method_getImplementation(method), to: BoolGetter.self)
        return getter(object, selector)
    }

    private static func isAccessory(name: String, details: [String: Any]) -> Bool {
        let minor = (details["device_minorType"] as? String ?? "").lowercased()
        let minorMarkers = [
            "headset", "headphone", "handsfree", "wearable", "watch", "band", "audio"
        ]
        if minorMarkers.contains(where: { minor.contains($0) }) {
            return true
        }

        let lowerName = name.lowercased()
        let nameMarkers = [
            "buds", "airpods", "airdots", "headphone", "headset", "beats",
            "jbl", "sony", "bose", "watch", "band"
        ]
        return nameMarkers.contains { lowerName.contains($0) }
    }

    private static func deviceType(name: String, details: [String: Any]) -> DeviceType {
        let lowerName = name.lowercased()
        let minor = (details["device_minorType"] as? String ?? "").lowercased()
        if lowerName.contains("watch") || lowerName.contains("band")
            || minor.contains("watch") || minor.contains("wearable") || minor.contains("band") {
            return .appleWatch
        }
        return .airPods
    }

    /// `system_profiler` reports a separate value for the main battery, each
    /// earbud, and the charging case. Use the main value when macOS has it;
    /// otherwise average the two earbuds. The case is only a last resort,
    /// because it is usually much fuller than the earbuds themselves.
    private static func batteryPercent(from details: [String: Any]) -> Int? {
        if let main = percentValue(details["device_batteryLevelMain"])
            ?? percentValue(details["device_batteryLevelCombined"])
            ?? percentValue(details["device_batteryLevel"]) {
            return main
        }

        let left = percentValue(details["device_batteryLevelLeft"])
        let right = percentValue(details["device_batteryLevelRight"])
        if let left, let right {
            return Int((Double(left + right) / 2.0).rounded())
        }
        if let single = left ?? right {
            return single
        }

        return percentValue(details["device_batteryLevelCase"])
    }

    private static func percentValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return normalizedPercent(number.doubleValue)
        }

        guard let string = value as? String else { return nil }
        let numeric = string.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard let number = Double(numeric) else { return nil }
        return normalizedPercent(number)
    }

    private static func normalizedPercent(_ raw: Double) -> Int? {
        var value = raw
        // A few reporters expose a fraction (0.85) instead of a percentage
        // (85). Keep 0 and 1 as whole percentages, because a real 1 % value is
        // more likely than a 1 % report being encoded as 1.0.
        if value > 0, value < 1 {
            value *= 100
        }

        let rounded = Int(value.rounded())
        // 0 from a connected accessory means “unknown” on this path. A real
        // empty battery is not useful in the widget either, so reject it here
        // rather than persisting a misleading record.
        guard (1...100).contains(rounded) else { return nil }
        return rounded
    }

    private static func runSystemProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "full"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)

        do {
            try process.run()
            process.waitUntilExit()
            timeout.cancel()
            guard process.terminationStatus == 0 else { return nil }
            return output.fileHandleForReading.readDataToEndOfFile()
        } catch {
            timeout.cancel()
            return nil
        }
    }
}
