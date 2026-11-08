import WidgetKit
import SwiftUI

// MARK: - Widget Entry

struct BatteryEntry: TimelineEntry {
    let date: Date
    let devices: [DeviceBatteryInfo]
}

// MARK: - Timeline Provider

struct BatteryTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BatteryEntry {
        BatteryEntry(date: .now, devices: [
            .init(id: "placeholder-mac", deviceType: .mac, deviceName: "Mac", batteryLevel: 1.0, batteryState: .charging),
            .init(id: "placeholder-headphones", deviceType: .airPods, deviceName: "Headphones", batteryLevel: 0.75, batteryState: .discharging),
            .init(id: "placeholder-phone", deviceType: .iPhone, deviceName: "iPhone", batteryLevel: 0.62, batteryState: .discharging)
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
        completion(BatteryEntry(date: .now, devices: BatteryWidgetData.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
        let entry = BatteryEntry(date: .now, devices: BatteryWidgetData.load())
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Widget Definition

@main
struct BatteryWidgetBundle: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.example.batterywidget", provider: BatteryTimelineProvider()) { entry in
            BatteryWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    // Kept as a containerBackground so WidgetKit doesn’t show
                    // its “Please adopt containerBackground API” error card.
                    BatteryWidgetBackground()
                }
        }
        .configurationDisplayName("Аккумуляторы")
        .description("Mac, наушники, iPhone и другие устройства на одном iCloud")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
        .containerBackgroundRemovable(true)
    }
}

// MARK: - Widget Views

struct BatteryWidgetView: View {
    let entry: BatteryEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:  SmallWidgetView(entry: entry)
        case .systemMedium: MediumWidgetView(entry: entry)
        case .systemLarge:  LargeWidgetView(entry: entry)
        default:            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: Small Widget

struct SmallWidgetView: View {
    let entry: BatteryEntry

    var body: some View {
        BatterySmallRingGrid(
            devices: entry.devices,
            localID: BatteryWidgetData.localDeviceID,
            maxRingSize: 72,
            ringSizeFraction: 0.44
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Medium Widget

struct MediumWidgetView: View {
    let entry: BatteryEntry

    var body: some View {
        BatteryMediumRingRow(
            devices: entry.devices,
            localID: BatteryWidgetData.localDeviceID,
            ringSize: 76
        )
        .padding(.horizontal, 16)
        .padding(.top, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: Large Widget

struct LargeWidgetView: View {
    let entry: BatteryEntry

    var body: some View {
        BatteryLargeDeviceList(
            devices: entry.devices,
            localID: BatteryWidgetData.localDeviceID
        )
    }
}

#Preview(as: .systemSmall) {
    BatteryWidgetBundle()
} timeline: {
    BatteryEntry(date: .now, devices: [
        .init(id: "preview-phone", deviceType: .iPhone, deviceName: "iPhone", batteryLevel: 0.29, batteryState: .discharging),
        .init(id: "preview-headphones", deviceType: .airPods, deviceName: "Headphones", batteryLevel: 0.95, batteryState: .discharging)
    ])
}

#Preview(as: .systemMedium) {
    BatteryWidgetBundle()
} timeline: {
    BatteryEntry(date: .now, devices: [
        .init(id: "preview-mac", deviceType: .mac, deviceName: "Mac", batteryLevel: 1.0, batteryState: .charging),
        .init(id: "preview-headphones", deviceType: .airPods, deviceName: "Headphones", batteryLevel: 0.75, batteryState: .discharging),
        .init(id: "preview-phone", deviceType: .iPhone, deviceName: "iPhone", batteryLevel: 0.62, batteryState: .discharging)
    ])
}

#Preview(as: .systemLarge) {
    BatteryWidgetBundle()
} timeline: {
    BatteryEntry(date: .now, devices: [
        .init(id: "preview-mac", deviceType: .mac, deviceName: "MacBook Air", batteryLevel: 0.73, batteryState: .discharging),
        .init(id: "preview-headphones", deviceType: .airPods, deviceName: "AirPods Pro", batteryLevel: 0.95, batteryState: .discharging),
        .init(id: "preview-phone", deviceType: .iPhone, deviceName: "iPhone", batteryLevel: 0.29, batteryState: .discharging),
        .init(id: "preview-watch", deviceType: .appleWatch, deviceName: "Apple Watch", batteryLevel: 0.58, batteryState: .charging)
    ])
}
