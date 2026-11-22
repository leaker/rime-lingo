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

    private static let french = TranslationTarget(code: "fr")!, german = TranslationTarget(code: "de")!
    private static let korean = TranslationTarget(code: "ko")!

    /// Every action of the defaults, plus a language that is not in the list.
    private static let sampleActions: [TranslationShortcutAction] = [.english, .japanese, .submit, .language(french)]

    private func language(_ target: TranslationTarget, _ shortcut: String = "") -> RimeLingoFeatures.TranslationLanguage {
        .init(code: target.code, shortcut: shortcut)
    }

    // MARK: - Storage

    @Test func defaultsAreTheOriginalShortcuts() {
        let defaults = bindings()
        #expect(defaults[.english] == "Control+Alt+Super+e")
        #expect(defaults[.japanese] == "Control+Alt+Super+j")
        #expect(defaults[.submit] == "Alt+Return")
        #expect(defaults.languages == [.english, .japanese])
        #expect(RimeLingoFeatures().translationLanguages == [
            language(.english, "Control+Alt+Super+e"), language(.japanese, "Control+Alt+Super+j"),
        ])
    }

    @Test func storedShortcutsRoundTripThroughFeatures() throws {
        var features = RimeLingoFeatures()
        features[shortcut: .english] = "Control+Alt+t"
        features[shortcut: .japanese] = ""
        features.translationLanguages.append(language(Self.french, "Control+Alt+f"))
        let decoded = try JSONDecoder().decode(RimeLingoFeatures.self, from: JSONEncoder().encode(features))
        #expect(decoded == features)
        let restored = TranslationShortcutBindings(features: decoded)
        #expect(restored[.english] == "Control+Alt+t")
        #expect(restored[.japanese] == "")
        #expect(restored[.language(Self.french)] == "Control+Alt+f")
        #expect(restored[.submit] == "Alt+Return")
        #expect(restored.languages == [.english, .japanese, Self.french])
    }

    /// The submit shortcut is the only way to insert a translation: it cannot be turned off.
    @Test func anEmptySubmitShortcutCountsAsTheDefault() {
        let cleared = bindings { $0[shortcut: .submit] = "" }
        #expect(cleared[.submit] == "Alt+Return")
        #expect(match(cleared, 36, "\r", Self.option) == .submit)
    }

    /// A language outside the list has no stored shortcut, and giving it one adds nothing.
    @Test func theShortcutOfAnUnlistedLanguageIsNotStored() {
        var features = RimeLingoFeatures()
        features[shortcut: .language(Self.french)] = "Control+Alt+f"
        #expect(features == RimeLingoFeatures())
        #expect(features[shortcut: .language(Self.french)] == "")
        let resolved = TranslationShortcutBindings(features: features)
        #expect(resolved[.language(Self.french)] == "")
        #expect(match(resolved, 3, "f", Self.control | Self.option) == nil)
    }

    // MARK: - Migration

    /// A file written before the language list: the custom English shortcut and the cleared
    /// Japanese one are both kept.
    @Test func legacyShortcutsBecomeTheLanguageList() throws {
        let old = try features(
            #"{"liveTranslation":true,"submitTranslationShortcut":"Alt+Return","translateEnglishShortcut":"Control+Alt+Super+t","translateJapaneseShortcut":""}"#)
        #expect(old.translationLanguages == [language(.english, "Control+Alt+Super+t"), language(.japanese)])
        let resolved = TranslationShortcutBindings(features: old)
        #expect(resolved.languages == [.english, .japanese])
        #expect(resolved[.english] == "Control+Alt+Super+t")
        #expect(resolved[.japanese] == "")
        #expect(match(resolved, 17, "t", Self.hyper) == .language(.english))
        #expect(match(resolved, 38, "j", Self.hyper) == nil)
        #expect(match(resolved, 14, "e", Self.hyper) == nil)
    }

    @Test func aMissingLegacyKeyIsThatLanguagesDefault() throws {
        let old = try features(#"{"translateJapaneseShortcut":"Control+Alt+k"}"#)
        #expect(old.translationLanguages == [language(.english, "Control+Alt+Super+e"), language(.japanese, "Control+Alt+k")])
    }

    @Test func theLanguageListWinsOverLegacyKeys() throws {
        let both = try features(
            #"{"translationLanguages":[{"code":"fr","shortcut":"Control+Alt+f"}],"translateEnglishShortcut":"Control+Alt+Super+t"}"#)
        #expect(both.translationLanguages == [language(Self.french, "Control+Alt+f")])
        #expect(TranslationShortcutBindings(features: both)[.english] == "")
    }

    /// Damaged elements, unknown codes and repeated languages are dropped one by one; codes
    /// take the catalog's spelling.
    @Test func unusableListElementsAreDropped() throws {
        let messy = try features(#"""
            {"usageStats":true,"translationLanguages":[
              {"code":"FR","shortcut":"Control+Alt+f"}, 7, {"code":"de"}, {"code":"xx","shortcut":""},
              {"code":"fr","shortcut":"Control+Alt+g"}, {"code":"zh-hant","shortcut":""}, {"code":3,"shortcut":""}, null]}
            """#)
        #expect(messy.usageStats)
        #expect(messy.translationLanguages == [
            language(Self.french, "Control+Alt+f"), language(TranslationTarget(code: "zh-Hant")!),
        ])
    }

    @Test func anEmptyListStaysEmpty() throws {
        let none = try features(#"{"translationLanguages":[],"translateEnglishShortcut":"Control+Alt+Super+t"}"#)
        #expect(none.translationLanguages.isEmpty)
        let resolved = TranslationShortcutBindings(features: none)
        #expect(resolved.languages.isEmpty)
        #expect(match(resolved, 14, "e", Self.hyper) == nil)
        #expect(match(resolved, 36, "\r", Self.option) == .submit)
    }

    /// A list that is not one, or has nothing usable in it, is damage and not the user
    /// removing every language: the legacy keys or the defaults apply, and the rest of the
    /// file is kept.
    @Test func aDamagedListFallsBackToLegacyKeysOrDefaults() throws {
        for damaged in [#""x""#, "7", #"{"code":"en"}"#, #"[{"code":"xx","shortcut":""}, 7]"#, "null"] {
            let withLegacy = try features(
                #"{"usageStats":true,"translationLanguages":\#(damaged),"translateEnglishShortcut":"Control+Alt+Super+t","translateJapaneseShortcut":""}"#)
            #expect(withLegacy.usageStats, "\(damaged)")
            #expect(withLegacy.translationLanguages == [language(.english, "Control+Alt+Super+t"), language(.japanese)], "\(damaged)")
            let alone = try features(#"{"usageStats":true,"translationLanguages":\#(damaged)}"#)
            #expect(alone.usageStats, "\(damaged)")
            #expect(alone.translationLanguages == RimeLingoFeatures().translationLanguages, "\(damaged)")
        }
    }

    @Test func savingWritesTheListAndDropsLegacyKeys() throws {
        let old = try features(#"{"translateEnglishShortcut":"Control+Alt+Super+t","translateJapaneseShortcut":""}"#)
        let data = try JSONEncoder().encode(old)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(keys["translateEnglishShortcut"] == nil && keys["translateJapaneseShortcut"] == nil)
        let list = try #require(keys["translationLanguages"] as? [[String: String]])
        #expect(list == [["code": "en", "shortcut": "Control+Alt+Super+t"], ["code": "ja", "shortcut": ""]])
        // Reading the file back gives the migrated value: opening Settings alone writes nothing.
        #expect(try JSONDecoder().decode(RimeLingoFeatures.self, from: data) == old)
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

    /// A file written by hand or by another build may hold the same key twice. Submit comes
    /// first, then the languages in list order: the earlier action keeps the key; the later one goes back to its default, or to nothing when an
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
        // Submit keeps the key over both languages, which go back to their defaults.
        #expect(custom[.submit] == "Control+Alt+t")
        #expect(custom[.english] == "Control+Alt+Super+e")
        #expect(custom[.japanese] == "Control+Alt+Super+j")
        #expect(match(custom, 38, "j", Self.hyper) == .language(.japanese))
        #expect(match(custom, 17, "t", Self.control | Self.option) == .submit)

        // A language on the key of a damaged submit shortcut: submit takes its default back.
        let fallback = bindings {
            $0[shortcut: .english] = "Alt+Return"
            $0[shortcut: .submit] = "Hyper+x"
        }
        #expect(fallback[.submit] == "Alt+Return")
        #expect(fallback[.english] == "Control+Alt+Super+e")
        // A language whose default an earlier action holds ends with nothing.
        let taken = bindings {
            $0[shortcut: .submit] = "Control+Alt+Super+j"
            $0[shortcut: .japanese] = "Control+Alt+Super+j"
        }
        #expect(taken[.submit] == "Control+Alt+Super+j")
        #expect(taken[.japanese] == "")
        // Cleared shortcuts never count as duplicates of each other.
        let cleared = bindings { $0[shortcut: .english] = ""; $0[shortcut: .japanese] = "" }
        #expect(cleared[.english] == "" && cleared[.japanese] == "" && cleared[.submit] == "Alt+Return")
    }

    /// With more languages the rule is the same: list order decides, and a language without
    /// a default ends with no shortcut.
    @Test func duplicatesAmongManyLanguagesFollowTheListOrder() {
        let many = bindings {
            $0.translationLanguages = [
                language(Self.french, "Control+Alt+t"), language(.english, "Control+Alt+t"),
                language(Self.german, "Control+Alt+t"), language(.japanese, "Control+Alt+Super+e"),
                language(Self.korean, "Hyper+k"), language(Self.french, "Control+Alt+x"),
            ]
        }
        #expect(many.languages == [Self.french, .english, Self.german, .japanese, Self.korean])
        #expect(many[.language(Self.french)] == "Control+Alt+t")
        #expect(many[.english] == "Control+Alt+Super+e")
        #expect(many[.language(Self.german)] == "")
        // Its stored value went to English as a default; its own default is still free.
        #expect(many[.japanese] == "Control+Alt+Super+j")
        // Damaged, and no default to go back to.
        #expect(many[.language(Self.korean)] == "")
        #expect(match(many, 17, "t", Self.control | Self.option) == .language(Self.french))
        #expect(match(many, 14, "e", Self.hyper) == .language(.english))
        #expect(match(many, 14, "e", Self.hyper, isRepeat: true) == .languageRepeat(.english))
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
        let cleared = bindings { $0[shortcut: .english] = "" }
        #expect(cleared[.english] == "")
        #expect(match(cleared, 14, "e", Self.hyper) == nil)
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

    @Test func rejectsDuplicatesAmongTheActions() {
        let defaults = bindings()
        #expect(defaults.issue(recording: "Control+Alt+Super+j", for: .english) == .duplicate(.japanese))
        #expect(defaults.issue(recording: "Control+Alt+Super+e", for: .japanese) == .duplicate(.english))
        #expect(defaults.issue(recording: "Alt+Return", for: .english) == .duplicate(.submit))
        #expect(defaults.issue(recording: "Control+Alt+Super+e", for: .submit) == .duplicate(.english))
        // A cleared shortcut holds nothing.
        let cleared = bindings { $0[shortcut: .japanese] = "" }
        #expect(cleared.issue(recording: "Control+Alt+Super+j", for: .english) == nil)
    }

    @Test func rejectsDuplicatesOfAnyListedLanguage() {
        let three = bindings { $0.translationLanguages.append(language(Self.french, "Control+Alt+f")) }
        #expect(three.issue(recording: "Control+Alt+f", for: .english) == .duplicate(.language(Self.french)))
        #expect(three.issue(recording: "Alt+Control+F", for: .submit) == .duplicate(.language(Self.french)))
        #expect(three.issue(recording: "Control+Alt+f", for: .language(Self.french)) == nil)
        #expect(TranslationShortcutIssue.duplicate(.language(Self.french)).message.contains("翻译为法语"))
        // A language about to be added is checked like a listed one.
        #expect(three.issue(recording: "Control+Alt+f", for: .language(Self.german)) == .duplicate(.language(Self.french)))
        #expect(three.issue(recording: "Alt+Return", for: .language(Self.german)) == .duplicate(.submit))
        #expect(three.issue(recording: "Alt+g", for: .language(Self.german)) == .producesCharacter)
        #expect(three.issue(recording: "Control+Alt+g", for: .language(Self.german)) == nil)
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
        for action in Self.sampleActions {
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
        let three = bindings { $0.translationLanguages.append(language(Self.french, "Control+Alt+f")) }
        #expect(three.action(holding: "Alt+Control+f") == .language(Self.french))
        #expect(three.action(holding: "Alt+Control+f")?.title == "翻译为法语")
        #expect(defaults.action(holding: "Alt+Control+f") == nil)
    }

    @Test func rejectsTheFixedShortcuts() {
        let defaults = bindings()
        for action in Self.sampleActions {
            #expect(defaults.issue(recording: "Control+Alt+p", for: action) == .reserved(.aiActions))
            #expect(defaults.issue(recording: "Control+Alt+m", for: action) == .reserved(.quickMenu))
        }
    }

    @Test func rejectsBareKeys() {
        let defaults = bindings()
        for bare in ["e", "Shift+e", "F5", "Return", "Shift+Return", "space"] {
            for action in Self.sampleActions {
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

    /// Bindings with the submit shortcut moved to ⌃↩, English to ⌃⌥⌘T and Japanese cleared.
    private var customised: TranslationShortcutBindings {
        bindings {
            $0[shortcut: .submit] = "Control+Return"
            $0[shortcut: .english] = "Control+Alt+Super+t"
            $0[shortcut: .japanese] = ""
        }
    }

    private func snapshot(_ status: LiveTranslationSnapshot.Status, _ message: String) -> LiveTranslationSnapshot {
        LiveTranslationSnapshot(
            targetLabel: "英语", status: status, text: "", isStale: false, message: message,
            canSubmit: false, canCopy: false, canRetry: status == .failed || status == .overLimit, showsPanel: true)
    }

    @Test func theStartedHintNamesTheKeysInEffect() {
        #expect(bindings().liveStartedHint(for: .english) == TranslationHint(
            targetLabel: "英语", title: "实时翻译已开启", keys: "↩ 上屏原文   ⌥↩ 上屏译文   ⌃⌥⌘E 关闭", duration: .seconds(3)))
        #expect(bindings().liveStartedHint(for: .japanese) == TranslationHint(
            targetLabel: "日语", title: "实时翻译已开启", keys: "↩ 上屏原文   ⌥↩ 上屏译文   ⌃⌥⌘J 关闭", duration: .seconds(3)))
        #expect(customised.liveStartedHint(for: .english).keys == "↩ 上屏原文   ⌃↩ 上屏译文   ⌃⌥⌘T 关闭")
        // An empty stored submit shortcut is the default one.
        #expect(bindings { $0[shortcut: .submit] = "" }.liveStartedHint(for: .english).keys
            == "↩ 上屏原文   ⌥↩ 上屏译文   ⌃⌥⌘E 关闭")
    }

    /// With an empty draft Esc goes to the app, so the hint never offers it as the way
    /// out while the language has a shortcut.
    @Test func theStartedHintOffersEscOnlyWithoutALanguageShortcut() {
        #expect(!bindings().liveStartedHint(for: .english).keys.contains("esc"))
        #expect(!customised.liveStartedHint(for: .english).keys.contains("esc"))
        #expect(customised.liveStartedHint(for: .japanese) == TranslationHint(
            targetLabel: "日语", title: "实时翻译已开启", keys: "↩ 上屏原文   ⌃↩ 上屏译文   esc 上屏原文并关闭",
            duration: .seconds(3)))
        // A language that is not in the list has no shortcut either.
        #expect(bindings().liveStartedHint(for: Self.french).keys == "↩ 上屏原文   ⌥↩ 上屏译文   esc 上屏原文并关闭")
    }

    @Test func theStoppedHintSaysWhetherTheSourceWasCommitted() {
        #expect(TranslationShortcutBindings.liveStoppedHint(committedSource: false) == TranslationHint(
            targetLabel: "", title: "翻译已关闭", keys: "", duration: .milliseconds(1500)))
        #expect(TranslationShortcutBindings.liveStoppedHint(committedSource: true) == TranslationHint(
            targetLabel: "", title: "翻译已关闭，原文已上屏", keys: "", duration: .milliseconds(1500)))
    }

    @Test func theSwitchedHintNamesTheNewTarget() {
        #expect(TranslationShortcutBindings.liveSwitchedHint(to: .japanese) == TranslationHint(
            targetLabel: "日语", title: "已切换翻译语言", keys: "", duration: .milliseconds(1500)))
        #expect(TranslationShortcutBindings.liveSwitchedHint(to: Self.french).targetLabel == "法语")
    }

    @Test func theLiveMessageNamesTheKeyThatActsOnIt() {
        #expect(bindings().liveMessage(snapshot(.failed, "请求失败")) == "请求失败 · ⌥↩ 重试")
        #expect(bindings().liveMessage(snapshot(.overLimit, "超过 200 字")) == "超过 200 字 · ⌥↩ 翻译")
        #expect(customised.liveMessage(snapshot(.failed, "请求失败")) == "请求失败 · ⌃↩ 重试")
        #expect(customised.liveMessage(snapshot(.overLimit, "超过 200 字")) == "超过 200 字 · ⌃↩ 翻译")
        // Everything else is shown as it is.
        #expect(bindings().liveMessage(snapshot(.updating, "翻译中…")) == "翻译中…")
        #expect(bindings().liveMessage(snapshot(.ready, "")) == "")
        #expect(bindings().liveMessage(snapshot(.waiting, "")) == "")
    }

    /// The message of a real session above the limit, end to end.
    @Test func theLiveMessageOfASessionAboveTheLimit() {
        var session = LiveTranslationSession(id: 1, target: .english)
        _ = session.handle(.sourceChanged(String(repeating: "字", count: LiveTranslationSession.autoTranslateLimit + 1)))
        #expect(bindings().liveMessage(session.snapshot) == "超过 200 字 · ⌥↩ 翻译")
    }

    @Test func theSelectionFootnoteNamesTheKeysInEffect() {
        #expect(bindings().selectionFootnote(canReplace: true, canRetry: false) == "⌥↩ 替换选区   esc 关闭")
        #expect(bindings().selectionFootnote(canReplace: false, canRetry: true) == "⌥↩ 重试   esc 关闭")
        #expect(bindings().selectionFootnote(canReplace: false, canRetry: false) == "esc 关闭")
        #expect(customised.selectionFootnote(canReplace: true, canRetry: false) == "⌃↩ 替换选区   esc 关闭")
        #expect(customised.selectionFootnote(canReplace: false, canRetry: true) == "⌃↩ 重试   esc 关闭")
        #expect(customised.selectionFootnote(canReplace: false, canRetry: false) == "esc 关闭")
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
        // Option+Return is an ordinary key once the shortcut moved.
        #expect(LiveSessionKey.decision(
            keyCode: 36, option: true, command: false, control: false, shift: false,
            isComposing: false, hasValidTranslation: true, submitMatched: false) == .none)
        // Esc keeps exiting.
        #expect(LiveSessionKey.decision(
            keyCode: 53, option: false, command: false, control: false, shift: false,
            isComposing: false, hasValidTranslation: true, submitMatched: false) == .exit)
        // With an empty draft the configured shortcut goes to the app; after a failure it retries.
        #expect(LiveSessionKey.decision(
            keyCode: 36, option: false, command: false, control: true, shift: false,
            isComposing: false, hasValidTranslation: false, submitMatched: true, draftIsEmpty: true) == .none)
        #expect(LiveSessionKey.decision(
            keyCode: 36, option: false, command: false, control: true, shift: false,
            isComposing: false, hasValidTranslation: false, submitMatched: true, canRetry: true) == .retry)
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
        #expect(SelectionPreviewKey.decision(
            keyCode: 36, option: false, command: false, control: true, shift: false,
            hasMarkedText: false, submitMatched: true, canRetry: true) == .retry)
    }
}
