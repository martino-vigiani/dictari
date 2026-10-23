# Dictari — Product Requirements Document

> **Local-first, latency-obsessed voice dictation for macOS.**
> Free and open source (MIT). Runs 100% on-device: no cloud, no subscription, no account.
> An open-source alternative to [Superwhisper](https://superwhisper.com).
>
> This is the original design spec. Some choices changed while building: the shipped default
> model is Parakeet TDT v3 (via FluidAudio), with Whisper models as alternatives. The code is
> the source of truth where the two disagree.

| | |
|---|---|
| **Status** | Draft v1 (requirements) |
| **Platform** | macOS 26+, Apple Silicon only |
| **Stack** | Swift 6, SwiftUI + AppKit, on-device Whisper |
| **Default model** | `whisper-large-v3-turbo` 8-bit ([mlx-community](https://huggingface.co/mlx-community/whisper-large-v3-turbo-8bit)) |
| **Distribution** | Notarized Developer ID DMG on GitHub Releases (not App Store) |
| **License** | MIT. Free to use, modify and redistribute. See `LICENSE`. |

---

## Table of Contents

1. [Vision & Mission](#vision--mission)
2. [Goals & Non-Goals](#goals--non-goals)
3. [Target Users & Personas](#target-users--personas)
4. [Positioning vs Superwhisper](#positioning-vs-superwhisper)
5. [Success Metrics](#success-metrics)
6. [Glossary](#glossary)
7. [System Overview](#system-overview)
8. [Transcription Engine — Decision](#transcription-engine--decision)
9. [Audio Capture & Pipeline](#audio-capture--pipeline)
10. [Latency Budget](#latency-budget)
11. [Text Injection](#text-injection)
12. [Model Manager](#model-manager)
13. [Performance & Concurrency](#performance--concurrency)
14. [Tech Stack & Project Layout](#tech-stack--project-layout)
15. [Security & Privacy](#security--privacy)
16. [Design Principles](#design-principles)
17. [The Pill — Anatomy & States](#the-pill--anatomy--states)
18. [Waveform Visualization](#waveform-visualization)
19. [Expanded View](#expanded-view)
20. [Interaction Model & Flows](#interaction-model--flows)
21. [Menu Bar Presence](#menu-bar-presence)
22. [Main Window / Settings Shell](#main-window--settings-shell)
23. [Motion & Micro-interactions](#motion--micro-interactions)
24. [Empty / Error / Onboarding States](#empty--error--onboarding-states)
25. [Functional Requirements](#functional-requirements)
26. [Settings — Full Specification](#settings--full-specification)
27. [Statistics / Dashboard](#statistics--dashboard)
28. [Vocabulary & Modes (Future)](#vocabulary--modes-future)
29. [Non-Functional Requirements](#non-functional-requirements)
30. [MVP Scope vs Later](#mvp-scope-vs-later)
31. [Roadmap & Milestones](#roadmap--milestones)
32. [Open Questions & Risks](#open-questions--risks)
33. [Performance Philosophy — Maniacal Optimization](#performance-philosophy--maniacal-optimization)

> **Note on the transcription engine (read first).** The default model the user picked
> (`mlx-community/whisper-large-v3-turbo-8bit`) is in **MLX/safetensors format**. The
> Architecture section recommends **WhisperKit (CoreML)** as the primary engine for
> lowest latency on the Neural Engine, with an **MLX engine** as a swappable fallback
> behind a `TranscriptionEngine` protocol. This is the single biggest open decision —
> see [OQ-2](#open-questions--risks). Wherever the spec says "MLX turbo-8bit," read it
> as "the default model, run by whichever engine wins the M1 latency spike." The engine
> abstraction means the rest of the spec is unaffected by the outcome.

---

# Part I — Product

## Vision & Mission

Dictari exists to make on-device voice dictation on Apple Silicon so fast and frictionless that it is the obvious alternative to typing — with zero privacy cost, zero subscription, and zero dependency on a network connection. Where cloud-based dictation services trade user privacy and monthly fees for convenience, Dictari bets that a local Whisper model running on the Neural Engine is fast enough to make that trade unnecessary.

**Guiding principles:**

- **Local-first, always.** Audio never leaves the device. No telemetry, no crash reporting that phones home, no model downloads forced through a proprietary server.
- **Latency above all.** Every architectural decision is evaluated against the end-to-end latency budget. A feature that slows insertion time by more than a few dozen milliseconds needs a very strong justification.
- **Minimal surface area.** The UI is a pill, not a dashboard. No preference panes users will never open, no feature bloat accreted to justify a price increase.
- **Open source, auditable.** The entire stack — including model loading, audio capture, and text injection — is readable and forkable. Trust through transparency.
- **No subscriptions, no gating.** The app ships with a capable default model. Advanced capabilities come from the user installing additional models, not from paying a tier.

---

## Goals & Non-Goals

### Goals

- Provide a global push-to-talk and toggle-to-record dictation experience triggered by a user-configured hotkey, available system-wide in any app.
- Inject transcribed text directly into the focused text field of the frontmost application using Accessibility APIs (AXUIElement) and CGEvent-based paste fallback.
- Ship with `whisper-large-v3-turbo` (8-bit quantized) preloaded; target end-to-end latency ≤ 800 ms for utterances under 10 seconds on an M-series chip.
- Display a live waveform pill during recording to give immediate visual feedback that audio is being captured.
- Support a model library UI where users can browse, install, and switch between additional Whisper variants.
- Dictation runs entirely without a network connection after the first model download; manual or
  user-enabled update checks are the only product-maintenance traffic.
- Publish the source on GitHub under the MIT license and ship a free notarized binary. Open source is what makes the privacy claim checkable.

### Non-Goals (MVP)

- **No cloud transcription.** No OpenAI Whisper API, no Apple Speech Recognition, no third-party cloud endpoint. Ever, as a core architectural option.
- **No mobile (iOS/iPadOS).** macOS Apple Silicon only. iOS requires a fundamentally different injection model.
- **No real-time captioning of external audio.** Dictari transcribes the user's own voice. It is not a live caption tool for meetings, videos, or other speakers.
- **No cloud sync or cross-device history.** Transcription history, if stored at all, lives only in a local store.
- **No built-in AI post-processing in MVP.** No LLM cleanup, translation, summarization, or command interpretation at launch.
- **No custom wake word or always-listening mode.** The microphone is activated only while the hotkey is held or the toggle is active.
- **No Windows/Linux support.** The stack (MLX/CoreML, Accessibility APIs, Swift) is Apple-only by design.
- **No enterprise MDM or multi-user account features.**

---

## Target Users & Personas

**Persona 1 — The Developer/Power User (primary)**
Writes code, comments, commit messages, PR descriptions, and long Slack messages. Already uses Alfred, Raycast, or custom hotkeys; expects tools that stay out of the way. Uses Superwhisper today but resents the subscription and worries about audio leaving the machine. Will compile from source if needed. Wants latency under one second and reliable injection into Terminal, Xcode, and VS Code. Success for this user means replacing keyboard shortcuts with voice without breaking flow.

**Persona 2 — The Privacy-Conscious Writer**
Journalist, researcher, or knowledge worker who dictates notes, drafts, and research summaries. Has declined every "send diagnostics" prompt ever shown. Runs macOS with strict privacy settings. May write about sensitive topics where cloud transcription is professionally unacceptable. Does not need a feature-rich app — needs one that provably does not talk to the internet. Will recommend Dictari to colleagues precisely because of what it does not do.

**Persona 3 — The LLM-Workflow Developer**
Uses Claude, GPT, or local models constantly and types long prompts into chat UIs dozens of times per day. Dictation is not a replacement for typing — it is a multiplier for prompt throughput. Cares about accuracy on technical vocabulary (model names, API terms, code identifiers) and wants the injection to land in the right field reliably. Will potentially script around Dictari's CLI interface or contribute model configurations upstream.

---

## Positioning vs Superwhisper

| Feature | Superwhisper | Dictari |
|---|---|---|
| **Price** | ~$8.49/month or ~$249 lifetime | Free |
| **Business model** | SaaS / paid license | None. Free and open source |
| **Transcription engine** | Whisper (cloud-enhanced tiers available) | 100% local Whisper |
| **Audio leaves device** | Yes, on higher-accuracy cloud tiers | Never |
| **Default model quality** | Varies by plan tier | whisper-large-v3-turbo (8-bit), capable on M1+ |
| **Model extensibility** | Locked to vendor-provided options | User-installable models |
| **macOS text injection** | Accessibility API + paste | Accessibility API + paste (same mechanism) |
| **Source code** | Closed | Open source (MIT), readable and auditable |
| **Network requirement** | Required for cloud tiers | Not required after initial model download |
| **Platform** | macOS, iOS | macOS Apple Silicon (iOS is non-goal) |
| **AI post-processing** | Yes (cleanup, translation, custom AI actions) | Roadmap; not in MVP |
| **Offline operation** | Partial (local-only tier available) | Always offline |

---

## Success Metrics

**Latency (primary)**
- End-to-end time from speech-end signal to first character inserted: **≤ 800 ms** for utterances ≤ 10 s on M1 / 16 GB RAM.
- Time-to-first-pill (hotkey press → waveform visible): **≤ 100 ms**.
- Model cold-load time (app launch → ready for first dictation): **≤ 3 s**.
- Model warm re-inference (second dictation after first): no additional load cost; target ≤ 600 ms end-to-end.

**Accuracy**
- Word Error Rate on standard English benchmarks (LibriSpeech clean): match published whisper-large-v3-turbo numbers (≤ 5% WER) when tested with the shipped quantized model.
- Subjective accuracy on technical vocabulary (code identifiers, model names, CLI flags): tracked informally via user-reported issues; target < 1 correction per 10-word technical phrase.

**Resource budget**
- Peak RAM during active transcription: **≤ 600 MB** (engine-dependent; see [Performance](#performance--concurrency)).
- Idle RAM (model loaded, not recording): **≤ 200 MB** target, **≤ 400 MB** hard limit (NFR-3).
- CPU/GPU usage while idle: **< 1%** — the app must be invisible when not in use.
- Energy impact in macOS Activity Monitor: "Low" at idle, "Medium" during active transcription. Must not appear in "Significant Energy" battery usage.

**Reliability**
- Injection success rate into tested apps (Xcode, VS Code, Terminal, Safari, Notes, Slack, Mail): **≥ 99%** on clean macOS installs.
- Crash-free sessions: **≥ 99.9%** (tracked locally via a write-to-disk crash log, not sent anywhere).

---

## Glossary

**Pill** — The small floating UI element that appears near the cursor (or screen center) when a dictation session is active. Displays a live waveform reacting to microphone input. Dismissed automatically when transcription completes and text is injected.

**Expanded view** — An optional secondary state showing the live transcript as words are recognized, plus session controls (cancel, copy to clipboard).

**Dictation session** — The lifecycle unit from hotkey activation (microphone opens) through audio capture, Whisper inference, and text injection. A single press-and-release or toggle-on/toggle-off cycle constitutes one session.

**Model** — A Whisper model variant (MLX or CoreML format), typically sourced from Hugging Face. Characterized by size (tiny → large-v3-turbo), quantization level (fp16, 8-bit, 4-bit), and language scope (multilingual vs English-only). The default shipped model is `whisper-large-v3-turbo` at 8-bit quantization.

**Injection** — The act of inserting transcribed text into the currently focused text input of the frontmost application. Attempted first via the macOS Accessibility API; falls back to writing to the pasteboard and synthesizing a Cmd+V key event.

**Push-to-talk (PTT)** — Hotkey mode where recording is active only while the key is held. Releasing the key ends the session and triggers inference. Lowest latency; lowest risk of accidental capture.

**Toggle mode** — Hotkey mode where the first press starts recording and the second press ends it. Useful for longer dictations where holding a key is impractical.

**Hotkey** — The global keyboard shortcut that activates Dictari system-wide, regardless of which app has focus. Configurable by the user. Default: ⌥Space.

---

# Part II — Architecture

## System Overview

Dictari is structured as a pipeline of eight discrete components. Each component owns a clear boundary; data flows unidirectionally from input to output with a single feedback path from the UI back to the pipeline for control signals (start/stop).

```
┌──────────────────────────────────────────────────────────────────────────┐
│                            Dictari Process                            │
│                                                                            │
│  ┌──────────────┐   hotkey event   ┌──────────────────────────────────┐   │
│  │  Hotkey      │ ──────────────► │  Pill UI (NSPanel, non-activating) │   │
│  │  Manager     │ ◄─────────────  │  waveform / state / dismiss        │   │
│  │  (Carbon /   │   stop signal   └──────────────────────────────────┘   │
│  │  CGEventTap) │                          ▲ amplitude (RMS)              │
│  └──────────────┘                          │                              │
│         │ start                            │                              │
│         ▼                                  │                              │
│  ┌──────────────┐  PCM Float32 ring buf  ┌─────────────────────────┐     │
│  │  Audio       │ ──────────────────────►│  Audio Pipeline / VAD   │     │
│  │  Capture     │                        │  (ring buffer, RMS,      │     │
│  │  (AVAudio-   │                        │   noise suppression,     │     │
│  │   Engine)    │                        │   silence timeout)       │     │
│  └──────────────┘                        └─────────────────────────┘     │
│                                                   │ ~480 ms chunks        │
│                                                   ▼                       │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Transcription Engine (protocol: WhisperKit | MLX)                │   │
│  │  encoder (ANE) + decoder (GPU/ANE), streaming partials           │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│         │ partial text            │ final text on stop                    │
│         ▼                         ▼                                       │
│  ┌──────────────────┐    ┌──────────────────┐                            │
│  │  Pill UI         │    │  Text Injection   │                            │
│  │  live fallback   │    │  (owned AX range /│                            │
│  └──────────────────┘    │   pasteboard ⌘V)  │                            │
│                          └──────────────────┘                            │
│                                                                          │
│  ┌──────────────────┐    ┌──────────────────┐                            │
│  │  Model Manager   │    │  Settings / Stats │                            │
│  │  (disk, download,│    │  Store            │                            │
│  │   manifest,      │    │                   │                            │
│  │   hot-swap)      │    └──────────────────┘                            │
│  └──────────────────┘                                                     │
└──────────────────────────────────────────────────────────────────────────┘
```

**Data flow summary:** A global hotkey fires → the Pill UI appears and Audio Capture starts → raw PCM is written into a ring buffer → the Audio Pipeline extracts RMS for the waveform and runs VAD → ~480 ms audio chunks are forwarded to the Transcription Engine → when the focused editor exposes a reversible writable selection, streaming partials replace one Dictari-owned provisional range in that editor; otherwise the pill remains waveform-only → on stop (user hotkey or VAD silence), the authoritative final transcript replaces the provisional range or uses the normal freshly-resolved injection path → latency and word-count metrics are written to the Stats Store.

---

## Transcription Engine — Decision

### Candidates

**WhisperKit (argmax-oss-swift)**
- Pure Swift, ships as a Swift Package.
- Model format: CoreML `.mlmodelc` bundles, compiled offline by Argmax and hosted on Hugging Face (`argmaxinc/whisperkit-coreml`).
- Streaming: native; the encoder supports sliding-window partial decoding; `AudioStreamTranscriber` publishes results as tokens arrive.
- ANE + Metal scheduling is automatic; no build flags required.
- `large-v3-turbo` is an explicitly supported and distributed model variant.
- MIT-licensed; active maintenance.

**mlx-swift / mlx-audio**
- The user's chosen default model (`mlx-community/whisper-large-v3-turbo-8bit`) is an **MLX-format, safetensors-quantized weight file** (~810–864 MB on disk).
- `mlx-audio` has a Swift package that wraps the MLX Swift framework.
- The MLX runtime operates on unified Apple Silicon memory and runs on GPU via Metal compute shaders; the Apple Neural Engine is only reachable via CoreML, so MLX does not use the ANE.
- Streaming support in the Swift layer is less mature than WhisperKit.
- Larger dependency surface.

**whisper.cpp**
- C++ library, callable from Swift via a bridging package.
- Model format: GGUF (the default model would require conversion).
- Metal works out of the box; CoreML encoder needs a separate build flag and converted model.
- Measurably higher latency than WhisperKit on the same hardware.

### Model Format Implication

The chosen default model is in **MLX/safetensors format**, which is **not directly loadable by WhisperKit** (needs CoreML `.mlmodelc`) or whisper.cpp (needs GGUF). Running this exact file natively implies the MLX path. However, Argmax distributes a pre-compiled CoreML `large-v3-turbo`, so the practical cost of choosing WhisperKit is using Argmax's hosted CoreML weights as the "default model" instead of the literal mlx-community file — a first-launch download of ~600–800 MB.

### Recommendation

**Primary: WhisperKit (CoreML).** Use Argmax's hosted `large-v3-turbo` CoreML bundle as the preinstalled default. Rationale: pure Swift, full streaming support, best measured latency on Apple Silicon, ANE acceleration without extra tooling, MIT license, actively maintained.

**Fallback / future: MLX engine via mlx-audio-swift.** Exposed as an opt-in alternative in the Model Manager manifest, enabling power users to run arbitrary mlx-community quantized models (including the literal 8-bit turbo file the user linked) without CoreML conversion. Wire it behind a `TranscriptionEngine` protocol so the engine is swappable at runtime.

**Do not use whisper.cpp as primary** — bridge overhead, GGUF conversion, and higher latency make it a poor fit for a latency-first app.

> ⚠️ **This is decided by a benchmark spike in milestone M1** ([OQ-2](#open-questions--risks)), not by this document. Both engines sit behind the same protocol; the loser becomes the opt-in alternative.

---

## Audio Capture & Pipeline

### Capture
Use `AVAudioEngine` with an `AVAudioInputNode` tap in real-time input mode. Install a tap with `installTap(onBus:bufferSize:format:block:)`, request the native hardware format, and convert to **16 kHz mono Float32** in the tap block using `AVAudioConverter` (Whisper requires exactly 16 000 Hz, mono, 32-bit float PCM).

```swift
inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
    self?.pipeline.ingest(buffer, at: time)
}
```

### Ring Buffer
Maintain a lock-free single-producer/single-consumer ring buffer sized to hold ~30 s of audio (480 000 samples, ~1.9 MB). This decouples the tap callback (real-time thread) from the pipeline (actor-isolated async thread).

### Voice Activity Detection
Primary path is a lightweight energy-based VAD:
- Compute RMS over each 10 ms frame (160 samples at 16 kHz).
- Maintain a ~300 ms trailing noise-floor estimate.
- `speechStart` when RMS exceeds `noiseFloor × 1.6` for 3 consecutive frames.
- `speechEnd` (auto-stop) after a configurable silence timeout (default 1 500–2 000 ms).

For higher accuracy, optionally integrate **Silero VAD** (CoreML, ~1 MB, < 1 ms/frame).

### RMS for Waveform
Expose a `@Published var amplitude: Float` from an `AudioPipeline` actor; publish each 10 ms RMS value to the main actor. The Pill UI reads this directly for its animated waveform bars.

### Permissions
`Info.plist` must contain `NSMicrophoneUsageDescription`. Microphone access is a TCC permission (`kTCCServiceMicrophone`); request it with `AVCaptureDevice.requestAccess(for: .audio)`. The app needs the `com.apple.security.device.audio-input` entitlement under hardened runtime.

---

## Latency Budget

Targets on M2 or later. "Streaming partial decode" means the first hypothesis word appears before the user finishes speaking.

| Stage | Target (ms) | Notes |
|---|---|---|
| Global hotkey → Pill appears | ≤ 20 | CGEventTap callback → `NSPanel.orderFrontRegardless`; NSPanel pre-allocated at launch |
| First audio frame captured | ≤ 5 | AVAudioEngine tap fires within one hardware buffer |
| VAD speech-start detection | ≤ 30 | 3 × 10 ms frames |
| First streaming partial decode | ≤ 400 | Sliding window: 480 ms chunk → encoder on ANE → first token stream |
| Per-chunk streaming cadence | 200–300 | New partial hypothesis every 200–300 ms of new audio |
| Final segment decode on stop | ≤ 300 | Flush remaining audio, run final decode pass |
| Text injection (pasteboard + ⌘V) | ≤ 30 | Pasteboard write + CGEvent post |
| **End-to-end (first word visible)** | **≤ 450** | Hotkey press → first word in target app |
| **End-to-end (full transcript injected after speech ends)** | **≤ 600** | Stop/VAD → full text in field |

**Current Parakeet dictation behavior:** decode completed phrases in the background, without
showing partial text. After at least 3 seconds, a conservative 450 ms quiet interval can close
one phrase. A single worker at user-initiated priority decodes each completed phrase once; stop reuses those results
and decodes the remaining original PCM, including samples not yet delivered by the audio pump.
Do not hard-cut speech: after 15 seconds without a safe boundary, defer the remaining phrase to
stop. Consequently the latency targets above are targets, not an unconditional guarantee.
Whisper continues to use its batch path. Missing/reordered audio callbacks, queue overflow, or a
failed/empty background decode fall back to the original complete recording. Keep the existing
recovery, frozen engine/language, cancellation/quarantine, vocabulary and final-only insertion
contracts. A cancelled background native call must actually finish before another engine is loaded.


---

## Text Injection

### 1. Pasteboard + Synthetic ⌘V (recommended primary path)
1. Snapshot the current pasteboard (all types) into memory.
2. `clearContents()` then `setString(transcript, forType: .string)`.
3. Post synthetic ⌘V via `CGEvent` keyboard events to `.cgSessionEventTap`.
4. After the target processes the paste, restore the original pasteboard contents only if the inserted text is confirmed and Dictari still owns the clipboard (if "Restore clipboard" is on).

`CGEvent.post` requires Accessibility permission (`kTCCServicePostEvent`). On first launch, check `AXIsProcessTrusted()` and prompt if false.

Track the current editable target while recording, refreshing it on user interaction and focus
notifications. Click coordinates are used only to resolve that click, never replayed at Stop.
Stop freezes the last completed, still-valid target or a closed clipboard-only decision; a pending
or later lookup must never acquire a destination for the stopped recording. Transient AX retries
are permitted only during target preparation and while both process and input generation match.
Before input, revalidate the exact field identity and capture a fresh verification baseline. A
custom AXGroup must expose writable text, not just selectable content. After input, count/caret
changes alone do not prove delivery: confirm the inserted range when the editor supports it;
otherwise keep the transcript and recovery. Once input has been posted to a validated field,
keep the brief compact feedback: missing AX evidence (including a submitted/cleared composer)
must not reopen the transcript preview. Show that preview for clipboard-only delivery, where no
input was posted. Never retry after posting ⌘V: an inconclusive receipt cannot justify duplicates.

### 2. Accessibility API — `AXUIElement.setValue` (fallback / replace mode)
Get the focused element of the frontmost app, then set `kAXValueAttribute`. This **replaces** the field value rather than inserting at the cursor, so use as a fallback or explicit "replace mode." Same Accessibility permission required.

### 3. CGEvent keystroke stream (last resort)
Synthesize per-character keydown/keyup events. Accurate cursor placement, no pasteboard touch, but slow for long text and unreliable for Unicode. Reserve for apps that intercept ⌘V.

### Clipboard Restoration
A delay alone is not confirmation. Restore only after the inserted UTF-16 range matches the transcript and the pasteboard ownership token still matches. Store the snapshot as `[(NSPasteboard.PasteboardType, Data)]` to preserve all UTI types, not just plain string.

### Secure Field Handling
Before injection, check `kAXSubroleAttribute` for `"AXSecureTextField"`. If detected, skip injection and show "Secure field — paste manually" in the pill, with a copy action.

---

## Model Manager

### Storage
All models live in `~/Library/Application Support/Dictari/Models/<manifestID>/`.

### Default Model Strategy
The default model is **downloaded on first launch**, not bundled (a ~700 MB+ app bundle is impractical for GitHub Releases, which caps single files at ~100 MB / 2 GB depending on release assets):
- On first launch, check whether the default model exists on disk.
- If absent, present an in-app download prompt showing size + ETA.
- Download via `URLSession` background transfer (`URLSessionDownloadTask`).
- Show progress in the pill placeholder / Models screen.
- Verify SHA-256 against the manifest before moving the file into place.

### Manifest Format
A `models-manifest.json` fetched over HTTPS (pinned URL, TTL-cached) drives the model list. Adding a model requires only a manifest push, no app update:

```json
{
  "schemaVersion": 1,
  "models": [
    {
      "id": "whisper-large-v3-turbo-coreml",
      "displayName": "Whisper Large v3 Turbo (CoreML, default)",
      "engine": "whisperkit",
      "variant": "large-v3-turbo",
      "isDefault": true,
      "sizeBytes": 734003200,
      "checksum": "sha256:<hex>",
      "downloadURL": "https://...",
      "minMacOSVersion": "26.0",
      "tags": ["fast", "accurate"]
    },
    {
      "id": "whisper-large-v3-turbo-mlx-8bit",
      "displayName": "Whisper Large v3 Turbo (MLX 8-bit)",
      "engine": "mlx",
      "sizeBytes": 906035200,
      "checksum": "sha256:<hex>",
      "downloadURL": "https://huggingface.co/mlx-community/whisper-large-v3-turbo-8bit/resolve/main/...",
      "minMacOSVersion": "26.0",
      "tags": ["mlx", "power-user"]
    }
  ]
}
```

The `engine` field selects the `TranscriptionEngine` implementation.

### Disk Accounting & Hot-Swap
Show per-model disk usage; warn before download if free space < `sizeBytes × 1.5`; allow deleting any non-active model. Switching the active model drains in-flight work, calls `engine.unload()`, instantiates + `warmUp()`s the new engine, and swaps the actor reference — no restart needed (~1–3 s, dominated by model load).

---

## Performance & Concurrency

### Swift Concurrency Architecture
- `AudioPipelineActor` — owns the ring buffer, VAD state, RMS publisher. Bridges the AVAudioEngine tap (real-time thread) to async via an `AsyncStream`.
- `TranscriptionEngineActor` — owns the engine instance; serializes transcription calls.
- `InjectionActor` — serializes pasteboard operations.
- Main actor — owns pill UI state and the `@Published` waveform amplitude.

Use structured concurrency throughout; avoid `DispatchQueue` in new code.

The only narrow, supervised exceptions are work owned by a dependency that cannot
cooperate with Swift cancellation:

- Third-party/native inference may run in one detached worker so a deadline or
  caller cancellation can return promptly instead of waiting for a native decoder.
  Cancellation must be forwarded immediately, the caller's result must resume
  exactly once, and the worker must report its eventual completion exactly once.
  A timed-out/cancelled engine is quarantined and never receives another utterance;
  at most one orphaned inference may exist, and only its eventual completion may
  release the quarantine and permit a fresh engine.
- Blocking Accessibility IPC may use a dedicated serial queue with an explicit
  messaging timeout. A cancelled or superseded request is discarded by its session
  token rather than updating UI or injection state; it never blocks the main actor
  or the event tap waiting for a wedged target. The queue remains the sole owner of
  its in-flight call and reports completion back through the current token.

### Engine Warm-Up
Pre-load the model at launch in a `Task.detached(priority: .background)` + one dummy inference to compile the ANE/GPU graph. Keep the model resident between dictations; evict only on memory pressure and reload on next hotkey.

### Main-Thread Policy
No file I/O, model inference, or ring-buffer reads on the main thread. RMS updates arrive as `@MainActor` publishes and must complete within one display frame (≈ 8 ms at 120 Hz).

### Memory Budget (WhisperKit/CoreML default)

| Component | Idle | Active |
|---|---|---|
| App shell (SwiftUI + AppKit) | ~25 MB | ~30 MB |
| CoreML model (large-v3-turbo, mmapped) | ~700 MB | ~700 MB |
| Ring buffer (30 s) | ~2 MB | ~2 MB |
| Transcription working memory | — | ~150 MB |
| **Total active** | | **~880 MB** |

The model is memory-mapped and pageable under pressure. Document an 8 GB minimum; 16 GB recommended.

---

## Tech Stack & Project Layout

### Stack
- **Language:** Swift 6 (strict concurrency)
- **UI:** SwiftUI for views; `NSPanel` (`.nonactivatingPanel`) for the floating pill so it never steals focus
- **Audio:** `AVFoundation` (`AVAudioEngine`, `AVAudioConverter`)
- **Transcription:** `argmax-oss-swift` (WhisperKit) primary; `mlx-audio-swift` optional target
- **Hotkey:** Carbon `RegisterEventHotKey` or `CGEventTap` (requires Accessibility)
- **Persistence:** `UserDefaults` for preferences; local store (SwiftData/SQLite/JSON) for history + stats
- **Networking (model download only):** `URLSession` background transfers
- **Login item:** `SMAppService`
- **Launch-at-login:** `SMAppService.mainApp.register()`

### Module / Target Layout
```
Dictari/
├── App/                  # @main, AppDelegate, Settings window
├── HotkeyManager/        # Carbon / CGEventTap registration
├── AudioCapture/         # AVAudioEngine tap, AVAudioConverter
├── AudioPipeline/        # Ring buffer, VAD, RMS publisher (actor)
├── TranscriptionEngine/
│   ├── TranscriptionEngine.swift  # Protocol + result types
│   ├── WhisperKitEngine.swift
│   └── MLXEngine.swift            # optional
├── ModelManager/         # Manifest, download, checksum, hot-swap
├── TextInjection/        # Pasteboard, CGEvent, AX fallback (actor)
├── PillUI/               # NSPanel subclass, SwiftUI waveform view
├── SettingsUI/           # SwiftUI preferences, model library
└── StatsStore/           # Latency, word-count, history logging
```

---

## Security & Privacy

### On-Device Only
All audio processing, VAD, and transcription run locally. No audio, transcripts, or dictation
metadata are ever sent to a remote server. Network access is limited to HTTPS model downloads
and signed Sparkle update checks initiated manually or enabled by the user.
Auditable with Little Snitch: zero outbound connections during dictation.

### Telemetry
**Off by default and opt-in only.** Default builds ship with telemetry disabled at compile time (`#if TELEMETRY_ENABLED`). Any opt-in crash reporting must be self-hosted/user-provided, never a hidden third party.

Apple MetricKit payloads are a local diagnostic source, not telemetry: Dictari may retain a
bounded archive of Apple-generated crash, hang and performance JSON under Application Support.
It also retains a bounded, typed lifecycle trail containing only permission/model readiness and
dictation/delivery states. The schema has no arbitrary message field. Nothing is uploaded
automatically. The only path out is an explicit **Export Diagnostics** save action; the export
never adds audio, transcripts, clipboard contents or focused-app metadata.

### Permissions Requested

| Permission | TCC Service | Why |
|---|---|---|
| Microphone | `kTCCServiceMicrophone` | Record audio for transcription |
| Accessibility | `kTCCServiceAccessibility` / `kTCCServicePostEvent` | Inject text via CGEvent ⌘V; read focused element subrole for secure-field detection |
| Network (outbound) | entitlement only | Download models on first use |

No screen recording, camera, contacts, location, or full disk access.

### Sandbox, Hardened Runtime, Distribution
The app is **not sandboxed** — sandbox blocks cross-process `CGEvent.post` and `AXUIElement` access, both core features (same as Raycast/Superwhisper). Consequence: **no Mac App Store**; distribute via a notarized Developer ID-signed `.dmg` on GitHub Releases. Hardened runtime is **enabled** with the microphone entitlement (and Apple-events automation if needed). Release pipeline: sign → notarize (`notarytool`) → staple → package, automated in GitHub Actions on a macOS runner. Downloaded models are SHA-256-verified against the manifest before use.

---

# Part III — UX / UI

## Design Principles

Dictari's visual language is a single rule applied without exception: **black, white, and the space between them.** No blue accents, no tinted glass, no semantic color.

### Core Tenets
- **Monochrome only.** Pure black (`#000000`), pure white (`#FFFFFF`), and a curated grey ramp (5/10/20/40/60/80% black). SF Symbols render in `.monochrome` only. System tints suppressed.
- **Motion in service of feedback, never decoration.** Every animation communicates a state transition. Zero animations at rest.
- **Never steals focus.** The pill is an `NSPanel` with `.nonactivatingPanel`; it floats above other windows without becoming key. It uses the status-bar window level plus `canJoinAllApplications` / `fullScreenAuxiliary`, so it remains visible over another app's full-screen Space without activating Dictari. The Settings window never opens unsolicited.
- **Perceived latency is the product.** The waveform reacts within one frame (≤ 16 ms at 60 fps); waiting feels structured, never frozen.
- **Accessibility is non-negotiable.** Dynamic Type in Settings, `accessibilityLabel`/`Hint` on all controls, VoiceOver state announcements, Reduce Motion collapses springs to 100 ms cross-fades.

---

## The Pill — Anatomy & States

The pill is a floating `NSPanel`, corner radius **22 pt** (half its height), solid fill (not vibrancy), `level = .statusBar`, ordered with `orderFrontRegardless()` and remembering its last position per display via `UserDefaults` (`pillLastOrigin`). The status-bar level plus `canJoinAllApplications` / `fullScreenAuxiliary` keeps the non-activating overlay above the active application's full-screen windows without becoming key or main. Default spawn: **bottom-center** of the display containing the frontmost app's key window, 48 pt above the screen edge.

### Idle / Collapsed
Dark capsule, **120 × 28 pt**, background `rgba(0,0,0,0.88)`. Five 4 pt dots, 7 pt apart, fill `rgba(255,255,255,0.35)`. Dots breathe subtly (opacity 0.25 → 0.45, 1.8 s, staggered 150 ms) — suppressed under Reduce Motion. Shown only if "Always show pill" is enabled; otherwise the pill appears only on hotkey.
**Enter:** drops in from 8 pt above, `spring(response: 0.3, dampingFraction: 0.72)`, fade 0 → 1 over 200 ms.
**Exit:** scale to 0.88 + fade out, 180 ms.

### Listening / Recording
Dark capsule with three explicit pointer targets: cancel, live feedback, and finish.
```
[ × ]  [════════ live waveform ════════]  [ ✓ ]
```
- **Cancel:** dark circular `×`; discards the active recording exactly like Escape.
- **Feedback:** the live waveform remains non-interactive. Partial transcript text is never shown
  in the pill; capable models write it only into a safely owned focused-field range.
- **Finish:** white circular `✓`; stops capture, transcribes, and delivers the final text exactly
  like the stop hotkey.
- Both actions are real accessible buttons with separate hit areas, labels, hints, tooltips, and
  pressed feedback. The non-activating panel must keep keyboard focus in the frontmost app.
**Enter from idle:** the shared black shell expands with the existing morph animation; Reduce
Motion uses the existing short cross-fade.

### Transcribing / Processing
White 360 × 44 pt form retained. Waveform replaced by a 1 pt horizontal shimmer (travelling bright spot, 1.2 s loop). Controls replaced by centered `"Transcribing…"` (11 pt, secondary) with a cycling-ellipsis (static under Reduce Motion).

### Success
Contracts to **200 pt**. `"checkmark"` (14 pt) + `"Inserted"` (12 pt), black. Held 900 ms then dismisses. If no focused field, move directly into the clipboard fallback preview without a visible failure/status sentence.

**Clipboard fallback transcript:** use a dark **260 × 52 pt** preview containing the transcript
itself and icon-only Improve and Copy controls. Do not add a separate clipboard-status glyph or
button. Never show visible wording such as
`"Not inserted"` or `"Copied to clipboard"`; preserve that state in accessibility labels and
tooltips. When the transcript truncates, the entire preview is the expansion target and includes a
small integrated chevron so the affordance is visible without becoming a third detached toolbar
button. Copy temporarily becomes a checkmark. Long transcripts expand into a
**360 × 220 pt** reading card with a separate header and scrollable 13 pt text. Grow from the
selected screen edge without moving the host window; suppress the size animation under Reduce
Motion. The panel remains non-activating and transparent margins pass clicks through.

### Error / No-Speech
Width 240 pt. `"waveform.slash"` + `"No speech detected"` / error string (11 pt secondary). 2 000 ms then dismisses, matching the menu-bar error hold and leaving enough time to read recovery guidance. No red, no color.

### Cancelled
Immediate exit animation (180 ms), no label. Silence is the acknowledgement.

---

## Waveform Visualization

The waveform is the soul of the pill — genuinely live, not decorative.

| Parameter | Value |
|---|---|
| Bar count | 28 (scales 28→56 with expanded-view width) |
| Bar width | 3 pt |
| Bar gap | 2.5 pt |
| Max bar height | 26 pt |
| Min bar height | 3 pt (never zero — "mic open") |
| Bar corner radius | 1.5 pt |
| Color | Black `#000000` |

**Audio mapping:** per-bar RMS from a rolling 512-sample buffer split into 28 bins weighted toward speech mid-range.
```
normalizedRMS = rms / referenceLevel   // referenceLevel ≈ -30 dBFS
barHeight = lerp(minHeight, maxHeight, clamp(normalizedRMS, 0, 1))
```
**Smoothing (per frame):** `displayHeight = displayHeight*0.55 + targetHeight*0.45` — snappy attack, graceful decay (~8–12 frames to settle).
**Cadence:** 60 fps via `CADisplayLink` on a dedicated queue; RMS computed on the most recent 512 samples each callback (sub-frame visual latency independent of audio buffer size).

**Dots → bars morph:** the 5 idle dots sit at the slots of bars 5/10/14/18/23; remaining 23 bars scale in (6 ms stagger, outward from center), dots morph corner radius 4 → 1.5 pt, color white → black; total 280 ms.

**Silence behavior:** below −60 dBFS for > 400 ms, bars decay to `minHeight` then enter a gentle sine sway (±1 pt, 1.5 s period, 0.12 rad phase offset/bar). Static under Reduce Motion.

**Reduce Motion:** transitions collapse to 100 ms cross-fades; waveform still updates live (it is functional feedback) with tighter smoothing (`0.65/0.35`).

---

## Expanded View

Opt-in alternative toggled in Settings → Appearance → "View Mode: Pill / Expanded"; takes effect next session (no ad-hoc mid-session switch).
**Size:** default **480 × 240 pt**, resizable (min 360 × 180, max 720 × 400), corner radius 16 pt, near-white frosted material (no color cast), same non-activating `NSPanel`.
```
┌──────────────────────────────────────────────────┐
│  ● Default  [mic picker ▾]              [×] close │  ← header 36 pt
├──────────────────────────────────────────────────┤
│      [═══════════ waveform, 48 pt tall ═══════]  │  ← waveform row 64 pt
├──────────────────────────────────────────────────┤
│  Live transcript, auto-scrolling,                │  ← transcript (flexible)
│  greyed partials, confirmed text black           │
├──────────────────────────────────────────────────┤
│  [Model: whisper-large-v3] [lang: auto]  [Stop]  │  ← footer 36 pt
└──────────────────────────────────────────────────┘
```
**Live transcript:** read-only `NSTextView`; confirmed tokens black 14 pt, in-progress partial in secondary grey; auto-scrolls unless user scrolled up (then a "↓ Latest" affordance appears).
**Edit before insert (off by default):** Stop switches the transcript to editable, button becomes `"Insert ⌥Space"`.
**Model indicator:** tappable → popover listing loaded models. Language shows detected/forced code.
**Resize:** `windowWillResize` clamps; waveform reflows, bar count scales proportionally.

---

## Interaction Model & Flows

### Activation Modes
- **Toggle (default):** press to start, press again to stop + transcribe + inject.
- **Push-to-talk:** hold to record, release to stop + transcribe + inject.

### Toggle-mode flow
```
⌥Space pressed → pill appears (Listening, ~0 ms) → waveform starts
⌥Space pressed → stop → Transcribing → inject into focused field → Success (900 ms) → dismiss
Esc            → discard at any point → instant dismiss (Cancelled)
```
### Push-to-talk flow
```
⌥Space down → record    ⌥Space up → stop → transcribe → inject → Success
Esc         → cancel (works mid-hold)
```
Global hotkey registered via `CGEventTap`, filtered to key-down, default ⌥Space, fully rebindable, torn down on quit.

### Injection
On success, insert at the insertion point via Accessibility (`kAXSelectedTextRangeAttribute` / `kAXValueAttribute`), requiring Accessibility permission. Fallback: copy to clipboard and show the compact transcript preview; the clipboard glyph communicates the state without a visible explanatory sentence.

### Multi-monitor
Pill appears on the display containing the frontmost app's key window at activation; per-display position memory recalls the preferred corner per screen.

### No focused text field
Detected at Stop: text is copied to clipboard and the compact transcript preview appears. The user is never blocked.

---

## Menu Bar Presence

`NSStatusItem` with a custom `NSStatusBarButton`, the app's persistent home.

### Icon States
| State | Appearance |
|---|---|
| Idle / Ready | `"waveform"` at full opacity, using the native menu-bar template tint (white on dark backgrounds, black on light backgrounds) |
| Recording | `"waveform"` full, subtle scale pulse 1.0 → 1.12 (static under Reduce Motion) |
| Transcribing | `"ellipsis"` cycling dots |
| Error | `"waveform.slash"` for 2 s, then idle |

### Native status-item menu
Assign an `NSMenu` to `NSStatusItem.menu`. AppKit owns the menu's material, sizing, placement, pointer tracking, keyboard navigation and dismissal, adopting the system appearance on the running macOS version. Use standard `NSMenuItem` rows, section headers, separators and one checked Profile submenu; no custom window, hosting view, background material, corner mask or presentation animation.

Contents: app name; status only when recording, processing or requiring attention; Start/Finish/Cancel and Copy Last Dictation grouped first; then Profile and Settings; finally About Dictari and Quit. The About submenu contains version, model and Check for Updates. Keep the recording shortcut as a concise native subtitle. Copy displays a bounded native preview on macOS 14.4+ and retains the complete transcript. Populate when AppKit requests an update, and update existing item properties for live state changes without rebuilding the menu during tracking.

---

## Main Window / Settings Shell

Standard activating `NSWindow`, `NavigationSplitView` hosted via `NSHostingController`, **820 × 540 pt** fixed, unified toolbar.

### Sidebar (200 pt, fixed)
Everyday pages first, developer-facing ones last. A search field on top (⌘F) finds any row,
including ones behind an "Advanced" disclosure. Page titles always equal the sidebar label.

| Group | Pages (symbol) | Holds |
|---|---|---|
| Overview | Home (`house`) | Stats, missing permissions, "Your setup" card (microphone, shortcut, languages) |
| Dictation | Dictation (`keyboard`) | Shortcut, mode, Conversation Mode, cancel; Languages I speak, language, spoken punctuation; capital letter, trailing space; Advanced: how text is inserted, keep clipboard, Live Typing |
| | Microphone & Sound (`mic`) | Microphone first; start/stop beep; stop by itself + quiet for; Advanced: what counts as silence, ignore distant voices |
| | Profiles (`slider.horizontal.3`) | Profiles and Language per Application |
| Words & Corrections | Vocabulary, Fix Mistakes | Custom words; Apple Intelligence fixes and per-app rules |
| History & Files | History, Files & Meetings | |
| App | Appearance (`paintbrush`) | Launch at Login, theme, recording indicator (style, position, always show) |
| Advanced | Speech Engine, AI Agents, Shared Settings, Diagnostics, Updates | |

`DICTARI_OPEN_SETTINGS` still accepts the old raw values `general` and `shortcuts` (→ Dictation).

Selected row: black fill + white text (no tint). Hover: 8% black. Row height 36 pt.

### Detail Panel
White background; content grouped in **rounded-rectangle cards** (12 pt radius, 4% black fill, 1 pt 10%-black border, 16 pt padding) — the primary container primitive.

| Role | Font | Size | Weight | Color |
|---|---|---|---|---|
| Card title | SF Pro | 13 | semibold | primary |
| Body / labels | SF Pro | 13 | regular | primary |
| Secondary / hints | SF Pro | 11 | regular | secondary |
| Monospace (hotkeys) | SF Mono | 11 | regular | primary in 8%-black capsule |

### Dark Capsule / Light Panel Duality
The pill is a dark capsule (active/ambient, present in the world); the Settings window is a light panel (deliberate configuration space). This holds regardless of system appearance.

---

## Motion & Micro-interactions

### Spring Token Library
| Token | Response | Damping | Used for |
|---|---|---|---|
| `snap` | 0.22 | 0.82 | Button presses, toggles |
| `appear` | 0.32 | 0.76 | Pill enter, panel open |
| `morph` | 0.38 | 0.72 | Pill width/height changes |
| `settle` | 0.55 | 0.85 | Waveform bar heights (via DisplayLink) |

**Summon:** `orderFront` then scale 0.82 → 1.0 + fade, `appear` spring, ~300 ms.
**Dismiss:** scale 1.0 → 0.88 + fade, linear 180 ms, then `orderOut`.

| Transition | Duration | Curve |
|---|---|---|
| Idle → Recording | 320 ms | `morph` |
| Recording → Transcribing | 200 ms | ease-out |
| Transcribing → Success | 150 ms | `snap` |
| Success auto-dismiss | hold 900 ms + 180 ms exit | linear |
| Error auto-dismiss | hold 2 000 ms + 180 ms exit | linear |

**Success feedback (no macOS haptics):** a soft 880 Hz sine, 80 ms, −18 dBFS (disable-able in Sound) + a single 120 ms white-flash on the pill. Under Reduce Motion: flash suppressed, sound stays. No sound on cancel.

**Waveform motion** runs on `CADisplayLink` + a `CALayer` renderer outside SwiftUI's update cycle for 60 fps without diffing overhead.

---

## Empty / Error / Onboarding States

### First Run — Permissions
A two-step onboarding inside the Settings window (before the sidebar appears), black/white only, two-dot progress indicator:
- **Step 1 — Microphone:** `"mic.fill"` 32 pt, one-sentence reason, **Grant Access** → `AVCaptureDevice.requestAccess(for: .audio)`. If denied → "Open System Settings" deep-link.
- **Step 2 — Accessibility:** `"accessibility"`, **Grant Access** → `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`. If denied → deep-link to the Accessibility pane.

On completion the card fades out (150 ms) and the sidebar slides in (`appear` spring). First-run flag stored in `UserDefaults`.

### Model Download Progress
Each model row shows `"arrow.down.circle"` + **Download**. On tap: a 4 pt horizontal track fills left→right with a `"47%"` label below; cancellable via `"×"`. On completion: snap to 100%, hold 300 ms, collapse to a checkmark. No circular spinner.

### No Speech Detected
Empty / `[BLANK_AUDIO]` result → Error state (`"waveform.slash"` + "No speech detected", 2 000 ms). Logged to History with a "no speech" tag. No modal, no sound.

### Transcription Failed
Inference throws → `"exclamationmark.triangle"` + "Transcription failed", 2 000 ms; one-line History entry; menu bar icon shows `"waveform.slash"` for 2 s. No crash reporter, no modal.

### History Empty State
Centered `"clock"` 28 pt secondary + "No transcriptions yet" (14 pt) + "Your dictations will appear here." (12 pt tertiary). No illustration, no CTA.

---

# Part IV — Features, Settings & Roadmap

## Functional Requirements

### Core Dictation Flow
| ID | Requirement |
|----|-------------|
| FR-1 | Register a global, user-configurable shortcut (default ⌥Space) active system-wide. |
| FR-2 | In **toggle mode**, one press starts dictation; a second press stops and injects. |
| FR-3 | In **push-to-talk mode**, holding starts dictation; releasing stops and injects. |
| FR-4 | The user can switch between toggle and push-to-talk from Settings. |
| FR-5 | A floating pill appears within 150 ms of dictation start with a live waveform reflecting mic amplitude. |
| FR-6 | The pill disappears within 300 ms of completion or cancellation. |
| FR-7 | Transcription is performed entirely on-device; no audio leaves the machine. |
| FR-8 | The default model is `whisper-large-v3-turbo` (8-bit); downloaded on first run with progress. |
| FR-9 | Transcribed text is injected into the frontmost field; primary = paste (⌘V), alternative = character typing (CGEvent). |
| FR-10 | When paste injection is used, the original pasteboard is restored if "Restore clipboard" is enabled. |
| FR-11 | Escape during an active session cancels recognition and discards the transcript. |
| FR-12 | The user can select the active microphone input from Settings; selection persists. |
| FR-13 | The user can switch the active model from Settings; switch applies next session. |
| FR-14 | The user can download additional models from a curated in-app list with per-model progress. |
| FR-15 | The user can delete any non-active downloaded model to reclaim disk space. |
| FR-16 | "Launch at Login" toggle via `SMAppService`, default enabled. |
| FR-17 | Three appearance modes (System / Light / Dark); palette stays strictly B/W in all. |
| FR-18 | The pill offers at least two style variants (Compact / Expanded), switchable in Settings. |
| FR-19 | Every completed session is appended to a local History log (transcript, timestamp, duration, language, target app bundle ID). |
| FR-20 | Per-session stats recorded (word count, speech duration, estimated time saved, latency); aggregated in a Dashboard. |
| FR-21 | The user can set a default transcription language or enable auto-detect. |
| FR-22 | The app lives in the menu bar with idle / recording / processing icon states. |
| FR-23 | All user data stored locally in `~/Library/Application Support/Dictari/`; nothing transmitted by default. Optional local MCP access is disabled by default, scoped by data category, and discloses that requested content becomes visible to the connected AI provider. |
| FR-24 | *(post-MVP)* Per-app injection behavior overrides (e.g. force typing in Terminal). |

---

## Settings — Full Specification

> The tables below are the original control spec. Where the controls now live, and their
> plain-language labels, follow the sidebar table in *Main Window / Settings Shell*.

### General
| Control | Type | Values / Behaviour |
|---|---|---|
| Launch at Login | Toggle | On/Off (default On) — `SMAppService.mainApp.register()` |
| Appearance | Segmented | System · Light · Dark (default System) |
| Default Pill Style | Segmented | Compact · Expanded (default Compact) |
| Pill Screen Position | Dropdown | Bottom-Center · Bottom-Leading · Bottom-Trailing · Top-Center · Cursor-Follow (default Bottom-Center) |
| Default Language | Dropdown + search | Auto-detect + ISO 639-1 list (default Auto-detect) |
| Injection Method | Segmented | Paste (⌘V) · Type (CGEvent) (default Paste) |
| Restore Clipboard After Paste | Toggle | On/Off (default On) — visible when method = Paste |
| Sound Cues | Toggle | Master switch over all Sound sub-settings |
| Show Transcription Preview in Pill | Toggle | Shows partial transcript before commit |
| Auto-capitalise First Word | Toggle | default On |
| Add Trailing Space After Injection | Toggle | default On |

### Shortcuts
| Control | Type | Values / Behaviour |
|---|---|---|
| Dictation Shortcut | Hotkey recorder | default ⌥Space; validates system conflicts |
| Interaction Mode | Segmented | Toggle · Push-to-Talk (default Toggle) |
| Cancel Shortcut | Hotkey recorder | default Escape |
| Secondary Shortcut | Hotkey recorder | optional, empty by default |
| Show Shortcut in Menu Bar Tooltip | Toggle | default On |

### Sound
| Control | Type | Values / Behaviour |
|---|---|---|
| Input Device | Dropdown | CoreAudio inputs; "System Default" first; live refresh |
| Input Level Meter | Live meter | ≥ 20 fps when pane open |
| Start Recording Sound | Dropdown + preview | None · Subtle Click · Tone Hi · Tone Lo (default Subtle Click) |
| Stop / Inject Sound | Dropdown + preview | None · Subtle Click · Tone Hi · Tone Lo · Whoosh (default Subtle Click) |
| Cancel Sound | Dropdown + preview | None · Low Thud (default Low Thud) |
| Stop After Silence | Toggle | Auto-stop on silence (default Off) |
| Quiet For | Slider | 0.5–5.0 s, 0.5 steps (default 2.5 s) — visible when auto-stop is On |
| What Counts as Silence | Descriptive menu | 1 (Very Tolerant) – 5 (Strict), default 3. Higher values stop more readily through room noise but may cut off a quiet voice. This does not alter the recorded audio. |
| Distant Voice Guard | Toggle + preset | Optional whole-dictation volume gate. Gentle / Balanced / Strict reject below 0.04 / 0.08 / 0.15 on the measured 0–1 voice meter. It is not speaker recognition and cannot remove a loud second voice from a kept recording. |

Sparkle update ordering uses the monotonically increasing `CFBundleVersion` / `sparkle:version`.
`CFBundleShortVersionString` is presentation only, so a higher build of the same visible version
(for example `0.1.3 (5)` over `0.1.3 (4)`) is still an update. Settings always displays both.

### Models Library
Each row: name · size on disk · accuracy badge · speed badge · download state · set-active radio.

#### Curated Model Tiers
| Model | Engine | Size (approx.) | Speed | Accuracy | Notes |
|---|---|---|---|---|---|
| whisper-tiny (8-bit) | MLX | ~45 MB | ●●●●● | ●○○○○ | Fastest, lowest accuracy |
| whisper-base (8-bit) | MLX | ~80 MB | ●●●●○ | ●●○○○ | Low-RAM devices |
| whisper-small (8-bit) | MLX | ~240 MB | ●●●○○ | ●●●○○ | Everyday balance |
| whisper-large-v3-turbo (8-bit) ★ | MLX / CoreML | ~810 MB | ●●●●○ | ●●●●○ | **Default / preinstalled** |
| whisper-large-v3 (4-bit) | MLX | ~1.1 GB | ●●○○○ | ●●●●● | Max accuracy; M2 Pro+ |
| whisper-distil-large-v3 | MLX | ~780 MB | ●●●●○ | ●●●●○ | Distilled, fast, near-large quality |

★ Downloaded on first run; others on demand.

| Control | Behaviour |
|---|---|
| Download | Background download, per-row progress + byte counter, cancellable |
| Delete | On installed non-active models; confirms bytes freed |
| Set Active radio | Immediate; applies next session |
| Total disk usage footer | Live sum of installed models |
| Open in Finder | Reveals model directory |

### History
| Control | Behaviour |
|---|---|
| Transcript list | Reverse-chronological; first ~80 chars, timestamp, duration, target app icon+name, language |
| No speech entries | Compact neutral badge with `waveform.slash`, also in menu-bar Recents; timestamp and duration stay visible in History; no Copy action for empty text |
| Search field | Full-text search with match highlight |
| Row actions | Copy · Re-inject into frontmost app · Delete |
| Bulk | Select All / Delete Selected with confirmation |
| Retention | Keep Forever · 7 / 30 / 90 days · 1 year (purge older at launch) |
| Privacy note | "All transcriptions are stored locally on this Mac. Nothing is sent to any server." |
| Export | Plain-text or JSON via save panel |

---

## Statistics / Dashboard

Landing screen of the Settings window.

**Time Range Selector:** 24 hours · 7 days · 30 days · 3 months · All time. The selector sits
with the usage chart and everything reacts; the 30-day view is the default.

### Hero Metric — Time Saved (the user's explicit priority over WPM)
> **Time Saved** — e.g. *4 h 12 min*

```
Time Saved = (Total Words Dictated ÷ Assumed Typing WPM) − Total Speech Duration
```
- **Total Words Dictated:** whitespace-delimited tokens across committed transcripts in the period.
- **Assumed Typing WPM:** user-configurable baseline (default **40 WPM**), with an inline slider on the card (20–120 WPM) that recomputes immediately.
- **Total Speech Duration:** sum of recording durations in the period.
- Negative result → show "0 s" + footnote "Adjust your typing speed baseline."
- Units: `X h Y min` ≥ 1 h · `Y min Z s` < 1 h · `Z s` < 60 s.

### Metrics Grid
| Metric | Definition |
|---|---|
| Words Dictated | Sum of word counts in period |
| Dictation Sessions | Count of completed (non-cancelled) sessions |
| Average Session Length | Total speech duration ÷ sessions |
| Average Transcription Latency | Mean stop→inject time (ms) |
| Most Used App | App + icon for the most-injected bundle ID |
| Longest Streak | Max consecutive days with ≥ 1 session (+ current streak) |

### Usage Over Time
Monochrome bar chart via **Swift Charts** (current band filled, past bands subdued). Preserve
empty bands so sparse data does not collapse the time axis: hourly for 24 hours, daily for 7/30
days, weekly for 3 months and monthly for all time. No third-party chart dependency.

---

## Vocabulary & Modes (Future)

Reserved as greyed-out sidebar placeholders for MVP.

**Vocabulary (Custom Dictionary):** user word list for proper nouns / jargon / brand spellings; post-processing replacement pass (word-boundary matching) before injection; simple add/edit/delete list with import/export.

**Learning Heard as variants:** each vocabulary editor offers “Suggest from history” and “Use a sentence…”. Suggestions are deterministic, local matches from up to 500 recent successful saved transcripts; show the observed spelling, occurrence count, date and an original context excerpt. Search runs off the main actor and cancels on dismissal. Never invent variants or add them without explicit selection and confirmation. Exclude canonical spellings, existing alternatives and variants assigned to other terms. Pasted text supports native selection of a word or short phrase and previews the replacement before adding it. Confirmed variants persist through the existing vocabulary store; history is never rewritten. Empty or unavailable history remains usable through the sentence flow.

**Sound-alike suggestions and “Scan history”:** history suggestions match by sound, not only by spelling, because the engine mishears rather than misspells (“Dipsick” for Deepseek, “di Tari” for Dictari, “Asense calibrator” for Sense Calibrator). Spellings are read as Italian/English/German sound classes (shared with the corrector's uncertain-word pass, whose own rules stay unchanged) and compared with a weighted distance where related sounds and vowels are cheap. A different first sound needs a near-identical rest; short phrases get a stricter bar; multiword windows must match word by word; common words alone and added articles are never candidates; each stretch of words is attributed to at most one term; words already written as a term or alternative are skipped. Candidates that are only moderately close and made entirely of dictionary words (system spelling dictionaries for it/en/de, checked on the main actor) are dropped. Vocabulary settings add “Scan history…”, which runs this for every enabled word off the main actor and lists suggestions grouped by word, each with context, occurrence count and a “Sounds like” label when the spelling differs. Each one is added to Heard as through the same learning path as History corrections, or dismissed. Nothing is applied automatically, and none of this runs on the dictation path.

**Modes (Transcription Profiles):** named profiles bundling model + language + vocabulary + injection override + auto-punctuation + a text transform. Proposed starters: **Default**, **Code** (strips punctuation, lowercases), **Email** (formal caps, paragraphs), **Notes** (loose). Manual trigger from menu bar, later auto per frontmost app (bundle-ID → mode rules, e.g. Xcode → Code).

---

## Non-Functional Requirements

| ID | Category | Requirement |
|---|---|---|
| NFR-1 | Performance | Transcription latency (stop→inject) ≤ 1.5 s for ≤ 10 s audio on M1+ with the default model. |
| NFR-2 | Performance | Pill appears within 150 ms of the shortcut firing. |
| NFR-3 | Performance | Idle memory (model loaded) ≤ 400 MB RSS. |
| NFR-4 | Performance | Idle CPU (model loaded) < 1% averaged over 30 s. |
| NFR-5 | Reliability | No crash on invalid audio input (e.g. mic disconnected mid-session); surface a non-modal error, return to idle. |
| NFR-6 | Reliability | A watchdog cancels any transcription running > 30 s, returns to idle, logs the failure. |
| NFR-7 | Privacy | No audio/transcript/telemetry transmitted by default; any opt-in crash reporter is labelled and off by default. |
| NFR-8 | Privacy | Request Microphone via `NSMicrophoneUsageDescription`; no recording before permission granted. |
| NFR-9 | Privacy | Request Accessibility via `AXIsProcessTrusted()`; degrade to paste-only if denied. |
| NFR-10 | Accessibility | Settings fully navigable by VoiceOver and keyboard Tab order. |
| NFR-11 | Accessibility | The pill never steals keyboard focus or interferes with assistive tech in the frontmost app. |
| NFR-12 | Localisation | UI ships English-first; strings externalised in `.xcstrings` from day one. |
| NFR-13 | Localisation | Transcription language independent of UI language; Whisper covers ≥ 90 languages. |
| NFR-14 | Offline | Fully functional with no network after first-run model install. |
| NFR-15 | Distribution | Open-source release (MIT) as a notarized Developer ID DMG on GitHub Releases; App Store not planned. |
| NFR-16 | Compatibility | Minimum macOS 26; Apple Silicon only (no Intel/Rosetta for MVP). |

---

## MVP Scope vs Later

| Feature | v0.1 MVP | v0.2 | Future |
|---|---|---|---|
| Global configurable hotkey | ✓ | | |
| Toggle mode | ✓ | | |
| Push-to-talk mode | ✓ | | |
| Floating pill + waveform | ✓ | | |
| Cancel with Escape | ✓ | | |
| Local transcription — default turbo-8bit | ✓ | | |
| Paste injection (⌘V) | ✓ | | |
| Typing injection (CGEvent) | ✓ | | |
| Restore clipboard | ✓ | | |
| Menu bar icon with state glyphs | ✓ | | |
| Settings (General, Shortcuts, Sound, Models, History) | ✓ | | |
| Launch at Login | ✓ | | |
| Basic Dashboard (time saved, words, sessions) | ✓ | | |
| Basic History log (no search) | ✓ | | |
| System / Light / Dark appearance | ✓ | | |
| Pill style variants (Compact / Expanded) | | ✓ | |
| History full-text search | | ✓ | |
| Model library — download additional models | | ✓ | |
| Model delete / disk management | | ✓ | |
| VAD / auto-stop on silence | | ✓ | |
| Noise suppression | | ✓ | |
| Usage-over-time Swift Chart | | ✓ | |
| Per-app injection overrides | | | ✓ |
| Vocabulary / custom dictionary | | | ✓ |
| Modes (Code, Email, Notes…) | | | ✓ |
| Per-app mode assignment | | | ✓ |
| Opt-in crash reporter | | | ✓ |
| Intel / Rosetta support | | | ✓ |
| App Store release | | | ✗ (unlikely) |

---

## Roadmap & Milestones

| Milestone | Name | Key Deliverable |
|---|---|---|
| M0 | Skeleton | Xcode project, SwiftUI shell, menu bar item, Settings navigator (empty screens), `SMAppService` login item, build + notarization pipeline. |
| M1 | Transcription Works | Global hotkey, AVAudioEngine capture, **engine spike: WhisperKit vs MLX benchmarked against NFR-1**, transcript logged to console. |
| M2 | Pill + Injection | Floating pill with live waveform, Escape cancel, paste + typing injection, clipboard restore, menu bar state icons, start/stop sounds. Daily-usable end-to-end. |
| M3 | Settings + Stats | All Settings screens functional, Dashboard with Time Saved hero + metrics grid, persistence for history + stats. |
| M4 | Model Library | Curated model download/delete/switch UI, per-model progress, disk footer, VAD + noise suppression, History search, pill style variants. |
| M5 | OSS Release | Cleanup, README, CONTRIBUTING, notarized DMG via GitHub Actions, first public tag, open repo. |

---

## Open Questions & Risks

| # | Topic | Question / Risk | Mitigation |
|---|---|---|---|
| OQ-1 | Model bundling vs download | Bundling turbo (~810 MB) bloats the DMG and hits GitHub Release file limits. | Download on first launch with a progress sheet; ship a < 20 MB stub DMG. |
| OQ-2 | **MLX vs WhisperKit engine** | The user's chosen model is MLX-format, but WhisperKit/CoreML likely wins on latency (uses ANE). Picking wrong risks a rewrite. | **Benchmark both in M1** behind the `TranscriptionEngine` protocol; primary = whichever meets NFR-1, the other becomes opt-in. |
| OQ-3 | Injection reliability | CGEvent typing is unreliable in some Electron/web/terminal apps; paste clobbers the clipboard. | Ship both methods + per-app override in v0.2; document known-incompatible apps. |
| OQ-4 | Latency target feasibility | NFR-1 (≤ 1.5 s) untested for turbo-8bit on M1; segmentation overhead may exceed it. | M1 latency spike; if missed, default to whisper-small with turbo opt-in, or lean on streaming partials. |
| OQ-5 | Accessibility permission UX | Granting Accessibility requires a manual System Settings trip; cannot be automated. | Dedicated onboarding sheet with deep-link; degrade to paste-only until granted. |
| OQ-6 | App Store distribution | Accessibility entitlement is incompatible with App Store sandboxing. | Distribute as a notarized Developer ID DMG on GitHub Releases; don't invest in App Store compliance. |
| OQ-7 | Privacy regression risk | A future contributor could add a network dependency that leaks audio/transcripts. | CONTRIBUTING policy: no network without explicit opt-in gate; CI lint failing on new networking imports outside a labelled `Telemetry` module. |

---

## Performance Philosophy — Maniacal Optimization

> **This is not a feature. It is the entire reason Dictari exists.**
> Superwhisper is "fast enough." Dictari must feel *instant* — the kind of fast where the user stops perceiving the tool at all and only perceives their own thought becoming text. Every other principle in this document yields to this one. When a design choice trades 50 ms of latency or 100 MB of RAM for convenience, the answer is no by default; the burden of proof is on the feature, not on the performance.

### Why It Matters

Dictation only replaces typing if it is faster than typing *and* feels effortless. A 1.5 s wait after speaking breaks flow; a stutter in the waveform reads as "the app is struggling"; a 900 MB idle footprint gets the app quit. The edge over a cloud-assisted product is precisely that a *local* tool can be made to feel faster than a *networked* one — there is no round-trip to hide. We must actually deliver on that.

### Non-Negotiable Performance Invariants

These are hard gates, not aspirations. A build that violates any of them is a regression and does not ship.

| Invariant | Target | Hard fail |
|---|---|---|
| Hotkey → pill visible | ≤ 50 ms | > 100 ms |
| Waveform frame rate | 60 fps (120 fps on ProMotion) | any sustained drop below 60 fps |
| Waveform audio→pixel latency | ≤ 16 ms (one frame) | > 33 ms |
| First streaming partial word | ≤ 400 ms after speech start | > 700 ms |
| End-to-end (speech end → text inserted) | ≤ 600 ms for ≤ 10 s audio | > 1.5 s (NFR-1) |
| Idle CPU (model resident) | ~0%, < 1% averaged | > 1% sustained |
| Idle RAM | ≤ 200 MB | > 400 MB (NFR-3) |
| Energy impact (idle) | "Low" / invisible in Activity Monitor | appears in "Significant Energy" |
| Cold launch → ready | ≤ 3 s | > 5 s |

### Engineering Rules That Enforce It

1. **Latency is a first-class budget, tracked per-stage.** The [Latency Budget](#latency-budget) table is a contract. Each stage owns a millisecond allowance; a stage that overruns must give the time back elsewhere or be redesigned. Latency is measured in CI on a reference machine, not eyeballed.
2. **Pre-allocate everything on the hot path.** The pill `NSPanel`, the audio ring buffer, the waveform `CALayer`s, and the engine are all allocated at launch and reused. Zero allocation between hotkey-press and first-pixel. No lazy-init, no JIT view construction in the dictation flow.
3. **Keep the model warm, always.** The transcription engine is loaded once and never unloaded except under genuine memory pressure. A dictation never pays model-load cost. Warm-up runs a dummy inference at launch to compile the ANE/GPU graph.
4. **The waveform never touches SwiftUI's diffing.** Rendered on a `CADisplayLink` + `CALayer` path, off the SwiftUI update cycle, so 60 fps is structurally guaranteed and independent of any view invalidation.
5. **Nothing heavy on the main thread.** No file I/O, no inference, no ring-buffer reads, no JSON parsing on the main actor. The main thread does animation and the panel lifecycle, nothing else. Audio capture lives on its real-time thread, bridged to actors via `AsyncStream`.
6. **Hide latency behind speech.** Decoding starts on the first ~480 ms of audio, not on stop. By the time the user stops talking, most of the transcript already exists. Perceived latency ≪ actual compute time.
7. **Use the right silicon.** Encoder on the ANE (the dominant cost), decoder attention on the GPU via Metal — verified with Core ML Performance Report, not assumed. The engine choice (OQ-2) is settled by *measured* latency, not by which API is nicer.
8. **Measure before optimizing, then measure again.** Every perf claim is backed by Instruments: Time Profiler for hotspots, the SwiftUI/Animation Hitches instrument for the pill, Allocations for the idle footprint, Energy Log for battery. "It feels fast" is not evidence.
9. **Idle must be free.** When not dictating, the app is effectively asleep: no timers spinning, no polling, no background work. The menu-bar presence costs nothing measurable. A laptop user should never notice Dictari is running.
10. **Binary and dependency discipline.** Minimal dependencies (no Combine, no third-party UI frameworks, no chart libraries). Every added package is weighed against launch time and binary size. Small, native, fast.

### Performance as a Gate in the Process

- **CI latency benchmark.** A scripted dictation runs in CI on a reference Apple Silicon machine and asserts the invariants above; a PR that regresses any gate fails.
- **Instruments traces in PRs.** Performance-relevant PRs attach a `.trace` showing the relevant metric before/after.
- **A regression is a bug.** Slipping from 500 ms to 800 ms end-to-end is treated with the same severity as a crash, not as "still under target."
- **Profile on the floor, not the ceiling.** Validate on the *minimum* supported hardware (base M1, 8 GB) under thermal load, not only on the developer's top-spec machine.

> The single sentence to keep in mind for every PR: **"Does this make the path from thought to text shorter, or longer?"** If longer, it does not merge without an extraordinary reason.


## Usability refinement — 5 September 2026

- Setup shows the selected model and keeps alternatives in an “Other models” menu. File availability is inspected off the main actor, outside view rendering, and refreshed after model loading finishes.
- Loading shows the backend's reported percentage rather than multiplying an estimated model size into an apparently exact downloaded-byte count. Size estimates remain explicitly approximate.
- History search is above both lists and includes recovery transcript, originating app and failure description. Recovery rows show a short transcript preview; searches and previews never alter stored recordings or text.
- Automatic stop uses plain-language labels (“Stop after silence”, “Pause Length”). Existing defaults and audio thresholds remain unchanged.
- Recording and processing durations use a monotonic clock. Displayed processing latency still measures stop to initial delivery/copy, not deferred insertion confirmation.
- Model descriptions do not imply Intel support or coverage of every language.


## Feature and performance refinement — 5 September 2026

- Menu offers Copy Last Transcription from the existing in-memory latest transcript, independently of pill visibility and history retention. Disabled before a transcript exists in this app session. It copies only; no synthetic paste, no new global shortcut and no additional persistence.
- Explicit Clear All Transcriptions also clears this in-memory copy; saved recoveries remain untouched and an active dictation is not cancelled.
- Vocabulary settings preview consumes corrected text and ordered corrections from a single matcher pass.

## Vocabulary import/export — 5 September 2026

- Vocabulary settings offer native Import/Export file panels for JSON archives. Export includes canonical words, Heard as alternatives and enabled state; no transcript/history/audio is included.
- Version 1 archives identify themselves as `dictari-vocabulary`; import also accepts legacy vocabulary.json arrays. Unknown formats/versions, malformed entries and files over 2 MiB or 5,000 entries are rejected before mutation.
- Import adds words and unions trimmed alternatives, matching canonical words case/accent-insensitively. Existing spelling, row identity and enabled state win. Incoming row IDs are regenerated for new words. Reimporting the same archive is idempotent.
- Bulk import rebuilds the corrector and enqueues one atomic save. All vocabulary saves use a serial queue so older edits cannot overwrite newer snapshots. Disk failures remain visible in settings; changes remain in memory and may be exported.
- Selected-file reads/writes run off the main actor. Import reads at most the byte limit plus one; export uses atomic replacement. Cancelling a file panel has no side effects.

## App languages and lightweight profiles — 5 September 2026

- General settings offer Language per Application via a native application picker. Rules use bundle identifiers, with display names for readability; re-adding an app preserves its rule, removal returns it to profile/default behavior.
- Precedence: application rule > selected profile language > default language. `auto` explicitly requests detection. Matching is for the frontmost application when capture starts, not a browser tab/site.
- Four fixed profiles are selectable in General and the menu bar. Default follows general formatting; Code preserves case/punctuation and adds no suffix; Email capitalises the first letter and adds a space; Notes capitalises and adds a newline. Each profile can remember a language. These conservative rules supersede the earlier proposed Code lowercasing/punctuation stripping, which could corrupt identifiers. No AI rewriting, code generation, model switching or per-profile vocabulary fork.
- Engine/language/formatting are frozen for a recording. The existing workspace lookup runs after audio capture starts. Changes during recording apply to the next session. No background polling or new model loads.
- Profile formatting is applied once before delivery; clipboard fallback, latest transcript, history and successful-transcription recovery text use that result. A failed inference retried from raw recovery audio still uses its saved language and the existing plain-text retry path.
- Settings additions are optional for backward decoding; unknown profile names fall back to Default.

## Files, meetings and team packages — 5 September 2026

- Files & Meetings is a separate workspace. Import audio/video supported by AVFoundation; only audio tracks are decoded, mixed to 16 kHz mono Float32 and saved as bounded 20-second chunks. Current limit: four hours per file. No full-file PCM allocation. Silent/corrupt/unsupported files report errors, original input is never altered.
- One media job owns the existing ready engine. Normal dictation and recovery retry cannot overlap it; model changes are deferred. Cancellation remains busy until inference actually returns. No second resident ASR engine or repeated transcription of a growing meeting.
- On macOS15+, meeting capture explicitly selects a running app and optionally microphone through ScreenCaptureKit. All windows/tabs of that app may contribute audio. Participants must be informed and agree before Start; capture is visible with Stop & Finish. No video output is registered. The operating system controls recording permissions. Headphones are recommended to prevent echo.
- Meeting PCM is appended to disk during capture. Sealed five-second segments feed sequential transcription; backlog remains on disk and is visible. Approximate segment timestamps retain microphone/app-audio source labels during capture. Latency is segment duration plus inference/queue time, not word-by-word streaming.
- Documents retain audio and transcript locally; interrupted chunks have sidecars for rediscovery. Resume processes unfinished segments. Export produces timestamped plain text. Delete requires explicit confirmation and removes that document and audio. There is no automatic retention deletion yet.
- Team provides a manual JSON package for vocabulary and profile/app-language defaults, with import preview. Existing personal settings win and vocabulary duplicates merge. No audio, transcripts or credentials are exported. This is not centralized administration, SSO, permissions enforcement, fleet deployment or automatic sync.
- Phone version remains planned. Automatic identification of meeting participants by name, summaries, subtitles, centrally managed companies and cloud collaboration remain separate work. No such capabilities are advertised as implemented.
- Before public release: physical capture/permissions/echo test, long recording test, cross-channel timing and word accuracy at chunk boundaries, CPU/RAM/backlog on M1, crash/restart and stop-during-start tests, actual model and media-format matrix. Host-less unit tests cannot establish these properties.


## Apple Intelligence writing preview (2026-09-05)

This explicitly extends the original MVP exclusion of AI post-processing. Writing is manual,
on-device and separate from dictation: Correct, Make clearer, Email and Organize notes.
Available through Writing, history rows and completed file/meeting text. Original transcripts
are never overwritten; the user reviews and explicitly copies the revision. There is no
automatic injection, cloud fallback, account, API key or model inference at app startup.

Foundation Models uses SystemLanguageModel.default on macOS 26+ with availability checks.
The rest of Dictari supports macOS 26+. This first version accepts at most 3,000 characters
and 12 KB UTF-8, never silently truncates, and asks for a shorter passage on context errors.
Long-document chunking and automatic profile activation are not implemented in this version.
Cancellation discards late output and prevents overlapping requests until the backend returns.
The preview is memory-only and cleared when leaving; original history retention is unchanged.
Model edits can alter meaning, so names/numbers and content must be reviewed before use.


## Writing in the pill and per-app offers (2026-09-05)

Clipboard fallback includes an explicit Improve action. It expands the existing non-activating
black pill into an on-device correction/rewrite preview, with original comparison and explicit
copy. It never replaces a focused field or changes the historical original.

Writing settings let users choose app bundles individually (no apps enabled by default).
Each rule has Never, Ask after pasting, or Prepare preview automatically, and a writing action.
Both active modes deliver the original immediately; Ask starts no model until Yes. Automatic
means generating a preview after delivery, not automatically replacing the pasted text.
Code profile disables app rules. Rules and app identity are frozen at recording start; offers
are suppressed for clipboard-only/failed delivery or when the current app no longer matches.
Unverified paste is labelled Paste requested, never Inserted. Compact requests dismiss after
15 seconds. Expanded previews remain until dismissed or a new dictation supersedes them;
cancelled or stale model responses cannot replace them. Ordinary dictation has no added AI wait.
Onboarding mentions optional per-app setup without enabling any app or running the model.


## Writing and navigation simplification — 7 September 2026

This supersedes the automatic-preview behavior described above. The fixed Command-Option-Shift-
Space shortcut starts a dictation with correction in every application and profile, following the
selected toggle or push-to-talk interaction mode. The ordinary shortcut uses the frozen app rule:
Off preserves the transcript, Ask offers an optional revision after pasting, and Automatic revises
before a single insertion. Code disables app rules but not explicitly requested correction.
Automatic/explicit correction shows compact monochrome moving text strokes in the pill, not an
expanded preview. The model limits and local availability checks still apply. Revision failure
shows an error and preserves the original in History and recovery, without silently inserting it.
Successful delivery uses the existing focus/PID checks; History retains the pre-revision original.
Cancellation rejects late output and the model slot stays occupied until the backend exits.

Profiles has its own settings section for profile formatting and per-application languages.
Writing separately explains correction and revision. Shared Settings replaces the Team label and
explicitly describes manual vocabulary/settings file exchange, with no automatic team sync.
Writing actions use outcome-based labels, show the selected action's one-line effect, and keep the
complete action guide collapsed by default so the editor stays compact.
The manual editor may reveal a throttled working draft while Apple Intelligence is generating;
copy and automatic insertion remain unavailable until the complete validated result arrives.
Settings is a managed window at the normal level while active. When another app becomes foreground, Settings moves one level below normal so accessory-app grouping cannot keep it above that app; activating Settings restores its normal level. It stays open and clickable. Only the non-activating pill is an overlay across apps/Spaces.
Processing animation is a bounded 30 fps drawing leaf and pauses when hidden or Reduce Motion is on.
History uses a bounded native table viewport with reusable fixed-height rows for the full archive,
without incremental page accumulation. Full text remains available through a shared detail view;
copy, revision and deletion use the original record. Search scans the full immutable archive
snapshot off the main actor, debounces typing, and rejects stale/canceled results. Static localized
dates replace per-row live relative-date updates. Shortcut displays share the same keycap capsule
in Shortcuts and Writing; the fixed correction shortcut has no recording interaction.


## Continuous pill presentation — 7 September 2026

All pill states share one persistent black shell. Width, height and corner radius interpolate
from the current presentation; changing content cross-fades inside its clipped bounds. Writing
preview close contracts directly to idle when always-show is enabled. Otherwise it keeps the
current card until its exit finishes, then clears presentation state. First appearance commits
an invisible layout before revealing. Interrupted entrances/exits are generation fenced so a
cancelled window-hide task cannot truncate the next animation. Fixed screen-edge anchors keep
the host window stationary while content morphs. Reduce Motion uses the existing short fade.


## Custom dictation profiles — 7 September 2026

- Profiles supports creating, duplicating, editing/renaming and deleting personal profiles. Built-in Default/Code/Email/Notes remain available as templates; Customize creates an independent copy.
- Each custom profile has a stable identifier, a unique user-editable name, optional language, first-letter capitalization, ending (nothing/space/new line), and Writing behavior (app rules/off/ask/automatic) plus an existing Writing action. No model switch, per-profile audio engine or free-form AI prompt is implied.
- New profiles become active for the next dictation. Profile edits and removal do not change an already captured recording context. Deleting the selected custom profile selects Default.
- Language precedence remains application rule > custom profile language > global language. Custom Writing behavior can override app rules; the explicit correction shortcut keeps working in every profile.
- Custom profiles appear in the menu-bar profile switcher and Profiles Settings. Optional settings and shared-package fields preserve existing JSON compatibility. Sharing merges profiles without replacing personal IDs or names and does not change the active profile.


## Meeting efficiency and optional voice analysis — 7 September 2026

- Selecting or opening a browser never starts capture. Meeting recording starts manually and stops explicitly; no browser polling or automatic speaker model runs at startup.
- Capture reuses conversion buffers, omits exact digitally silent segments and stores silent gaps sparsely. Quiet nonzero audio is retained. Transcription waits for segment callbacks instead of polling every 500 ms, and skips exact zero PCM in existing archives too.
- Completed meetings offer Distinguish voices. Only this explicit action loads/downloads a separate local FluidAudio LS-EEND model; analysis runs after capture, with progress and cancellation, and releases its model afterward. The first download requires a connection; subsequent cached analysis is local.
- Analysis supports meetings up to one hour and up to ten anonymous voice slots in the app-audio track. Microphone remains a source label. Labels are estimates, not identities; a five-second text block can list multiple speakers. Original audio and text are preserved. No word-level attribution is claimed.
- The menu uses `NSStatusItem.menu` and native `NSMenuItem` controls. macOS provides its current menu appearance, including Liquid Glass where the system uses it, and owns presentation and tracking. This supersedes both the original custom popover and the build 16 manual-material workaround.
- Copy Last Dictation retains the full original text; only the native subtitle (46 characters) and tooltip (240 characters) are shortened. Built-in and custom profiles use the same checked submenu. No custom SwiftUI content or effects run inside the menu, and no application I/O or model work runs while building its rows. A presentation-only `MenuBarMenu` renders the coordinator's snapshot and forwards actions, allowing the same native component to run in a preview without services or user data.
