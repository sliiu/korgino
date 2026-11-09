import AppKit
import SwiftUI

/// 主窗口里的一页。侧栏顺序就是这个枚举的顺序。
enum MainPage: String, CaseIterable, Identifiable {
    case translate
    case live
    case history
    case dictionary
    case media
    case voice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translate: return L("翻译")
        case .live: return L("实时与会议")
        case .history: return L("历史")
        case .dictionary: return L("词典")
        case .media: return L("媒体字幕")
        case .voice: return L("语音")
        }
    }

    var symbol: String {
        switch self {
        case .translate: return "character.bubble"
        case .live: return "waveform"
        case .history: return "clock"
        case .dictionary: return "text.book.closed"
        case .media: return "film"
        case .voice: return "mic"
        }
    }

    /// 「更多」下面的三项。功能在设置里关掉时侧栏不显示。
    var isMore: Bool {
        switch self {
        case .dictionary, .media, .voice: return true
        case .translate, .live, .history: return false
        }
    }

    /// 对应的功能开关。没有开关的页一直在。
    var feature: HotkeyAction? {
        switch self {
        case .dictionary: return .dictionary
        case .media: return .mediaCaptions
        case .voice: return nil
        case .translate, .live, .history: return nil
        }
    }

    func isShown(in config: AppConfig) -> Bool {
        switch self {
        case .voice: return config.dictateEnabled
        case .dictionary, .media:
            guard let feature else { return true }
            return config.isFeatureEnabled(feature)
        case .translate, .live, .history:
            return true
        }
    }
}

/// 主窗口：侧栏切换各页，记住大小和上次所在页。
/// 关掉它不退出；实时字幕在听时继续听，沉浸字幕和菜单栏图标都不跟着走。
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?
    let model = MainWindowModel()

    func show(page: MainPage? = nil) {
        if let page {
            model.page = page
        }
        if window == nil {
            let root = MainWindowView(model: model)
                .environmentObject(AppConfig.shared)
            let host = NSHostingController(rootView: root)
            let w = NSWindow(contentViewController: host)
            w.title = "Korgino"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 900, height: 620))
            w.minSize = NSSize(width: 760, height: 520)
            w.setFrameAutosaveName("KorginoMain")
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func relocalize() {
        model.epoch += 1
    }
}

@MainActor
final class MainWindowModel: ObservableObject {
    @Published var page: MainPage {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: Self.pageKey) }
    }
    /// 界面语言变了就加一，好让已经算出的文案重画。
    @Published var epoch = 0

    private static let pageKey = "mainWindow.page"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.pageKey),
           let saved = MainPage(rawValue: raw) {
            page = saved
        } else {
            page = .translate
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var model: MainWindowModel
    @EnvironmentObject private var config: AppConfig
    @ObservedObject private var live = SystemAudioTranslateController.shared

    private var listening: Bool {
        if case .listening = live.state { return true }
        return false
    }

    var body: some View {
        let _ = config.appLanguage
        let _ = model.epoch
        NavigationSplitView {
            sidebar
        } detail: {
            page(model.page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: config.featureEnabled) { _, _ in keepPageVisible() }
        .onChange(of: config.dictateEnabled) { _, _ in keepPageVisible() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.page) {
                ForEach(primary) { page in
                    row(page)
                }
                if !more.isEmpty {
                    Section(L("更多")) {
                        ForEach(more) { page in
                            row(page)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            Button {
                PreferencesController.shared.show()
            } label: {
                Label(L("设置"), systemImage: "gearshape")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    private func row(_ page: MainPage) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(page.title)
                if page == .live, listening {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel(L("正在听"))
                }
            }
        } icon: {
            Image(systemName: page.symbol)
        }
        .font(.body)
        .tag(page)
    }

    private var primary: [MainPage] {
        MainPage.allCases.filter { !$0.isMore && $0.isShown(in: config) }
    }

    private var more: [MainPage] {
        MainPage.allCases.filter { $0.isMore && $0.isShown(in: config) }
    }

    @ViewBuilder
    private func page(_ page: MainPage) -> some View {
        switch page {
        case .translate:
            TranslatePage()
        case .live:
            LiveMeetingPage()
        case .history:
            HistoryFavoritesView(model: HistoryController.shared.model)
        case .dictionary:
            DictionaryView(model: DictionaryController.shared)
        case .media:
            MediaCaptionsPage()
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { CaptionBudget.note("media", geo.size.width) }
                            .onChange(of: geo.size.width) { _, width in
                                CaptionBudget.note("media", width)
                            }
                    }
                }
        case .voice:
            VoicePage()
        }
    }

    /// 当前页被关掉时回到翻译页，免得侧栏空着、内容还停在看不见的页上。
    private func keepPageVisible() {
        guard !model.page.isShown(in: config) else { return }
        model.page = .translate
    }
}

/// 媒体字幕嵌进主窗口后，宽度从这一页量，不再从独立窗口量。
private struct MediaCaptionsPage: View {
    @ObservedObject private var model = MediaCaptionsController.shared
    @EnvironmentObject private var config: AppConfig

    var body: some View {
        let _ = config.appLanguage
        MediaCaptionsView(model: model)
    }
}

/// 翻译页的占位。完整的输入、自动翻译和文档视图是后续任务。
private struct TranslatePage: View {
    @EnvironmentObject private var config: AppConfig
    @State private var draft = ""

    var body: some View {
        let _ = config.appLanguage
        VStack(alignment: .leading, spacing: 16) {
            Text(L("翻译"))
                .font(.title2)
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 240)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(L("原文"))
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Button(L("剪贴板")) {
                    AppDelegate.shared?.translateClipboard()
                }
                .disabled(!config.isFeatureEnabled(.clipboard))
                Button(L("截图")) {
                    AppDelegate.shared?.ocrTranslate()
                }
                .disabled(!config.isFeatureEnabled(.ocr))
                Button(L("文档")) {
                    AppDelegate.shared?.fileTranslate()
                }
                .disabled(!config.isFeatureEnabled(.file))
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 实时字幕和会议记录收在同一页。听的状态在控制器上，离开这一页不会停。
private struct LiveMeetingPage: View {
    @EnvironmentObject private var config: AppConfig
    @ObservedObject private var live = SystemAudioTranslateController.shared

    var body: some View {
        let _ = config.appLanguage
        VStack(spacing: 0) {
            SystemAudioTranslateView(model: live)
                .environmentObject(config)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            MeetingRecordsView(model: MeetingRecordsController.shared.model)
                .environmentObject(config)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { CaptionBudget.note("live", geo.size.width) }
                    .onChange(of: geo.size.width) { _, width in
                        CaptionBudget.note("live", width)
                    }
            }
        }
    }
}

/// 语音还没有自己的页。这里只说明三种模式，并打开设置里现有的语音部分。
private struct VoicePage: View {
    @EnvironmentObject private var config: AppConfig

    var body: some View {
        let _ = config.appLanguage
        VStack(alignment: .leading, spacing: 12) {
            Text(L("语音"))
                .font(.title2)
            Text(L("按住 Fn 走当前这一条：语音识别、语音翻译或语音传译。快捷键只切换模式，不开始听。"))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("打开语音设置")) {
                PreferencesController.shared.showVoice()
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
