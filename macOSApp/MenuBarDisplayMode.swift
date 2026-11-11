import Foundation

// MARK: - Menu-bar display mode

enum MenuBarBatteryTint: String, CaseIterable, Identifiable, Hashable {
    case white
    case green

    static let storageKey = "menuBarBatteryTint"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white:
            return "Белый"
        case .green:
            return "Зелёный"
        }
    }

    var detail: String {
        switch self {
        case .white:
            return "Белая заливка на светлой полупрозрачной подложке. На низком заряде становится красной."
        case .green:
            return "Зелёная заливка на светлой полупрозрачной подложке. На низком заряде становится красной."
        }
    }

    /// The previous alpha build exposed a third “По уровню” option that used
    /// yellow. Yellow is deferred, so an existing selection is migrated to the
    /// new default instead of leaving the menu bar on a removed value.
    static func migrateStoredSelectionIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: storageKey) == "level" else { return }
        defaults.set(Self.white.rawValue, forKey: storageKey)
    }
}

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Hashable {
    case iconAndPercent
    case batteryWithNumber
    case batteryOnly
    case percentOnly

    static let storageKey = "menuBarDisplayMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconAndPercent:
            return "Батарейка и процент"
        case .batteryWithNumber:
            return "Процент внутри батарейки"
        case .batteryOnly:
            return "Только батарейка"
        case .percentOnly:
            return "Только процент"
        }
    }

    var detail: String {
        switch self {
        case .iconAndPercent:
            return "Динамическая батарейка, справа — процент."
        case .batteryWithNumber:
            return "Число без знака % находится внутри батарейки."
        case .batteryOnly:
            return "Только динамическая батарейка, без числа и процента."
        case .percentOnly:
            return "Только процент, без иконки."
        }
    }
}
