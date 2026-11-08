import Foundation

// MARK: - Device Types

public enum DeviceType: String, Codable, CaseIterable, Sendable {
    case iPhone = "iphone"
    case mac = "mac"
    case airPods = "airpods"
    case appleWatch = "watch"
    case other = "other"

    public var systemImageName: String {
        switch self {
        case .iPhone: return "iphone"
        case .mac: return "laptopcomputer"
        case .airPods: return "headphones"
        case .appleWatch: return "applewatch"
        case .other: return "battery.100"
        }
    }

    /// The order used by the ring widget: Mac, headphones, iPhone.
    public var widgetOrder: Int {
        switch self {
        case .mac: return 0
        case .airPods: return 1
        case .iPhone: return 2
        case .appleWatch: return 3
        case .other: return 4
        }
    }

    public var displayName: String {
        switch self {
        case .iPhone: return "iPhone"
        case .mac: return "Mac"
        case .airPods: return "AirPods"
        case .appleWatch: return "Apple Watch"
        case .other: return "Устройство"
        }
    }
}

// MARK: - Battery State

public enum BatteryState: String, Codable, Sendable {
    case charging
    case discharging
    case full
    case unknown

    public var isCharging: Bool {
        self == .charging || self == .full
    }
}

// MARK: - Battery Info

public struct DeviceBatteryInfo: Codable, Identifiable, Equatable, Sendable {
    public var id: String         // UUID устройства или имя хоста
    public var deviceType: DeviceType
    public var deviceName: String
    public var batteryLevel: Double   // 0.0 – 1.0
    public var batteryState: BatteryState
    public var timestamp: Date
    /// Whether `batteryLevel` came from a successful battery read.
    /// `nil` marks records written by older app versions.
    public var isBatteryReadingAvailable: Bool?

    public init(
        id: String,
        deviceType: DeviceType,
        deviceName: String,
        batteryLevel: Double,
        batteryState: BatteryState,
        timestamp: Date = .now,
        isBatteryReadingAvailable: Bool? = nil
    ) {
        self.id = id
        self.deviceType = deviceType
        self.deviceName = deviceName
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.timestamp = timestamp
        self.isBatteryReadingAvailable = isBatteryReadingAvailable
    }

    /// A missing reading is not the same thing as 0 %. In particular, an
    /// iPhone can see a headset as connected but cannot read its battery, so it
    /// reports 0. Legacy records used 0 for both states; for those, a positive
    /// level is the only value we can safely treat as a real reading.
    public var hasBatteryReading: Bool {
        guard batteryLevel.isFinite else { return false }

        switch deviceType {
        case .mac, .iPhone:
            return true
        case .airPods, .appleWatch, .other:
            if let isBatteryReadingAvailable {
                return isBatteryReadingAvailable
            }
            return batteryLevel > 0.001
        }
    }

    public var levelPercent: Int {
        Int((batteryLevel * 100).rounded())
    }

    public var isStale: Bool {
        // Cloud Keychain updates can arrive a little later than Bonjour packets.
        Date().timeIntervalSince(timestamp) > 10 * 60
    }

    /// The last known value is still useful for the widget for a day, even if
    /// the other device has not opened the app recently.
    public var isExpired: Bool {
        Date().timeIntervalSince(timestamp) > 24 * 60 * 60
    }

    /// Accessories are shown only while they have a real, recent battery
    /// reading. Disconnecting a device must not turn its last known level into
    /// 0 %: unavailable records are tombstones and stay hidden. Mac and iPhone
    /// stay visible even at 0 %, because their own readings are always valid.
    public var isWidgetVisible: Bool {
        guard !isExpired else { return false }

        switch deviceType {
        case .mac, .iPhone:
            return true
        case .airPods, .appleWatch, .other:
            return !isStale && hasBatteryReading && batteryLevel > 0.001
        }
    }
}
