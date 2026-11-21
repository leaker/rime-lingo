/// The three translation actions that have a configurable shortcut.
public enum TranslationShortcutAction: String, Sendable, CaseIterable, Equatable {
    case english, japanese, submit

    /// In the key recorder's notation (see `HotkeyFormatter`).
    public var defaultShortcut: String {
        switch self {
        case .english: "Control+Alt+Super+e"
        case .japanese: "Control+Alt+Super+j"
        case .submit: "Alt+Return"
        }
    }

    public var title: String {
        switch self {
        case .english: "翻译为英语"
        case .japanese: "翻译为日语"
        case .submit: "提交译文"
        }
    }

    var target: TranslationTarget? {
        switch self {
        case .english: .english
        case .japanese: .japanese
        case .submit: nil
        }
    }
}

extension RimeLingoFeatures {
    /// The stored value of a translation shortcut, as written by the settings application.
    public subscript(shortcut action: TranslationShortcutAction) -> String {
        get {
            switch action {
            case .english: translateEnglishShortcut
            case .japanese: translateJapaneseShortcut
            case .submit: submitTranslationShortcut
            }
        }
        set {
            switch action {
            case .english: translateEnglishShortcut = newValue
            case .japanese: translateJapaneseShortcut = newValue
            case .submit: submitTranslationShortcut = newValue
            }
        }
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

/// What a key press means to the translation shortcuts.
public enum TranslationShortcutMatch: Sendable, Equatable {
    case language(TranslationTarget)
    /// A language shortcut held down. It never acts a second time; it is reported so the
    /// host can swallow the repeat where it took the first press.
    case languageRepeat(TranslationTarget)
    case submit
}

/// The translation shortcuts in effect, read from the features file at use. A stored value
/// that is missing, damaged or unsafe counts as the default; an empty one turns its action off.
/// No two actions share a shortcut: of stored duplicates the earlier action keeps the key.
public struct TranslationShortcutBindings: Sendable, Equatable {
    private var values: [TranslationShortcutAction: String] = [:]

    public init(features: RimeLingoFeatures) {
        for action in TranslationShortcutAction.allCases {
            let stored = features[shortcut: action]
            if stored.isEmpty {
                values[action] = ""
            } else if let parsed = Self.parse(stored), Self.intrinsicIssue(parsed, for: action) == nil {
                values[action] = parsed.notation
            } else {
                values[action] = action.defaultShortcut
            }
            guard let resolved = values[action], !resolved.isEmpty else { continue }
            let earlier = TranslationShortcutAction.allCases.prefix { $0 != action }.compactMap { values[$0] }
            if earlier.contains(resolved) {
                values[action] = earlier.contains(action.defaultShortcut) ? "" : action.defaultShortcut
            }
        }
    }

    /// The shortcut in effect in normalised notation; empty when the action has none.
    public subscript(action: TranslationShortcutAction) -> String { values[action] ?? action.defaultShortcut }

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
        for action in TranslationShortcutAction.allCases where self[action] == pressed {
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
    /// when it can. `others` are the input method's other hotkey settings with their titles,
    /// as stored. Conflicts with other applications are not known to the input method.
    public func issue(
        recording candidate: String, for action: TranslationShortcutAction, others: [(shortcut: String, title: String)] = []
    ) -> TranslationShortcutIssue? {
        guard let parsed = Self.parse(candidate) else { return .unsupported }
        if let issue = Self.intrinsicIssue(parsed, for: action) { return issue }
        for other in TranslationShortcutAction.allCases where other != action && self[other] == parsed.notation {
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
        return TranslationShortcutAction.allCases.first { self[$0] == notation }
    }

    // MARK: - Hints

    /// The hint under the draft of a live session, naming the submit shortcut in effect.
    public var liveStatusHint: String {
        let submit = self[.submit]
        return submit.isEmpty ? "↩ 原文   esc 退出" : "↩ 原文   \(HotkeyFormatter.display(submit)) 译文   esc 退出"
    }

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
