/// Drives a `LiveTranslationSession`: owns the debounce timer and the request in flight,
/// and reports every snapshot change. Time and translation are injected.
@MainActor public final class LiveTranslationCoordinator {
    public typealias Translate = @Sendable (TranslationRequest) async -> Result<String, TranslationFailure>
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Called once per render with the new snapshot, and once with nil after `end()`.
    /// After `end()` it is never called with a snapshot of the ended session.
    public var onChange: (@MainActor (LiveTranslationSnapshot?) -> Void)?
    public private(set) var session: LiveTranslationSession?

    private static var lastID: UInt64 = 0
    private let translate: Translate
    private let sleep: Sleep
    private var debounceTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?

    public init(translate: @escaping Translate, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.translate = translate
        self.sleep = sleep
    }

    public var isActive: Bool { session != nil }
    /// The target of the running session.
    public var target: TranslationTarget? { session?.target }
    public var validTranslation: String? { session?.validTranslation }

    /// Starts a session, ending the current one first. Ids grow monotonically within the process.
    public func start(target: TranslationTarget) {
        if session != nil { end() }
        Self.lastID += 1
        let started = LiveTranslationSession(id: Self.lastID, target: target)
        session = started
        onChange?(started.snapshot)
    }

    public func sourceChanged(_ text: String) { apply(.sourceChanged(text)) }
    public func targetPressed(_ target: TranslationTarget) { apply(.targetPressed(target)) }
    public func retry() { apply(.retry) }

    /// Ends the session. Results that arrive later are dropped.
    public func end() {
        guard session != nil else { return }
        cancelPending()
        session = nil
        onChange?(nil)
    }

    private func apply(_ event: LiveTranslationSession.Event) {
        guard var current = session else { return }
        let effects = current.handle(event)
        session = current
        for effect in effects {
            // A callback may have ended or replaced the session in the middle of the list.
            guard session?.id == current.id else { return }
            switch effect {
            case .cancelPending: cancelPending()
            case let .scheduleDebounce(tag): scheduleDebounce(tag)
            case let .start(request): start(request)
            case .render: onChange?(session?.snapshot)
            }
        }
    }

    private func cancelPending() {
        debounceTask?.cancel()
        debounceTask = nil
        requestTask?.cancel()
        requestTask = nil
    }

    private func scheduleDebounce(_ tag: TranslationTag) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, sleep] in
            // A throwing sleep means the timer was cancelled.
            do { try await sleep(LiveTranslationSession.debounce) } catch { return }
            guard !Task.isCancelled, let self, self.session?.id == tag.session else { return }
            self.apply(.debounceFired(tag))
        }
    }

    private func start(_ request: TranslationRequest) {
        requestTask?.cancel()
        requestTask = Task { [weak self, translate] in
            let result = await translate(request)
            // A provider may ignore cancellation; the tag check in the session drops what is stale.
            guard !Task.isCancelled, let self, self.session?.id == request.tag.session else { return }
            self.apply(.completed(request.tag, result))
        }
    }
}
