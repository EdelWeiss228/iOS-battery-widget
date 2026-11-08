import Foundation
import Security

#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import IOKit
#endif

// MARK: - Shared persistence + iCloud Keychain transport
//
// A local (non-synchronisable) Keychain item is the fast cache shared by an
// app and its widget on the same device. The synchronizable Keychain item is
// the cross-device transport. It uses the same Apple ID / iCloud Keychain
// account as the user and is shared by the macOS app, macOS widget, iOS app
// and iOS widget through one keychain group. App Group files are kept as an
// additional fallback where the signing profile allows them.
//
// This deliberately does not require the iCloud container entitlement (which
// a free Personal Team cannot provision). The user does, of course, need
// iCloud Keychain enabled on both devices.

public enum BatterySharedStore {
    /// Keep the identifier out of Swift so a template user only has to edit
    /// `BUNDLE_ID_PREFIX` in project.yml. The Info.plist value is expanded by
    /// Xcode for every app/widget target.
    public static var appGroup: String {
        (Bundle.main.object(forInfoDictionaryKey: "BatteryAppGroup") as? String)
            ?? "group.com.example.batterywidget"
    }
    public static let devicesKey = "devices"

    /// Keychain items and widget kinds are namespaced by an explicit Info.plist
    /// value rather than by a bundle ID or the App Group. The value is derived
    /// from `BUNDLE_ID_PREFIX` in project.yml, so a template user still edits
    /// one setting, while the legacy signing flow can override that setting
    /// without rewriting Swift sources.
    private static var servicePrefix: String {
        if let prefix = Bundle.main.object(forInfoDictionaryKey: "BatteryServicePrefix") as? String,
           !prefix.isEmpty,
           !prefix.contains("$(") {
            return prefix
        }

        // Backward-compatible fallback for builds made before the explicit key.
        let group = appGroup
        if group.hasPrefix("group.") {
            return String(group.dropFirst("group.".count))
        }
        return group
    }

    private static var keychainService: String {
        servicePrefix + ".sync"
    }

    private static let keychainLabel = "Battery Widget device state"
    private static let keychainAccountPrefix = "device."
    private static let deviceIDPrefix = "batteryDeviceID."
    private static let snapshotFileName = "devices.json"

    private static var localSnapshotService: String {
        servicePrefix + ".local-snapshot"
    }

    /// WidgetKit kinds must stay stable across app updates. Older builds used
    /// the legacy prefix for the kind, not the template `com.example` value,
    /// so an already-placed widget would otherwise remain orphaned after an
    /// update.
    public static var widgetKind: String {
        servicePrefix
    }

    public static var macWidgetKind: String {
        servicePrefix + ".mac"
    }

    private static let localSnapshotAccount = "devices"

    // MARK: UserDefaults / shared snapshot

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    private static var snapshotDirectoryURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Library/Application Support/BatteryWidget", isDirectory: true)
    }

    private static var snapshotURL: URL? {
        snapshotDirectoryURL?.appendingPathComponent(snapshotFileName, isDirectory: false)
    }

    /// The snapshot is kept in a local (non-synchronisable) keychain item.
    /// App Group containers are not writable for the macOS build with a
    /// Personal Team profile, but the keychain access group is available to
    /// both the app and its widget. The file and UserDefaults copies remain as
    /// fallbacks (and work on iOS).
    public static func loadSharedDevices() -> [DeviceBatteryInfo] {
        if let data = loadLocalSnapshotData(),
           let devices = try? JSONDecoder().decode([DeviceBatteryInfo].self, from: data) {
            return devices
        }

        if let url = snapshotURL,
           let data = try? Data(contentsOf: url),
           let devices = try? JSONDecoder().decode([DeviceBatteryInfo].self, from: data) {
            return devices
        }

        // Migration / fallback for builds that only wrote UserDefaults.
        guard let data = defaults.data(forKey: devicesKey),
              let devices = try? JSONDecoder().decode([DeviceBatteryInfo].self, from: data)
        else { return [] }
        return devices
    }

    public static func saveSharedDevices(_ devices: [DeviceBatteryInfo]) {
        let compact = deduplicated(devices)
        guard let data = try? JSONEncoder().encode(compact) else { return }

        _ = saveLocalSnapshotData(data)
        if let directory = snapshotDirectoryURL, let url = snapshotURL {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
        defaults.set(data, forKey: devicesKey)
    }

    // MARK: Local keychain snapshot

    private static func loadLocalSnapshotData() -> Data? {
        guard let accessGroup = keychainAccessGroup else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: localSnapshotService,
            kSecAttrAccount as String: localSnapshotAccount,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    public static func removeLocalSnapshot() {
        if let accessGroup = keychainAccessGroup {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: localSnapshotService,
                kSecAttrAccount as String: localSnapshotAccount,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any
            ]
            SecItemDelete(query as CFDictionary)
        }

        defaults.removeObject(forKey: devicesKey)
        if let url = snapshotURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    private static func saveLocalSnapshotData(_ data: Data) -> Bool {
        guard let accessGroup = keychainAccessGroup else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: localSnapshotService,
            kSecAttrAccount as String: localSnapshotAccount,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let updates: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // MARK: Stable device identity

    /// The app and its widget extension must agree on the same local ID. A
    /// random UUID persisted in the app group was not reliable enough: an
    /// extension could read a missing value during an early launch and publish
    /// a second record for the same Mac. Hardware-derived IDs remove that race.
    public static func deviceID(for type: DeviceType) -> String {
        #if os(macOS)
        if type == .mac, let hardwareUUID = macHardwareUUID() {
            return "mac-\(hardwareUUID)"
        }
        #elseif os(iOS)
        if type == .iPhone, let vendorUUID = iphoneVendorUUID() {
            return vendorUUID
        }
        #endif

        let key = deviceIDPrefix + type.rawValue
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString
        defaults.set(value, forKey: key)
        return value
    }

    #if os(macOS)
    private static func macHardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ), let uuid = property.takeRetainedValue() as? String, !uuid.isEmpty
        else { return nil }

        return uuid
    }
    #endif

    #if os(iOS)
    private static func iphoneVendorUUID() -> String? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { iphoneVendorUUIDOnMain() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { iphoneVendorUUIDOnMain() }
        }
    }

    @MainActor
    private static func iphoneVendorUUIDOnMain() -> String? {
        UIDevice.current.identifierForVendor?.uuidString
    }
    #endif

    // MARK: Merge / deduplicate

    public static func merge(_ groups: [[DeviceBatteryInfo]]) -> [DeviceBatteryInfo] {
        deduplicated(groups.flatMap { $0 })
    }

    public static func deduplicated(_ devices: [DeviceBatteryInfo]) -> [DeviceBatteryInfo] {
        var byID: [String: DeviceBatteryInfo] = [:]
        for device in devices {
            guard !device.isExpired else { continue }
            if let old = byID[device.id], old.timestamp >= device.timestamp {
                continue
            }
            byID[device.id] = device
        }
        return byID.values.sorted {
            if $0.deviceType.widgetOrder != $1.deviceType.widgetOrder {
                return $0.deviceType.widgetOrder < $1.deviceType.widgetOrder
            }
            return $0.timestamp > $1.timestamp
        }
    }

    // MARK: iCloud Keychain

    /// Populated from the generated Info.plist. It is kept out of source code so
    /// changing the Apple Developer Team does not require a code change.
    public static var keychainAccessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "BatteryKeychainAccessGroup") as? String,
              !group.isEmpty,
              !group.contains("$(")
        else { return nil }
        return group
    }

    public static var isCloudTransportConfigured: Bool {
        keychainAccessGroup != nil
    }

    /// Removes all synchronisable records for this app from the shared
    /// keychain group. Useful for a manual reset and for cleaning up old
    /// device IDs.
    public static func removeAllCloudDevices() {
        guard let accessGroup = keychainAccessGroup else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
        SecItemDelete(query as CFDictionary)
    }

    @discardableResult
    public static func publishCloud(_ info: DeviceBatteryInfo) -> Bool {
        guard let data = try? JSONEncoder().encode(info) else { return false }
        guard let accessGroup = keychainAccessGroup else { return false }

        let account = keychainAccountPrefix + info.id
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]

        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: keychainLabel
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = keychainLabel
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Reads all synchronisable device records. The caller is responsible for
    /// filtering out its own ID. An empty result is normal when the other
    /// device has not opened the app yet or iCloud Keychain is disabled.
    public static func loadCloudDevices() -> [DeviceBatteryInfo] {
        guard let accessGroup = keychainAccessGroup else { return [] }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }

        let entries: [[String: Any]]
        if let array = result as? [[String: Any]] {
            entries = array
        } else if let dict = result as? [String: Any] {
            entries = [dict]
        } else {
            return []
        }

        var devices: [DeviceBatteryInfo] = []
        for entry in entries {
            guard let data = entry[kSecValueData as String] as? Data,
                  let info = try? JSONDecoder().decode(DeviceBatteryInfo.self, from: data)
            else { continue }
            devices.append(info)
        }
        return deduplicated(devices)
    }
}

// MARK: - Widget snapshot

public enum BatteryWidgetData {
    /// The local app and widget use the same app group cache, but the widget
    /// also reads the synchronisable Keychain. This means it can show the other
    /// device even when the app itself has not been opened yet.
    ///
    /// The widget is also a publisher: every timeline refresh writes the
    /// current local iPhone/Mac battery into the shared keychain. This keeps
    /// the other device reasonably fresh even when the app is closed. WidgetKit
    /// decides the exact refresh cadence; a five-minute request is a hint, not
    /// a guarantee.
    public static func load() -> [DeviceBatteryInfo] {
        var devices = BatterySharedStore.merge([
            BatterySharedStore.loadSharedDevices(),
            BatterySharedStore.loadCloudDevices()
        ])

        var local: DeviceBatteryInfo?
        #if os(iOS)
        local = makeLocalIPhone()
        #elseif os(macOS)
        local = makeLocalMac()
        #endif

        if let local {
            devices = devices.filter { $0.id != local.id } + [local]
            // Best effort. A missing keychain entitlement must not prevent the
            // widget from rendering its local device.
            _ = BatterySharedStore.publishCloud(local)
        }

        return BatterySharedStore.deduplicated(devices)
    }

    public static var localDeviceID: String {
        #if os(iOS)
        return BatterySharedStore.deviceID(for: .iPhone)
        #else
        return BatterySharedStore.deviceID(for: .mac)
        #endif
    }

    #if os(iOS)
    private static func makeLocalIPhone() -> DeviceBatteryInfo? {
        // WidgetKit may call the timeline provider off the main thread, while
        // UIDevice battery properties are main-actor isolated. Hop to the main
        // queue only when necessary and read the values synchronously.
        if Thread.isMainThread {
            return MainActor.assumeIsolated { makeLocalIPhoneOnMain() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { makeLocalIPhoneOnMain() }
        }
    }

    @MainActor
    private static func makeLocalIPhoneOnMain() -> DeviceBatteryInfo? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }

        let state: BatteryState
        switch UIDevice.current.batteryState {
        case .charging: state = .charging
        case .full: state = .full
        case .unplugged: state = .discharging
        default: state = .unknown
        }

        return DeviceBatteryInfo(
            id: BatterySharedStore.deviceID(for: .iPhone),
            deviceType: .iPhone,
            deviceName: UIDevice.current.name,
            batteryLevel: Double(level),
            batteryState: state
        )
    }
    #endif

    #if os(macOS)
    private static func makeLocalMac() -> DeviceBatteryInfo {
        DeviceBatteryInfo(
            id: BatterySharedStore.deviceID(for: .mac),
            deviceType: .mac,
            deviceName: Host.current().localizedName ?? "Mac",
            batteryLevel: IOKitBatteryReader.readBatteryLevel(),
            batteryState: IOKitBatteryReader.readBatteryState()
        )
    }
    #endif
}
