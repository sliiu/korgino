# 一条链路一个任务，一份实现一处定义

2026-11-08 按审查结果分六段修完。这份记下改了什么、为什么这样分，以及刻意没动的地方。

## 结论

**本地化**。代码里 1133 个 `L()` key，13 种语言包此前只有 1172 条，128 条 key 在所有语言里都缺，英文和繁体用户会看到原样简体中文。补齐后各 1300 条。`tools/check-strings.sh` 进 `build.sh`，缺 key 直接失败；`tools/add-strings.py` 负责把译文追加进 UTF-16 的 `.strings`。`maskSwitch` 以前在函数内部包 `L()`，调用点的字符串因此对扫描不可见，改成调用点直接写 `L("…")`。

**任务槽**。`AppDelegate` 原来只有一个 `task`，划词、撤销、剪贴板、OCR、插件共用，新的会静默掐掉旧的；`Popup.dismiss()` 直接取消它，写回成功关掉最后一个标签也算「用户关闭」，会连带取消无关请求。现在拆成 `panelTask`（填浮层的几条，彼此替换是对的）、`ocrTask`（选区拖拽不能被翻译打断）、`undoTask`。

**互斥**。`QuickSpaceTap.busy` 原来只挡「快捷翻译进行时按 Fn」，反方向缺一道：听写期间连按三下空格照样会起翻译，两边往同一个输入框写字。`FnDictate` 现在起手 `claim`、收尾 `release`，并且锁绑定到这一轮的会话号，上一轮收尾不会把下一轮的锁放掉。

**共用定义**。`HotkeySpec`、`HotkeyAction`、`Notification.Name.korgiHotkeysDidChange`、免费档上限提到 `Engine/`，Windows 侧不再各抄一份。键码表写成数值常量（Carbon 虚拟键码），Engine 才不用 import AppKit。`/chat/completions` 从 4 份收成 `Engine/ChatClient` 一份；「遮盖 → 确认 → 还原」从 7 处收成 `Engine/MaskedSend` 一条管线。时间格式、JSON 包装、字符串截断各收一处。

**性能**。`SecretCover` 的占位符表加了 4096 条上限和排序缓存；`ModelListFetcher` 加了一层内存缓存；实时字幕切句从逐字符重排改成一次量宽；历史读取与快捷翻译的写盘挪到后台；`LiveASRLane.stop()` 不再在主线程 `queue.sync`。

## 为什么

审查分四路读完整份代码，逐条回到源码确认后才改。改完每一段都跑一次 `./build.sh`（0 error）和 `check-strings.sh`。

## 刻意没改

- `AppConfig`（2429 行、100 个 `@Published`）和 `SystemAudioTranslateController`（2685 行）拆类型，牵涉面太大，单独排期。ADR 0027 已经记过同样的判断。
- 浮层定位、淡入、失焦的重复逻辑（QuickOverlay / SelectionPlugins / Popup 各一套）。这次只抽了 `NSPanel` 的公共参数，摆放规则仍各写各的。
- `Windows/` 目录和 `Engine/WindowsCompile.swift` 的桩保留。前者不在任何构建输入里，后者编译时在 Mac 上是空的。

## 考虑过

- 任务槽只留一个、用 generation 区分。最后还是按链路拆：三条链路的取消语义本来就不一样，一个代数变量表达不了。
- 把 `SecretCover` 的占位符表在每次请求后清空。不做：同一段文字在翻译、词典、对话之间共享占位符，清早了还原会失败。用上限淘汰最早的那批。
- `check-strings.sh` 同时报「未使用的 key」。只警告不失败——那 167 条里有跨平台和预留的，判断不了哪些能删。
