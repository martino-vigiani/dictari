#!/bin/bash
# Runs the deterministic part of the test suite: the classes below download no model, open no
# microphone, synthesize no speech and post no keyboard events, so they run anywhere in minutes.
# CI runs exactly this. The rest (transcription, streaming, latency and ASR quality benchmarks,
# audio capture) needs real models or a microphone and runs locally only; see CONTRIBUTING.md.
#
# Usage: ./scripts/ci-tests.sh [extra xcodebuild arguments]

set -euo pipefail
cd "$(dirname "$0")/.."

CLASSES=(
  AccidentalSessionTests AgentProposalStoreTests AppFeedbackPresentationTests AppWritingRuleTests
  ConversationAudioSegmentTests ConversationHotkeyTests ConversationPolicyTests
  CorrectionLearningTests CustomDictationProfileTests DashboardTimelineTests DictationProfileTests
  DictationRecoveryRetentionPolicyTests DictationRecoveryStoreTests DictationRevisionRegressionTests
  EnergyVoiceActivityDetectorTests HistoryFailureDescriptionTests HistorySearchTests
  HistoryTimelineTests HotkeyMatchingTests InjectionTests LiveTypingTests LocalDiagnosticsStoreTests
  LocalMCPAuthPolicyTests LocalMCPServerTests MediaArchiveTests MeetingApplicationSelectionTests
  MeetingCaptureTimingTests MeetingSpeakerRuntimeTests MenuBarPresentationTests ModelIntegrityTests
  ModifierTapGestureTests PhoneticVocabularyScanTests PillGeometryTests PillHostingViewTests
  PillWindowRecoveryTests PinnedModelDownloaderTests SettingsPersistenceTests SettingsSearchTests
  SoundClassesTests SpokenFormattingTests SpokenLanguagesTests TeamPackageTests TextRefinementTests
  TranscriptionDeadlineTests UncertainSpanRenderingTests VocabularySuggestionsTests VocabularyTests
  VocabularyTransferTests WritingPromptPolicyTests
)

only=()
for class in "${CLASSES[@]}"; do
  only+=("-only-testing:DictariTests/$class")
done

xcodebuild -project Dictari.xcodeproj -scheme Dictari \
  -destination 'platform=macOS,arch=arm64' \
  test "${only[@]}" "$@"
