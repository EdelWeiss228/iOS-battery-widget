import Foundation
import Combine

// MARK: - Combined sync
//
// Two transports are active at the same time:
//  • Bonjour — instant while both devices are on the same Wi-Fi / hotspot.
//  • synchronisable Keychain — same iCloud account, works across networks.
//
// Devices are merged by ID and the newest record wins. The Keychain record is
// deliberately kept after the other app goes to the background, so the widget
// can continue showing the last known iPhone/Mac percentage.

@MainActor
public final class BatterySyncManager: ObservableObject {
    public static let shared = BatterySyncManager()

    @Published public private(set) var remoteDevices: [DeviceBatteryInfo] = []
    @Published public private(set) var cloudTransportConfigured: Bool = false

    private let bonjour = BonjourSyncManager.shared
    private var localInfo: DeviceBatteryInfo?
    private var bonjourDevices: [DeviceBatteryInfo] = []
    private var cloudDevices: [DeviceBatteryInfo] = []

    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var lastCloudPublish = Date.distantPast
    private var lastPublishedLevel = -1.0
    private var lastPublishedState: BatteryState?

    private init() {
        cloudTransportConfigured = BatterySharedStore.isCloudTransportConfigured

        bonjour.$remoteDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                guard let self else { return }
                // Bonjour records go away quickly when a peer disconnects.
                self.bonjourDevices = devices.filter { !$0.isStale }
                self.rebuild()
            }
            .store(in: &cancellables)
    }

    public func start(localInfo: DeviceBatteryInfo) {
        self.localInfo = localInfo

        bonjour.start(localInfo: localInfo)
        cloudTransportConfigured = BatterySharedStore.isCloudTransportConfigured
        publishToCloud(localInfo, force: true)
        refreshCloud()

        if timer == nil {
            let cloudTimer = Timer(timeInterval: 45, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshCloud() }
            }
            cloudTimer.tolerance = 5
            RunLoop.main.add(cloudTimer, forMode: .common)
            timer = cloudTimer
        }
    }

    public func update(localInfo: DeviceBatteryInfo) {
        self.localInfo = localInfo
        bonjour.update(localInfo: localInfo)
        publishToCloud(localInfo, force: false)
        refreshCloud()
    }

    public func refreshCloud() {
        guard let localInfo else { return }

        let loaded = BatterySharedStore.loadCloudDevices()
        cloudDevices = loaded.filter { $0.id != localInfo.id }
        cloudTransportConfigured = BatterySharedStore.isCloudTransportConfigured
        rebuild()
    }

    private func rebuild() {
        let localID = localInfo?.id
        let merged = BatterySharedStore.merge([bonjourDevices, cloudDevices])
        remoteDevices = merged.filter { $0.id != localID }
    }

    private func publishToCloud(_ info: DeviceBatteryInfo, force: Bool) {
        let stateChanged = info.batteryState != lastPublishedState
        let levelChanged = abs(info.batteryLevel - lastPublishedLevel) > 0.004
        let heartbeatDue = Date().timeIntervalSince(lastCloudPublish) > 120

        guard force || stateChanged || levelChanged || heartbeatDue else { return }

        if BatterySharedStore.publishCloud(info) {
            lastCloudPublish = .now
            lastPublishedLevel = info.batteryLevel
            lastPublishedState = info.batteryState
        }
    }
}
