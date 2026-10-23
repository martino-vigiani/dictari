# Contributing to Dictari

Thanks for helping. Bug reports, fixes and small focused features are all welcome. For anything
big, open an issue first so we can agree on the approach before you spend time on it.

Architecture and engineering rules live in [AGENTS.md](AGENTS.md). Read it before you change
behavior. It is written for AI coding agents, but it is the same document humans should use.
The product spec and latency budget are in [REQUIREMENTS.md](REQUIREMENTS.md).

## Warning: Dictari types and pastes for real

Dictari posts real keystrokes and pastes into whatever app has focus. Running the app, the in-app
self test or some of the tests on a Mac where you are typing can insert text into your own work.
Do not run `DICTARI_SELFTEST=1` on a machine you are actively using.

## Build

Requirements: Apple Silicon Mac, macOS 26, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Dictari.xcodeproj -scheme Dictari -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
```

`project.yml` is the source of truth. `Dictari.xcodeproj` is generated and not committed, so run
`xcodegen generate` again whenever you add, remove or move a source file.

To run the app with stable permission grants, copy `Local.xcconfig.example` to `Local.xcconfig`
and set your own signing identity. Without it, macOS asks for Microphone and Accessibility again
after every rebuild.

## Tests

```sh
xcodebuild -project Dictari.xcodeproj -scheme Dictari -destination 'platform=macOS,arch=arm64' test
# one class
xcodebuild ... test -only-testing:DictariTests/TranscriptionEngineTests
```

- The test target is host-less. It compiles a hand-picked list of files from `Sources/` (listed
  in `project.yml`), so a new file is only testable after you add it to the `DictariTests` sources.
- Tests use real audio, not mocks. `Tests/AudioFixture.swift` makes speech with `/usr/bin/say`.
- Transcription tests download and run a real model, so they are slow. Run the class you touched,
  not the whole suite, while you work.
- Microphone tests skip themselves when the harness has no permission.

## Localization

The UI ships in eight languages: English (source), Italian, German, French, Spanish, Portuguese,
Russian and Ukrainian. If you change UI text, run `./scripts/sync-strings.sh` to add the new keys
to `Resources/Localizable.xcstrings`, then add the seven translations. Only string literals that
reach the compiler as localizable are translated, see the Localization section of AGENTS.md.

## Design

The UI is monochrome. Use the tokens in `Core/DesignTokens.swift` (`Mono.*`, `Color.adaptive`).
No raw colors, system tints or accent colors.

## Pull requests

- Keep a PR to one change, and say how you tested it.
- Match the style and comment density of the surrounding code. Comments explain why, not what.
- Latency matters: anything on the start-dictation or stop-to-paste path is checked against the
  budget in REQUIREMENTS.md.
- By contributing you agree that your work is released under the [MIT License](LICENSE).
