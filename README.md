<div align="center">

<img src="Assets/png/icon-256.png" width="112" alt="Korgino">

# Korgino

### Select it. It's translated.

**Live captions for anything playing. Files side by side.**<br>
A translation app for macOS. The text you select comes back translated,<br>
and the sound playing on your Mac becomes captions as it plays.

[![Release](https://img.shields.io/github/v/release/sliiu/korgino?label=release&color=111111)](https://github.com/sliiu/korgino/releases/latest) [![Stars](https://img.shields.io/github/stars/sliiu/korgino?style=flat&color=111111)](https://github.com/sliiu/korgino/stargazers) [![License](https://img.shields.io/badge/license-AGPL--3.0-111111)](LICENSE)<br>
![macOS](https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white)

**[Download](https://github.com/sliiu/korgino/releases/latest)** &nbsp;·&nbsp; **[Sponsor](#sponsor)** &nbsp;·&nbsp; **English** · [简体中文](README.zh-CN.md)

<br>

<img src="docs/design/mockups/01-①.png" width="900" alt="The main window: source text on top, translations underneath.">

</div>

<br>

## Is Korgino for you?

System Live Captions write down what is playing. They don't translate it. A menu bar translator waits for you to select something. Korgino does both:

- **Select text** in another app and the translation overlay shows the original and each translation. It can write the result back over the selection.
- **Live captions** follow the system audio or the microphone, translated as it is spoken. Finished segments can be saved as text.
- **Drop in a file** — text, PDF, Word, Excel, PowerPoint, or an image — and read the original next to the translation.
- **Select a region of the screen.** The app reads the text and translates it.

It's for you if you read or hear another language on your Mac and want it in yours, right there. Windows is the same product. That build is not usable yet.

## Quick start

**1 · Install.** Download the disk image from **[Releases](https://github.com/sliiu/korgino/releases/latest)** and drag Korgino into Applications.

<sub>Needs macOS 15 or later. These builds are ad-hoc signed and not notarized. The first time you open the app, allow it in System Settings.</sub>

**2 · Translate.** Select text in any app, or paste it into the window. Each service you turn on gets its own card.

**3 · Listen.** Open **Live & meetings**, pick system audio or the microphone, and press start. Captions come in as the words are spoken.

To build it yourself, run `./build.sh` on a Mac with the Swift toolchain and the macOS SDK. It compiles a universal app and installs it into `~/Applications`. `./build.sh --release` builds the package that goes into a release, and leaves `~/Applications` alone.

## What it does

### Selection

Select text in another app. The overlay shows the original and one card per service, and the result can go back over the selection. A short word can carry a dictionary entry beside it.

### Live captions

<img src="docs/design/mockups/02-②.png" width="900" alt="Live captions: system audio and microphone, with past meetings underneath.">

System audio and the microphone each have a card. Both can run together, and the session is kept as one meeting record. Finished segments export as text.

### Files and screenshots

Drop a file onto the window, or pick one. Text, PDF, Word, Excel, PowerPoint and images open with the original on one side and the translation on the other. Screenshot translation reads the text inside a region you draw.

A short film of the overlay, screenshot translation and live captions: [docs/promo/korgi-launch.mp4](docs/promo/korgi-launch.mp4).

## License

[AGPL-3.0-or-later](LICENSE). Copyright holder: Sliiu Inc. See [COPYRIGHT](COPYRIGHT). Embedding this in a closed-source program needs a commercial license. See [COMMERCIAL.md](COMMERCIAL.md).

Third-party notices are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Speaker separation uses code and a model that stay under their own licenses.

## Sponsor

<a href="https://www.buymeacoffee.com/pax_z" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" style="height: 60px !important;width: 217px !important;" ></a>
