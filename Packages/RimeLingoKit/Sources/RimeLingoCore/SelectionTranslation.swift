public import Foundation

// Selected-text translation: the user selects text in an editable field and presses a
// translation shortcut. The selection is captured once, translated, and shown in the
// preview; it is replaced only on request and only after the field was checked again.
// Everything here is a pure value or takes its dependencies as arguments; no type logs
// or stores the text anywhere but in memory.

/// The field a selection was captured in: the input controller, its client object and
/// the application. All three must still match before anything is written back.
public struct SelectionContext: Sendable, Equatable {
    public let owner: ObjectIdentifier
    public let client: ObjectIdentifier
    public let bundleID: String

    public init(owner: ObjectIdentifier, client: ObjectIdentifier, bundleID: String) {
        self.owner = owner
        self.client = client
        self.bundleID = bundleID
    }
}

/// Why a selection was not captured. Nothing else happens then: no dialog, no clipboard.
public enum SelectionCaptureFailure: Error, Sendable, Equatable {
    /// The client gave no text, blank text, or text of another length than the range.
    case unreadable
    case tooLong

    public var message: String {
        switch self {
        case .unreadable: "无法读取选中的文字"
        case .tooLong: "选中的文字超过 \(SelectionCapture.maxLength) 字符上限"
        }
    }
}

/// The selection as it was when the shortcut was pressed. It is never read again:
/// a new target translates this text, and replacing compares the field against it.
public struct SelectionCapture: Sendable, Equatable {
    /// UTF-16 units. A longer selection is refused, never truncated.
    public static let maxLength = 2000

    public let context: SelectionContext
    public let range: NSRange
    public let text: String

    /// Validates what the client reported. `text` is asked for only when the range is
    /// a non-empty selection within the limit.
    public static func read(
        context: SelectionContext, range: NSRange, text: () -> String?
    ) -> Result<SelectionCapture, SelectionCaptureFailure> {
        guard range.location != NSNotFound, range.length > 0 else { return .failure(.unreadable) }
        guard range.length <= maxLength else { return .failure(.tooLong) }
        guard let text = text(), text.utf16.count == range.length, !text.allSatisfy(\.isWhitespace) else {
            return .failure(.unreadable)
        }
        return .success(SelectionCapture(context: context, range: range, text: text))
    }

    /// The text that replaces the selection. The translator works on the trimmed source,
    /// so the white space and line breaks around it are put back: a selection that ends
    /// with a line break must not pull the next paragraph up.
    public func replacement(for translation: String) -> String {
        let leading = text.prefix(while: \.isWhitespace)
        let trailing = text.dropFirst(leading.count).reversed().prefix(while: \.isWhitespace).reversed()
        return String(leading) + translation + String(trailing)
    }
}

/// Why the selection is not replaced.
public enum SelectionReplaceBlock: Sendable, Equatable {
    /// No finished translation of the capture into the current target yet.
    case notReady
    /// Another controller, client or application: the capture's field is not the active one.
    case contextChanged
    /// The captured range no longer holds the captured text.
    case sourceChanged

    public var message: String {
        switch self {
        case .notReady: "译文尚未就绪"
        case .contextChanged: "输入位置已改变，无法替换"
        case .sourceChanged: "原文已变化，无法替换"
        }
    }

    /// Stays for the rest of the capture: the preview keeps the translation for reading,
    /// with replacement off.
    public var isPermanent: Bool { self != .notReady }
}

public enum SelectionReplaceDecision: Sendable, Equatable {
    /// Insert this text over this range, and nothing else.
    case replace(NSRange, String)
    case blocked(SelectionReplaceBlock)
    /// A secure context: capture and preview are dropped, nothing is written.
    case discard
}

/// How the client's selection relates to an open selection preview.
public enum SelectionPresence: Sendable, Equatable {
    /// No selection (or our own marked text is pending).
    case none
    /// The selection the open preview was captured from, still replaceable.
    case captured
    /// A selection that has to be captured.
    case new
}

/// State of one selected-text translation. A pure value like `LiveTranslationSession`:
/// the host feeds events and carries out the effects.
public struct SelectionTranslationSession: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case translating, ready, failed(TranslationFailure)
    }

    public enum Event: Sendable, Equatable {
        case targetPressed(TranslationTarget)
        case completed(TranslationTag, Result<String, TranslationFailure>)
        case retry
        /// The capture's controller was deactivated or lost its client.
        case detached
        case replaceRefused(SelectionReplaceBlock)
    }

    public enum Effect: Sendable, Equatable {
        /// Cancel the request in flight (idempotent).
        case cancelPending
        case start(TranslationRequest)
        case render
    }

    /// The capture id: grows with every capture, so results of an earlier one never match.
    public let id: UInt64
    public let capture: SelectionCapture
    public private(set) var target: TranslationTarget
    /// Grows with every request, so only the latest answer is taken.
    public private(set) var attempt: Int
    public private(set) var phase: Phase
    public private(set) var translation: LiveTranslationSession.Translation?
    /// Set once replacing became unsafe; it stays until the preview closes.
    public private(set) var replaceBlock: SelectionReplaceBlock?

    public init(id: UInt64, capture: SelectionCapture, target: TranslationTarget) {
        self.id = id
        self.capture = capture
        self.target = target
        attempt = 0
        phase = .translating
        translation = nil
        replaceBlock = nil
    }

    public var currentTag: TranslationTag { TranslationTag(session: id, revision: attempt, target: target) }

    /// The only text that may be copied or used for replacing.
    public var validTranslation: String? {
        guard phase == .ready, let translation, translation.tag == currentTag else { return nil }
        return translation.text
    }

    /// The first request. Called once, right after the capture.
    public mutating func begin() -> [Effect] { startNow() }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .targetPressed(pressed):
            // The current target again: show the preview again, or retry after a failure.
            guard pressed != target else { return isFailed ? startNow() : [.render] }
            // Another target: the same captured text, never a new read.
            target = pressed
            return startNow()

        case let .completed(tag, result):
            guard tag == currentTag, phase == .translating else { return [] }
            switch result {
            case let .success(text):
                translation = LiveTranslationSession.Translation(text: text, tag: tag)
                phase = .ready
            case let .failure(failure):
                phase = .failed(failure)
            }
            return [.render]

        case .retry:
            return isFailed ? startNow() : []

        case .detached:
            return block(.contextChanged)

        case let .replaceRefused(reason):
            return reason.isPermanent ? block(reason) : []
        }
    }

    /// Decides a replacement right before it is written. `active` is the field that has
    /// the keyboard now (nil when none); `currentText` reads the captured range from it
    /// and is asked only when that field is the capture's and the context is not secure.
    public func checkReplace(
        active: SelectionContext?, isSecure: Bool, currentText: () -> String?
    ) -> SelectionReplaceDecision {
        if isSecure { return .discard }
        if let replaceBlock { return .blocked(replaceBlock) }
        guard let text = validTranslation else { return .blocked(.notReady) }
        guard active == capture.context else { return .blocked(.contextChanged) }
        guard currentText() == capture.text else { return .blocked(.sourceChanged) }
        return .replace(capture.range, capture.replacement(for: text))
    }

    /// Whether the preview belongs to this field. Its keys (⌥↩, Esc) and a shortcut
    /// pressed without a selection act on it only there.
    public func isAttached(to context: SelectionContext) -> Bool { context == capture.context }

    /// `range` is the client's non-empty selection, nil when it has none. `currentText`
    /// reads that selection and is asked only when it is the captured range of this
    /// field: other text at the same place is a selection of its own, not the captured one.
    public func presence(
        ofSelection range: NSRange?, in context: SelectionContext, currentText: () -> String?
    ) -> SelectionPresence {
        guard let range else { return .none }
        // Once replacing is off, pressing the shortcut on the selection captures it afresh.
        guard isAttached(to: context), range == capture.range, replaceBlock == nil else { return .new }
        return currentText() == capture.text ? .captured : .new
    }

    public var snapshot: LiveTranslationSnapshot {
        let status: LiveTranslationSnapshot.Status
        var message: String
        switch phase {
        case .translating: (status, message) = (.updating, "翻译中…")
        case .ready: (status, message) = (.ready, "")
        case let .failed(failure): (status, message) = (.failed, failure.message)
        }
        let text = validTranslation
        // The reason replacing is off, unless a failure has to be shown.
        if status != .failed, let replaceBlock { message = replaceBlock.message }
        return LiveTranslationSnapshot(
            targetLabel: target.displayName, status: status, text: text ?? "", isStale: false, message: message,
            canSubmit: text != nil && replaceBlock == nil, canRetry: status == .failed,
            showsPanel: true)
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private mutating func block(_ reason: SelectionReplaceBlock) -> [Effect] {
        guard replaceBlock == nil else { return [] }
        replaceBlock = reason
        return [.render]
    }

    private mutating func startNow() -> [Effect] {
        attempt += 1
        phase = .translating
        return [.cancelPending, .start(TranslationRequest(tag: currentTag, source: capture.text)), .render]
    }
}

/// Keys that belong to an open selection preview in its own field. Everything else,
/// ordinary typing included, takes the normal input path.
public enum SelectionPreviewKey: Sendable, Equatable {
    /// Option+Return or Option+Enter: replace the selection (revalidated by the host).
    case replace
    /// Option+Return or Option+Enter after a failed translation: translate the capture again.
    case retry
    /// Option+Return or Option+Enter while a composition or a draft is pending: nothing
    /// is replaced, and the key is still swallowed. Passed on, it would commit the draft
    /// unasked or reach the application, where it could send a message.
    case replaceBlocked
    /// Esc: close the preview and change nothing.
    case close
    case none

    /// Shown for `replaceBlocked`.
    public static let pendingInputMessage = "请先完成输入"

    /// `hasMarkedText`: a composition or a draft of ours is pending in the field; every
    /// key but the submit shortcut keeps its meaning there. `submitMatched`: whether the
    /// key is the configured submit shortcut; nil stands for the default, Option+Return.
    /// `canRetry`: the translation failed.
    public static func decision(
        keyCode: UInt16, option: Bool, command: Bool, control: Bool, shift: Bool, hasMarkedText: Bool,
        submitMatched: Bool? = nil, canRetry: Bool = false
    ) -> SelectionPreviewKey {
        if submitMatched ?? TranslationShortcutBindings.isDefaultSubmit(
            keyCode: keyCode, option: option, command: command, control: control, shift: shift) {
            if hasMarkedText { return .replaceBlocked }
            return canRetry ? .retry : .replace
        }
        guard !command, !control, keyCode == 53 else { return .none }
        return option || hasMarkedText ? .none : .close
    }
}

/// Who owns the one preview panel while a selection preview is open.
public enum SelectionPreviewOwnership {
    /// A live session stays suspended under a selection preview only while its draft is
    /// empty. Once the draft has text the session translates it, and that translation
    /// must be on screen before it can be submitted: the selection preview closes and
    /// the live preview takes the panel back.
    public static func yieldsToLiveSession(liveSessionActive: Bool, draftIsEmpty: Bool) -> Bool {
        liveSessionActive && !draftIsEmpty
    }
}

/// Drives a `SelectionTranslationSession`: owns the request in flight and reports every
/// snapshot change. One instance serves the whole input method; the preview it feeds
/// outlives the controller the selection was captured in.
@MainActor public final class SelectionTranslationCoordinator {
    /// Called once per render with the new snapshot, and once with nil after `end()`.
    public var onChange: (@MainActor (LiveTranslationSnapshot?) -> Void)?
    public private(set) var session: SelectionTranslationSession?

    private static var lastID: UInt64 = 0
    private let translate: LiveTranslationCoordinator.Translate
    private var requestTask: Task<Void, Never>?

    public init(translate: @escaping LiveTranslationCoordinator.Translate) {
        self.translate = translate
    }

    public var isActive: Bool { session != nil }
    public var validTranslation: String? { session?.validTranslation }

    /// Starts translating a new capture, ending the current one first.
    public func start(capture: SelectionCapture, target: TranslationTarget) {
        if session != nil { end() }
        Self.lastID += 1
        var started = SelectionTranslationSession(id: Self.lastID, capture: capture, target: target)
        let effects = started.begin()
        session = started
        run(effects, for: started.id)
    }

    public func targetPressed(_ target: TranslationTarget) { apply(.targetPressed(target)) }
    public func retry() { apply(.retry) }
    /// The capture's field is gone: the preview stays, replacing is off.
    public func detach() { apply(.detached) }

    /// Decides a replacement (see `SelectionTranslationSession.checkReplace`) and records
    /// its outcome: a permanent block stays on the preview, a secure context ends it.
    /// After `.replace` the caller writes the text and calls `end()`.
    public func replace(
        active: SelectionContext?, isSecure: Bool, currentText: () -> String?
    ) -> SelectionReplaceDecision? {
        guard let session else { return nil }
        let decision = session.checkReplace(active: active, isSecure: isSecure, currentText: currentText)
        switch decision {
        case .replace: break
        case let .blocked(reason): apply(.replaceRefused(reason))
        case .discard: end()
        }
        return decision
    }

    /// Closes the preview: cancel, a finished replacement, or a secure context. Results
    /// that arrive later are dropped.
    public func end() {
        guard session != nil else { return }
        requestTask?.cancel()
        requestTask = nil
        session = nil
        onChange?(nil)
    }

    private func apply(_ event: SelectionTranslationSession.Event) {
        guard var current = session else { return }
        let effects = current.handle(event)
        session = current
        run(effects, for: current.id)
    }

    private func run(_ effects: [SelectionTranslationSession.Effect], for id: UInt64) {
        for effect in effects {
            // A callback may have ended or replaced the session in the middle of the list.
            guard session?.id == id else { return }
            switch effect {
            case .cancelPending:
                requestTask?.cancel()
                requestTask = nil
            case let .start(request):
                requestTask = Task { [weak self, translate] in
                    let result = await translate(request)
                    // A provider may ignore cancellation; the tag check drops what is stale.
                    guard !Task.isCancelled, let self, self.session?.id == request.tag.session else { return }
                    self.apply(.completed(request.tag, result))
                }
            case .render:
                onChange?(session?.snapshot)
            }
        }
    }
}
