# 浮层动效只留该动的（2026-11-02）

快捷翻译一天会触发很多次。这一轮不加新动效，只收三处已经在动、但动错了的地方。扫光仍只留给快捷翻译（`0024`、`0049`），听写仍是电平条加转圈。

## 决定

- **相位不带动位置。** 浮层整棵视图绑在 `phase` 上时，高亮框和徽章会跟着滑，正在读的字也跟着动。位置、字号、徽章内容改为立刻切换。描边和底色仍用 180ms ease-out，标出「翻译中 / 已替换 / 失败」。减弱动态效果时颜色也不过渡。
- **扫光仍是 1.2 秒从左到右的匀速斜光。** 不再用 `TimelineView` 每秒 60 次重绘。一条重复的位移动画走完就回到左侧；光带在两端都完全出框，回绕看不见。
- **设置里已有的展开，和外观分段药丸，尊重减弱动态效果。** 时长不改：展开 160ms snappy，药丸 200ms snappy。系统打开减弱动态效果时，展开和滑块都直接到位。

## 实现

- `Sources/QuickOverlay.swift`：去掉 `ZStack` 上的 `.animation(_:value: phase)`。填充和描边各自带颜色动画，扫光不在这条动画里。`SelectionSweep` 用 `keyframeAnimator(repeating:)` 驱动位移。
- `Sources/Preferences.swift`：内置引擎行、OCR 行、展开箭头的 `.snappy(duration: 0.16)` 在减弱动态效果时为 `nil`。
- `Sources/Theme.swift`：`PillSegmented` 同样处理 `.snappy(duration: 0.2)`。
