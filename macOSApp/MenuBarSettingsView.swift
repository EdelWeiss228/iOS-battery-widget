import SwiftUI

// MARK: - Settings

struct MenuBarSettingsView: View {
    @AppStorage(MenuBarDisplayMode.storageKey)
    private var mode: MenuBarDisplayMode = .iconAndPercent
    @AppStorage(MenuBarBatteryTint.storageKey)
    private var tint: MenuBarBatteryTint = .white

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

            Section("Цвет батарейки") {
                Picker("Цвет", selection: $tint) {
                    ForEach(MenuBarBatteryTint.allCases) { option in
                        Text(option.title)
                            .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(tint.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Предпросмотр") {
                previewRow(title: "42 %", level: 0.42, isCharging: false)
                previewRow(title: "19 % · зарядка", level: 0.19, isCharging: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 430)
        .padding(.vertical, 8)
    }

    private func previewRow(
        title: String,
        level: Double,
        isCharging: Bool
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            MenuBarBatteryLabel(
                level: level,
                isCharging: isCharging,
                mode: mode,
                tint: tint
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Color(hex: "495266"),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }
}
