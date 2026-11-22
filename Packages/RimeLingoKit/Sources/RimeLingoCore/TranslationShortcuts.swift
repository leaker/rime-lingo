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
    /// Live translation is off: turn it on with this target. Like `switchTarget`, this
    /// closes a selection preview left over from another field.
    case start(TranslationTarget)
    /// The shortcut of the active target pressed again: the source text goes into the app
    /// and live translation turns off.
    case stop
    /// Live translation is on with another target: switch to this one and retranslate
    /// the current draft.
    case switchTarget(TranslationTarget)

    public static func decide(
        target: TranslationTarget, featureEnabled: Bool, isRepeat: Bool, menuOrActionOpen: Bool,
        selection: SelectionPresence, selectionPreviewAttached: Bool, activeTarget: TranslationTarget?
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
        // A language shortcut is a toggle.
        guard let activeTarget else { return .start(target) }
        return activeTarget == target ? .stop : .switchTarget(target)
    }
}

/// How the live translation mode applies to one field. The mode is process-wide, but a
/// session is not started behind the user's back in an application the input layer leaves
/// alone (`DraftBuffer.isExempt`: terminals, launchers, password managers, English-first
/// applications): there typed text would go into a hidden draft instead of the app.
public enum LiveFieldPolicy {
    /// The target a field without a session resumes with on its next key, silently. Nil:
    /// no session starts and every key takes the path it has with translation off. The
    /// mode itself is not touched, so other applications still resume.
    public static func silentResumeTarget(
        mode: TranslationTarget?, featureEnabled: Bool, sessionActive: Bool, appExempt: Bool
    ) -> TranslationTarget? {
        guard featureEnabled, !sessionActive, !appExempt else { return nil }
        return mode
    }

    /// The active target a language shortcut toggles against in this field
    /// (`TranslationDispatch.decide`). An exempt application without a session is not
    /// translating, whatever the mode says: a shortcut pressed there is the user asking
    /// for translation in that field, so it starts a session instead of turning off or
    /// switching a mode that shows nothing there.
    public static func toggleTarget(mode: TranslationTarget?, sessionActive: Bool, appExempt: Bool) -> TranslationTarget? {
        appExempt && !sessionActive ? nil : mode
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

/// Keys that belong to an active live translation session: the submit shortcut and Esc,
/// while there is a draft or a composition. With an empty draft and nothing being composed
/// neither belongs to the session: live translation stays on for as long as the user
/// wants, and must not keep these keys away from the app. Everything else keeps the
/// existing draft / engine handling.
public enum LiveSessionKey: Sendable, Equatable {
    /// The submit shortcut (Option+Return or Option+Enter by default) with a valid
    /// translation and nothing being composed.
    case submit
    /// The submit shortcut after a failure or above the automatic limit: translate the
    /// draft now.
    case retry
    /// The submit shortcut where it must not submit. The key is still swallowed:
    /// in the app it could send a message.
    case submitBlocked(LiveSubmitBlock)
    /// Esc with a draft and nothing being composed: the source text goes into the app
    /// and live translation turns off.
    case exit
    /// Not a session key: Esc while composing belongs to the engine, and with an empty
    /// draft Esc and the submit shortcut belong to the app.
    case none

    /// `submitMatched`: whether the key is the configured submit shortcut; nil stands for
    /// the default one. `canRetry`: the translation failed or the draft is above the
    /// automatic limit.
    public static func decision(
        keyCode: UInt16, option: Bool, command: Bool, control: Bool, shift: Bool,
        isComposing: Bool, hasValidTranslation: Bool, selectionPreviewOpen: Bool = false,
        submitMatched: Bool? = nil, draftIsEmpty: Bool = false, canRetry: Bool = false
    ) -> LiveSessionKey {
        if submitMatched ?? TranslationShortcutBindings.isDefaultSubmit(
            keyCode: keyCode, option: option, command: command, control: control, shift: shift) {
            if draftIsEmpty, !isComposing { return .none }
            if let block = LiveSubmitBlock.check(
                isComposing: isComposing, hasValidTranslation: hasValidTranslation || canRetry,
                selectionPreviewOpen: selectionPreviewOpen) {
                return .submitBlocked(block)
            }
            return hasValidTranslation ? .submit : .retry
        }
        guard !command, !control, !option, keyCode == 53 else { return .none }
        return isComposing || draftIsEmpty ? .none : .exit
    }
}

/// Swallows the auto-repeats of a key press that a translation session consumed.
///
/// The session keys (the submit shortcut and Esc) stop belonging to the session the moment
/// they act: a submit empties the draft, a replace closes the selection preview. Holding the
/// key a little too long would hand its repeats to the app, where the submit shortcut can
/// send a message. A repeat therefore goes wherever its press went: swallowed when the
/// press was consumed, passed on when the press was passed on.
public struct ConsumedKeyRepeat: Sendable, Equatable {
    private var consumedKeyCode: UInt16?

    public init() {}

    /// Call for every key down before it is handled. True when the event repeats a press
    /// recorded with `consumed(keyCode:)`: it must be swallowed without acting again.
    /// Any new press forgets the record.
    public mutating func swallows(keyCode: UInt16, isRepeat: Bool) -> Bool {
        if isRepeat { return consumedKeyCode == keyCode }
        consumedKeyCode = nil
        return false
    }

    /// A translation session consumed this key down.
    public mutating func consumed(keyCode: UInt16) { consumedKeyCode = keyCode }
}

extension DraftBuffer {
    /// The draft of a live translation session is at its limit: the host takes no more
    /// typed keys into it (and starts no new composition) until the user submits or commits.
    public var isFullForLiveSession: Bool { text.utf16.count >= Self.maxLength }

    /// Adds text the engine has already committed to the draft of a live session, at the
    /// caret. Nothing spills into the app and nothing is dropped: the text can no longer be
    /// refused, so the draft may end past `maxLength` by at most one commit. Returns whether
    /// it is now full.
    public mutating func insertForLiveSession(_ addition: String) -> Bool {
        insertAtCaret(addition)
        return isFullForLiveSession
    }

    /// Carries out a caret key; false when nothing changed (the caret was at a boundary).
    public mutating func apply(_ key: LiveDraftKey) -> Bool {
        switch key {
        case let .move(move): moveCaret(move)
        case .deleteBackward: deleteBackward()
        case .deleteForward: deleteForward()
        }
    }
}

/// Keys that edit the draft of a live translation session at its caret, while the draft
/// is not empty and nothing is being composed. They are consumed and never commit the
/// draft. Every other key keeps the draft handling it has outside a session.
public enum LiveDraftKey: Sendable, Equatable {
    case move(DraftBuffer.CaretMove)
    case deleteBackward
    case deleteForward

    public static func decision(
        keyCode: UInt16, option: Bool, command: Bool, control: Bool, shift: Bool,
        sessionActive: Bool, draftIsEmpty: Bool, isComposing: Bool
    ) -> LiveDraftKey? {
        guard sessionActive, !draftIsEmpty, !isComposing else { return nil }
        let plain = !option && !command && !control && !shift
        let commandOnly = command && !option && !control && !shift
        let controlOnly = control && !option && !command && !shift
        switch keyCode {
        case 123: return plain ? .move(.left) : commandOnly ? .move(.start) : nil   // ←
        case 124: return plain ? .move(.right) : commandOnly ? .move(.end) : nil    // →
        case 115: return plain ? .move(.start) : nil                                // Home
        case 119: return plain ? .move(.end) : nil                                  // End
        case 0: return controlOnly ? .move(.start) : nil                            // ⌃A
        case 14: return controlOnly ? .move(.end) : nil                             // ⌃E
        case 51: return command || control ? nil : .deleteBackward                  // ⌫
        case 117: return command || control ? nil : .deleteForward                  // ⌦
        default: return nil
        }
    }
}
