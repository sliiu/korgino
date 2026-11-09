import AppKit
import SwiftUI

enum Theme {
    static let panelRadius: CGFloat = 16
    static let cardRadius: CGFloat = 10
    static let hairline = Color.primary.opacity(0.08)
    static let cardFill = Color(nsColor: dynamic(light: 0xFFFFFF, dark: 0x2A2A2F))
    static let wellFill = Color.primary.opacity(0.045)
    static let windowFill = Color(nsColor: dynamic(light: 0xF4F4F6, dark: 0x1C1C20))

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
            .font(.system(size: 11, weight: .semibold))
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
            Image(systemName: "magnifyingglass")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, fontSize * 0.45)
        .well(radius: 8)
    }
}

/// Borderless SF Symbol button with a soft hover plate.
struct IconButton: View {
    let systemImage: String
    var help: String = ""
    var tint: Color? = nil
    var size: CGFloat = 12
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverPlateButtonStyle())
        .help(help)
        .accessibilityLabel(help.isEmpty ? Text(Image(systemName: systemImage)) : Text(help))
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
                .opacity(enabled ? 1 : 0.4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
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
                        .font(.system(size: fontSize, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, fontSize + 1)
                        .padding(.vertical, fontSize * 0.3)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
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
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
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
                    Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary.opacity(0.5))
                        .contentTransition(.symbolEffect(.replace))
                    configuration.label
                        .foregroundStyle(configuration.isOn ? Color.primary : Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.45)
        }
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
            .font(.system(size: 12, weight: .semibold))
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
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
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

/// 错误：12 磅红字，前面一个三角标。
struct ErrorLine: View {
    var text: String
    var lineLimit: Int? = nil

    var body: some View {
        Label {
            Text(text)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.system(size: 12))
        .foregroundStyle(.red)
        .lineLimit(lineLimit)
        .fixedSize(horizontal: false, vertical: lineLimit == nil)
    }
}

/// 「未填密钥」：次要色文字，前面一个小橙点。
struct MissingKeyLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
            Text(L("未填密钥"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
