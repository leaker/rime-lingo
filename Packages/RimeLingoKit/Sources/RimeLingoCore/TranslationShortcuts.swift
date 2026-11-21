/// The live translation shortcuts. The key codes live here and nowhere else.
public enum TranslationShortcuts {
    public static let englishKeyCode: UInt16 = 14   // E
    public static let japaneseKeyCode: UInt16 = 38  // J

    /// Matches only when the modifiers are exactly Control+Option+Command (no Shift).
    public static func target(keyCode: UInt16, control: Bool, option: Bool, command: Bool, shift: Bool) -> TranslationTarget? {
        guard control, option, command, !shift else { return nil }
        switch keyCode {
        case englishKeyCode: return .english
        case japaneseKeyCode: return .japanese
        default: return nil
        }
    }
}

/// What a matched translation shortcut does.
public enum TranslationDispatch: Sendable, Equatable {
    /// The feature is off: the key is not consumed and takes today's path.
    case ignore
    /// Swallowed without any effect: a key repeat, or the quick menu / an action owns the keyboard.
    case consume
    /// The client has a non-empty selection that is not the open preview's: capture and
    /// translate it. A live session, if any, stays suspended underneath.
    case captureSelection(TranslationTarget)
    /// A selection preview is open for this field: hand the target to it (retranslate the
    /// captured text, or re-show / retry). The selection is not read again.
    case retargetSelection(TranslationTarget)
    /// No session yet: start one. Like `forward`, this closes a selection preview left
    /// over from another field.
    case start(TranslationTarget)
    /// A session is active: hand the target to it (switch, or re-show / refresh).
    case forward(TranslationTarget)

    public static func decide(
        target: TranslationTarget, featureEnabled: Bool, isRepeat: Bool, menuOrActionOpen: Bool,
        selection: SelectionPresence, selectionPreviewAttached: Bool, sessionActive: Bool
    ) -> TranslationDispatch {
        if !featureEnabled { return .ignore }
        // A held shortcut acts once; it must not restart a request on every repeat.
        if isRepeat || menuOrActionOpen { return .consume }
        // A selection comes before a live session, and so does the preview of one.
        switch selection {
        case .new: return .captureSelection(target)
        case .captured: return .retargetSelection(target)
        case .none: if selectionPreviewAttached { return .retargetSelection(target) }
        }
        return sessionActive ? .forward(target) : .start(target)
    }
}

/// Why a submit does nothing. Only a current, finished translation is ever inserted.
public enum LiveSubmitBlock: Sendable, Equatable {
    /// Candidates are still open: the source is not final.
    case composing
    /// No finished translation of the current source and target.
    case notReady
    /// A selection preview owns the panel: the session's translation is not on screen,
    /// and nothing the user has not seen is inserted.
    case previewHidden

    public var message: String {
        switch self {
        case .composing: "请先完成选词"
        case .notReady: "译文尚未就绪"
        case .previewHidden: "请先关闭选区译文预览"
        }
    }

    /// Nil when the translation may be submitted.
    public static func check(
        isComposing: Bool, hasValidTranslation: Bool, selectionPreviewOpen: Bool = false
    ) -> LiveSubmitBlock? {
        if selectionPreviewOpen { return .previewHidden }
        if isComposing { return .composing }
        return hasValidTranslation ? nil : .notReady
    }
}

/// Keys that belong to an active live translation session. Everything else keeps the
/// existing draft / engine handling.
public enum LiveSessionKey: Sendable, Equatable {
    /// Option+Return or Option+Enter with a valid translation and nothing being composed.
    case submit
    /// Option+Return or Option+Enter that must not submit. The key is still swallowed:
    /// in the app it could send a message.
    case submitBlocked(LiveSubmitBlock)
    /// Esc while nothing is being composed.
    case exit
    /// Not a session key (Esc while composing belongs to the engine).
    case none

    public static func decision(
        keyCode: UInt16, option: Bool, command: Bool, control: Bool, shift: Bool,
        isComposing: Bool, hasValidTranslation: Bool, selectionPreviewOpen: Bool = false
    ) -> LiveSessionKey {
        guard !command, !control else { return .none }
        switch keyCode {
        case 36, 76:
            guard option, !shift else { return .none }
            if let block = LiveSubmitBlock.check(
                isComposing: isComposing, hasValidTranslation: hasValidTranslation,
                selectionPreviewOpen: selectionPreviewOpen) {
                return .submitBlocked(block)
            }
            return .submit
        case 53: return option || isComposing ? .none : .exit
        default: return .none
        }
    }
}

extension DraftBuffer {
    /// The draft of a live translation session is at its limit: the host takes no more
    /// typed keys into it (and starts no new composition) until the user submits or commits.
    public var isFullForLiveSession: Bool { text.utf16.count >= Self.maxLength }

    /// Adds text the engine has already committed to the draft of a live session. Nothing
    /// spills into the app and nothing is dropped: the text can no longer be refused, so the
    /// draft may end past `maxLength` by at most one commit. Returns whether it is now full.
    public mutating func appendForLiveSession(_ addition: String) -> Bool {
        replace(with: text + addition)
        return isFullForLiveSession
    }
}
