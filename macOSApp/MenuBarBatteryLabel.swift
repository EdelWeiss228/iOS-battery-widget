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
    private var tint: MenuBarBatteryTint = .white

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
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
    }

    private var accessibilityLabel: String {
        let charging = isCharging ? ", заряжается" : ""
        return "Mac, \(percent) процентов\(charging)"
    }
}

// MARK: - Battery glyph

/// A compact reconstruction of the macOS 27 menu-bar battery. The body is a
/// light, translucent underlay with the charged part painted on top. The
/// number and bolt are knocked out of those layers instead of being drawn in a
/// foreground color, so the menu-bar background shows through them exactly
/// like it does in the system indicator.
private struct MenuBarBatteryGlyph: View {
    let level: Double
    let isCharging: Bool
    let showsNumber: Bool
    let tint: MenuBarBatteryTint

    private let bodyHeight: CGFloat = 15
    private let capSpacing: CGFloat = 1.3
    private let capWidth: CGFloat = 2.2

    private var bodyWidth: CGFloat {
        28
    }

    private var bodyCornerRadius: CGFloat {
        4.2
    }

    private var clampedLevel: Double {
        guard level.isFinite else { return 0 }
        return min(max(level, 0), 1)
    }

    private var displayedPercent: Int {
        Int((clampedLevel * 100).rounded())
    }

    /// The system uses roughly 45 % white for the empty body on a dark menu
    /// bar. The underlay is invisible at 100 % because the opaque fill covers
    /// it completely.
    private var underlayColor: Color {
        Color.white.opacity(0.45)
    }

    private var fillColor: Color {
        if BatteryColors.isLow(clampedLevel) {
            return BatteryColors.systemRed
        }

        switch tint {
        case .white:
            return Color(hex: "F5F6F7")
        case .green:
            return BatteryColors.systemGreen
        }
    }

    private var bodyShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: bodyCornerRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: capSpacing) {
            bodyLayers
                .compositingGroup()
                .mask {
                    ZStack {
                        Rectangle().fill(.white)

                        if showsNumber || isCharging {
                            glyphContent
                                .opacity(0.9)
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
                }

            Capsule()
                .fill(underlayColor)
                .frame(width: capWidth, height: bodyHeight * 0.38)
        }
        .accessibilityHidden(true)
    }

    private var bodyLayers: some View {
        ZStack {
            bodyShape
                .fill(underlayColor)

            Rectangle()
                .fill(fillColor)
                .frame(width: bodyWidth * clampedLevel, height: bodyHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: bodyWidth, height: bodyHeight)
        .clipShape(bodyShape)
    }

    private var glyphContent: some View {
        HStack(spacing: 1.2) {
            if showsNumber {
                Text("\(displayedPercent)")
                    .font(.system(size: 9.2, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7.4, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 1)
    }
}
