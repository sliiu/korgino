# feature-evidence · Korgino

范围：用户 2026-11-07 确认「整个产品」，平台面只取 **Mac 版**。Windows 版能力对齐（GLOSSARY.md：「Mac 与 Windows 上的同一个翻译产品」），但本片不演示 Windows，交付时声明。
产品状态：开发中，未发布版本号；仓库不是 git 仓库，证据以源码路径与 ADR 为准。

| feature | benefit | status | source | component | demoState | limits |
|---|---|---|---|---|---|---|
| 划词翻译 | 选中任意应用里的文字，浮层里出原文和译文，可写回选区 | 已合并 | `Sources/Popup.swift` PopupView；`docs/adr/0056-native-and-target-are-a-pair.md` | PopupView：header 语言菜单、sourceWell、multiBody 供应商卡 | 固定中文句 → 英文译文，一家供应商（Apple） | 多家并行、对话、词典面板本片不演示 |
| 划词插件 | 选中后浮出一排图标，点一下直接出结果；翻译只是其中一种 | 已合并 | `Sources/SelectionPlugins.swift` SelectionPluginBarView；GLOSSARY 「划词插件」 | 磨砂胶囊条 + 圆形按钮 + 自画名字浮签 | 三枚插件：翻译 / 润色 / 解释，悬停显名 | 插件由用户自定义，名字为演示固定值 |
| 语音 | 按住 Fn 走当前模式：语音识别、语音翻译、语音传译；松开后润色 | 已合并 | `Sources/QuickOverlay.swift` QuickOverlayView；`docs/adr/0053-three-voice-gestures.md`、0054 | 磨砂胶囊：声波条 + 「在听 · 模式名」+ 原文/译文 | 胶囊从「在听 · 语音翻译」落到一句中英对照 | 传译读音、润色风格本片不演示 |
| 实时字幕 | 系统声音边听边译，一路一块面板，带说话人和时间码 | 已合并 | `Sources/SystemAudioTranslate.swift` laneTranscriptCard / segmentRow；`docs/adr/0059-lane-panel.md`、0065 | 路面板卡：标题、语言摘要、段数、段行（时间码 / 说话人芯片 / 原文 / 译文） | 两个说话人的三段英文口播落成中文 | 会议记录、一场笔记、导出本片不演示 |
| 母语与目标语言对翻 | 原文是母语就译成目标语言，反之亦然 | 已合并 | `docs/adr/0056-native-and-target-are-a-pair.md` | — | 中 ↔ 英，各镜头一致 | 第三种语言译成母语不在本片证明 |

不进本片：截图识别、文件翻译、词典、历史、快捷翻译、会议记录、声纹模型、购买与钥匙。旧发布片 `docs/promo/korgi-launch.mp4`（2026-10-24，18 秒）已讲过划词、截图、实时字幕，本片重讲时换取景与文案。
