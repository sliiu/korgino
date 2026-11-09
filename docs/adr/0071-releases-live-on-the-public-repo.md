# 发布包放在公开仓库

## 结论

源码在私有仓库 `sliiu/korgino-code`。安装包在公开仓库 `sliiu/korgino` 的 GitHub Releases。应用里的检查更新读的是公开仓库，`githubReleasesRepo` 是 `sliiu/korgino`。

在私有仓库推送 `v*` 标签（`v` 加点分数字，如 `v1.42`）触发 `.github/workflows/release.yml`。流水线把标签写进 `CFBundleShortVersionString`，把 `github.run_number` 写进 `CFBundleVersion`，在 `macos-26` runner 上打两份：

- `Korgino-<version>-macos26.dmg`：`./build.sh --macos26 --no-install`
- `Korgino-<version>-macos15.dmg`：`./build.sh --macos15 --no-install`

两份都带 `KORGI_TEST_PRO`，Pro 开到 2026-12-31，见 `0070`。镜像里是 `Korgino.app` 和 Applications 替身。签名是临时签名，没有公证。GitHub 托管 runner 没有 Developer ID。

`--no-install` 只产出 `.app`，不覆盖 `~/Applications`，不启动。本机 `./build.sh` 不带这个参数，行为不变。

流水线用私有仓库的 secret `KORGINO_RELEASES_TOKEN` 往公开仓库建 Release。这是一把只对 `sliiu/korgino` 有 contents 写权限的 fine-grained PAT。组织免费计划没有跨仓库 token。

## 考虑过

- 源码也放公开仓库：源码要私有。
- 发布包也放私有仓库：检查更新走的是未登录的 GitHub API，私有仓库读不到。
- 打包用 zip：改成 dmg，镜像里直接拖到 Applications。
- 用 `macos-latest`：源码里有 macOS 26 的 API，要 26 的 SDK。`macos-26` 上有 Xcode 26。
