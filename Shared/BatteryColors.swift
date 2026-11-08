import SwiftUI

// MARK: - Battery Level Colors

public struct BatteryColors {
    /// 20 % and below use the low-battery red state, including the ring arc.
    public static let lowBatteryThreshold = 0.2

    // Цветовые остановки для градиента
    public static func gradient(for level: Double) -> LinearGradient {
        if level > 0.5 {
            return LinearGradient(
                colors: [Color(hex: "30D158"), Color(hex: "26B94A")],
                startPoint: .top, endPoint: .bottom
            )
        } else if level > lowBatteryThreshold {
            return LinearGradient(
                colors: [Color(hex: "FFD60A"), Color(hex: "FFB800")],
                startPoint: .top, endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [Color(hex: "FF453A"), Color(hex: "FF2D20")],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    public static func solidColor(for level: Double) -> Color {
        if level > 0.5 {
            return Color(hex: "30D158")
        } else if level > lowBatteryThreshold {
            return Color(hex: "FFD60A")
        } else {
            return Color(hex: "FF453A")
        }
    }

    public static func isLow(_ level: Double) -> Bool { level <= lowBatteryThreshold }
    public static func isCritical(_ level: Double) -> Bool { level <= 0.1 }

    /// The system Batteries widget keeps the arc green at normal levels. At
    /// 20 % and below, the ring switches to the same system-red palette as the
    /// other low-battery indicators.
    public static func ringGradient(for level: Double) -> LinearGradient {
        LinearGradient(
            colors: isLow(level)
                ? [systemRed, ringLowStart]
                : [systemGreen, ringStart],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// Apple’s system green. The arc starts slightly darker and reaches this
    /// exact value as it gets brighter, so the ring reads as #30D158 instead of
    /// the mint green used by earlier builds.
    public static let systemGreen = Color(hex: "30D158")
    public static let ringStart = Color(hex: "26B94A")
    public static let ringMiddle = systemGreen
    public static let ringEnd = systemGreen
    public static let ringTip = systemGreen

    /// The system red used by the existing low-battery indicators. The arc
    /// starts slightly darker and reaches this exact value at the tip.
    public static let systemRed = Color(hex: "FF453A")
    public static let ringLowStart = Color(hex: "FF2D20")
    public static let ringLowMiddle = systemRed
    public static let ringLowEnd = systemRed

    public static func ringStartColor(for level: Double) -> Color {
        isLow(level) ? ringLowStart : ringStart
    }

    public static func ringEndColor(for level: Double) -> Color {
        isLow(level) ? ringLowEnd : ringEnd
    }

    /// The progress arc uses an angular gradient. The beginning of the arc is
    /// dark and it gets lighter clockwise, so the bright end always sits at
    /// the current level. At 100 % the bright tip overlaps the dark beginning
    /// at the top, which closes the ring without flattening the gradient.
    public static func ringArcGradient(for level: Double) -> AngularGradient {
        let fraction = min(max(level, 0.001), 1.0)
        return AngularGradient(
            gradient: Gradient(stops: ringGradientStops(for: level)),
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360 * fraction)
        )
    }

    static func ringGradientStops(for level: Double) -> [Gradient.Stop] {
        let low = isLow(level)
        let start = low ? ringLowStart : ringStart
        let middle = low ? ringLowMiddle : ringMiddle
        let end = low ? ringLowEnd : ringEnd
        return [
            .init(color: start, location: 0.0),
            .init(color: start.opacity(0.96), location: 0.18),
            .init(color: middle, location: 0.52),
            .init(color: middle.opacity(0.98), location: 0.72),
            .init(color: end, location: 0.94),
            .init(color: end, location: 1.0)
        ]
    }

    public static func ringGlow(for level: Double) -> Color {
        isLow(level) ? ringLowEnd : systemGreen
    }
}

// MARK: - Glass Colors

public extension Color {
    // Neutral black glass. The blue cast in the reference comes from the
    // wallpaper showing through, not from the material itself.
    static let batteryCardTop = Color(hex: "101113")
    static let batteryCardBottom = Color(hex: "030405")
    static let batteryRingTrackTop = Color.white.opacity(0.18)
    static let batteryRingTrackBottom = Color.white.opacity(0.055)
    static let batteryGlassBorder = Color.white
}

// MARK: - Hex Color Extension

public extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        _ = scanner.scanString("#")
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Liquid Glass Battery Indicator

public struct BatteryIndicatorView: View {
    public let level: Double
    public let isCharging: Bool
    public let compact: Bool

    public init(level: Double, isCharging: Bool, compact: Bool = false) {
        self.level = level
        self.isCharging = isCharging
        self.compact = compact
    }

    public var body: some View {
        ZStack {
            // Фон батарейки
            RoundedRectangle(cornerRadius: compact ? 3 : 5)
                .stroke(.white.opacity(0.4), lineWidth: 1.5)
                .frame(width: compact ? 28 : 44, height: compact ? 14 : 22)

            // Заполненная часть
            HStack {
                GeometryReader { geo in
                    BatteryColors.gradient(for: level)
                        .clipShape(RoundedRectangle(cornerRadius: compact ? 2 : 4))
                        .frame(width: geo.size.width * level)
                        .animation(.spring(duration: 0.6), value: level)
                }
            }
            .frame(width: compact ? 26 : 42, height: compact ? 12 : 20)
            .padding(1)

            // Иконка зарядки
            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: compact ? 8 : 12, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1)
            }
        }
        // Правый "контакт"
        .overlay(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.4))
                .frame(width: compact ? 3 : 4, height: compact ? 6 : 10)
                .offset(x: compact ? 5 : 7)
        }
    }
}

// MARK: - Ring Battery View

/// One ring from the reference design. Nil means an empty, unlabelled slot.
public struct BatteryRingView: View {
    public let info: DeviceBatteryInfo?
    public let size: CGFloat
    public let lineWidth: CGFloat
    public let showsLabel: Bool

    @Environment(\.colorScheme) private var colorScheme

    public init(
        info: DeviceBatteryInfo?,
        size: CGFloat = 54,
        lineWidth: CGFloat = 6,
        showsLabel: Bool = true
    ) {
        self.info = info
        self.size = size
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
    }

    public var body: some View {
        VStack(spacing: showsLabel ? 18 : 0) {
            ZStack {
                // Keep the track and the progress arc on exactly the same
                // circle. The padding puts the stroke's centreline at the
                // same radius for both.
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: trackColors,
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: lineWidth
                    )
                    .padding(lineWidth / 2)

                if let info, info.batteryLevel > 0.001 {
                    let level = min(max(info.batteryLevel, 0), 1)
                    let fraction = min(max(level, 0.001), 1)
                    let stops = BatteryColors.ringGradientStops(for: level).map {
                        Gradient.Stop(
                            color: $0.color,
                            location: min($0.location * fraction, fraction)
                        )
                    }

                    // Round the 0 % end as well as the growing tip. Without
                    // this cap the track shows through the seam at 12 o'clock,
                    // especially when the ring reaches 100 %.
                    BatteryRingStartCap(lineWidth: lineWidth)
                        .fill(BatteryColors.ringStartColor(for: level))
                        .padding(lineWidth / 2)

                    // Draw the arc as a Shape instead of a Canvas. On current
                    // macOS/iOS the live Canvas renderer turns a conic-gradient
                    // stroke into a rounded square, while a shape stroke keeps
                    // the ring perfectly circular.
                    BatteryRingProgressArc(level: level)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(stops: stops),
                                center: .center,
                                startAngle: .degrees(-90),
                                endAngle: .degrees(270)
                            ),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                        )
                        .padding(lineWidth / 2)

                    BatteryRingTipCap(level: level, lineWidth: lineWidth)
                        .fill(BatteryColors.ringEndColor(for: level))
                        .padding(lineWidth / 2)
                        .shadow(
                            color: BatteryColors.ringEndColor(for: level).opacity(0.24),
                            radius: lineWidth * 0.28,
                            x: 0,
                            y: 0
                        )
                }

                if let info {
                    Image(systemName: info.deviceType.systemImageName)
                        .font(.system(size: size * 0.38, weight: .light))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(contentColor.opacity(info.isStale ? 0.5 : 0.86))
                }
            }
            .frame(width: size, height: size)
            .opacity(info?.isStale == true ? 0.78 : 1)

            if showsLabel {
                if let info {
                    Text("\(info.levelPercent) %")
                        .font(.system(size: max(12, size * 0.27), weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(contentColor.opacity(info.isStale ? 0.48 : 0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    // Keeps every column the same height as the reference card.
                    Text("0 %")
                        .font(.system(size: max(12, size * 0.27), weight: .medium, design: .rounded))
                        .hidden()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// The ring content follows the system appearance explicitly. This matters
    /// in widgets, where the glass material can look much brighter than the
    /// surrounding wallpaper.
    private var contentColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var trackColors: [Color] {
        if colorScheme == .dark {
            return [Color.white.opacity(0.20), Color.white.opacity(0.11)]
        }
        return [Color.black.opacity(0.18), Color.black.opacity(0.08)]
    }

    private var accessibilityText: String {
        guard let info else { return "Пустой слот" }
        return "\(info.deviceType.displayName), \(info.levelPercent) процентов\(info.isStale ? ", данные устарели" : "")"
    }
}

/// The arc uses butt ends; the rounded end is drawn as a separate cap so the
/// bright tip can visibly sit on top of the dark start at 100 %. The gradient
/// itself is applied by the caller with `AngularGradient`; using a `Shape`
/// instead of a `Canvas` keeps the ring circular in the live renderer.
private struct BatteryRingProgressArc: Shape {
    let level: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let start = Angle.degrees(-90)
        let end = start + .degrees(360 * min(max(level, 0.001), 1))

        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: start,
            endAngle: end,
            clockwise: false
        )
        return path
    }
}

/// A round cap at 12 o'clock. The right half sits under the progress arc;
/// the left half rounds the 0 % end so the track doesn't end with a hard cut.
/// A full circle is used instead of a semicircle because the latter can be
/// clipped or covered at the start of the arc.
private struct BatteryRingStartCap: Shape {
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let tip = CGPoint(x: center.x, y: center.y - radius)
        let capRadius = lineWidth / 2

        return Path(ellipseIn: CGRect(
            x: tip.x - capRadius,
            y: tip.y - capRadius,
            width: capRadius * 2,
            height: capRadius * 2
        ))
    }
}

/// A semi-circular cap that continues the stroke past its end. Unlike a full
/// circle it only rounds the tip; at 100 % the small rounded end sits on top of
/// the dark beginning of the ring. The soft shadow helps the two ends meet
/// without a hard seam.
private struct BatteryRingTipCap: Shape {
    let level: Double
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let end = -90.0 + 360.0 * min(max(level, 0.001), 1.0)
        let tip = CGPoint(
            x: center.x + cos(end * .pi / 180) * radius,
            y: center.y + sin(end * .pi / 180) * radius
        )

        let capRadius = lineWidth / 2
        let radial = Angle.degrees(end)

        var path = Path()
        path.move(to: CGPoint(
            x: tip.x + cos(radial.radians) * capRadius,
            y: tip.y + sin(radial.radians) * capRadius
        ))
        path.addArc(
            center: tip,
            radius: capRadius,
            startAngle: radial,
            endAngle: radial + .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// A dynamic row of every connected device, in the same order the system
/// Batteries widget uses: Mac, headphones, iPhone, Watch, other. Empty slots
/// are omitted, so two devices produce two centred columns rather than a row
/// with holes.
public struct BatteryRingPanel: View {
    public let devices: [DeviceBatteryInfo]
    public let ringSize: CGFloat
    public let localID: String?

    public init(devices: [DeviceBatteryInfo], ringSize: CGFloat = 54, localID: String? = nil) {
        self.devices = devices
        self.ringSize = ringSize
        self.localID = localID
    }

    public var body: some View {
        HStack(alignment: .top, spacing: columnSpacing) {
            ForEach(columns, id: \.id) { info in
                BatteryRingView(
                    info: info,
                    size: effectiveRingSize,
                    lineWidth: max(5, effectiveRingSize * 0.11)
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var columns: [DeviceBatteryInfo] {
        Self.orderedDevices(from: devices, localID: localID)
    }

    /// One latest device per type, in the same order the system Batteries
    /// widget uses. The local device wins if several records share its type,
    /// which protects against stale IDs left by older builds.
    public static func orderedDevices(
        from devices: [DeviceBatteryInfo],
        localID: String?
    ) -> [DeviceBatteryInfo] {
        let ordered = DeviceType.allCases
            .sorted { $0.widgetOrder < $1.widgetOrder }
            .compactMap { type in
                let matches = devices
                    .filter { $0.deviceType == type && $0.isWidgetVisible }
                    .sorted { $0.timestamp > $1.timestamp }

                if let localID, let local = matches.first(where: { $0.id == localID }) {
                    return local
                }
                return matches.first
            }

        // The system widget puts the current device first (iPhone on iPhone,
        // Mac on Mac) and then the other device types in order.
        guard let localID,
              let local = ordered.first(where: { $0.id == localID })
        else { return ordered }
        return [local] + ordered.filter { $0.id != local.id }
    }

    /// Five device types can be present at once. Keep the row inside a medium
    /// widget by making those rings a little smaller; the normal three-device
    /// case keeps the reference size.
    private var effectiveRingSize: CGFloat {
        columns.count >= 5 ? ringSize * 0.84 : ringSize
    }

    private var columnSpacing: CGFloat {
        columns.count >= 5 ? 6 : 8
    }
}

/// The medium Batteries widget always keeps four columns. Devices occupy the
/// first slots; unused slots stay as empty tracks, exactly like the compact
/// 2×2 grid. The app and menu-bar popover keep using the dynamic panel above.
public struct BatteryMediumRingRow: View {
    public let devices: [DeviceBatteryInfo]
    public let localID: String?
    public let ringSize: CGFloat

    public init(
        devices: [DeviceBatteryInfo],
        localID: String? = nil,
        ringSize: CGFloat = 64
    ) {
        self.devices = devices
        self.localID = localID
        self.ringSize = ringSize
    }

    public var body: some View {
        let ordered = BatteryRingPanel.orderedDevices(from: devices, localID: localID)
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<4, id: \.self) { index in
                BatteryRingView(
                    info: index < ordered.count ? ordered[index] : nil,
                    size: ringSize,
                    lineWidth: max(5, ringSize * 0.09)
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The system Batteries small widget uses a fixed 2×2 grid: known devices
/// fill the first slots and any unused slots remain as empty tracks. Unlike
/// the medium row, the small family has no percentage labels.
public struct BatterySmallRingGrid: View {
    public let devices: [DeviceBatteryInfo]
    public let localID: String?
    public let maxRingSize: CGFloat
    public let ringSizeFraction: CGFloat

    public init(
        devices: [DeviceBatteryInfo],
        localID: String? = nil,
        maxRingSize: CGFloat = 64,
        ringSizeFraction: CGFloat = 0.38
    ) {
        self.devices = devices
        self.localID = localID
        self.maxRingSize = maxRingSize
        self.ringSizeFraction = ringSizeFraction
    }

    public var body: some View {
        GeometryReader { geo in
            let shortestSide = min(geo.size.width, geo.size.height)
            // The system small widget leaves more air around the four rings
            // than the medium widget does. These proportions reproduce its
            // 2×2 composition instead of stretching the rings into the corners.
            let ringSize = min(maxRingSize, shortestSide * ringSizeFraction)
            let spacing = shortestSide * 0.08
            let lineWidth = max(5, ringSize * 0.09)

            VStack(spacing: spacing) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            BatteryRingView(
                                info: slot(at: index),
                                size: ringSize,
                                lineWidth: lineWidth,
                                showsLabel: false
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var orderedDevices: [DeviceBatteryInfo] {
        BatteryRingPanel.orderedDevices(from: devices, localID: localID)
    }

    private func slot(at index: Int) -> DeviceBatteryInfo? {
        guard index < orderedDevices.count else { return nil }
        return orderedDevices[index]
    }
}

/// The large Batteries widget is a vertical list. Unlike the small grid it is
/// not capped at four slots, so every known device is listed with its name,
/// charge and a small battery indicator.
public struct BatteryLargeDeviceList: View {
    public let devices: [DeviceBatteryInfo]
    public let localID: String?

    @Environment(\.colorScheme) private var colorScheme

    public init(devices: [DeviceBatteryInfo], localID: String? = nil) {
        self.devices = devices
        self.localID = localID
    }

    public var body: some View {
        let rows = listedDevices
        let slotCount = max(6, rows.count)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<slotCount, id: \.self) { index in
                if index < rows.count {
                    BatteryLargeDeviceRow(info: rows[index], color: contentColor)
                        .frame(height: 56, alignment: .leading)
                } else {
                    Color.clear.frame(height: 56)
                }

                if index < slotCount - 1 {
                    Rectangle()
                        .fill(contentColor.opacity(0.09))
                        .frame(height: 1)
                        .padding(.leading, 34)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var contentColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var listedDevices: [DeviceBatteryInfo] {
        var byID: [String: DeviceBatteryInfo] = [:]
        for device in devices where device.isWidgetVisible {
            if let old = byID[device.id], old.timestamp >= device.timestamp {
                continue
            }
            byID[device.id] = device
        }

        return byID.values.sorted { lhs, rhs in
            if lhs.id == localID, rhs.id != localID { return true }
            if rhs.id == localID, lhs.id != localID { return false }
            if lhs.deviceType.widgetOrder != rhs.deviceType.widgetOrder {
                return lhs.deviceType.widgetOrder < rhs.deviceType.widgetOrder
            }
            return lhs.timestamp > rhs.timestamp
        }
    }
}

private struct BatteryLargeDeviceRow: View {
    let info: DeviceBatteryInfo
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: info.deviceType.systemImageName)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(color.opacity(info.isStale ? 0.5 : 0.9))
                .frame(width: 24)

            Text(info.deviceName)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(color.opacity(info.isStale ? 0.48 : 0.92))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text("\(info.levelPercent) %")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color.opacity(info.isStale ? 0.48 : 0.92))
                    .lineLimit(1)

                BatteryLargeBatteryGlyph(
                    level: info.batteryLevel,
                    isCharging: info.batteryState.isCharging,
                    color: color.opacity(info.isStale ? 0.5 : 1)
                )
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(info.deviceType.displayName), \(info.levelPercent) процентов\(info.isStale ? ", данные устарели" : "")"
        )
    }
}

private struct BatteryLargeBatteryGlyph: View {
    let level: Double
    let isCharging: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(color.opacity(0.45), lineWidth: 1.1)

                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(BatteryColors.ringGradient(for: level))
                    .frame(width: max(0, 18 * min(max(level, 0), 1)), height: 7)
                    .padding(.leading, 2)

                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 22, height: 11)

            Capsule()
                .fill(color.opacity(0.45))
                .frame(width: 2, height: 5)
        }
    }
}

// MARK: - Glass Surfaces

public struct BatteryGlassBackground: View {
    public let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(cornerRadius: CGFloat = 28) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark

        ZStack {
            shape.fill(isDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.regularMaterial))

            // Neutral tint. The blue in the reference is the wallpaper
            // underneath, not a blue fill. The dark base is deliberately
            // strong: WidgetKit can render Material much brighter than an
            // AppKit preview, and a weak tint turns pale over a bright sky.
            shape.fill(
                LinearGradient(
                    colors: isDark
                        ? [Color.black.opacity(0.42), Color.black.opacity(0.58)]
                        : [Color.white.opacity(0.14), Color.white.opacity(0.28)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )

            RadialGradient(
                colors: [Color.white.opacity(isDark ? 0.10 : 0.34), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 260
            )
            .clipShape(shape)

            LinearGradient(
                colors: [.clear, Color.black.opacity(isDark ? 0.16 : 0.07)],
                startPoint: .top, endPoint: .bottom
            )
            .clipShape(shape)
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: isDark
                        ? [Color.white.opacity(0.22), Color.white.opacity(0.035)]
                        : [Color.white.opacity(0.85), Color.black.opacity(0.07)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
    }
}

/// Background used inside WidgetKit's containerBackground. It fills the
/// system-provided widget shape, so it also works on the macOS widget surface.
public struct BatteryWidgetBackground: View {
    public init() {}

    public var body: some View {
        Color.clear
    }
}

public struct BatteryGlassCard<Content: View>: View {
    public let cornerRadius: CGFloat
    public let padding: CGFloat
    @ViewBuilder public let content: Content
    @Environment(\.colorScheme) private var colorScheme

    public init(
        cornerRadius: CGFloat = 28,
        padding: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .background {
                BatteryGlassBackground(cornerRadius: cornerRadius)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color.white.opacity(0.22), Color.white.opacity(0.035)]
                                : [Color.white.opacity(0.9), Color.black.opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .glassEffect(
                .regular.tint(colorScheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.16)),
                in: .rect(cornerRadius: cornerRadius)
            )
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.35 : 0.16),
                radius: 24,
                y: 14
            )
    }
}

/// A deliberately transparent wrapper for content shown inside a system glass
/// surface, such as the macOS menu-bar panel. Drawing another card here made
/// the menu look like a light square with rings inside it.
public struct BatteryNestedGlassCard<Content: View>: View {
    public let cornerRadius: CGFloat
    public let padding: CGFloat
    @ViewBuilder public let content: Content

    public init(
        cornerRadius: CGFloat = 24,
        padding: CGFloat = 16,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
    }
}
