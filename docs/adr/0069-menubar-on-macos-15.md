# macOS 15 的菜单栏包单独声明 LSUIElement

## 结论

macOS 15 的包在 Info.plist 里写 `LSUIElement`，启动时不再调用 `setActivationPolicy(.accessory)`。macOS 26 及以上的包不写这个键，只在系统版本 ≥ 26 时切到 accessory。

`./build.sh --macos15` 产出 `dist/Korgino-macos15.app`，不装进 `~/Applications`。`./build.sh --macos26` 把最低系统写成 26.0。不带参数的 `./build.sh` 仍是本机开发包。

15 上如果打开了没写 `LSUIElement` 的包，保持 regular：菜单栏图标能出来，Dock 图标会留着。

## 为什么

1.41（43）在 macOS 15.1 上只有 Dock 图标，没有窗口，也没有菜单栏图标。入口在 `app.run()` 之前就切到 accessory，菜单栏图标要等 `applicationDidFinishLaunching`。15 上这次切换经常不生效，应用停在 Dock 还在、状态栏项又不给的状态。

macOS 26 不能把 `LSUIElement` 写进 plist，`open` 会报 -600。两个办法叠在同一个包里时，Control Center 还会把状态栏图标拉黑。所以按系统拆包，而不是在一份 plist 里两头都做。

## 考虑过

- 只在代码里按系统版本跳过 `setActivationPolicy`。15 上菜单栏能出来，但 Dock 图标去不掉。15 的发布包仍要 `LSUIElement`。
- 所有包都写 `LSUIElement`。26 上 `open` 失败。
