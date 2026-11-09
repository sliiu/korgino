# 启用前必须就绪：所有类型提供商（2026-11-02）

## 决定

未配置、或就绪检查不通过的提供商（所有类型）不能被勾选启用。守住不变式：**启用 ⇒ 已就绪**。

grill 过的四条：

- **Q1 判定口径**：按**就绪检查**（必填字段齐全：key、baseURL 等），不是连接测试。连接测试仍是手动按钮，不做启用门槛。
- **Q2 免密钥/本地**：`noKey` 及无需 key 的（Apple 系、Google 免费、Bing、MyMemory、Free Dictionary、Apple Vision）恒为就绪，可直接勾。
- **Q3 配置流程**：未就绪时勾选框置灰禁用（`.disabled(!ready && !on)`），悬停提示「填好密钥后可启用」；行可展开，填好字段 → 就绪后勾选框变可用，用户自己勾。去掉「启用时自动展开」。
- **Q4 旧数据**：加载时自动取消未就绪却被启用的（`enforceReadyInvariant`）。新加的预设也按就绪决定初始启用状态。

## 实现

`Engine/Config.swift`：

- 新增就绪判定：`builtinReady`、`ocrReady`、`aiReady`、`asrProfileReady`、`ttsReady`（词典沿用已有 `dictReady`）。判定 = 必填字段非空；`noKey` 预设豁免 key。
- `enforceReadyInvariant()`：清掉启用但未就绪的六类提供商；在 `init()` 末尾调用。清空后各类兜底（builtin→googleFree，OCR→appleVision，dict→freeDictionary）。
- `addProvider` / `addASR` / `addTTS`：新加的提供商按 `*Ready` 决定初始 `enabled`（本地免密钥的仍会直接启用）。

`Sources/Preferences.swift`：

- 六类行（内置引擎、OCR、词典、AI、ASR、TTS）的勾选框：`set` 里 `if enabled && !ready { return }`；`.disabled(!ready && !on)`；help 文案按就绪切换。
- 内置引擎 / OCR / 词典行：未就绪时显示 `MissingKeyLabel`（原来只在「已启用但缺 key」时显示，现在改成「未就绪即显示」，解释为什么置灰）。
- 删掉不再使用的 `builtinMissing`、`ocrMissing`（由 `config.builtinReady`/`ocrReady` 取代）。
- 词典行特殊处理：它的 key 和翻译引擎共用；未就绪时仍把共用 key 的内联字段显示出来（`on || !ready`），保证能就地填 key 再启用，不出现「想配却进不去」的死循环。

## 功能设置里只列已启用的（2026-11-02 追加）

未勾选启用的提供商，功能设置里也不能被选中。走查后发现只有两个 AI 档选择器漏网，其余早已过滤：

- 翻译服务选择（`providerTags` → `catalogTargets`）：`checkedTargets` 已按 `isProviderOn` / `aiProfiles.enabled` 过滤，再交 `availableTargets`（就绪）取交集，只剩已启用+就绪的。
- OCR 默认（`orderedOCRProviders`）、识别/朗读引擎（`enabledASRChoices` / `enabledTTSChoices`）、词典默认：都已只列启用的。
- 修复：文件翻译「默认模型」`fileAIProfileID`、OCR AI 视觉「模型」`ocrAIProfileID` 两个 Picker 原来 `ForEach(config.aiProfiles)` 列全部，改成 `.filter { config.isAIOn($0) }`；并把 selection 包一层，存的档若已停用就回落到「自动」，避免选中项显示空白。

## 已知取舍

- `aiVision`（AI 视觉 OCR）沿用原判定恒为就绪，不额外校验 AI 档——保持与旧行为一致，避免回归。
- 运行时把某个已启用提供商的 key 清空：`.disabled(!ready && !on)` 仍让它可被取消勾选（不会卡死），并显示未就绪提示；下次启动 `enforceReadyInvariant` 会清掉。
