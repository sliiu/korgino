# Windows 开发

Windows 版和 Mac 是同一个产品。翻译请求、遮盖、原文骨架、历史、收藏、字幕时间轴、查词和网络会话在 `Engine/`。界面、划词、写回、系统声音、热键、截图和本地识别各写各的。决定见 `docs/adr/0029` 到 `0034`。

`Engine/` 可以在 Windows 上通过类型检查。`build\Korgino.exe` 是一个 Win32 窗口：输入原文，点「翻译」，走引擎里已启用的服务。Git、CMake、Ninja、NuGet 和 Windows SDK 10.0.26100 已安装，`swiftwinrt` 已编出，WinUI 的 Swift 绑定在本机 `C:\Users\pax\src\korgi-winui`。这些绑定还没编进程序，所以它还不是 `docs/adr/0031` 定的 WinUI 3 壳。托盘、热键、划词、写回和系统声音还没写。

## 虚拟机

用 Parallels 里那台 Windows 11。Whisky 和 Wine 只负责跑现成的程序，没有 Windows SDK，不能用来编译。

工程在 Mac 上的 `Documents/Code/Korgino`。虚拟机通过 Parallels 共享文件夹打开它，确认能看见 `Engine` 和 `Sources`。

在 Windows 终端里先装 Visual Studio，再装 Swift。这台虚拟机是 ARM，要带 ARM64 的编译工具。

```bat
winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64" --source winget
winget install --id Swift.Toolchain -e --source winget
```

新开一个终端，运行 `swift --version`。能打出版本号，工具链就好了。软件源里如果已经没有 Visual Studio 2022，就装列出的新版本，组件仍是 C++ 工具和最新的 Windows 11 SDK。

先不要在这个目录里运行 `swift build`。

## 代码

`Engine/` 不引用 AppKit、SwiftUI、NaturalLanguage、Speech、AVFoundation、Security、Translation、ScreenCaptureKit、CoreMedia。`build.sh` 会检查这一点。

Mac 在启动时接上三处实现，见 `Sources/main.swift`：

- `MacKeychain`：密钥进钥匙串
- `AppleLanguageDetect`：用 NaturalLanguage 判语种
- `AppleASRLocales`：Apple 语音能识别的语言列表

Apple 本地翻译在 `Sources/AppleTranslate.swift`。截图的 PNG 编码和 Apple Vision 在 `Sources/OCRImage.swift`。系统声音、麦克风和朗读播放仍在 `Sources/`。

Windows 壳用 Swift 写 WinUI 3。Mac 的 SwiftUI 不参加这次编译。窗口和动作与 Mac 对齐，画风用 `Theme` 里的同一套数值，见 `docs/adr/0034-windows-matches-mac-theme.md`。

## 壳要接的系统

- 托盘
- 全局热键。Mac 的 ⌘ 和 ⌥ 在这里是 Ctrl 和 Alt
- 划词和写回：UI Automation。能直接改选区就改，改不了再粘贴，并先核对选区还是那句原文
- 系统声音：WASAPI 环回
- 截图识别：Windows 自带 OCR，这一行叫「系统 OCR」
- 朗读：Windows 自带语音合成，这一行叫「系统语音」
- 免费的本地识别：一行「离线识别」，多语言 Whisper base，大约 150MB。不放进安装包。实时字幕、媒体字幕或麦克风听写第一次要用时再问：下载，或取消。见 `docs/adr/0033-offline-asr-downloads-on-first-use.md`
- 设置、历史和密钥各存在各的电脑上

不打包离线翻译。翻译服务列表里不出现 Apple 本地。新装只默认启用 Google（免费）。

这台虚拟机上的包不接商店。和 Mac 的开发包一样，默认当作已购买。购买、试用、恢复购买仍只在 Mac 的商店包里。

## Mac

改了 `Engine/` 或 `Sources/` 之后，在 Mac 上运行 `./build.sh`。它编译、签名，覆盖 `~/Applications/Korgino.app`，然后打开。
