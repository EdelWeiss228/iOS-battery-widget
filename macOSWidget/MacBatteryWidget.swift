import WidgetKit
import SwiftUI

// MARK: - macOS Widget

struct MacBatteryEntry: TimelineEntry {
    let date: Date
    let devices: [DeviceBatteryInfo]
}

struct MacBatteryTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacBatteryEntry {
        MacBatteryEntry(date: .now, devices: [
            .init(id: "placeholder-mac", deviceType: .mac, deviceName: "Mac", batteryLevel: 1.0, batteryState: .charging),
            .init(id: "placeholder-headphones", deviceType: .airPods, deviceName: "Headphones", batteryLevel: 0.75, batteryState: .discharging),
            .init(id: "placeholder-phone", deviceType: .iPhone, deviceName: "iPhone", batteryLevel: 0.62, batteryState: .discharging)
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (MacBatteryEntry) -> Void) {
        completion(MacBatteryEntry(date: .now, devices: BatteryWidgetData.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MacBatteryEntry>) -> Void) {
        let entry = MacBatteryEntry(date: .now, devices: BatteryWidgetData.load())
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

@main
struct MacBatteryWidgetBundle: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BatterySharedStore.macWidgetKind, provider: MacBatteryTimelineProvider()) { entry in
            MacBatteryWidgetView(entry: entry)
                .containerBackground(for: .widget) {
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

// MARK: - macOS Widget View

struct MacBatteryWidgetView: View {
    let entry: MacBatteryEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:  MacSmallWidget(entry: entry)
        case .systemMedium: MacMediumWidget(entry: entry)
        case .systemLarge:  MacLargeWidget(entry: entry)
        default:            MacSmallWidget(entry: entry)
        }
    }
}

// MARK: Small Widget

struct MacSmallWidget: View {
    let entry: MacBatteryEntry

    var body: some View {
        BatterySmallRingGrid(
            devices: entry.devices,
            localID: BatteryWidgetData.localDeviceID
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Medium Widget

struct MacMediumWidget: View {
    let entry: MacBatteryEntry

    var body: some View {
        BatteryMediumRingRow(
            devices: entry.devices,
            localID: BatteryWidgetData.localDeviceID,
            ringSize: 64
        )
        .padding(.horizontal, 16)
        .padding(.top, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: Large Widget

struct MacLargeWidget: View {
    let entry: MacBatteryEntry

    var body: some View {
        BatteryLargeDeviceList(
            devices: entry.devices,
            localID: BatteryWidgetData.localDeviceID
        )
    }
}
