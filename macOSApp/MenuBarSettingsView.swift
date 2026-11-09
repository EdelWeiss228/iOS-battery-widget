import SwiftUI

// MARK: - Settings

struct MenuBarSettingsView: View {
    @AppStorage(MenuBarDisplayMode.storageKey)
    private var mode: MenuBarDisplayMode = .iconAndPercent

    var body: some View {
        Form {
            Section("Строка меню") {
                Picker("Отображение заряда", selection: $mode) {
                    ForEach(MenuBarDisplayMode.allCases) { option in
                        Text(option.title)
                            .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Предпросмотр") {
                HStack {
                    Text("Заряд 42 %")
                    Spacer()
                    MenuBarBatteryLabel(
                        level: 0.42,
                        isCharging: false,
                        mode: mode
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .padding(.vertical, 8)
    }
}
