# 第三方组件与声明 / Third-Party Notices

Korgino 本体不含第三方库：界面、网络、音频、字幕处理均只用 Apple SDK
（Foundation、SwiftUI、AppKit、AVFoundation、Speech、Translation、Vision、
Core ML、Accelerate 等），随 macOS 分发，无单独署名义务。

下面两项只涉及**声纹分说话人**（实时字幕与会议记录里的「用声纹分得更准…」）。

---

## 1. WeSpeaker ResNet34-LM（模型权重）

- 来源：https://github.com/wenet-e2e/wespeaker
- 使用形式：预训练权重，在 VoxCeleb 上训练，原样用于本地推理，未再训练
- 许可：CC BY 4.0 — https://creativecommons.org/licenses/by/4.0/
- 改动说明：由 wquguru/cicada 转换为 Core ML 格式并重新量化，本项目按原样分发该转换结果
- 模型文件仍受 CC BY 4.0 约束，不适用本仓库其余部分的 AGPL-3.0-or-later

## 2. wquguru/cicada — SpeakerID.swift 的 Swift 移植（代码）

- 来源：https://github.com/wquguru/cicada
- 许可：Apache License 2.0，副本见 `LICENSES/Apache-2.0.txt`
- 派生文件：`Sources/Voiceprint.swift` 中的 `VoiceFbank`（Kaldi 对数梅尔滤波器组）
  与 `SpeakerModel.embed` 里逐 bin 去均值的一段
- 改动说明：改为 Swift + Accelerate（vDSP）实现，包成 `enum` 与本项目的
  采样管线对接；数学常数与计算顺序保持不变，以便与 Core ML 模型的训练前处理对齐
- 原文件版权归 wquguru/cicada 项目作者，仍按 Apache-2.0。上述改动部分随本仓库按 AGPL-3.0-or-later 分发

---

## 商标

`Assets/ProviderIcons/` 里的各家 Logo 仅用于标示 App 内正在连接的服务，
各名称与标识归各自所有者。Korgino 与这些服务商无从属或背书关系。
