/// The translation actions that have a configurable shortcut: one per target language,
/// and submitting the translation.
public enum TranslationShortcutAction: Sendable, Hashable {
    case language(TranslationTarget)
    case submit

    public static var english: Self { .language(.english) }
    public static var japanese: Self { .language(.japanese) }

    /// In the key recorder's notation (see `HotkeyFormatter`); empty for a language
    /// without a default.
    public var defaultShortcut: String {
        switch self {
        case let .language(target): target.defaultShortcut
        case .submit: "Alt+Return"
        }
    }

    public var title: String {
        switch self {
        case let .language(target): "翻译为\(target.displayName)"
        case .submit: "提交译文"
        }
    }

    public var target: TranslationTarget? {
        switch self {
        case let .language(target): target
        case .submit: nil
        }
    }
}

extension RimeLingoFeatures {
    /// The stored value of a translation shortcut, as written by the settings application.
    /// A language that is not in `translationLanguages` reads as empty, and setting its
    /// shortcut changes nothing: the language has to be added to the list first.
    public subscript(shortcut action: TranslationShortcutAction) -> String {
        get {
            switch action {
            case let .language(target): translationLanguages.first { $0.code == target.code }?.shortcut ?? ""
            case .submit: submitTranslationShortcut
            }
        }
        set {
            switch action {
            case let .language(target):
                guard let index = translationLanguages.firstIndex(where: { $0.code == target.code }) else { return }
                translationLanguages[index].shortcut = newValue
            case .submit: submitTranslationShortcut = newValue
            }
        }
    }

    // MARK: - The language list

    /// Appends `target` to the enabled languages; nothing changes when it is already
    /// there. It brings its default shortcut when it has one that passes every check a
    /// recording takes (`others` as in `TranslationShortcutBindings.issue`), and no
    /// shortcut otherwise.
    public mutating func addTranslationLanguage(_ target: TranslationTarget, others: [(shortcut: String, title: String)] = []) {
        guard !translationLanguages.contains(where: { $0.code == target.code }) else { return }
        var shortcut = target.defaultShortcut
        if !shortcut.isEmpty,
           TranslationShortcutBindings(features: self).issue(recording: shortcut, for: .language(target), others: others) != nil {
            shortcut = ""
        }
        translationLanguages.append(TranslationLanguage(code: target.code, shortcut: shortcut))
    }

    /// Moves a language `offset` places in the list (negative = towards the front);
    /// nothing changes when it is not in the list or would leave it.
    public mutating func moveTranslationLanguage(code: String, by offset: Int) {
        guard let index = translationLanguages.firstIndex(where: { $0.code == code }) else { return }
        let destination = index + offset
        guard offset != 0, translationLanguages.indices.contains(destination) else { return }
        translationLanguages.insert(translationLanguages.remove(at: index), at: destination)
    }

    public mutating func removeTranslationLanguage(code: String) {
        translationLanguages.removeAll { $0.code == code }
    }
}

extension HotkeyFormatter.Modifiers {
    /// From the raw value of an event's modifier flags. Control, Option, Command and Shift
    /// count; Caps Lock, Fn and the keypad flag do not.
    public init(eventFlags: UInt) {
        self = []
        if eventFlags & (1 << 17) != 0 { insert(.shift) }
        if eventFlags & (1 << 18) != 0 { insert(.control) }
        if eventFlags & (1 << 19) != 0 { insert(.alt) }
        if eventFlags & (1 << 20) != 0 { insert(.command) }
    }
}

/// Why a recorded combination is not taken as a translation shortcut.
public enum TranslationShortcutIssue: Sendable, Equatable {
    /// Shortcuts of the input method that cannot be changed.
    public enum Reserved: Sendable, Equatable, CaseIterable {
        case aiActions, quickMenu

        var shortcut: String {
            switch self {
            case .aiActions: "Control+Alt+p"
            case .quickMenu: "Control+Alt+m"
            }
        }

        var title: String {
            switch self {
            case .aiActions: "AI 处理"
            case .quickMenu: "快捷菜单"
            }
        }
    }

    /// Not a combination the recorder's notation can express.
    case unsupported
    /// No Control, Option or Command: the key would be taken away from typing.
    case needsModifier
    /// Option with a key that types a character on its own (language shortcuts only).
    case producesCharacter
    case duplicate(TranslationShortcutAction)
    case reserved(Reserved)
    /// Held by another hotkey setting of the input method, named by its title.
    case taken(by: String)

    public var message: String {
        switch self {
        case .unsupported: "不支持这个按键组合"
        case .needsModifier: "需要包含 ⌃、⌥ 或 ⌘：单独的按键会影响正常打字"
        case .producesCharacter: "⌥ 加字母、数字或符号会直接打出字符，请再加上 ⌃ 或 ⌘"
        case let .duplicate(action): "与「\(action.title)」的快捷键重复"
        case let .taken(title): "与「\(title)」重复"
        case let .reserved(fixed): "与固定快捷键 \(HotkeyFormatter.display(fixed.shortcut))（\(fixed.title)）重复"
        }
    }
}

/// A transient notice of the live translation mode: shown once when the mode changes, and
/// gone after `duration` or at the next key press.
public struct TranslationHint: Sendable, Equatable {
    /// The target's display name; empty when the notice names no language.
    public var targetLabel: String
    public var title: String
    /// One line of keys; empty when there is nothing to explain.
    public var keys: String
    public var duration: Duration

    public init(targetLabel: String, title: String, keys: String, duration: Duration) {
        self.targetLabel = targetLabel
        self.title = title
        self.keys = keys
        self.duration = duration
    }
}

/// What the one translation preview panel shows for the field that has the keyboard.
public enum TranslationPreviewContent: Sendable, Equatable {
    /// An open selection preview owns the panel: nothing else is drawn.
    case selection
    /// The live translation of the draft. `footnote` carries the key line of a hint
    /// that came up while a translation was already on screen; empty otherwise.
    case translation(footnote: String)
    /// A transient notice alone: the mode changed and there is no draft to translate.
    case hint(TranslationHint)
    case hidden

    /// `sessionShowsPanel`: this field has a live session whose draft has text
    /// (`LiveTranslationSnapshot.showsPanel`). A hint needs no session: the one shown
    /// when the mode is turned off comes after the session ended.
    public static func decide(
        selectionPreviewOpen: Bool, sessionShowsPanel: Bool, hint: TranslationHint?
    ) -> TranslationPreviewContent {
        if selectionPreviewOpen { return .selection }
        if sessionShowsPanel { return .translation(footnote: hint?.keys ?? "") }
        if let hint { return .hint(hint) }
        return .hidden
    }
}

/// What a key press means to the translation shortcuts.
public enum TranslationShortcutMatch: Sendable, Equatable {
    case language(TranslationTarget)
    /// A language shortcut held down. It never acts a second time; it is reported so the
    /// host can swallow the repeat where it took the first press.
    case languageRepeat(TranslationTarget)
    case submit
}

/// The translation shortcuts in effect, resolved from the features file.
///
/// Actions are resolved in the order submit, then the languages as the user listed them:
/// - Submit is always in effect. A stored value that is empty, cannot be parsed or is
///   unsafe counts as the default.
/// - A language with an empty stored value has no shortcut. A value that cannot be parsed
///   or is unsafe counts as the language's default, which is empty for most languages.
/// - No two actions share a shortcut. Of stored duplicates the earlier action keeps the
///   key; the later one goes back to its default, or to nothing when it has no default or
///   an earlier action already holds it.
public struct TranslationShortcutBindings: Sendable, Equatable {
    /// The enabled target languages in the user's order.
    public let languages: [TranslationTarget]
    private var values: [TranslationShortcutAction: String] = [:]

    public init(features: RimeLingoFeatures) {
        var seen = Set<String>()
        languages = features.translationLanguages.compactMap { TranslationTarget(code: $0.code) }
            .filter { seen.insert($0.code).inserted }
        var taken: Set<String> = []
        for action in actions {
            let stored = features[shortcut: action]
            var resolved: String
            if stored.isEmpty, action != .submit {
                resolved = ""
            } else if let parsed = Self.parse(stored), Self.intrinsicIssue(parsed, for: action) == nil {
                resolved = parsed.notation
            } else {
                resolved = action.defaultShortcut
            }
            if !resolved.isEmpty, taken.contains(resolved) {
                resolved = taken.contains(action.defaultShortcut) ? "" : action.defaultShortcut
            }
            values[action] = resolved
            if !resolved.isEmpty { taken.insert(resolved) }
        }
    }

    /// Every action that can hold a shortcut, in the order they are resolved.
    private var actions: [TranslationShortcutAction] { [.submit] + languages.map(TranslationShortcutAction.language) }

    /// The shortcut in effect in normalised notation; empty when the action has none, as
    /// for a language that is not in the list.
    public subscript(action: TranslationShortcutAction) -> String { values[action] ?? "" }

    // MARK: - Matching

    /// `characters` is the event's characters ignoring modifiers and `eventFlags` the raw
    /// value of its modifier flags, as the settings recorder reads them: letters and digits
    /// are compared by character, named keys by key code, and Control, Option, Command and
    /// Shift must be exactly those of the shortcut.
    public func match(keyCode: UInt16, characters: String?, eventFlags: UInt, isRepeat: Bool) -> TranslationShortcutMatch? {
        // The keypad Enter stands for Return.
        guard let pressed = HotkeyFormatter.rimeName(
            keyCode: keyCode == 0x4c ? 0x24 : keyCode, character: characters,
            modifiers: HotkeyFormatter.Modifiers(eventFlags: eventFlags)) else { return nil }
        for action in actions where self[action] == pressed {
            guard let target = action.target else { return .submit }
            return isRepeat ? .languageRepeat(target) : .language(target)
        }
        return nil
    }

    /// The default submit shortcut, for callers that do not pass a configured match.
    static func isDefaultSubmit(keyCode: UInt16, option: Bool, command: Bool, control: Bool, shift: Bool) -> Bool {
        option && !command && !control && !shift && (keyCode == 36 || keyCode == 76)
    }

    // MARK: - Recording

    /// Why `candidate` (recorder notation) cannot become the shortcut of `action`, or nil
    /// when it can. The action may be a language that is not in the list yet. `others` are the input method's other hotkey settings with their titles,
    /// as stored. Conflicts with other applications are not known to the input method.
    public func issue(
        recording candidate: String, for action: TranslationShortcutAction, others: [(shortcut: String, title: String)] = []
    ) -> TranslationShortcutIssue? {
        guard let parsed = Self.parse(candidate) else { return .unsupported }
        if let issue = Self.intrinsicIssue(parsed, for: action) { return issue }
        for other in actions where other != action && self[other] == parsed.notation {
            return .duplicate(other)
        }
        if let other = others.first(where: { Self.parse($0.shortcut)?.notation == parsed.notation }) {
            return .taken(by: other.title)
        }
        return nil
    }

    /// The translation action whose shortcut is `hotkey` (any modifier order), for refusing
    /// that hotkey in another setting.
    public func action(holding hotkey: String) -> TranslationShortcutAction? {
        guard let notation = Self.parse(hotkey)?.notation else { return nil }
        return actions.first { self[$0] == notation }
    }

    /// Whether live translation may stay on with `target`: the language is in the list
    /// and has a shortcut in effect. Without one nothing could turn the mode off while
    /// the draft is empty.
    public func sustainsLive(_ target: TranslationTarget) -> Bool {
        languages.contains(target) && !self[.language(target)].isEmpty
    }

    // MARK: - Hints

    private var submitKey: String { HotkeyFormatter.display(self[.submit]) }

    /// Shown once when live translation is turned on. The keys name only what works at any
    /// time: Esc is left out because with an empty draft it goes to the app.
    public func liveStartedHint(for target: TranslationTarget) -> TranslationHint {
        let toggle = self[.language(target)]
        let off = toggle.isEmpty ? "esc 上屏原文并关闭" : "\(HotkeyFormatter.display(toggle)) 关闭"
        return TranslationHint(
            targetLabel: target.displayName, title: "实时翻译已开启",
            keys: ["↩ 上屏原文", "\(submitKey) 上屏译文", off].joined(separator: Self.hintSeparator),
            duration: .seconds(3))
    }

    /// Shown once when live translation is turned off. `committedSource`: a draft was
    /// pending and its source text went into the app.
    public static func liveStoppedHint(committedSource: Bool) -> TranslationHint {
        TranslationHint(
            targetLabel: "", title: committedSource ? "翻译已关闭，原文已上屏" : "翻译已关闭", keys: "",
            duration: .milliseconds(1500))
    }

    /// Shown when the target changes while the draft is empty. With a draft the preview
    /// shows the new target itself.
    public static func liveSwitchedHint(to target: TranslationTarget) -> TranslationHint {
        TranslationHint(targetLabel: target.displayName, title: "已切换翻译语言", keys: "", duration: .milliseconds(1500))
    }

    /// The status line of the live preview: the snapshot's message, with the key that
    /// acts on a failure or on a draft above the automatic limit.
    public func liveMessage(_ snapshot: LiveTranslationSnapshot) -> String {
        switch snapshot.status {
        case .failed: "\(snapshot.message) · \(submitKey) 重试"
        case .overLimit: "\(snapshot.message) · \(submitKey) 翻译"
        case .waiting, .updating, .ready: snapshot.message
        }
    }

    /// The line of keys under a selection preview.
    public func selectionFootnote(canReplace: Bool, canRetry: Bool) -> String {
        var keys: [String] = []
        if canReplace {
            keys.append("\(submitKey) 替换选区")
        } else if canRetry {
            keys.append("\(submitKey) 重试")
        }
        keys.append("esc 关闭")
        return keys.joined(separator: Self.hintSeparator)
    }

    private static let hintSeparator = "   "

    // MARK: - Notation

    struct Parsed: Equatable {
        var modifiers: HotkeyFormatter.Modifiers
        var key: String

        /// Modifiers in the order the recorder writes them.
        var notation: String {
            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("Control") }
            if modifiers.contains(.alt) { parts.append("Alt") }
            if modifiers.contains(.shift) { parts.append("Shift") }
            if modifiers.contains(.command) { parts.append("Super") }
            parts.append(key)
            return parts.joined(separator: "+")
        }
    }

    private static let namedKeys = Set(HotkeyFormatter.namedKeys.values)
    /// Named keys that type a character, like letters and digits do.
    private static let characterKeys: Set<String> = [
        "grave", "minus", "equal", "bracketleft", "bracketright", "backslash", "semicolon", "apostrophe",
        "comma", "period", "slash", "space",
    ]

    static func parse(_ stored: String) -> Parsed? {
        var parts = stored.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let rawKey = parts.popLast() else { return nil }
        var modifiers: HotkeyFormatter.Modifiers = []
        for part in parts {
            let modifier: HotkeyFormatter.Modifiers
            switch part {
            case "Control": modifier = .control
            case "Alt": modifier = .alt
            case "Shift": modifier = .shift
            case "Super", "Command": modifier = .command
            default: return nil
            }
            guard !modifiers.contains(modifier) else { return nil }
            modifiers.insert(modifier)
        }
        if namedKeys.contains(rawKey) { return Parsed(modifiers: modifiers, key: rawKey) }
        let scalars = Array(rawKey.lowercased().unicodeScalars)
        guard scalars.count == 1, (0x61...0x7a).contains(scalars[0].value) || (0x30...0x39).contains(scalars[0].value) else {
            return nil
        }
        return Parsed(modifiers: modifiers, key: String(Character(scalars[0])))
    }

    /// Problems of a combination on its own, whatever the other shortcuts are.
    private static func intrinsicIssue(_ parsed: Parsed, for action: TranslationShortcutAction) -> TranslationShortcutIssue? {
        if parsed.modifiers.isDisjoint(with: [.control, .alt, .command]) { return .needsModifier }
        if action.target != nil, parsed.modifiers.isDisjoint(with: [.control, .command]),
           parsed.key.count == 1 || characterKeys.contains(parsed.key) {
            return .producesCharacter
        }
        if let fixed = TranslationShortcutIssue.Reserved.allCases.first(where: { $0.shortcut == parsed.notation }) {
            return .reserved(fixed)
        }
        return nil
    }
}
