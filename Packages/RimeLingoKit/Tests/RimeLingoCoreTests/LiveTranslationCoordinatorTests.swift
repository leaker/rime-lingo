import Foundation
import Testing
@testable import RimeLingoCore

/// A sleep that ends only when the test fires it, or throws when its task is cancelled.
private final class ManualSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledIDs: Set<Int> = []
    private var started = 0
    private var requested: [Duration] = []

    var calls: Int { lock.withLock { started } }
    var pending: Int { lock.withLock { waiters.count } }
    var cancellations: Int { lock.withLock { cancelledIDs.count } }
    var durations: [Duration] { lock.withLock { requested } }

    func sleep(_ duration: Duration) async throws {
        let id = lock.withLock { () -> Int in
            started += 1
            requested.append(duration)
            return started
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    if cancelledIDs.contains(id) { return true }
                    waiters[id] = continuation
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                cancelledIDs.insert(id)
                return waiters.removeValue(forKey: id)
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Lets every sleeping timer elapse.
    func fire() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        ready.forEach { $0.resume() }
    }
}

/// A translator that answers only when the test says so. It ignores cancellation on
/// purpose (it only counts it), so late results really arrive.
private final class ManualTranslator: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [TranslationRequest] = []
    private var waiters: [Int: CheckedContinuation<Result<String, TranslationFailure>, Never>] = [:]
    private var cancelled = 0

    var requests: [TranslationRequest] { lock.withLock { received } }
    var cancellations: Int { lock.withLock { cancelled } }

    func translate(_ request: TranslationRequest) async -> Result<String, TranslationFailure> {
        let index = lock.withLock { () -> Int in
            received.append(request)
            return received.count - 1
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock { waiters[index] = continuation }
            }
        } onCancel: {
            lock.withLock { cancelled += 1 }
        }
    }

    /// Answers the request with this index; false when it is not waiting.
    @discardableResult func answer(_ index: Int, _ result: Result<String, TranslationFailure>) -> Bool {
        guard let waiter = lock.withLock({ waiters.removeValue(forKey: index) }) else { return false }
        waiter.resume(returning: result)
        return true
    }
}

@MainActor
struct LiveTranslationCoordinatorTests {
    private let sleeper = ManualSleep()
    private let translator = ManualTranslator()
    private let coordinator: LiveTranslationCoordinator
    private let log = Log()

    @MainActor final class Log {
        var snapshots: [LiveTranslationSnapshot?] = []
    }

    init() {
        coordinator = LiveTranslationCoordinator(
            translate: { [translator] in await translator.translate($0) },
            sleep: { [sleeper] in try await sleeper.sleep($0) })
        coordinator.onChange = { [log] in log.snapshots.append($0) }
    }

    /// Waits until `condition` holds; the wait is bounded so a broken build fails instead of hanging.
    private func eventually(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("condition was not reached", sourceLocation: sourceLocation)
    }

    /// Gives finished or cancelled tasks time to run to their end before a negative check.
    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Types `text`, lets the debounce elapse and waits for request number `count`.
    private func type(_ text: String, expectingRequests count: Int) async {
        coordinator.sourceChanged(text)
        await eventually { sleeper.pending == 1 }
        sleeper.fire()
        await eventually { translator.requests.count == count }
    }

    @Test func startShowsAWaitingPreview() {
        #expect(!coordinator.isActive)
        coordinator.start(target: .japanese)
        #expect(coordinator.isActive)
        #expect(log.snapshots.count == 1)
        #expect(log.snapshots.last??.status == .waiting)
        #expect(log.snapshots.last??.targetLabel == "日语")
        #expect(coordinator.validTranslation == nil)
    }

    @Test func nothingHappensWithoutASession() async {
        coordinator.sourceChanged("你好")
        coordinator.targetPressed(.english)
        coordinator.retry()
        coordinator.end()
        await settle()
        #expect(log.snapshots.isEmpty)
        #expect(sleeper.calls == 0)
        #expect(translator.requests.isEmpty)
    }

    @Test func sessionIDsGrow() {
        coordinator.start(target: .english)
        let first = coordinator.session?.id
        coordinator.start(target: .english)
        let second = coordinator.session?.id
        let other = LiveTranslationCoordinator(translate: { _ in .failure(.cancelled) })
        other.start(target: .english)
        #expect(first != nil && second != nil)
        #expect(first! < second!)
        #expect(second! < other.session!.id)
    }

    @Test func translatesAfterTheDebounce() async {
        coordinator.start(target: .english)
        coordinator.sourceChanged("你好")
        await eventually { sleeper.pending == 1 }
        #expect(sleeper.durations == [.milliseconds(400)])
        #expect(translator.requests.isEmpty)
        #expect(log.snapshots.last??.status == .updating)

        sleeper.fire()
        await eventually { translator.requests.count == 1 }
        let request = translator.requests[0]
        #expect(request.source == "你好")
        #expect(request.tag == coordinator.session?.currentTag)

        translator.answer(0, .success("Hello"))
        await eventually { coordinator.validTranslation == "Hello" }
        #expect(log.snapshots.last??.status == .ready)
        #expect(log.snapshots.last??.text == "Hello")
        #expect(log.snapshots.last??.canSubmit == true)
    }

    @Test func rapidTypingSendsOneRequest() async {
        coordinator.start(target: .english)
        coordinator.sourceChanged("你")
        coordinator.sourceChanged("你好")
        coordinator.sourceChanged("你好吗")
        await eventually { sleeper.calls == 3 && sleeper.cancellations == 2 && sleeper.pending == 1 }
        sleeper.fire()
        await eventually { translator.requests.count == 1 }
        await settle()
        #expect(translator.requests.map(\.source) == ["你好吗"])
        #expect(translator.requests[0].tag.revision == 3)
    }

    @Test func editingCancelsTheRequestInFlightAndDropsItsLateResult() async {
        coordinator.start(target: .english)
        await type("你好", expectingRequests: 1)
        coordinator.sourceChanged("你好吗")
        await eventually { translator.cancellations == 1 }

        translator.answer(0, .success("Hello"))
        await settle()
        #expect(coordinator.validTranslation == nil)
        #expect(coordinator.session?.translation == nil)

        await eventually { sleeper.pending == 1 }
        sleeper.fire()
        await eventually { translator.requests.count == 2 }
        translator.answer(1, .success("How are you?"))
        await eventually { coordinator.validTranslation == "How are you?" }
    }

    @Test func switchingTheTargetCancelsAndTranslatesAtOnce() async {
        coordinator.start(target: .english)
        await type("你好", expectingRequests: 1)
        coordinator.targetPressed(.japanese)
        await eventually { translator.requests.count == 2 }
        #expect(translator.cancellations == 1)
        #expect(sleeper.calls == 1)                     // no second debounce
        #expect(translator.requests[1].tag.target == .japanese)
        #expect(translator.requests[1].source == "你好")

        translator.answer(1, .success("こんにちは"))
        await eventually { coordinator.validTranslation == "こんにちは" }
        translator.answer(0, .success("Hello"))
        await settle()
        #expect(coordinator.validTranslation == "こんにちは")
        #expect(log.snapshots.last??.targetLabel == "日语")
    }

    @Test func pressingTheCurrentTargetRendersWithoutANewRequest() async {
        coordinator.start(target: .english)
        await type("你好", expectingRequests: 1)
        translator.answer(0, .success("Hello"))
        await eventually { coordinator.validTranslation == "Hello" }
        let rendered = log.snapshots.count
        coordinator.targetPressed(.english)
        await settle()
        #expect(log.snapshots.count == rendered + 1)
        #expect(log.snapshots.last??.text == "Hello")
        #expect(translator.requests.count == 1)
        #expect(translator.cancellations == 0)
    }

    @Test func clearingCancelsEverythingAndWaits() async {
        coordinator.start(target: .english)
        await type("你好", expectingRequests: 1)
        coordinator.sourceChanged("")
        #expect(log.snapshots.last??.status == .waiting)
        await eventually { translator.cancellations == 1 }
        translator.answer(0, .success("Hello"))
        await settle()
        #expect(coordinator.validTranslation == nil)
        #expect(log.snapshots.last??.status == .waiting)
        #expect(log.snapshots.last??.text == "")
    }

    @Test func clearingCancelsAPendingDebounce() async {
        coordinator.start(target: .english)
        coordinator.sourceChanged("你好")
        await eventually { sleeper.pending == 1 }
        coordinator.sourceChanged("")
        await eventually { sleeper.cancellations == 1 }
        sleeper.fire()
        await settle()
        #expect(translator.requests.isEmpty)
    }

    @Test func aboveTheLimitNothingIsSentUntilTheUserRefreshes() async {
        coordinator.start(target: .english)
        let long = String(repeating: "字", count: 201)
        coordinator.sourceChanged(long)
        await settle()
        #expect(sleeper.calls == 0)
        #expect(translator.requests.isEmpty)
        #expect(log.snapshots.last??.status == .overLimit)

        coordinator.targetPressed(.english)
        await eventually { translator.requests.count == 1 }
        #expect(translator.requests[0].source == long)
        translator.answer(0, .success("Long"))
        await eventually { coordinator.validTranslation == "Long" }
    }

    @Test func aFailureCanBeRetried() async {
        coordinator.start(target: .english)
        await type("你好", expectingRequests: 1)
        translator.answer(0, .failure(.requestFailed))
        await eventually { log.snapshots.last??.status == .failed }
        #expect(log.snapshots.last??.message == TranslationFailure.requestFailed.message)
        #expect(coordinator.validTranslation == nil)

        coordinator.retry()
        await eventually { translator.requests.count == 2 }
        #expect(translator.requests[1].tag == translator.requests[0].tag)
        translator.answer(1, .success("Hello"))
        await eventually { coordinator.validTranslation == "Hello" }
    }

    @Test func endReportsNilOnceAndLateResultsNeverReopenThePreview() async {
        coordinator.start(target: .english)
        await type("你好", expectingRequests: 1)
        coordinator.end()
        #expect(!coordinator.isActive)
        #expect(coordinator.validTranslation == nil)
        #expect(log.snapshots.last! == nil)
        let reported = log.snapshots.count
        await eventually { translator.cancellations == 1 }

        translator.answer(0, .success("Hello"))
        await settle()
        coordinator.end()
        #expect(log.snapshots.count == reported)
        #expect(!coordinator.isActive)
    }

    @Test func endCancelsAPendingDebounce() async {
        coordinator.start(target: .english)
        coordinator.sourceChanged("你好")
        await eventually { sleeper.pending == 1 }
        coordinator.end()
        await eventually { sleeper.cancellations == 1 }
        sleeper.fire()
        await settle()
        #expect(translator.requests.isEmpty)
        #expect(log.snapshots.last! == nil)
    }

    @Test func aResultFromAnEndedSessionDoesNotReachTheNextOne() async {
        coordinator.start(target: .english)
        await type("你好", expectingRequests: 1)
        coordinator.start(target: .english)                // ends the first session
        #expect(log.snapshots.contains { $0 == nil })
        await type("你好", expectingRequests: 2)           // same text, same revision, new session id
        #expect(translator.requests[0].tag != translator.requests[1].tag)

        translator.answer(0, .success("Stale"))
        await settle()
        #expect(coordinator.validTranslation == nil)
        translator.answer(1, .success("Hello"))
        await eventually { coordinator.validTranslation == "Hello" }
    }

    @Test func endingInsideTheCallbackStopsTheRemainingEffects() async {
        coordinator.start(target: .english)
        coordinator.onChange = { [coordinator, log] snapshot in
            log.snapshots.append(snapshot)
            if snapshot?.status == .ready { coordinator.end() }
        }
        await type("你好", expectingRequests: 1)
        translator.answer(0, .success("Hello"))
        await eventually { !coordinator.isActive }
        #expect(log.snapshots.last! == nil)
    }
}
