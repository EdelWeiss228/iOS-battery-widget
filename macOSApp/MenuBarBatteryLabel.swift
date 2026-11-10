import AppKit
import SwiftUI

// MARK: - Menu-bar label

/// `MenuBarExtra` does not reliably invalidate its label when the storage is
/// observed by the app scene, so observe the selected mode inside the label
/// itself. The Settings preview still uses `MenuBarBatteryLabel` directly.
struct MenuBarStatusLabel: View {
    @AppStorage(MenuBarDisplayMode.storageKey)
    private var mode: MenuBarDisplayMode = .iconAndPercent
    @AppStorage(MenuBarBatteryTint.storageKey)
    private var tint: MenuBarBatteryTint = .level

    let level: Double
    let isCharging: Bool

    var body: some View {
        MenuBarBatteryLabel(
            level: level,
            isCharging: isCharging,
            mode: mode,
            tint: tint
        )
    }
}

/// The label used by `MenuBarExtra`. Every mode keeps the same text metrics and
/// a fixed-size battery glyph so the status item does not jump when the user
/// switches modes.
struct MenuBarBatteryLabel: View {
    let level: Double
    let isCharging: Bool
    let mode: MenuBarDisplayMode
    let tint: MenuBarBatteryTint

    private var clampedLevel: Double {
        guard level.isFinite else { return 0 }
        return min(max(level, 0), 1)
    }

    private var percent: Int {
        Int((clampedLevel * 100).rounded())
    }

    var body: some View {
        Group {
            switch mode {
            case .iconAndPercent:
                HStack(spacing: 4) {
                    batteryGlyph(showsNumber: false)
                    percentText
                }
            case .batteryWithNumber:
                batteryGlyph(showsNumber: true)
            case .batteryOnly:
                batteryGlyph(showsNumber: false)
            case .percentOnly:
                percentText
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// `MenuBarExtra` renders text in the status item, but custom shapes in a
    /// composite label are ignored on macOS. Render the custom battery into an
    /// image so the status item keeps the dynamic fill instead of showing only
    /// its percentage text.
    private func batteryGlyph(showsNumber: Bool) -> some View {
        Image(nsImage: renderedBatteryGlyph(showsNumber: showsNumber))
            .renderingMode(.original)
            .accessibilityHidden(true)
    }

    private func renderedBatteryGlyph(showsNumber: Bool) -> NSImage {
        let glyph = MenuBarBatteryGlyph(
            level: clampedLevel,
            isCharging: isCharging,
            showsNumber: showsNumber,
            tint: tint
        )
        let renderer = ImageRenderer(content: glyph)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else {
            return NSImage(
                systemSymbolName: "battery.100",
                accessibilityDescription: nil
            ) ?? NSImage(size: NSSize(width: 30, height: 14))
        }
        image.isTemplate = false
        return image
    }

    private var percentText: some View {
        Text("\(percent)%")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(
                BatteryColors.isLow(clampedLevel) ? BatteryColors.systemRed : Color.primary
            )
    }

    private var accessibilityLabel: String {
        let charging = isCharging ? ", заряжается" : ""
        return "Mac, \(percent) процентов\(charging)"
    }
}

// MARK: - Battery glyph

/// A compact system-style battery with a dynamic fill. The empty part stays
/// transparent, so the menu bar background shows through just like the system
/// battery indicator.
private struct MenuBarBatteryGlyph: View {
    let level: Double
    let isCharging: Bool
    let showsNumber: Bool
    let tint: MenuBarBatteryTint

    private let bodyHeight: CGFloat = 14
    private let inset: CGFloat = 1.5
    private let capSpacing: CGFloat = 1.3

    private var bodyWidth: CGFloat {
        showsNumber ? 30 : 27
    }

    private var clampedLevel: Double {
        guard level.isFinite else { return 0 }
        return min(max(level, 0), 1)
    }

    private var statusColor: Color {
        switch tint {
        case .level:
            return BatteryColors.solidColor(for: clampedLevel)
        case .green:
            return BatteryColors.systemGreen
        case .white:
            return .white
        }
    }

    private var fillStyle: AnyShapeStyle {
        switch tint {
        case .level:
            return AnyShapeStyle(BatteryColors.gradient(for: clampedLevel))
        case .green:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color(hex: "54E878"), BatteryColors.systemGreen],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .white:
            return AnyShapeStyle(Color.white)
        }
    }

    private var usesDarkNumber: Bool {
        tint == .white && clampedLevel >= 0.5
    }

    private var numberColor: Color {
        usesDarkNumber ? .black : .white
    }

    private var numberShadow: Color {
        usesDarkNumber ? .white.opacity(0.7) : .black.opacity(0.7)
    }

    private var innerWidth: CGFloat {
        max(0, bodyWidth - inset * 2)
    }

    private var innerHeight: CGFloat {
        max(0, bodyHeight - inset * 2)
    }

    var body: some View {
        HStack(spacing: capSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: 3.6, style: .continuous)
                    .strokeBorder(statusColor.opacity(0.9), lineWidth: 1.2)

                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.9, style: .continuous)
                        .fill(fillStyle)
                        .frame(width: innerWidth * clampedLevel)
                    Spacer(minLength: 0)
                }
                .frame(width: innerWidth, height: innerHeight, alignment: .leading)
                .padding(inset)

                if isCharging && !showsNumber {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(numberColor)
                        .shadow(color: numberShadow, radius: 0.8)
                }

                if showsNumber {
                    Text("\(Int((clampedLevel * 100).rounded()))")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(numberColor)
                        .shadow(color: numberShadow, radius: 0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .padding(.horizontal, 1.5)
                }
            }
            .frame(width: bodyWidth, height: bodyHeight)

            Capsule()
                .fill(statusColor.opacity(0.9))
                .frame(width: 2.2, height: bodyHeight * 0.38)
        }
        .accessibilityHidden(true)
    }
}
