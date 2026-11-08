import SwiftUI

// MARK: - Main Content View (iOS App)

struct ContentView: View {
    @EnvironmentObject var vm: BatteryViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.scenePhase) var scenePhase
    @ObservedObject private var sync = BatterySyncManager.shared

    var body: some View {
        NavigationStack {
            ZStack {
                background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        headerView

                        BatteryGlassCard(cornerRadius: 30, padding: 18) {
                            BatteryRingPanel(
                                devices: vm.allDevices,
                                ringSize: 64,
                                localID: vm.localDevice.id
                            )
                        }

                        syncStatus
                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .animation(.spring(duration: 0.45), value: vm.allDevices.count)
                }
            }
            .navigationBarHidden(true)
            .refreshable { vm.refreshLocal() }
        }
        .onChange(of: scenePhase) { _, _ in
            vm.refreshLocal()
        }
    }

    // MARK: - Background

    private var background: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(hex: "111214"), Color(hex: "050506")]
                : [Color(hex: "F4F5F7"), Color(hex: "DDE1E6")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Header

    var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Аккумуляторы")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(Date(), style: .time)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                vm.refreshLocal()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.primary.opacity(0.07), in: Circle())
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Sync Status

    private var syncStatus: some View {
        HStack(spacing: 7) {
            Image(systemName: sync.cloudTransportConfigured ? "icloud" : "wifi")
                .font(.system(size: 12, weight: .medium))
            Text(sync.cloudTransportConfigured ? "iCloud Keychain" : "Локальная сеть")
                .font(.system(size: 12, weight: .medium))
            Text("•")
                .font(.system(size: 12))
                .foregroundStyle(.quaternary)
            Text("Mac и iPhone")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(BatteryViewModel())
}
