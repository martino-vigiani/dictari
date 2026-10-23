import Foundation
import FoundationModels

@MainActor
struct AppleTextRefiner: TextRefiner {
    var unavailableReason: String? {
        guard #available(macOS 26.0, *) else {
            return String(localized: "Apple Intelligence requires macOS 26 or later. Normal dictation remains available.",
                          comment: "Writing unavailable reason")
        }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible):
            return String(localized: "This Mac does not support Apple Intelligence.", comment: "Writing unavailable reason")
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Enable Apple Intelligence in System Settings, then refresh availability.",
                          comment: "Writing unavailable reason")
        case .unavailable(.modelNotReady):
            return String(localized: "Apple Intelligence is downloading or preparing its model. Try again when it is ready.",
                          comment: "Writing unavailable reason")
        case .unavailable:
            return String(localized: "Apple Intelligence is currently unavailable. Check System Settings and try again.",
                          comment: "Writing unavailable reason")
        }
    }

    func refine(_ text: String, action: WritingAction) async throws -> String {
        try await refineStreaming(text, action: action) { _ in }
    }

    func refineStreaming(
        _ text: String,
        action: WritingAction,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        try TextRefinement.validate(text)
        if let unavailableReason { throw WritingError.unavailable(unavailableReason) }
        guard #available(macOS 26.0, *) else {
            throw WritingError.unavailable(String(localized: "Requires macOS 26 or later.", comment: "Writing unavailable reason"))
        }
        try Task.checkCancellation()
        // Explicit on-device model, fresh context for every revision; no tools or cloud fallback.
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            tools: [],
            instructions: action.instructions(for: text)
        )
        do {
            let clock = ContinuousClock()
            var lastPublished: ContinuousClock.Instant?
            var latest = ""
            for try await snapshot in session.streamResponse(to: text) {
                try Task.checkCancellation()
                latest = snapshot.content
                let now = clock.now
                if !latest.isEmpty,
                   lastPublished == nil || lastPublished!.duration(to: now) >= .milliseconds(100) {
                    onPartial(latest)
                    lastPublished = now
                }
            }
            try Task.checkCancellation()
            if !latest.isEmpty { onPartial(latest) }
            return latest
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                throw WritingError.unavailable(String(
                    localized: "This passage exceeds Apple's context window. Select a shorter passage; your original is unchanged.",
                    comment: "Writing error"))
            case .unsupportedLanguageOrLocale:
                throw WritingError.unavailable(String(
                    localized: "Apple Intelligence does not support this text's language or locale.",
                    comment: "Writing error"))
            case .guardrailViolation, .refusal:
                throw WritingError.unavailable(String(
                    localized: "Apple Intelligence declined this revision. Your original is unchanged.",
                    comment: "Writing error"))
            default:
                throw WritingError.unavailable(String(
                    localized: "Apple Intelligence could not finish this revision. Try a shorter passage or try again later.",
                    comment: "Writing error"))
            }
        }
    }
}

#if DEBUG
@MainActor
struct WritingPreviewRefiner: TextRefiner {
    var unavailableReason: String? { nil }
    func refine(_ text: String, action: WritingAction) async throws -> String {
        try await Task.sleep(for: .milliseconds(200))
        return "Ciao, possiamo spostare la riunione a domani alle 10?"
    }
}
#endif
