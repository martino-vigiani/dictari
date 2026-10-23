# Dictari

Talk instead of type. Free, open-source dictation for Mac that runs entirely on your device.

[![License: MIT](https://img.shields.io/badge/license-MIT-black.svg)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black.svg)](#install)

<!-- screenshot -->

**[⬇ Download Dictari for Mac](https://github.com/martino-vigiani/dictari/releases/latest/download/Dictari.dmg)**

macOS 26 or later · Apple Silicon

## Install

1. Open the DMG and drag Dictari to Applications.
2. Open Dictari and allow Microphone and Accessibility when asked.
3. Pick a model. It downloads once (about 480 MB for the default), then works offline.

Prefer the terminal?

```sh
curl -fsSL https://raw.githubusercontent.com/martino-vigiani/dictari/main/scripts/install.sh | bash
```

Updates install automatically.

## Use it

- Press **⌥ Space** (Option + Space) anywhere. Dictari starts listening.
- Speak.
- Press **⌥ Space** again. The text appears where your cursor is. Press **Esc** to cancel instead.

You can change the shortcut, or switch to push-to-talk (hold to record), in Settings.

## Features

- On-device speech recognition with Parakeet (default, 25 European languages) and Whisper models.
- Vocabulary corrections for names, jargon and words the model keeps getting wrong.
- Local history of your dictations, with saved recordings for recovery.
- Transcribe audio and video files, or capture a meeting from a chosen app, with speaker labels.
- Optional live typing: text appears as you speak.
- A local MCP server, so AI agents such as Claude Code, Codex or Cursor can read your transcripts. Off by default.
- Per-app writing rules, spoken formatting and optional clean-up with Apple Intelligence.

## Privacy

Your audio never leaves your Mac. Transcription, history and vocabulary all stay local.
The only network traffic is downloading models and checking for updates.

## Build from source

You need an Apple Silicon Mac on macOS 26, Xcode 26 and XcodeGen.

```sh
brew install xcodegen
git clone https://github.com/martino-vigiani/dictari.git
cd dictari
xcodegen generate
open Dictari.xcodeproj
```

Or from the command line:

```sh
xcodebuild -project Dictari.xcodeproj -scheme Dictari -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
```

An unsigned or ad-hoc build makes macOS ask for Microphone and Accessibility again after each rebuild.
To sign with your own identity, copy `Local.xcconfig.example` to `Local.xcconfig` and fill it in.

Want to help? See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Third-party software and models are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
The Dictari name and icon are covered by [TRADEMARKS.md](TRADEMARKS.md).
