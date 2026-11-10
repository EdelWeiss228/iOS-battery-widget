import SwiftUI
import Foundation
import IOKit.ps

// MARK: - macOS App

@main
struct BatteryMacApp: App {
    @StateObject private var vm: MacBatteryViewModel

    init() {
        // Parent refreshes start this executable as a short-lived probe so the
        // IOBluetooth cache is fresh. The probe prints only the encoded battery
        // records and exits before SwiftUI creates any windows.
        if CommandLine.arguments.contains("--bluetooth-probe") {
            let devices = BluetoothBatteryReader.connectedDevices()
            if let data = try? JSONEncoder().encode(devices) {
                FileHandle.standardOutput.write(data)
            }
            exit(0)
        }

        let model = MacBatteryViewModel()
        _vm = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(vm)
        } label: {
            MenuBarStatusLabel(
                level: vm.primaryDevice.batteryLevel,
                isCharging: vm.primaryDevice.batteryState.isCharging
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            MenuBarSettingsView()
        }
    }
}

// MARK: - macOS Menu Bar Content

struct MenuBarContentView: View {
    @EnvironmentObject var vm: MacBatteryViewModel
    @ObservedObject private var sync = BatterySyncManager.shared

    var body: some View {
        VStack(spacing: 10) {
            BatteryNestedGlassCard(cornerRadius: 24, padding: 16) {
                BatteryRingPanel(
                    devices: vm.allDevices,
                    ringSize: 52,
                    localID: vm.local.id
                )
            }

            HStack(spacing: 8) {
                Image(systemName: sync.cloudTransportConfigured ? "icloud" : "wifi")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(sync.cloudTransportConfigured ? "iCloud Keychain" : "Локальная сеть")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("•")
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)

                Text(Date(), style: .time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                Spacer()

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Параметры")

                Button {
                    vm.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Обновить")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Выйти")
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 358)
    }
}
