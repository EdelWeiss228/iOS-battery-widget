import AppKit
import CoreText
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
    @StateObject private var monitor = MenuBarBatteryMonitor()

    var body: some View {
        MenuBarBatteryLabel(
            level: monitor.level,
            isCharging: monitor.isCharging,
            mode: mode,
            tint: tint
        )
    }
}

/// Keeps only the menu-bar icon in step with the system battery. This monitor
/// is deliberately separate from `MacBatteryViewModel`: a one-second local
/// IOKit read must not trigger accessory probes, Keychain/cloud sync, shared
/// defaults writes, or WidgetKit reloads. Publishing only on a displayed
/// change keeps the status item from re-rendering every second.
@MainActor
private final class MenuBarBatteryMonitor: ObservableObject {
    @Published private(set) var level: Double
    @Published private(set) var isCharging: Bool

    private var refreshTask: Task<Void, Never>?
    private var displayedPercent: Int

    init() {
        let initialLevel = Self.readLevel()
        let initialState = IOKitBatteryReader.readBatteryState()
        level = initialLevel
        isCharging = initialState.isCharging
        displayedPercent = Int((initialLevel * 100).rounded())

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let newLevel = Self.readLevel()
        let newCharging = IOKitBatteryReader.readBatteryState().isCharging
        let newPercent = Int((newLevel * 100).rounded())

        guard newPercent != displayedPercent || newCharging != isCharging else {
            return
        }

        level = newLevel
        isCharging = newCharging
        displayedPercent = newPercent
    }

    private static func readLevel() -> Double {
        let raw = IOKitBatteryReader.readBatteryLevel()
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
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

    private let bodyHeight: CGFloat = 12
    private let capSpacing: CGFloat = 1.0
    private let capWidth: CGFloat = 1.5
    private let largeBoltSize = CGSize(width: 9, height: 13.25)
    private let largeBoltStrokeWidth: CGFloat = 2.6
    private let largeBoltOffset: CGFloat = 1.0

    private var bodyWidth: CGFloat {
        // The system body is 23 × 12 pt (46 × 24 px at 2×). Only three
        // digits plus the bolt need the extra room.
        showsNumber && isCharging && displayedPercent >= 100 ? 27 : 23
    }

    private var bodyCornerRadius: CGFloat {
        4.0
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

    /// The cap is part of the empty battery, not the charged fill. The system
    /// renders it at roughly 55 % white, a touch lighter than the body underlay.
    private var capColor: Color {
        Color.white.opacity(0.55)
    }

    private var fillColor: Color {
        if BatteryColors.isLow(clampedLevel) {
            return BatteryColors.systemRed
        }

        switch tint {
        case .white:
            return Color(hex: "F5F7FA")
        case .green:
            return BatteryColors.systemGreen
        }
    }

    private var bodyShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: bodyCornerRadius, style: .continuous)
    }

    /// macOS 27 draws a battery without digits as a large solid bolt separated
    /// from the body by a transparent gap. The numbered variant keeps the
    /// small solid `bolt.fill` next to the figures.
    private var usesLargeChargingBolt: Bool {
        isCharging && !showsNumber
    }

    var body: some View {
        HStack(spacing: capSpacing) {
            ZStack {
                bodyLayers
                    .compositingGroup()
                    .mask {
                        ZStack {
                            Rectangle().fill(.white)

                            if showsNumber || isCharging {
                                glyphContent
                                    // The system's large bolt is a full
                                    // knockout; the small digit/bolt engraving
                                    // is slightly softened.
                                    .opacity(usesLargeChargingBolt ? 1 : 0.9)
                                    .blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                    }

                if usesLargeChargingBolt {
                    largeChargingBoltFill
                }
            }
            .frame(width: bodyWidth, height: bodyHeight)

            Capsule()
                .fill(capColor)
                .frame(width: capWidth, height: bodyHeight / 3)
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

    /// The system uses the variable SF NS face for the menu-bar figures. Its
    /// default `.system` instance is too heavy and a little too wide against
    /// the battery: the system's digits are 15 px tall and sit between
    /// Regular and Medium in weight. A 420 weight at 96 % width matches the
    /// system's glyph boxes and ink distribution at every percentage.
    private var numberFont: Font {
        let size: CGFloat = 10.2
        let axes: [NSNumber: NSNumber] = [
            // Optical Size -> 17, matching the system's smallest optical size.
            NSNumber(value: 1869640570): 17,
            // Weight -> 420, between Regular (400) and .medium (510).
            NSNumber(value: 2003265652): 420,
            // Width -> 96 %, matching the system's slightly narrower figures.
            NSNumber(value: 2003072104): 96,
        ]
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        let descriptor = base.fontDescriptor.addingAttributes([.variation: axes])
        let ctFont = CTFontCreateWithFontDescriptor(
            descriptor as CTFontDescriptor,
            size,
            nil
        )
        return Font(ctFont)
    }

    /// The solid foreground bolt that sits inside the transparent gap. It is
    /// drawn over the body so its tips can protrude by half a point, exactly
    /// like the system icon.
    private var largeChargingBoltFill: some View {
        BoltShape()
            .fill(fillColor)
            .frame(width: largeBoltSize.width, height: largeBoltSize.height)
            .offset(x: largeBoltOffset)
    }

    @ViewBuilder
    private var glyphContent: some View {
        if usesLargeChargingBolt {
            // The system bolt is a solid foreground shape with a transparent
            // gap around it. The gap is the outer half of this stroke: the
            // white fill below covers the inner half.
            BoltShape()
                .stroke(
                    style: StrokeStyle(
                        lineWidth: largeBoltStrokeWidth,
                        lineJoin: .round
                    )
                )
                .frame(width: largeBoltSize.width, height: largeBoltSize.height)
                .offset(x: largeBoltOffset)
                .foregroundStyle(.white)
        } else {
            // The menu-bar figures are proportional SF Pro, not SF Rounded:
            // at 100 % the system zeros are 10 px wide at 2×, while SF Rounded
            // makes them 12 px. The negative spacing makes up for the SF
            // Symbol side bearing so the bolt sits the same distance from the
            // last digit as it does in the system battery. A half-point shift
            // centres the pair.
            HStack(spacing: -1.5) {
                if showsNumber {
                    Text("\(displayedPercent)")
                        .font(numberFont)
                        .fixedSize()
                        .lineLimit(1)
                }

                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 6.7, weight: .semibold))
                        .offset(x: showsNumber ? 0.5 : 0)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 1)
            .offset(x: showsNumber && isCharging ? 0.5 : 0)
        }
    }
}

// MARK: - Bolt path

/// Outline of the SF Symbols `bolt` glyph, normalised to its 206 × 328 px
/// bounding box. macOS 27 uses the bolt as a solid shape separated from the
/// battery body by a transparent gap, so the glyph is rebuilt as a path and
/// stroked at the exact gap width instead of being scaled as an image.
private struct BoltShape: Shape {
    private static let points: [(CGFloat, CGFloat)] = [
        (0.709, 0.000),
        (0.752, 0.012),
        (0.757, 0.052),
        (0.544, 0.396),
        (0.961, 0.399),
        (0.995, 0.439),
        (0.320, 0.988),
        (0.233, 0.960),
        (0.451, 0.601),
        (0.034, 0.598),
        (0.000, 0.561),
        (0.650, 0.027),
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, point) in Self.points.enumerated() {
            let scaled = CGPoint(
                x: rect.minX + point.0 * rect.width,
                y: rect.minY + point.1 * rect.height
            )
            if index == 0 {
                path.move(to: scaled)
            } else {
                path.addLine(to: scaled)
            }
        }
        path.closeSubpath()
        return path
    }
}
