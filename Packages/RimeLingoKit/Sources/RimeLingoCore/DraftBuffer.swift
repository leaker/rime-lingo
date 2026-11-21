public import Foundation

/// 输入图层: text committed by the engine waits here — shown at the cursor as underlined
/// (marked) text — until the user confirms it, the auto-commit delay passes, or an action
/// (polish, translate…) replaces it. Pure state; the input method renders and applies it.
public struct DraftBuffer: Sendable, Equatable {
    /// Long marked text is expensive for clients; past this the oldest part is committed.
    public static let maxLength = 300

    /// Every plain change of the text leaves the caret at its end.
    public private(set) var text = "" { didSet { caret = text.utf16.count } }
    /// Where text goes in and ⌫ takes it out: a UTF-16 offset into `text`, always between
    /// two characters. It is the end of the draft unless a live translation session moved it.
    public private(set) var caret = 0

    public init() {}

    public var isEmpty: Bool { text.isEmpty }

    public enum CaretMove: Sendable, Equatable { case left, right, start, end }

    /// Moves the caret by one character or to an end; false when it was already there.
    public mutating func moveCaret(_ move: CaretMove) -> Bool {
        let destination: Int? = switch move {
        case .left: boundaries.last { $0 < caret }
        case .right: boundaries.first { $0 > caret }
        case .start: 0
        case .end: text.utf16.count
        }
        guard let destination, destination != caret else { return false }
        caret = destination
        return true
    }

    public var textBeforeCaret: String { String(text[..<caretIndex]) }
    public var textAfterCaret: String { String(text[caretIndex...]) }

    /// Puts text in at the caret; the caret ends after it.
    public mutating func insertAtCaret(_ addition: String) {
        let offset = caret + addition.utf16.count
        var edited = text
        edited.insert(contentsOf: addition, at: caretIndex)
        setText(edited, caret: offset)
    }

    /// Removes the character after the caret; false when there was none.
    public mutating func deleteForward() -> Bool {
        guard let end = boundaries.first(where: { $0 > caret }) else { return false }
        var edited = text
        edited.removeSubrange(caretIndex..<String.Index(utf16Offset: end, in: text))
        setText(edited, caret: caret)
        return true
    }

    /// UTF-16 offsets between characters, from 0 to the length of the text.
    private var boundaries: [Int] {
        text.reduce(into: [0]) { offsets, character in offsets.append(offsets[offsets.count - 1] + character.utf16.count) }
    }

    private var caretIndex: String.Index { String.Index(utf16Offset: caret, in: text) }

    /// An edit can join the characters around the caret (a combining mark after a new
    /// letter): the caret then goes after the joined character, never inside it.
    private mutating func setText(_ newText: String, caret offset: Int) {
        text = newText
        caret = boundaries.first { $0 >= offset } ?? text.utf16.count
    }

    /// Appends committed text at the end, wherever the caret was. Returns text that must be inserted into the app first when
    /// the draft would grow past `maxLength`.
    public mutating func append(_ addition: String) -> String? {
        guard text.utf16.count + addition.utf16.count > Self.maxLength, !text.isEmpty else {
            text += addition
            return nil
        }
        let overflow = text
        text = addition
        return overflow
    }

    /// Removes the character before the caret; false when there was none.
    public mutating func deleteBackward() -> Bool {
        guard let start = boundaries.last(where: { $0 < caret }) else { return false }
        var edited = text
        edited.removeSubrange(String.Index(utf16Offset: start, in: text)..<caretIndex)
        setText(edited, caret: start)
        return true
    }

    /// Empties the draft and returns what it held.
    public mutating func take() -> String {
        defer { text = "" }
        return text
    }

    public mutating func replace(with newText: String) { text = newText }

    /// What a key does while a draft is pending and nothing is being composed.
    public enum KeyDecision: Sendable, Equatable {
        /// Put the draft into the app; the key is consumed (Return, Esc).
        case commit
        /// Put the draft into the app, then let the app have the key (arrows, Tab, ⌘ / ⌃ shortcuts).
        case commitAndPass
        case deleteBackward
        /// An ordinary key: the engine sees it first.
        case toEngine
    }

    public static func decision(keyCode: UInt16, command: Bool, control: Bool) -> KeyDecision {
        if command || control { return .commitAndPass }
        switch keyCode {
        case 36, 76, 53: return .commit                                   // Return, Enter, Esc
        case 51: return .deleteBackward                                   // ⌫
        case 48, 123, 124, 125, 126, 115, 116, 117, 119, 121:             // Tab, arrows, Home, PgUp, ⌦, End, PgDn
            return .commitAndPass
        default: return .toEngine
        }
    }

    /// Whether `text` may open a draft: words (汉字 or Latin letters). A space, digits or
    /// punctuation on their own go straight to the app; once a draft is open they join it.
    public static func opensDraft(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) || (0x20000...0x2EBEF).contains(value)
                || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
        }
    }

    /// Apps where the layer stays off even when enabled: English-first apps (terminals,
    /// editors, launchers — their keys must reach the app at once) and password managers.
    public static func isExempt(appStartsInEnglish: Bool, bundleID: String?, secureInput: Bool) -> Bool {
        if secureInput || appStartsInEnglish { return true }
        if let bundleID, UsageStatsStore.excludedApps.contains(bundleID) { return true }
        return false
    }
}

/// What the input method just put into the current text field, kept in memory so an AI
/// action can work on "what I just typed" without a selection. It is only a hint: before
/// anything is replaced, the text is read back from the app and must match.
public struct RecentText: Sendable, Equatable {
    public static let maxLength = 500

    public private(set) var text = ""

    public init() {}

    public mutating func append(_ addition: String) {
        text += addition
        if text.utf16.count > Self.maxLength {
            // Keep the tail; cut on a character boundary.
            var tail = Substring(text)
            while tail.utf16.count > Self.maxLength { tail = tail.dropFirst() }
            text = String(tail)
        }
    }

    public mutating func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    public mutating func reset() { text = "" }

    /// The range the text should occupy when the caret sits right after it.
    public func range(caretAt location: Int) -> NSRange? {
        let length = text.utf16.count
        guard length > 0, location != NSNotFound, location >= length else { return nil }
        return NSRange(location: location - length, length: length)
    }
}
