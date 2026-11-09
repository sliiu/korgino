# 拆文件，不拆状态机

2026-11-09 把 `AppConfig`（2429 行）和实时字幕控制器（5086 行）按主题拆开，浮层的坐标换算与淡入也收到一处。

## 结论

**`AppConfig`**。2429 → 1241 行，函数按主题分进 9 个文件：`Config+Providers`、`+ASR`、`+TTS`、`+OCR`、`+Apps`、`+Hotkeys`、`+Readiness`、`+Persist`、`+Proxy`。Swift 不允许在 extension 里放存储属性，所以 100 个 `@Published` 与它们的 `didSet` 留在主声明，搬走的只有函数。80 个字面量键收进 `ConfigKeys`，替换 172 处调用点；字符串本身逐字未改。

**实时字幕**。5086 → 2517 行，视图、模型、音频通道、窗口各成一个文件（`LiveCaptionsView` / `LiveCaptionModels` / `LiveCaptionLanes` / `LiveCaptionWindow`）。控制器本体与它 1452 行的扩展**没拆**：按段统计，`Capture` 段用到 21 个私有成员、`ASR → Translate` 37 个、`Overlay + TTS` 20 个。按段拆文件要把近百个 `private` 改成 `internal`，换来的是更松的封装和更长的 diff，不是更好的结构。

**浮层**。辅助功能坐标换屏幕坐标三处逐字相同，抽进 `OverlayPlacement.onScreen`；0.12 秒淡入两处相同，抽进 `fadeIn`。`NSPanel` 的参数上一轮已经收到 `OverlayPanel`。

## 为什么

「一个类型太大」不是拆的理由，耦合才是依据。先量每段引用了多少私有状态，只拆引用少的三段（权限 1、录音 5、窗口 3），其余留着。`AppConfig` 相反：函数之间的共享状态是那几个 `@Published`，函数本身几乎不互相调用，所以按主题搬文件是安全的，编译错误会立刻指出没搬干净的 `private`。

## 考虑过

- `AppConfig` 再拆成 `ProviderStore` / `ASRStore` 之类的子对象，`AppConfig` 只做转发。没做：146 处调用点全要跟着改，而且 `didSet` 之间互相触发（改 ASR 默认会动翻译名单），拆开后触发顺序更难追。
- 实时字幕按 MARK 段落拆成 6 个 extension 文件。没做，理由见上：`private` 会全线放宽，等于取消封装。
- 两份「点外面就收」的监控合并。没做：插件条要认自己窗口里的点击，弹窗要放过 pinned / 聊天展开 / OCR 草稿，两套语义不同。
- 保留 `tools/split-config.py`。它是这次拆 `AppConfig` 用的；留着是因为同样的搬移可能再来一次，脚本按大括号配对切块、连同文档注释一起走。

## 效果

`build.sh` 0 error，warning 仍是 12 条（与改动前一致）。`check-strings.sh` 1133 个 key 全语言齐全。
