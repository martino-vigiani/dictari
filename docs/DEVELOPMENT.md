# Development guide

How Dictari is built, tested and put together, and the rules that keep it fast and safe.
Read the relevant section before changing behaviour. [CONTRIBUTING.md](../CONTRIBUTING.md) has the
short version.

## What this is

Dictari is a local-first macOS menu-bar dictation app (macOS 26+, Apple Silicon, Swift 6 with
`SWIFT_STRICT_CONCURRENCY: complete`). Hotkey → microphone capture → on-device transcription →
text injected into the frontmost app. No network except model downloads and update checks.
[`REQUIREMENTS.md`](../REQUIREMENTS.md) is the full product spec (vision, latency budget, UI anatomy) — read the relevant
section before changing behaviour that it specifies.

## Build & run

The Xcode project is **generated** — `Dictari.xcodeproj/` is gitignored. `project.yml` (XcodeGen) is
the source of truth; after adding/removing/moving any source file, run `xcodegen generate`.

```bash
./scripts/build-run.sh        # xcodegen + xcodebuild + stable re-sign + relaunch
```

Use that script rather than a raw `xcodebuild` when you need the running app. It signs with the
identity in `DICTARI_SIGN_IDENTITY` if that is set (environment, or `Local.xcconfig` copied from
`Local.xcconfig.example`) and falls back to ad-hoc signing otherwise. macOS TCC keys Accessibility
and Microphone grants on the code-signing requirement, so a stable identity keeps those grants
across rebuilds; with ad-hoc signing macOS asks again after every rebuild. Do not change the
signing identity of someone's existing local install without asking.
`build-run.sh` also passes `SWIFT_OPTIMIZATION_LEVEL=-O`: Debug otherwise compiles FluidAudio and
WhisperKit with `-Onone` (Parakeet ~30% slower), and project.yml settings never reach SwiftPM
targets. Measure with `TEST_RUNNER_DICTARI_LATENCY_BENCH=<file.json>` on
`TranscriptionLatencyBenchmarkTests`.

Build only:

```bash
xcodebuild -project Dictari.xcodeproj -scheme Dictari -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO
```

Reach settings without the menu bar: `DICTARI_OPEN_SETTINGS=1 open -a Dictari` (value is a
`SettingsSection` raw value).

## Tests

```bash
./scripts/ci-tests.sh         # the deterministic suite CI runs: no models, no mic, ~2 minutes
xcodebuild -project Dictari.xcodeproj -scheme Dictari -destination 'platform=macOS,arch=arm64' test
# single class / single test
xcodebuild ... test -only-testing:DictariTests/TranscriptionEngineTests
xcodebuild ... test -only-testing:DictariTests/HotkeyMatchingTests/testSwallowsTheCancelShortcut
```

The test target is **host-less by design**: it compiles a hand-picked subset of `Sources/` directly
(listed in `project.yml`), so tests run inside `xctest` with no app launch, no event tap, no TCC
prompts. Consequence: a new file is only testable once it is added to the `DictariTests` sources
list. UI, `AppCoordinator` and menu-bar code are deliberately excluded.

Tests use real audio, not mocks — `Tests/AudioFixture.swift` synthesizes speech with `/usr/bin/say`
(English/German/Italian voices) and decodes to 16 kHz mono Float32. Transcription tests download and
run the real model, so they are slow. Microphone capture tests skip in the harness (no TCC grant).

For the end-to-end chain the harness can't cover (mic → tap → resampler → model → transcript), run
the in-app self test, which replaces normal startup and exits with a status code. **It posts real
keystrokes and pastes into whatever app has focus: do not run it, or launch the app, on a machine
where someone is typing.**

```bash
DICTARI_SELFTEST=1 ~/Library/Developer/Xcode/DerivedData/Dictari-*/Build/Products/Debug/Dictari.app/Contents/MacOS/Dictari
```

Settings smoothness (Debug builds) has its own harness, `App/SettingsPerfProbe.swift`: it starts
no services, drives the real `SettingsRootView` through every page in a window with 2 px on screen,
and writes frame hitches and main-thread CPU per page switch as JSON, then exits.
`DICTARI_PERF_SEQUENCE=sound,history` alternates two pages; `DICTARI_PERF_CYCLES` and
`DICTARI_PERF_NOSCROLL` shorten a run. Compare builds with interleaved runs: the Mac's own load moves
the numbers by 3×.

```bash
DICTARI_SETTINGS_PERF=/tmp/perf.json /path/to/Debug/Dictari.app/Contents/MacOS/Dictari
```

To profile it, start it directly and `xcrun xctrace record --attach <pid>` or `sample <pid>`. Never
`xctrace --launch` it: LaunchServices resolves the bundle id and starts the installed
`/Applications/Dictari.app` copies, with event taps, instead.

## Localization

The UI ships in the eight dictation languages (en source; it, de, fr, es, pt, ru, uk) and follows
the Mac's language. Text lives in `Resources/Localizable.xcstrings`; Info.plist text in `Resources/InfoPlist.xcstrings`.

- A string is only translated if it reaches the compiler as a localizable literal: `Text("…")`,
  `String(localized: "…", comment: "…")`, `LocalizedStringResource`, or a `LocalizedStringKey`
  parameter. Shared components (`SettingsRow`, `SettingsCard`, …) translate literals and show a
  `String` verbatim, so convert computed text at its source.
- Persisted or compared values stay English (`MediaDocument.status`,
  `DictationRecovery.failureDescription`, raw values); screens use their `display…` mapping.
- Not translated: logs, MCP tool text, prompts to Apple Intelligence, spoken-punctuation commands,
  brand and model names.
- After changing UI text run `./scripts/sync-strings.sh` (builds the app and merges new keys
  into the catalog), then add the seven translations. The German UI uses "du".
- Check layouts without opening the app on screen:
  `DICTARI_SETTINGS_SNAPSHOT=/tmp/de …/Debug/Dictari.app/Contents/MacOS/Dictari -AppleLanguages '(de)'`
  renders every Settings page to PNG and exits.

## Architecture

`AppCoordinator` (`Core/AppCoordinator.swift`, `@MainActor @Observable`) is the single integration
hub: it owns every component and drives the whole lifecycle (hotkey → pill → capture → transcribe →
inject → history/stats). Leaf components own no policy — they expose callbacks (`onActivate`,
`onLevel`, `onAutoStop`) that the coordinator wires in `wireHotkey()`, and settings are pushed into
them by `configureComponents()`. When adding a feature, put the decision in the coordinator and keep
the component mechanical.

Components:

- `Hotkey/HotkeyManager` — global `CGEventTap`. Needs Accessibility; if missing at launch the
  coordinator polls until granted and arms without a restart. The C tap callback can't capture
  `self`: it bridges via an `Unmanaged` `RoutingBox` in `userInfo`, decides *synchronously* whether
  to swallow the event from a lock-guarded `Sendable` snapshot, then hops to `MainActor` for side
  effects. Keep that split — never touch actor-isolated state from the tap.
- `Audio/AudioCaptureEngine` — `AVAudioEngine` → 16 kHz mono Float32, level stream, VAD auto-stop.
  Class is `@MainActor`, but the tap closure runs on a realtime thread: all realtime state lives in
  one `@unchecked Sendable` `RealtimeState` guarded by `os_unfair_lock`, with tiny critical sections
  and no allocation. `prearm()` pays graph setup cost ahead of the user pressing the key.
- `Core/TranscriptionEngine` — the backend protocol (`warmUp` / `transcribe` / `currentModelName`).
  Two implementations, chosen per `ModelDescriptor.backend` by `AppCoordinator.makeEngine`:
  `WhisperKitEngine` (CoreML/ANE) and `ParakeetEngine` (FluidAudio, the default model). Switching models
  builds a **new** engine instance; engines are never re-warmed in place — `WhisperKitEngine`'s
  `nonisolated(unsafe) pipe` is sound only because of that plus the coordinator's rule of never
  calling `transcribe` before `modelState == .ready`.
- `Injection/TextInjector` — `.paste` (pasteboard + synthesized ⌘V, optional restore) or `.type`
  (Unicode key events) into whatever has focus at delivery. `FocusVerdict` (in `FocusInspector`)
  sends the text to the pill's copy button only when AX *proves* there is no text box or it is a
  password field; "AX could not answer" pastes. Recording start sets `AXManualAccessibility` on
  Chromium/Electron apps so they expose their tree. Don't reintroduce positive-editable gates or
  frozen-target/epoch machinery: that is what broke pasting in September 2026. Synthetic input is
  disabled under XCTest (`postsSyntheticInput`).
- `Injection/LiveTyper` + `Core/LiveTyping` — opt-in Live Typing (off by default). Streaming hypotheses from
  `ChunkedStreamingSession` are turned into Backspace + Unicode key edits by the pure
  `LiveTypingPlanner`; `LiveTypingPolicy` stops the session on any user key/click (counted
  lock-free by the hotkey tap via `UserInputMonitor`), app switch, secure input or a
  non-editable/secure focus. Posted events carry `SyntheticInputMarker.liveTyping` so the tap
  ignores them. This is separate from the paste path; it does not gate or change it.
- `Pill/PillController` — a non-activating `NSPanel` overlay. It must never become key/main or
  activate the app; only the pill's own rect is interactive, everything else passes clicks through.
  It also allows the panel to hang off-screen (`constrainFrameRect` override) and clamps the visible
  content itself.
- `MenuBar/MenuBarController` — status item and popover. `DictariApp`/`AppDelegate` is an
  `.accessory` app: no Dock icon, no main window; the settings window is plain AppKit, and the
  hand-built main menu exists so ⌘, and Edit-menu ⌘C/⌘V/⌘A work at all.
- `Core/Stores` — `SettingsStore` / `HistoryStore`, JSON in
  `~/Library/Application Support/Dictari/` (with a one-shot move from the old `RobinWhisper/`
  folder). Everything local; nothing networked.

`Core/LevelBuffer` is deliberately **not** an observed property — waveform levels arrive ~50×/sec and
publishing them re-invalidated the view tree for nothing. Keep it `@ObservationIgnored`.

## Conventions

- **Monochrome only.** `Core/DesignTokens.swift` is the single source of truth: use `Mono.*` /
  `Color.adaptive`. No raw colors, no system tints, no accent color. The pill is always a dark
  capsule in both appearances.
- Startup side effects are gated: nothing installs an event tap, opens the mic or downloads a model
  under XCTest (`AppDelegate.isRunningTests`) or in self-test mode.
- Comments here explain *why* a non-obvious choice was made (concurrency invariants, TCC, focus
  behaviour). When changing such code, update the reasoning rather than deleting it.
- Latency is a product requirement, not a nicety — weigh anything added to the
  start-dictation or stop→inject path against the budget in `REQUIREMENTS.md`.
