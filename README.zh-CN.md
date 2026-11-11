[英文](README.md) | 中文

# Korgino

<img src="Assets/png/icon-256.png" width="96" alt="Korgino">

macOS 上的翻译应用。选中即译。实时字幕跟着系统声音或麦克风走。文件拖进来，原文和译文对照看。

Windows 版是同一个产品，现在还不能用。

## 使用方式

需要 macOS 15 或更高。

1. 从 [Releases](https://github.com/sliiu/korgino/releases) 下载磁盘镜像。
2. 打开，把 Korgino 拖进「应用程序」。

现在的安装包是临时签名，没有公证。第一次打开时，macOS 会要求在系统设置里允许。

自己编译：在装了 Swift 工具链和 macOS SDK 的 Mac 上运行 `./build.sh`。它编出一个通用应用，装进 `~/Applications`。

## 能做什么

- **划词。** 在别的应用里选中文字来翻译。翻译浮层里是原文和各家译文，写回盖回当时的选区。
- **实时字幕。** 听系统声音或麦克风，边说边出译文。已经译完的段可以存成文本。
- **文件。** 拖进文本、PDF、Word、Excel、PowerPoint 或图片。原文和译文并排。
- **截图。** 框一块屏幕，认出字，再翻译。

![主窗口：上面是原文，下面是各家译文。](docs/design/mockups/01-①.png)

翻译浮层、截图识别和实时字幕的一段短片：[docs/promo/korgi-launch.mp4](docs/promo/korgi-launch.mp4)。

## 开源协议

[AGPL-3.0-or-later](LICENSE)。版权人是 Sliiu Inc，见 [COPYRIGHT](COPYRIGHT)。闭源嵌入需要商业授权，见 [COMMERCIAL.md](COMMERCIAL.md)。

第三方组件见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。声纹分说话人用的代码和模型仍按它们自己的许可证，不改成 AGPL。

## 赞助

<a href="https://www.buymeacoffee.com/pax_z" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" style="height: 60px !important;width: 217px !important;" ></a>
