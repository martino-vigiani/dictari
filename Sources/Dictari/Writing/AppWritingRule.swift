import Foundation

enum WritingTrigger: String, CaseIterable, Identifiable {
    case never, ask, automatic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .never: String(localized: "Never", comment: "Writing rule: never offer Fix Mistakes")
        case .ask: String(localized: "Ask after pasting", comment: "Writing rule: offer Fix Mistakes after the text is pasted")
        case .automatic: String(localized: "Fix before inserting", comment: "Writing rule: fix the text before it is inserted")
        }
    }
}

struct AppWritingRule: Codable, Equatable, Sendable {
    var name: String
    // Unknown future values fail closed, without making older Dictari reject all settings.
    var trigger: String = WritingTrigger.ask.rawValue
    var action: String = "correct"
    var mode: WritingTrigger { WritingTrigger(rawValue: trigger) ?? .never }
    func shouldOffer(after kind: DictationState.SuccessKind, recordedApp: String?, currentApp: String?) -> Bool {
        mode != .never && recordedApp != nil && recordedApp == currentApp
            && (kind == .inserted || kind == .pastedUnverified)
    }
    var writingAction: WritingAction { WritingAction(rawValue: action) ?? .correct }
}

extension SettingsData {
    func writingRule(for bundleID: String?) -> AppWritingRule? {
        if let profile = selectedCustomDictationProfile {
            switch profile.writingBehavior {
            case .off: return nil
            case .ask, .automatic:
                return AppWritingRule(name: profile.name,
                                      trigger: profile.writingBehavior == .ask ? WritingTrigger.ask.rawValue : WritingTrigger.automatic.rawValue,
                                      action: profile.writingAction)
            case .appRules: break
            }
        }
        guard dictationProfile != .code, let bundleID,
              let rule = applicationWritingRules?[bundleID], rule.mode != .never else { return nil }
        return rule
    }
}

/// Frozen at capture start. Explicit correction works in every app and profile;
/// ordinary dictation only waits for a revision when its app rule opts in.
enum DictationRevisionPolicy {
    static func isConstituentModifier(_ shortcut: Shortcut) -> Bool {
        // Both left/right hardware modifiers, excluding Control and Caps Lock.
        [54, 55, 56, 58, 60, 61].contains(shortcut.keyCode)
            && !shortcut.modifierFlags.isEmpty
            && Shortcut.revisionDictation.modifierFlags.isSuperset(of: shortcut.modifierFlags)
    }

    static func action(explicitCorrection: Bool, rule: AppWritingRule?) -> WritingAction? {
        if explicitCorrection { return .correct }
        return rule?.mode == .automatic ? rule?.writingAction : nil
    }
}
