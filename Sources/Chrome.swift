import AppKit
import SwiftUI

/// 效果图里反复出现的控件。各页只用这些，不再各画一套。
/// 数值对着 docs/design/mockups/2026-11-09-main-window.html。

/// 白底圆角卡。圆角 10，0.5 磅 hairline，内边距 14 / 16。
struct PageCard<Content: View>: View {
    var minHeight: CGFloat? = nil
    var padding = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
    var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
    }
}

/// 下拉框右边的箭头。和「设置」同一支 KIcon.chevD，10 磅。
/// 系统 Menu 自己也会画一个，所以语言选择不用系统 Menu。
struct ChromeChevron: View {
    var color: Color = Color.secondary

    var body: some View {
        KIconView(.chevD, size: 10)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// 返回箭头。文件面板和设置侧栏同一支 KIcon.chevL，10 磅。颜色跟着外面走。
struct BackChevron: View {
    var body: some View {
        KIconView(.chevL, size: 10)
    }
}

/// 文字下拉的标签：文字后面跟设置箭头，并藏掉系统 Menu 自己画的那个。
/// 图标按钮（加号、省略号、三点）不是下拉框，不要用这个。
struct MenuLabel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 4) {
            content()
            ChromeChevron()
        }
    }
}

extension View {
    /// 无边按钮样式的菜单，只留自绘箭头。配 `MenuLabel` 用。
    func menuChevron() -> some View {
        menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// 白底菜单。高 24、圆角 6、0.5 磅边（黑 14%）、12 磅字，右边只有一个设置箭头。
/// 语言这类长列表超过一屏就在框里滚，滚动条一直在。短菜单仍按内容收高，不留空槽。
struct MenuChip<Option: Hashable>: View {
    var title: String
    var options: [Option]
    var label: (Option) -> String
    var isSelected: (Option) -> Bool
    var select: (Option) -> Void
    /// 标题左边的小图标。没有就只显示文字。
    var icon: AnyView? = nil

    @State private var open = false
    @State private var hover = false
    @State private var menuSize: CGSize = .zero

    /// 大约 12 行。再高就盖住浮层，下面的语言也够不着。
    private var menuMaxHeight: CGFloat { 320 }
    /// 防止某次量出来的宽是无穷（行里的 Spacer），把浮层撑满屏。
    private var menuMaxWidth: CGFloat { 420 }

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 5) {
                if let icon { icon }
                Text(title)
                    .font(Theme.TypeScale.label)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                ChromeChevron()
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.04) : Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .strokeBorder(hover ? Color.black.opacity(0.2) : Theme.chipStroke, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 0.5, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .fixedSize()
        .disabled(options.isEmpty)
        .popover(isPresented: $open, arrowEdge: .top) {
            menuList
        }
    }

    private var menuList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            select(option)
                            open = false
                        } label: {
                            HStack(spacing: 6) {
                                KIconView(.check, size: 11)
                                    .foregroundStyle(isSelected(option) ? Color.primary : Color.clear)
                                    .frame(width: 12)
                                Text(label(option))
                                    .font(Theme.TypeScale.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 12)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(option)
                    }
                }
                .padding(5)
                .frame(minWidth: 160, alignment: .leading)
                .fixedSize(horizontal: true, vertical: true)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: MenuListSize.self, value: geo.size)
                    }
                }
                .background(alignment: .center) { MenuScrollAnchor(pinned: menuOverflows) }
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.visible, axes: .vertical)
            .scrollIndicators(.hidden, axes: .horizontal)
            .scrollBounceBehavior(.basedOnSize)
            .onAppear {
                guard let selected = options.first(where: isSelected) else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
        }
        .onPreferenceChange(MenuListSize.self) { menuSize = $0 }
        .frame(width: menuWidth, height: menuHeight)
    }

    private var contentHeight: CGFloat {
        menuSize.height > 1 ? menuSize.height : estimatedHeight
    }

    private var menuHeight: CGFloat {
        min(contentHeight, menuMaxHeight)
    }

    private var menuOverflows: Bool {
        contentHeight > menuMaxHeight + 1
    }

    /// 滚动条占一条宽度。不加这一条，最长的语言名会被挤掉字。
    private var menuWidth: CGFloat? {
        guard menuSize.width > 1 else { return nil }
        let raw = min(menuSize.width, menuMaxWidth)
        guard menuOverflows else { return raw }
        return raw + NSScroller.scrollerWidth(for: .mini, scrollerStyle: .legacy)
    }

    /// 第一帧还没量到。一行大约 25，行距 1，上下内边距 10。
    private var estimatedHeight: CGFloat {
        let rows = CGFloat(max(options.count, 1))
        return rows * 25 + (rows - 1) + 10
    }
}

private struct MenuListSize: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

/// 和 MenuChip 同高同边。左边 13 磅图标，次要色。primary 是强调色底、白字、无边。
struct PageButton: View {
    var title: String
    var systemImage: String? = nil
    var icon: KIcon? = nil
    var primary = false
    var action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    KIconView(icon, size: 13)
                        .foregroundStyle(primary ? Color.white : Color.secondary)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(Theme.TypeScale.glyph)
                        .foregroundStyle(primary ? Color.white : Color.secondary)
                }
                Text(title)
                    .font(primary ? Theme.TypeScale.labelMedium : Theme.TypeScale.label)
                    .foregroundStyle(primary ? Color.white : Color.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, primary ? 16 : 10)
            .frame(height: primary ? 28 : 24)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(primary ? Theme.accent : (hover ? Color.primary.opacity(0.04) : Theme.cardFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .strokeBorder(primary ? Color.clear : (hover ? Color.black.opacity(0.2) : Theme.chipStroke), lineWidth: 0.5)
            )
            .shadow(color: primary ? Color.clear : Color.black.opacity(0.04), radius: 0.5, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .fixedSize()
    }
}

/// 缺权限时内容区顶部的一条。圆角 8、橙 12% 底、6 磅橙点、12 磅字。
struct PermissionBanner: View {
    var text: String
    var authorize: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.attention)
                .frame(width: 6, height: 6)
            Text(text)
                .font(Theme.TypeScale.label)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(L("去授权"), action: authorize)
                .buttonStyle(.plain)
                .font(Theme.TypeScale.labelMedium)
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                .fill(Theme.attention.opacity(0.12))
        )
    }
}

/// 设置页度量。对着 docs/design/mockups/2026-11-09-main-window.html。
enum SettingsChrome {
    static let controlWidth: CGFloat = 300
    static let rowMinHeight: CGFloat = 38
    /// 填写块左缩进：和行标题文字同一列（图标之后）。
    static let expandLeading: CGFloat = 36
    static let expandTrailing: CGFloat = 14
}

/// 一节一张白卡。节名 11 磅半粗、三级色。行最小高 38，内边距 7 / 14，行间 0.5 磅细线。
struct SettingsGroup<Content: View>: View {
    var title: String
    var content: Content

    init(title: String, content: Content) {
        self.title = title
        self.content = content
    }

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(Theme.TypeScale.captionSemibold)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
    }
}

/// 设置行。标签左对齐，控件贴右。说明写在标签下面。
struct SettingsRow<Control: View>: View {
    var title: String
    var detail: String? = nil
    var showsDivider = true
    var control: Control

    init(
        title: String,
        detail: String? = nil,
        showsDivider: Bool = true,
        control: Control
    ) {
        self.title = title
        self.detail = detail
        self.showsDivider = showsDivider
        self.control = control
    }

    init(
        title: String,
        detail: String? = nil,
        showsDivider: Bool = true,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.showsDivider = showsDivider
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(.primary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
        }
    }
}

/// 侧栏一项。圆角 6、内边距 5 / 9、13 磅。选中是黑 8% 底、字重 medium。
struct SidebarRow: View {
    var title: String
    var systemImage: String? = nil
    var icon: KIcon? = nil
    var selected: Bool
    var badge = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    KIconView(icon, size: 15)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 15, height: 15)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(Theme.TypeScale.sidebarIcon)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 15, height: 15)
                }
                Text(title)
                    .font(Theme.TypeScale.body)
                    .fontWeight(selected ? .medium : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if badge {
                    Circle()
                        .fill(Theme.live)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(L("正在听"))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.08) : (hover ? Color.primary.opacity(0.04) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 「更多」、「高级」这种分组。11 磅半粗、三级色。
struct SidebarGroupLabel: View {
    var title: String

    var body: some View {
        Text(title)
            .font(Theme.TypeScale.captionSemibold)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

/// 翻译浮层的材质。圆角 14、regularMaterial、0.5 磅边、阴影黑 18% 半径 12 y 4。
extension View {
    func floatingPanel(radius: CGFloat = Theme.panelRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            shape.fill(.regularMaterial)
                .overlay { shape.fill(Theme.panelMat.opacity(Theme.panelMatCover)) }
        }
            .overlay { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
            .clipShape(shape)
            .shadow(color: Theme.panelShadow, radius: Theme.panelShadowRadius, y: Theme.panelShadowY)
    }
}
