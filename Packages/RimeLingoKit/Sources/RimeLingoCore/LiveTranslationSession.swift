/// State machine of one live translation session. A pure value: no clock and no tasks.
/// The host feeds events and carries out the returned effects, so every run is deterministic.
public struct LiveTranslationSession: Sendable, Equatable {
    public static let debounce: Duration = .milliseconds(400)
    /// Counted in characters (`String.count`). Above it automatic translation stops.
    public static let autoTranslateLimit = 200

    public enum Phase: Sendable, Equatable {
        case waiting, debouncing, translating, ready, failed(TranslationFailure), overLimit
    }

    public struct Translation: Sendable, Equatable {
        public let text: String
        public let tag: TranslationTag

        public init(text: String, tag: TranslationTag) {
            self.text = text
            self.tag = tag
        }
    }

    public enum Event: Sendable, Equatable {
        /// The whole draft text. Unfinished pinyin never gets here.
        case sourceChanged(String)
        case targetPressed(TranslationTarget)
        case debounceFired(TranslationTag)
        case completed(TranslationTag, Result<String, TranslationFailure>)
        case retry
    }

    public enum Effect: Sendable, Equatable {
        /// Cancel the debounce timer and the request in flight (idempotent).
        case cancelPending
        /// After `debounce`, send back `.debounceFired(tag)`.
        case scheduleDebounce(TranslationTag)
        case start(TranslationRequest)
        /// The snapshot changed, or the preview should be shown again.
        case render
    }

    public let id: UInt64
    public private(set) var target: TranslationTarget
    /// Starts at 0 and grows by one whenever the source changes.
    public private(set) var revision: Int
    public private(set) var source: String
    public private(set) var phase: Phase
    /// The translation shown last. It may be stale.
    public private(set) var translation: Translation?

    public init(id: UInt64, target: TranslationTarget) {
        self.id = id
        self.target = target
        revision = 0
        source = ""
        phase = .waiting
        translation = nil
    }

    public var currentTag: TranslationTag { TranslationTag(session: id, revision: revision, target: target) }

    /// The only text that may be submitted or copied: a finished translation of the
    /// current source into the current target.
    public var validTranslation: String? {
        guard phase == .ready, let translation, translation.tag == currentTag else { return nil }
        return translation.text
    }

    public var snapshot: LiveTranslationSnapshot {
        let status: LiveTranslationSnapshot.Status
        let message: String
        switch phase {
        case .waiting: (status, message) = (.waiting, "")
        case .debouncing, .translating: (status, message) = (.updating, "翻译中…")
        case .ready: (status, message) = (.ready, "")
        case let .failed(failure): (status, message) = (.failed, failure.message)
        case .overLimit: (status, message) = (.overLimit, "超过 \(Self.autoTranslateLimit) 字")
        }
        let showsText = status != .waiting && status != .failed
        let text = showsText ? translation?.text ?? "" : ""
        let canSubmit = validTranslation != nil
        return LiveTranslationSnapshot(
            targetLabel: target.displayName,
            status: status,
            text: text,
            isStale: !text.isEmpty && (translation?.tag != currentTag || status != .ready),
            message: message,
            canSubmit: canSubmit,
            canRetry: status == .failed || status == .overLimit,
            showsPanel: hasSource
        )
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .sourceChanged(text):
            guard text != source else { return [] }
            revision += 1
            source = text
            // Blank text is no source: nothing is sent and nothing is reported as a failure.
            if !hasSource {
                translation = nil
                phase = .waiting
                return [.cancelPending, .render]
            }
            if text.count > Self.autoTranslateLimit {
                phase = .overLimit
                return [.cancelPending, .render]
            }
            phase = .debouncing
            return [.cancelPending, .scheduleDebounce(currentTag), .render]

        case let .targetPressed(pressed):
            // The host sends a target only to switch to it; the current one changes nothing.
            guard pressed != target else { return [] }
            target = pressed
            guard hasSource else {
                phase = .waiting
                return [.cancelPending, .render]
            }
            return startNow()

        case let .debounceFired(tag):
            guard tag == currentTag, phase == .debouncing else { return [] }
            phase = .translating
            return [.start(TranslationRequest(tag: currentTag, source: source)), .render]

        case let .completed(tag, result):
            guard tag == currentTag, phase == .translating else { return [] }
            switch result {
            case let .success(text):
                translation = Translation(text: text, tag: tag)
                phase = .ready
            case let .failure(failure):
                phase = .failed(failure)
            }
            return [.render]

        case .retry:
            return canRestart ? startNow() : []
        }
    }

    /// Whether there is anything to translate: whitespace alone is not a source.
    private var hasSource: Bool { !source.allSatisfy(\.isWhitespace) }

    /// An explicit refresh is possible after a failure or above the automatic limit.
    private var canRestart: Bool {
        guard hasSource else { return false }
        switch phase {
        case .failed, .overLimit: return true
        case .waiting, .debouncing, .translating, .ready: return false
        }
    }

    /// Explicit actions skip the debounce and are sent even above the automatic limit.
    private mutating func startNow() -> [Effect] {
        phase = .translating
        return [.cancelPending, .start(TranslationRequest(tag: currentTag, source: source)), .render]
    }
}

/// What the preview shows for a session.
public struct LiveTranslationSnapshot: Sendable, Equatable {
    /// `debouncing` and `translating` both appear as `updating`.
    public enum Status: Sendable, Equatable { case waiting, updating, ready, failed, overLimit }

    /// The target's display name.
    public var targetLabel: String
    public var status: Status
    /// The translation, possibly stale. Empty while waiting and after a failure.
    public var text: String
    /// There is text, but it does not belong to the current source and target, or it is being replaced.
    public var isStale: Bool
    /// Status line: empty when ready or waiting, the reason after a failure. The host adds
    /// the key that acts on it (`TranslationShortcutBindings.liveMessage`).
    public var message: String
    public var canSubmit: Bool
    public var canRetry: Bool
    /// The live preview is on screen only while there is a draft: false for a live session
    /// whose source is empty or blank, always true for a selection.
    public var showsPanel: Bool
}
