import SwiftUI

/// 「分说话人」 in the live window: the voiceprint model when it is installed, the old timbre slider until then.
struct VoiceprintSettingRow: View {
    var threshold: Binding<Double>
    /// 同传这一路说完后，再按本机声纹分一次。默认关，用服务给的说话人。
    var reseparateInterp: Binding<Bool>
    /// Taggers are attached at 开始, so a change shows from the next session.
    var listening: Bool
    @ObservedObject private var model = VoiceprintModel.shared
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.state {
            case .ready:
                HStack(spacing: 8) {
                    Image(systemName: "waveform.badge.person.crop")
                        .foregroundStyle(Color.accentColor)
                    Text(L("按声纹分，在本机运行"))
                        .font(Theme.TypeScale.label)
                    Spacer(minLength: 4)
                    Menu {
                        Button(L("删除声纹模型"), role: .destructive) { model.remove() }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(listening)
                    .accessibilityLabel(Text(L("更多")))
                }
                .help(L("每段说完后按声音认是谁，认错了可以在说话人上改名或并入另一位"))
                Toggle(L("同传也按声纹再分"), isOn: reseparateInterp)
                    .toggleStyle(.checkbox)
                    .font(Theme.TypeScale.label)
                    .help(L("关着时用同传服务标出的说话人。打开后，这一路说完再按本机声纹分一次。"))
            case .downloading(let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(maxWidth: .infinity)
                    Text(String(format: "%d%%", Int((progress * 100).rounded())))
                        .font(Theme.TypeScale.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button(L("取消")) { model.cancel() }
                        .controlSize(.small)
                }
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("正在准备声纹模型"))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                }
            case .absent, .failed:
                slider
                HStack(spacing: 8) {
                    Button(L("用声纹分得更准…")) { asking = true }
                        .buttonStyle(.link)
                        .font(Theme.TypeScale.caption)
                    if case .failed(let message) = model.state {
                        Text(message)
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(Theme.danger)
                            .lineLimit(2)
                    }
                }
            }
            if listening, model.state == .ready {
                Text(L("下次开始时用上"))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .confirmationDialog(L("下载声纹模型？"), isPresented: $asking) {
            Button(L("下载（约 12 MB）")) { model.download() }
            Button(L("从文件导入…")) { importFile() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("按声音分出每个人，比现在只看音高准得多。模型只在本机运行，声音不出电脑。"))
        }
    }

    private var slider: some View {
        HStack(spacing: 8) {
            Text(L("少分")).font(Theme.TypeScale.caption).foregroundStyle(.tertiary)
            Slider(value: threshold, in: SpeakerThreshold.range)
            Text(L("多分")).font(Theme.TypeScale.caption).foregroundStyle(.tertiary)
        }
        .help(L("往「多分」拖，声音稍有不同就当成另一个人"))
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = L("选声纹模型的 zip 或 .mlpackage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.install(from: url)
    }
}
