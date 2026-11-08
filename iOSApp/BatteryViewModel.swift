import SwiftUI
import UIKit
import Combine
import WidgetKit
import Darwin

@MainActor
final class BatteryViewModel: ObservableObject {
    @Published var localDevice: DeviceBatteryInfo
    @Published var remoteDevices: [DeviceBatteryInfo] = []
    /// Batteries of Bluetooth headphones and watches that iOS already knows
    /// about. They are read through the system Bluetooth manager and then
    /// published alongside the iPhone battery.
    @Published var accessoryDevices: [DeviceBatteryInfo] = []

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true

        localDevice = DeviceBatteryInfo(
            id: BatterySharedStore.deviceID(for: .iPhone),
            deviceType: .iPhone,
            deviceName: UIDevice.current.name,
            batteryLevel: max(0, Double(UIDevice.current.batteryLevel)),
            batteryState: BatteryViewModel.mapBatteryState(UIDevice.current.batteryState)
        )

        BatterySyncManager.shared.start(localInfo: localDevice)
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

        NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshLocal() }
            .store(in: &cancellables)

        startBatteryUpdates()
    }

    private func startBatteryUpdates() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLocal() }
        }
    }

    func refreshLocal() {
        localDevice.batteryLevel = max(0, Double(UIDevice.current.batteryLevel))
        localDevice.batteryState = BatteryViewModel.mapBatteryState(UIDevice.current.batteryState)
        localDevice.timestamp = .now
        BatterySyncManager.shared.update(localInfo: localDevice)
        saveToSharedDefaults()
        WidgetCenter.shared.reloadAllTimelines()
        refreshAccessories()
    }

    private func saveToSharedDefaults() {
        BatterySharedStore.saveSharedDevices(allDevices)
    }

    private func refreshAccessories() {
        let batteryCenterDevices = BatteryCenterReader.connectedDevices()
        let managerDevices = BluetoothBatteryReader.connectedDevices()
        // Never publish an accessory without a real reading. iOS can see a
        // paired headset as connected but report 0 when it cannot read its
        // battery; publishing that zero would overwrite the Mac relay.
        let devices = BatterySharedStore
            .deduplicated(batteryCenterDevices + managerDevices)
            .filter { $0.hasBatteryReading && $0.batteryLevel > 0.001 }
        accessoryDevices = devices
        print("BatteryWidget accessories:", devices.map { "\($0.deviceName)=\($0.levelPercent)% (\($0.id))" })

        for device in devices {
            _ = BatterySharedStore.publishCloud(device)
        }

        BatterySyncManager.shared.refreshCloud()
        saveToSharedDefaults()
        WidgetCenter.shared.reloadAllTimelines()
    }

    var allDevices: [DeviceBatteryInfo] {
        BatterySharedStore.deduplicated([localDevice] + accessoryDevices + remoteDevices)
    }

    private static func mapBatteryState(_ state: UIDevice.BatteryState) -> BatteryState {
        switch state {
        case .charging:    return .charging
        case .full:        return .full
        case .unplugged:   return .discharging
        default:           return .unknown
        }
    }
}

// MARK: - BatteryCenter accessory battery (iOS)

/// The system Batteries widget is backed by `BatteryCenter.framework`. Its
/// controller exposes the already-coalesced Bluetooth accessory list, which is
/// exactly what the system widget shows for headsets and watches.
private enum BatteryCenterReader {
    static func connectedDevices() -> [DeviceBatteryInfo] {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/BatteryCenter.framework/BatteryCenter",
            RTLD_NOW
        )
        let loadError = dlerror()
        print("BatteryWidget BC dlopen:", handle != nil,
              loadError.map { String(cString: $0) } ?? "no error")

        guard let controllerClass = NSClassFromString("BCBatteryDeviceController") as? NSObject.Type else {
            print("BatteryWidget BC controller class missing")
            return []
        }

        let controller: NSObject?
        if controllerClass.responds(to: NSSelectorFromString("_sharedPowerSourceController")),
           let result = controllerClass.perform(NSSelectorFromString("_sharedPowerSourceController")),
           let shared = result.takeUnretainedValue() as? NSObject {
            controller = shared
        } else if let allocated = controllerClass.perform(NSSelectorFromString("alloc"))?
            .takeUnretainedValue() as? NSObject,
                  let initialized = allocated.perform(NSSelectorFromString("init"))?
            .takeUnretainedValue() as? NSObject {
            controller = initialized
        } else {
            controller = nil
        }

        guard let controller else {
            print("BatteryWidget BC controller unavailable")
            return []
        }
        guard controller.responds(to: NSSelectorFromString("connectedDevices")),
              let rawDevices = controller.value(forKey: "connectedDevices") as? [NSObject] else {
            print("BatteryWidget BC connectedDevices unavailable")
            return []
        }

        print("BatteryWidget BC connected count:", rawDevices.count)
        var devices: [String: DeviceBatteryInfo] = [:]

        for device in rawDevices {
            let name = stringValue(device, key: "name") ?? "?"
            let internalDevice = boolValue(device, key: "internal") ?? false
            let connected = boolValue(device, key: "connected") ?? true
            let percent = intValue(device, key: "percentCharge")
            let category = stringValue(device, key: "accessoryCategory") ?? "?"
            let transport = stringValue(device, key: "transportType") ?? "?"
            let identifier = stringValue(device, key: "identifier")
                ?? stringValue(device, key: "matchIdentifier")
                ?? name
            let charging = boolValue(device, key: "charging") ?? false

            print("BatteryWidget BC device:", name,
                  "percent:", percent as Any,
                  "category:", category,
                  "transport:", transport,
                  "connected:", connected,
                  "internal:", internalDevice,
                  "charging:", charging,
                  "id:", identifier)

            guard !internalDevice, connected, let percent, (1...100).contains(percent) else { continue }

            let lower = name.lowercased()
            let lowerCategory = category.lowercased()
            let audio = ["buds", "airpods", "headphone", "headset", "beats", "jbl", "sony", "bose"]
            let isAudio = audio.contains { lower.contains($0) }
                || lowerCategory.contains("audio")
                || lowerCategory.contains("headphone")
            let isWatch = lower.contains("watch")
                || lower.contains("band")
                || lowerCategory.contains("watch")

            guard isAudio || isWatch else { continue }

            let type: DeviceType = isWatch ? .appleWatch : .airPods
            let id = "batterycenter-" + identifier
                .lowercased()
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: " ", with: "-")

            devices[id] = DeviceBatteryInfo(
                id: id,
                deviceType: type,
                deviceName: name,
                batteryLevel: Double(percent) / 100.0,
                batteryState: charging ? .charging : .discharging,
                isBatteryReadingAvailable: true
            )
        }

        return devices.values.sorted { $0.deviceName < $1.deviceName }
    }

    private static func stringValue(_ object: NSObject, key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        if let string = object.value(forKey: key) as? String { return string }
        return nil
    }

    private static func intValue(_ object: NSObject, key: String) -> Int? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return (object.value(forKey: key) as? NSNumber)?.intValue
    }

    private static func boolValue(_ object: NSObject, key: String) -> Bool? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return (object.value(forKey: key) as? NSNumber)?.boolValue
    }
}

// MARK: - Bluetooth accessory battery (iOS)

/// The system Batteries widget reads battery levels from the private
/// `BluetoothManager` framework; public iOS Bluetooth APIs do not expose this
/// for classic headsets. The app is installed for personal use, so it reads the
/// same manager and publishes the values through the normal widget cache.
private enum BluetoothBatteryReader {
    static func connectedDevices() -> [DeviceBatteryInfo] {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager",
            RTLD_NOW
        )
        let loadError = dlerror()
        print("BatteryWidget BT dlopen:", handle != nil, loadError.map { String(cString: $0) } ?? "no error")

        guard let managerClass = NSClassFromString("BluetoothManager") as? NSObject.Type else {
            print("BatteryWidget BT manager class missing")
            return []
        }
        print("BatteryWidget BT manager class:", managerClass)

        let sharedSelector = NSSelectorFromString("sharedInstance")
        guard managerClass.responds(to: sharedSelector),
              let managerResult = managerClass.perform(sharedSelector),
              let manager = managerResult.takeUnretainedValue() as? NSObject
        else {
            print("BatteryWidget BT manager unavailable")
            return []
        }
        print("BatteryWidget BT manager:", manager)

        let connectedSelector = NSSelectorFromString("connectedDevices")
        guard manager.responds(to: connectedSelector),
              let rawDevices = manager.value(forKey: "connectedDevices") as? [NSObject]
        else {
            print("BatteryWidget BT connectedDevices unavailable")
            return []
        }
        print("BatteryWidget BT connected count:", rawDevices.count)
        for device in rawDevices {
            print("BatteryWidget BT device:", device, "name:", stringValue(device, key: "name") ?? "?",
                  "battery:", intValue(device, key: "batteryLevel") as Any,
                  "supported:", boolValue(device, key: "supportsBatteryLevel") as Any)
        }

        for key in ["pairedDevices", "available", "powered", "bluetoothState"] {
            let selector = NSSelectorFromString(key)
            guard manager.responds(to: selector) else {
                print("BatteryWidget BT manager has no \(key)")
                continue
            }
            let value = manager.value(forKey: key)
            if let list = value as? [NSObject] {
                print("BatteryWidget BT \(key) count:", list.count)
                for device in list {
                    print("BatteryWidget BT \(key) item:", stringValue(device, key: "name") ?? "?",
                          "battery:", intValue(device, key: "batteryLevel") as Any,
                          "supported:", boolValue(device, key: "supportsBatteryLevel") as Any,
                          "connected:", boolValue(device, key: "connected") as Any)
                }
            } else {
                print("BatteryWidget BT \(key):", value as Any)
            }
        }

        var devices: [String: DeviceBatteryInfo] = [:]

        for device in rawDevices {
            guard let name = stringValue(device, key: "name"), !name.isEmpty else { continue }
            guard isAccessory(name: name) else { continue }
            if let connected = boolValue(device, key: "connected"), !connected {
                continue
            }

            if let supported = boolValue(device, key: "supportsBatteryLevel"), !supported {
                continue
            }

            // A zero from BluetoothManager means “unknown” for many third-party
            // headsets, even while they are connected. It is not a valid battery
            // reading and must not overwrite the Mac relay.
            guard let level = intValue(device, key: "batteryLevel"), (1...100).contains(level) else {
                continue
            }

            let address = stringValue(device, key: "address") ?? name
            let id = "bluetooth-\(address.lowercased().replacingOccurrences(of: ":", with: "-"))"
            let lower = name.lowercased()

            let type: DeviceType
            if lower.contains("watch") {
                type = .appleWatch
            } else if lower.contains("buds") || lower.contains("airpods")
                        || lower.contains("headphone") || lower.contains("headset")
                        || lower.contains("beats") {
                type = .airPods
            } else {
                type = .other
            }

            devices[id] = DeviceBatteryInfo(
                id: id,
                deviceType: type,
                deviceName: name,
                batteryLevel: Double(level) / 100.0,
                batteryState: .discharging,
                isBatteryReadingAvailable: true
            )
        }

        return devices.values.sorted { $0.deviceName < $1.deviceName }
    }

    private static func isAccessory(name: String) -> Bool {
        let lower = name.lowercased()
        let audio = ["buds", "airpods", "headphone", "headset", "beats", "jbl", "sony", "bose"]
        let watch = ["watch", "band"]
        return audio.contains(where: { lower.contains($0) })
            || watch.contains(where: { lower.contains($0) })
    }

    private static func stringValue(_ object: NSObject, key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }

    private static func intValue(_ object: NSObject, key: String) -> Int? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return (object.value(forKey: key) as? NSNumber)?.intValue
    }

    private static func boolValue(_ object: NSObject, key: String) -> Bool? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return (object.value(forKey: key) as? NSNumber)?.boolValue
    }
}
