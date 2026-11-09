import Foundation

// MARK: - Menu-bar display mode

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
