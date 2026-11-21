import Foundation
import Testing
@testable import RimeLingoCore

struct TranslationShortcutSettingsTests {
    // NSEvent.ModifierFlags raw values.
    private static let capsLock: UInt = 1 << 16, shift: UInt = 1 << 17, control: UInt = 1 << 18
    private static let option: UInt = 1 << 19, command: UInt = 1 << 20, function: UInt = 1 << 23
    private static let hyper = control | option | command

    private func features(_ json: String) throws -> RimeLingoFeatures {
        try JSONDecoder().decode(RimeLingoFeatures.self, from: Data(json.utf8))
    }

    private func bindings(_ body: (inout RimeLingoFeatures) -> Void = { _ in }) -> TranslationShortcutBindings {
        var features = RimeLingoFeatures()
        body(&features)
        return TranslationShortcutBindings(features: features)
    }

    // MARK: - Storage

    @Test func defaultsAreTheOriginalShortcuts() {
        let defaults = bindings()
        #expect(defaults[.english] == "Control+Alt+Super+e")
        #expect(defaults[.japanese] == "Control+Alt+Super+j")
        #expect(defaults[.submit] == "Alt+Return")
        for action in TranslationShortcutAction.allCases { #expect(defaults[action] == action.defaultShortcut) }
    }

    @Test func storedShortcutsRoundTripThroughFeatures() throws {
        var features = RimeLingoFeatures()
        features[shortcut: .english] = "Control+Alt+t"
        features[shortcut: .submit] = ""
        let decoded = try JSONDecoder().decode(RimeLingoFeatures.self, from: JSONEncoder().encode(features))
        #expect(decoded == features)
        let restored = TranslationShortcutBindings(features: decoded)
        #expect(restored[.english] == "Control+Alt+t")
        #expect(restored[.japanese] == "Control+Alt+Super+j")
        #expect(restored[.submit] == "")
    }

    @Test func missingValuesFallBackToTheDefaults() throws {
        let old = try features(#"{"liveTranslation":true}"#)
        #expect(TranslationShortcutBindings(features: old) == bindings())
    }

    /// A value of the wrong type costs that shortcut only, never the rest of the file.
    @Test func corruptValuesFallBackWithoutLosingOtherSettings() throws {
        let corrupt = try features(
            #"{"usageStats":true,"translateEnglishShortcut":7,"translateJapaneseShortcut":["x"],"submitTranslationShortcut":null}"#)
        #expect(corrupt.usageStats)
        #expect(TranslationShortcutBindings(features: corrupt) == bindings())
    }

    @Test func unparsableOrUnsafeValuesFallBackToTheDefault() {
        for junk in ["Hyper+e", "Control+", "+", "Control+Alt+nosuchkey", "e", "Shift+j", "Alt+e", "Control+Control+e", "  "] {
            let stored = bindings { $0[shortcut: .english] = junk }
            #expect(stored[.english] == "Control+Alt+Super+e", "\(junk)")
        }
        #expect(bindings { $0[shortcut: .submit] = "Return" }[.submit] == "Alt+Return")
    }

    /// A file written by hand or by another build may hold the same key twice. The earlier
    /// action keeps it; the later one goes back to its default, or to nothing when an
    /// earlier action already holds that default.
    @Test func storedDuplicatesAreResolvedOnLoad() throws {
        let same = try features(
            #"{"translateEnglishShortcut":"Control+Alt+Super+j","translateJapaneseShortcut":"Super+Alt+Control+J"}"#)
        let resolved = TranslationShortcutBindings(features: same)
        #expect(resolved[.english] == "Control+Alt+Super+j")
        #expect(resolved[.japanese] == "")
        #expect(resolved[.submit] == "Alt+Return")
        #expect(match(resolved, 38, "j", Self.hyper) == .language(.english))

        let custom = bindings {
            $0[shortcut: .english] = "Control+Alt+t"
            $0[shortcut: .japanese] = "Control+Alt+t"
            $0[shortcut: .submit] = "Control+Alt+t"
        }
        #expect(custom[.english] == "Control+Alt+t")
        #expect(custom[.japanese] == "Control+Alt+Super+j")
        #expect(custom[.submit] == "Alt+Return")
        #expect(match(custom, 38, "j", Self.hyper) == .language(.japanese))
        #expect(match(custom, 36, "\r", Self.option) == .submit)

        // A damaged value whose default an earlier action holds.
        let fallback = bindings {
            $0[shortcut: .english] = "Alt+Return"
            $0[shortcut: .submit] = "Hyper+x"
        }
        #expect(fallback[.english] == "Alt+Return")
        #expect(fallback[.submit] == "")
        // Cleared shortcuts never count as duplicates of each other.
        let cleared = bindings { $0[shortcut: .english] = ""; $0[shortcut: .japanese] = "" }
        #expect(cleared[.english] == "" && cleared[.japanese] == "" && cleared[.submit] == "Alt+Return")
    }

    @Test func storedValuesAreNormalised() {
        let stored = bindings { $0[shortcut: .english] = "Super+Shift+Control+T" }
        #expect(stored[.english] == "Control+Shift+Super+t")
    }

    // MARK: - Matching

    private func match(
        _ bindings: TranslationShortcutBindings, _ keyCode: UInt16, _ characters: String?, _ flags: UInt, isRepeat: Bool = false
    ) -> TranslationShortcutMatch? {
        bindings.match(keyCode: keyCode, characters: characters, eventFlags: flags, isRepeat: isRepeat)
    }

    @Test func defaultsMatchTheirKeys() {
        let defaults = bindings()
        #expect(match(defaults, 14, "e", Self.hyper) == .language(.english))
        #expect(match(defaults, 38, "j", Self.hyper) == .language(.japanese))
        #expect(match(defaults, 36, "\r", Self.option) == .submit)
        // The keypad Enter submits like Return.
        #expect(match(defaults, 76, "\u{3}", Self.option) == .submit)
        #expect(match(defaults, 0, "a", Self.hyper) == nil)
    }

    /// Letters and digits are matched by character like the recorder stores them, so the
    /// key code plays no part; named keys are matched by key code.
    @Test func lettersMatchByCharacterAndNamedKeysByKeyCode() {
        let custom = bindings {
            $0[shortcut: .english] = "Control+Alt+2"
            $0[shortcut: .japanese] = "Control+Alt+grave"
            $0[shortcut: .submit] = "Super+F5"
        }
        #expect(match(custom, 19, "2", Self.control | Self.option) == .language(.english))
        #expect(match(custom, 84, "2", Self.control | Self.option) == .language(.english)) // keypad 2
        #expect(match(custom, 0x32, "`", Self.control | Self.option) == .language(.japanese))
        #expect(match(custom, 0x32, nil, Self.control | Self.option) == .language(.japanese))
        #expect(match(custom, 0x60, nil, Self.command) == .submit)
        // The old defaults no longer match.
        #expect(match(custom, 14, "e", Self.hyper) == nil)
        #expect(match(custom, 36, "\r", Self.option) == nil)
    }

    @Test func modifiersMustBeExact() {
        let defaults = bindings()
        for bits in 0..<16 {
            var flags: UInt = 0
            if bits & 1 != 0 { flags |= Self.control }
            if bits & 2 != 0 { flags |= Self.option }
            if bits & 4 != 0 { flags |= Self.command }
            if bits & 8 != 0 { flags |= Self.shift }
            #expect((match(defaults, 14, "e", flags) != nil) == (flags == Self.hyper))
            #expect((match(defaults, 36, "\r", flags) != nil) == (flags == Self.option))
        }
    }

    @Test func capsLockAndFnAreIgnored() {
        let defaults = bindings()
        #expect(match(defaults, 14, "E", Self.hyper | Self.capsLock) == .language(.english))
        #expect(match(defaults, 38, "j", Self.hyper | Self.function) == .language(.japanese))
        #expect(match(defaults, 36, "\r", Self.option | Self.capsLock | Self.function) == .submit)
    }

    /// A held language shortcut is reported apart, so the host can swallow it without acting.
    @Test func languageRepeatsNeverMatchAsAPress() {
        let defaults = bindings()
        #expect(match(defaults, 14, "e", Self.hyper, isRepeat: true) == .languageRepeat(.english))
        #expect(match(defaults, 38, "j", Self.hyper, isRepeat: true) == .languageRepeat(.japanese))
        #expect(match(defaults, 36, "\r", Self.option, isRepeat: true) == .submit)
    }

    @Test func aClearedShortcutMatchesNothing() {
        let cleared = bindings {
            $0[shortcut: .english] = ""
            $0[shortcut: .submit] = ""
        }
        #expect(cleared[.english] == "")
        #expect(match(cleared, 14, "e", Self.hyper) == nil)
        #expect(match(cleared, 36, "\r", Self.option) == nil)
        #expect(match(cleared, 38, "j", Self.hyper) == .language(.japanese))
        // No modifiers and an unbindable key: an empty binding must not match it.
        #expect(match(cleared, 10, "§", 0) == nil)
    }

    // MARK: - Recording

    @Test func acceptsAFreeCombination() {
        let defaults = bindings()
        #expect(defaults.issue(recording: "Control+Alt+t", for: .english) == nil)
        #expect(defaults.issue(recording: "Control+Return", for: .submit) == nil)
        // Recording the value an action already has is not a conflict with itself.
        #expect(defaults.issue(recording: "Control+Alt+Super+e", for: .english) == nil)
    }

    @Test func rejectsDuplicatesAmongTheThree() {
        let defaults = bindings()
        #expect(defaults.issue(recording: "Control+Alt+Super+j", for: .english) == .duplicate(.japanese))
        #expect(defaults.issue(recording: "Control+Alt+Super+e", for: .japanese) == .duplicate(.english))
        #expect(defaults.issue(recording: "Alt+Return", for: .english) == .duplicate(.submit))
        #expect(defaults.issue(recording: "Control+Alt+Super+e", for: .submit) == .duplicate(.english))
        // A cleared shortcut holds nothing.
        let cleared = bindings { $0[shortcut: .japanese] = "" }
        #expect(cleared.issue(recording: "Control+Alt+Super+j", for: .english) == nil)
    }

    /// The input method's other recordable hotkeys, as stored for librime: any order of
    /// modifiers, and strings the recorder would never write.
    @Test func rejectsHotkeysHeldByOtherSettings() {
        let defaults = bindings()
        let others = [
            (shortcut: "Control+grave", title: "方案选单快捷键"), (shortcut: "Shift+Control+grave", title: "方案选单快捷键"),
            (shortcut: "F4", title: "方案选单快捷键"), (shortcut: "Control+Shift+Alt+nosuchkey", title: "损坏"),
            (shortcut: "", title: "未设置"), (shortcut: "Super+Control+K", title: "以词定字"),
        ]
        for action in TranslationShortcutAction.allCases {
            #expect(defaults.issue(recording: "Control+grave", for: action, others: others) == .taken(by: "方案选单快捷键"))
            #expect(defaults.issue(recording: "Control+Shift+grave", for: action, others: others) == .taken(by: "方案选单快捷键"))
            #expect(defaults.issue(recording: "Control+Super+k", for: action, others: others) == .taken(by: "以词定字"))
            #expect(defaults.issue(recording: "Control+Alt+grave", for: action, others: others) == nil)
        }
        // Without the list nothing changes.
        #expect(defaults.issue(recording: "Control+grave", for: .english) == nil)
        #expect(TranslationShortcutIssue.taken(by: "方案选单快捷键").message.contains("方案选单快捷键"))
    }

    /// The other direction: a hotkey about to be given to another setting.
    @Test func reportsTheActionHoldingAHotkey() {
        let defaults = bindings()
        #expect(defaults.action(holding: "Control+Alt+Super+e") == .english)
        #expect(defaults.action(holding: "Super+Alt+Control+J") == .japanese)
        #expect(defaults.action(holding: "Alt+Return") == .submit)
        #expect(defaults.action(holding: "Control+grave") == nil)
        #expect(defaults.action(holding: "") == nil)
        #expect(defaults.action(holding: "Hyper+e") == nil)
        let cleared = bindings { $0[shortcut: .english] = "" }
        #expect(cleared.action(holding: "Control+Alt+Super+e") == nil)
        #expect(cleared.action(holding: "") == nil)
    }

    @Test func rejectsTheFixedShortcuts() {
        let defaults = bindings()
        for action in TranslationShortcutAction.allCases {
            #expect(defaults.issue(recording: "Control+Alt+p", for: action) == .reserved(.aiActions))
            #expect(defaults.issue(recording: "Control+Alt+m", for: action) == .reserved(.quickMenu))
        }
    }

    @Test func rejectsBareKeys() {
        let defaults = bindings()
        for bare in ["e", "Shift+e", "F5", "Return", "Shift+Return", "space"] {
            for action in TranslationShortcutAction.allCases {
                #expect(defaults.issue(recording: bare, for: action) == .needsModifier, "\(bare)")
            }
        }
    }

    /// Option with a letter, digit or punctuation key types a character on its own.
    @Test func rejectsOptionCharactersForLanguageShortcuts() {
        let defaults = bindings()
        for typing in ["Alt+e", "Alt+Shift+k", "Alt+3", "Alt+comma", "Alt+space"] {
            #expect(defaults.issue(recording: typing, for: .english) == .producesCharacter, "\(typing)")
            #expect(defaults.issue(recording: typing, for: .japanese) == .producesCharacter, "\(typing)")
        }
        #expect(defaults.issue(recording: "Alt+F5", for: .english) == nil)
        #expect(defaults.issue(recording: "Control+Alt+k", for: .english) == nil)
        #expect(defaults.issue(recording: "Alt+Super+k", for: .japanese) == nil)
    }

    @Test func rejectsWhatCannotBeParsed() {
        #expect(bindings().issue(recording: "Hyper+e", for: .english) == .unsupported)
        #expect(bindings().issue(recording: "", for: .english) == .unsupported)
    }

    @Test func everyIssueNamesItsCauseInChinese() {
        #expect(TranslationShortcutIssue.duplicate(.japanese).message.contains(TranslationShortcutAction.japanese.title))
        #expect(TranslationShortcutIssue.duplicate(.submit).message.contains(TranslationShortcutAction.submit.title))
        #expect(TranslationShortcutIssue.reserved(.aiActions).message.contains("AI"))
        #expect(TranslationShortcutIssue.reserved(.quickMenu).message.contains("快捷菜单"))
        for issue: TranslationShortcutIssue in [.unsupported, .needsModifier, .producesCharacter] {
            #expect(!issue.message.isEmpty)
        }
    }

    // MARK: - Hints

    @Test func theLiveHintShowsTheConfiguredSubmitShortcut() {
        #expect(bindings().liveStatusHint == "↩ 原文   ⌥↩ 译文   esc 退出")
        #expect(bindings { $0[shortcut: .submit] = "Control+Return" }.liveStatusHint == "↩ 原文   ⌃↩ 译文   esc 退出")
        #expect(bindings { $0[shortcut: .submit] = "" }.liveStatusHint == "↩ 原文   esc 退出")
    }

    // MARK: - Session keys

    @Test func sessionKeysFollowTheConfiguredSubmitShortcut() {
        // Matched by the configured shortcut: submits whatever the key is.
        #expect(LiveSessionKey.decision(
            keyCode: 36, option: false, command: false, control: true, shift: false,
            isComposing: false, hasValidTranslation: true, submitMatched: true) == .submit)
        #expect(LiveSessionKey.decision(
            keyCode: 36, option: false, command: false, control: true, shift: false,
            isComposing: true, hasValidTranslation: true, submitMatched: true) == .submitBlocked(.composing))
        // Option+Return is an ordinary key once the shortcut moved or was cleared.
        #expect(LiveSessionKey.decision(
            keyCode: 36, option: true, command: false, control: false, shift: false,
            isComposing: false, hasValidTranslation: true, submitMatched: false) == .none)
        // Esc keeps exiting.
        #expect(LiveSessionKey.decision(
            keyCode: 53, option: false, command: false, control: false, shift: false,
            isComposing: false, hasValidTranslation: true, submitMatched: false) == .exit)
    }

    @Test func selectionPreviewKeysFollowTheConfiguredSubmitShortcut() {
        #expect(SelectionPreviewKey.decision(
            keyCode: 36, option: false, command: false, control: true, shift: false,
            hasMarkedText: false, submitMatched: true) == .replace)
        #expect(SelectionPreviewKey.decision(
            keyCode: 36, option: false, command: false, control: true, shift: false,
            hasMarkedText: true, submitMatched: true) == .replaceBlocked)
        #expect(SelectionPreviewKey.decision(
            keyCode: 36, option: true, command: false, control: false, shift: false,
            hasMarkedText: false, submitMatched: false) == .none)
        #expect(SelectionPreviewKey.decision(
            keyCode: 53, option: false, command: false, control: false, shift: false,
            hasMarkedText: false, submitMatched: false) == .close)
    }
}
