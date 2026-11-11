import AppKit
import SwiftUI

enum Theme {
    /// 翻译浮层的圆角。效果图是 14，不是之前的 16。
    static let panelRadius: CGFloat = 14
    static let cardRadius: CGFloat = 10
    /// 小控件（按钮、输入框、小块底色）的圆角。别再写 4、5、7、8、9 这些中间值。
    static let smallRadius: CGFloat = 6
    /// 高度一两磅的细条，圆角跟着高度走。
    static let hairRadius: CGFloat = 2
    /// 白卡描边。主色 8%。
    static let hairline = Color.primary.opacity(0.08)
    /// 菜单和页按钮的边。黑 14%。
    static let chipStroke = Color.black.opacity(0.14)
    /// 侧栏底。效果图 #ECECEF。
    static let sidebarFill = Color(nsColor: dynamic(light: 0xECECEF, dark: 0x242428))
    static let sidebarWidth: CGFloat = 180
    /// 浮层阴影：黑 18%，半径 12，y 4。
    static let panelShadow = Color.black.opacity(0.18)
    static let panelShadowRadius: CGFloat = 12
    static let panelShadowY: CGFloat = 4
    /// 浮层罩色。效果图 `--mat` 盖在 regularMaterial 上，少透一点。
    /// 浅色 #FAFAFC；深色用抬一点的面板色，避免整块发灰发白。
    static let panelMat = Color(nsColor: dynamic(light: 0xFAFAFC, dark: 0x2C2C31))
    /// 罩色盖住的比例。效果图是 82%，底下仍能透出一点模糊。
    static let panelMatCover: Double = 0.82
    static let cardFill = Color(nsColor: dynamic(light: 0xFFFFFF, dark: 0x2A2A2F))
    static let wellFill = Color.primary.opacity(0.045)
    /// 设置填写块底。效果图黑 1.8%。
    static let expandFill = Color.primary.opacity(0.018)
    static let windowFill = Color(nsColor: dynamic(light: 0xF4F4F6, dark: 0x1C1C20))

    /// 七档字号。全应用用 `.font(Theme.TypeScale.reading)` 这种写法，不再直接写 `.system(size:)`。
    /// 名字是 TypeScale 而不是 Type：Type 是 Swift 关键字，写出来的 .system(size: 会被构建检查拦住。
    enum TypeScale {
        static let display = Font.system(size: 28, weight: .semibold)
        static let title = Font.system(size: 17, weight: .semibold)
        static let reading = Font.system(size: 15, weight: .medium)
        static let body = Font.system(size: 13, weight: .regular)
        static let label = Font.system(size: 12, weight: .regular)
        static let labelMedium = Font.system(size: 12, weight: .medium)
        static let caption = Font.system(size: 11, weight: .regular)
        static let captionSemibold = Font.system(size: 11, weight: .semibold)
        static let micro = Font.system(size: 10, weight: .medium)
        /// 页按钮左边的图标。13 磅，次要色。
        static let glyph = Font.system(size: 13, weight: .regular)
        /// 侧栏图标。15 磅，强调色。
        static let sidebarIcon = Font.system(size: 15, weight: .regular)
        /// 沉浸字幕原文。15 磅不在七档里，只给这一处。
        static let displaySource = Font.system(size: 15, weight: .medium)

        /// AppKit 量字用。对应上面同名的 SwiftUI 字体。
        static let nsDisplay = NSFont.systemFont(ofSize: 28, weight: .semibold)
        static let nsTitle = NSFont.systemFont(ofSize: 17, weight: .semibold)
        static let nsReading = NSFont.systemFont(ofSize: 15, weight: .medium)
        static let nsBody = NSFont.systemFont(ofSize: 13, weight: .regular)
        static let nsBodyMedium = NSFont.systemFont(ofSize: 13, weight: .medium)
        static let nsLabel = NSFont.systemFont(ofSize: 12, weight: .regular)
        static let nsLabelMono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        static let nsLabelMedium = NSFont.systemFont(ofSize: 12, weight: .medium)
        static let nsCaption = NSFont.systemFont(ofSize: 11, weight: .regular)
        static let nsCaptionMedium = NSFont.systemFont(ofSize: 11, weight: .medium)
        static let nsMicro = NSFont.systemFont(ofSize: 10, weight: .medium)
        static let nsMicroSemibold = NSFont.systemFont(ofSize: 10, weight: .semibold)
    }

    /// 语义色。失败用 danger，缺东西用 attention，成功用 ok，正在听或录只给点用 live。
    static let accent = Color.accentColor
    static let danger = Color.red
    static let attention = Color.orange
    static let ok = Color.green
    static let live = Color.red

    /// 深色底上的白字，只三档：100%、70%、45%。
    enum onDark {
        static let primary = Color.white
        static let secondary = Color.white.opacity(0.7)
        static let tertiary = Color.white.opacity(0.45)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

extension View {
    func card(fill: Color = Theme.cardFill, radius: CGFloat = Theme.cardRadius, stroke: Bool = true) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(stroke ? Theme.hairline : .clear, lineWidth: 0.5)
            )
    }

    func well(radius: CGFloat = Theme.cardRadius) -> some View {
        card(fill: Theme.wellFill, radius: radius, stroke: false)
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(Theme.TypeScale.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt: String
    var fontSize: CGFloat = 13
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            KIconView(.search, size: fontSize >= 14 ? 13 : 12)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(fontSize >= 14 ? Theme.TypeScale.reading : (fontSize >= 13 ? Theme.TypeScale.body : Theme.TypeScale.label))
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    KIconView(.clear, size: 13).foregroundStyle(.tertiary)
                }
                .buttonStyle(HoverPlateButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, fontSize * 0.45)
        .well(radius: 8)
    }
}

/// Borderless icon button with a soft hover plate. 自绘图标（icon）是 22×22，次要色，悬停变实；
/// SF Symbol 版本保持原样。
struct IconButton: View {
    var systemImage: String = ""
    var icon: KIcon? = nil
    var help: String = ""
    var tint: Color? = nil
    var size: CGFloat = 12
    let action: () -> Void

    init(systemImage: String, help: String = "", tint: Color? = nil, size: CGFloat = 12, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.tint = tint
        self.size = size
        self.action = action
    }

    init(icon: KIcon, help: String = "", tint: Color? = nil, size: CGFloat = 12, action: @escaping () -> Void) {
        self.icon = icon
        self.help = help
        self.tint = tint
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let icon {
                IconGlyph(icon: icon, tint: tint)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            } else {
                Image(systemName: systemImage)
                    .font(size >= 13 ? Theme.TypeScale.body : (size >= 12 ? Theme.TypeScale.labelMedium : Theme.TypeScale.caption))
                    .foregroundStyle(tint ?? Color.secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(HoverPlateButtonStyle())
        .help(help)
        .accessibilityLabel(help.isEmpty ? Text(icon?.rawValue ?? systemImage) : Text(help))
    }

    /// 13 磅自绘图标：默认次要色，悬停变实（primary）。
    private struct IconGlyph: View {
        let icon: KIcon
        let tint: Color?
        @Environment(\.hoverPlateHovering) private var hovering

        var body: some View {
            KIconView(icon, size: 13)
                .foregroundStyle(tint ?? (hovering ? Color.primary : Color.secondary))
        }
    }
}

private struct HoverPlateHoveringKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var hoverPlateHovering: Bool {
        get { self[HoverPlateHoveringKey.self] }
        set { self[HoverPlateHoveringKey.self] = newValue }
    }
}

struct HoverPlateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverPlate(pressed: configuration.isPressed) { configuration.label }
    }

    private struct HoverPlate<Label: View>: View {
        let pressed: Bool
        @ViewBuilder let label: () -> Label
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            label()
                .environment(\.hoverPlateHovering, hovering && enabled)
                .opacity(enabled ? 1 : 0.4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                        .fill(Color.primary.opacity(pressed ? 0.14 : (hovering && enabled ? 0.07 : 0)))
                )
                .onHover { hovering = $0 }
        }
    }
}

/// Native small switch; keeps Form row layout (label left, control right).
struct SegmentedToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        } label: {
            configuration.label
        }
    }
}

/// 等待中的一行：小转圈 + 一句话。翻译、识别、加载都走这一个，别再各画各的。
struct LoadingLine: View {
    var text: String = L("翻译中…")
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(Theme.TypeScale.label)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text))
    }
}

/// 空页面：图标 + 一句标题 + 一句说明。整页没有内容时用这个，纯一段灰字只在格子、行里用。
struct EmptyState<Footer: View>: View {
    let icon: String
    let title: String
    var detail: String?
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(Theme.TypeScale.display)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(Theme.TypeScale.body)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(detail.map { "\(title)，\($0)" } ?? title))
    }
}

extension EmptyState where Footer == EmptyView {
    init(icon: String, title: String, detail: String? = nil) {
        self.init(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}

/// Gray track with a sliding white thumb.
struct PillSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var fontSize: CGFloat = 11
    @Namespace private var ns
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let (value, title) = options[i]
                let selected = value == selection
                Button {
                    selection = value
                } label: {
                    Text(title)
                        .font(fontSize >= 12 ? Theme.TypeScale.label : Theme.TypeScale.caption)
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, fontSize + 1)
                        .padding(.vertical, fontSize * 0.3)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                                    .fill(Theme.cardFill)
                                    .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous).fill(Color.primary.opacity(0.07)))
        .opacity(enabled ? 1 : 0.45)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: selection)
        .fixedSize()
    }
}

/// Leading check circle; the whole label is the hit target. For enable/disable lists.
struct CheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        CheckRow(configuration: configuration)
    }

    private struct CheckRow: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: 8) {
                    ShortcutCheck(on: configuration.isOn)
                    configuration.label
                        .foregroundStyle(Color.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.45)
        }
    }
}

/// 效果图里的勾选：14 磅圆角方框，勾上是强调色底、白勾。
struct ShortcutCheck: View {
    var on: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                .fill(on ? Color.accentColor : Color.clear)
            RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                .strokeBorder(on ? Color.clear : Color.primary.opacity(0.25), lineWidth: 1)
            if on {
                ShortcutCheckMark()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 14, height: 14)
        .frame(width: 20, height: 24)
        .contentShape(Rectangle())
    }
}

private struct ShortcutCheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - 1))
        path.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.minY + 1))
        return path
    }
}

extension View {
    /// 整行可点，点一下展开或收起。行里的按钮自己先接住点击，不传到行上。
    func rowTapToggle(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    /// 放在可点整行里的控件。控件禁用时，SwiftUI 把点击交给外层手势，
    /// 这里盖一层吃掉点击，免得点灰掉的勾选框却把整行展开。
    func stopsRowTap(when disabled: Bool) -> some View {
        overlay {
            if disabled {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
            }
        }
    }
}

/// Capsule chip used for tabs / provider switches.
/// 工具栏里的主按钮。自己画底色，不靠工具栏给的样式：工具栏不画 borderedProminent 的底，
/// 只剩一行浅灰字，看不出是按钮。
struct ToolbarProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.TypeScale.label)
            .fontWeight(.semibold)
            .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.7))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4))
            )
            .contentShape(Capsule())
    }
}

struct ChipButtonStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.TypeScale.caption)
            .fontWeight(selected ? .semibold : .regular)
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(configuration.isPressed ? 0.1 : 0.05))
            )
            .contentShape(Capsule())
    }
}

/// 状态点：6 磅圆点加次要色文字。只给点上色，字不上色。
enum StatusKind {
    case live, attention, ok, idle

    var color: Color {
        switch self {
        case .live: return Theme.live
        case .attention: return Theme.attention
        case .ok: return Theme.ok
        case .idle: return Color.secondary
        }
    }

    var pulses: Bool { self == .live }
}

struct StatusDot: View {
    var kind: StatusKind
    var text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    init(_ kind: StatusKind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(kind.color)
                .frame(width: 6, height: 6)
                .opacity(kind.pulses && dim && !reduceMotion ? 0.35 : 1)
                .onAppear { dim = kind.pulses }
                .animation(
                    kind.pulses && !reduceMotion ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : nil,
                    value: dim
                )
            Text(text)
                .font(Theme.TypeScale.label)
                .foregroundStyle(.secondary)
        }
    }
}

/// 行内错误：三角标加 12 磅 danger 字。后面可带一个「重试」。
struct ErrorLine: View {
    var text: String
    var lineLimit: Int? = nil
    var onDark = false
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            KIconView(.warn, size: 13)
                .foregroundStyle(Theme.danger)
            Text(text)
                .font(Theme.TypeScale.label)
                .foregroundStyle(onDark ? Theme.onDark.secondary : Theme.danger)
                .textSelection(.enabled)
                .lineLimit(lineLimit)
            if let retry {
                Button(L("重试"), action: retry)
                    .buttonStyle(HoverPlateButtonStyle())
                    .font(Theme.TypeScale.label)
                    .foregroundStyle(onDark ? Theme.onDark.primary : Theme.accent)
            }
        }
        .fixedSize(horizontal: false, vertical: lineLimit == nil)
    }
}

/// 整块失败：居中图标用 danger，说明用 13 磅主要色，不用红字。
struct ErrorBlock: View {
    var text: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            KIconView(.warn, size: 20)
                .foregroundStyle(Theme.danger)
            Text(text)
                .font(Theme.TypeScale.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let retry {
                Button(L("重试"), action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 「未填密钥」：次要色文字，前面一个小橙点。
struct MissingKeyLabel: View {
    var body: some View {
        StatusDot(.attention, L("未填密钥"))
    }
}

/// 一行放不下就折到下一行。设置里的服务列表和文件窗口的页标签都用它。
struct FlowTags: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += (x > 0 ? spacing : 0) + size.width
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0
        var rowHeights: [CGFloat] = [0]
        for (index, size) in sizes.enumerated() {
            if rowWidth > 0, rowWidth + spacing + size.width > bounds.width {
                rows.append([])
                rowWidth = 0
                rowHeights.append(0)
            }
            if rowWidth > 0 { rowWidth += spacing }
            rows[rows.count - 1].append(index)
            rowWidth += size.width
            rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
        }
        var y = bounds.minY
        for (rowIndex, row) in rows.enumerated() {
            var x = bounds.minX
            let rowHeight = rowHeights[rowIndex]
            for index in row {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
