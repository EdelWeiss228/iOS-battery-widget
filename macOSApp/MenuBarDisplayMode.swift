import Foundation

// MARK: - Menu-bar display mode

enum MenuBarBatteryTint: String, CaseIterable, Identifiable, Hashable {
    case level
    case green
    case white

    static let storageKey = "menuBarBatteryTint"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .level:
            return "По уровню"
        case .green:
            return "Зелёный"
        case .white:
            return "Белый"
        }
    }

    var detail: String {
        switch self {
        case .level:
            return "Зелёный, жёлтый или красный в зависимости от заряда."
        case .green:
            return "Всегда зелёная заливка."
        case .white:
            return "Белая заливка, как у системной батарейки."
        }
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
