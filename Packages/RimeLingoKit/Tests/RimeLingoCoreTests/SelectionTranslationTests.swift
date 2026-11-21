import Foundation
import Testing
@testable import RimeLingoCore

private final class Owner: Sendable {}

/// Two fields: `field` is where the selection is captured, `other` is anything else.
private enum Fixture {
    static let controller = Owner(), client = Owner(), otherController = Owner(), otherClient = Owner()
    static let field = SelectionContext(
        owner: ObjectIdentifier(controller), client: ObjectIdentifier(client), bundleID: "com.example.editor")
    static let range = NSRange(location: 7, length: 5)

    static func capture(_ text: String = "你好，世界", at location: Int = 7) -> SelectionCapture {
        SelectionCapture(context: field, range: NSRange(location: location, length: text.utf16.count), text: text)
    }
}

struct SelectionCaptureTests {
    private func read(_ range: NSRange, _ text: String?) -> Result<SelectionCapture, SelectionCaptureFailure> {
        SelectionCapture.read(context: Fixture.field, range: range) { text }
    }

    @Test func readableSelectionIsCapturedAsReported() throws {
        let capture = try read(Fixture.range, "你好，世界").get()
        #expect(capture == Fixture.capture())
        #expect(capture.context.bundleID == "com.example.editor")
    }

    @Test func missingOrEmptyRangeIsUnreadableAndTheTextIsNotAskedFor() {
        for range in [NSRange(location: NSNotFound, length: 0), NSRange(location: NSNotFound, length: 3), NSRange(location: 4, length: 0)] {
            var asked = false
            let result = SelectionCapture.read(context: Fixture.field, range: range) { asked = true; return "abc" }
            #expect(result == .failure(.unreadable))
            #expect(!asked)
        }
    }

    @Test func textThatIsMissingBlankOrOfAnotherLengthIsUnreadable() {
        #expect(read(Fixture.range, nil) == .failure(.unreadable))
        #expect(read(Fixture.range, "") == .failure(.unreadable))
        #expect(read(Fixture.range, "你好") == .failure(.unreadable))
        #expect(read(Fixture.range, "你好，世界！") == .failure(.unreadable))
        #expect(read(NSRange(location: 0, length: 3), " \n\t") == .failure(.unreadable))
    }

    /// The limit counts UTF-16 units, is inclusive, and is never enforced by cutting.
    @Test func limitIsTwoThousandUTF16Units() throws {
        #expect(SelectionCapture.maxLength == 2000)
        let atLimit = String(repeating: "字", count: 2000)
        #expect(try read(NSRange(location: 0, length: 2000), atLimit).get().text == atLimit)
        // 1000 emoji are 2000 units; one more character is over.
        let emoji = String(repeating: "😀", count: 1000)
        #expect(try read(NSRange(location: 0, length: 2000), emoji).get().text == emoji)

        var asked = false
        let over = SelectionCapture.read(context: Fixture.field, range: NSRange(location: 0, length: 2001)) {
            asked = true
            return atLimit + "字"
        }
        #expect(over == .failure(.tooLong))
        #expect(!asked)
    }

    @Test func failuresHaveShortMessages() {
        #expect(SelectionCaptureFailure.unreadable.message == "无法读取选中的文字")
        #expect(SelectionCaptureFailure.tooLong.message == "选中的文字超过 2000 字符上限")
    }

    /// The translator trims its source; what surrounded it in the selection comes back.
    @Test func replacementKeepsTheWhiteSpaceAroundTheSource() {
        #expect(Fixture.capture("你好").replacement(for: "Hello") == "Hello")
        #expect(Fixture.capture("  第一段\n\n第二段\n").replacement(for: "One\n\nTwo") == "  One\n\nTwo\n")
        #expect(Fixture.capture("\n你好\r\n").replacement(for: "Hello") == "\nHello\r\n")
    }
}

struct SelectionTranslationSessionTests {
    private typealias Session = SelectionTranslationSession

    private func started(_ target: TranslationTarget = .english, text: String = "你好，世界") -> (Session, TranslationRequest) {
        var session = Session(id: 3, capture: Fixture.capture(text), target: target)
        let effects = session.begin()
        guard case let .start(request) = effects[1] else { fatalError("no request") }
        return (session, request)
    }

    private func ready(_ translation: String = "Hello, world") -> Session {
        var (session, request) = started()
        _ = session.handle(.completed(request.tag, .success(translation)))
        return session
    }

    private func check(_ session: Session, active: SelectionContext? = Fixture.field, secure: Bool = false,
                       current: String? = "你好，世界") -> SelectionReplaceDecision {
        session.checkReplace(active: active, isSecure: secure) { current }
    }

    @Test func beginSendsTheCapturedTextTaggedWithCaptureAndTarget() {
        var session = Session(id: 3, capture: Fixture.capture(), target: .japanese)
        let effects = session.begin()
        let request = TranslationRequest(tag: TranslationTag(session: 3, revision: 1, target: .japanese), source: "你好，世界")
        #expect(effects == [.cancelPending, .start(request), .render])
        #expect(session.snapshot == LiveTranslationSnapshot(
            targetLabel: "日语", status: .updating, text: "", isStale: false, message: "翻译中…",
            canSubmit: false, canCopy: false, canRetry: false))
        #expect(session.validTranslation == nil)
    }

    @Test func matchingResultBecomesReadyAndNothingIsReplacedByItself() {
        var (session, request) = started()
        // Only a render: a finished translation asks the host for nothing else.
        #expect(session.handle(.completed(request.tag, .success("Hello, world"))) == [.render])
        #expect(session.validTranslation == "Hello, world")
        #expect(session.snapshot == LiveTranslationSnapshot(
            targetLabel: "英语", status: .ready, text: "Hello, world", isStale: false, message: "",
            canSubmit: true, canCopy: true, canRetry: false))
    }

    @Test func resultsOfAnotherCaptureTargetOrAttemptAreDiscarded() {
        var (session, request) = started()
        let stale = [
            TranslationTag(session: 2, revision: request.tag.revision, target: .english),
            TranslationTag(session: 3, revision: request.tag.revision, target: .japanese),
            TranslationTag(session: 3, revision: request.tag.revision + 1, target: .english),
        ]
        for tag in stale {
            #expect(session.handle(.completed(tag, .success("stale"))).isEmpty)
            #expect(session.phase == .translating)
        }
        _ = session.handle(.completed(request.tag, .success("Hello")))
        // A second answer to the same request changes nothing.
        #expect(session.handle(.completed(request.tag, .success("again"))).isEmpty)
        #expect(session.validTranslation == "Hello")
    }

    /// The other shortcut translates the text captured at the start, into the new target.
    @Test func otherTargetRetranslatesTheSameCapture() {
        var session = ready()
        let before = session.capture
        let effects = session.handle(.targetPressed(.japanese))
        let request = TranslationRequest(tag: TranslationTag(session: 3, revision: 2, target: .japanese), source: "你好，世界")
        #expect(effects == [.cancelPending, .start(request), .render])
        #expect(session.capture == before)
        // The English text is not shown under the Japanese label, and cannot be used.
        #expect(session.validTranslation == nil)
        #expect(session.snapshot.text.isEmpty && session.snapshot.targetLabel == "日语" && !session.snapshot.canCopy)
        // The English answer that was still on its way is dropped.
        #expect(session.handle(.completed(TranslationTag(session: 3, revision: 1, target: .english), .success("late"))).isEmpty)
        _ = session.handle(.completed(request.tag, .success("こんにちは、世界")))
        #expect(session.validTranslation == "こんにちは、世界")
    }

    @Test func currentTargetShowsThePreviewAgainWithoutANewRequest() {
        var session = ready()
        #expect(session.handle(.targetPressed(.english)) == [.render])
        var (translating, _) = started()
        #expect(translating.handle(.targetPressed(.english)) == [.render])
        #expect(translating.attempt == 1)
    }

    @Test(arguments: TranslationFailure.allCases)
    func failureShowsItsReasonAndCanBeRetried(failure: TranslationFailure) {
        var (session, request) = started()
        #expect(session.handle(.completed(request.tag, .failure(failure))) == [.render])
        #expect(session.snapshot == LiveTranslationSnapshot(
            targetLabel: "英语", status: .failed, text: "", isStale: false, message: failure.message,
            canSubmit: false, canCopy: false, canRetry: true))
        #expect(check(session) == .blocked(.notReady))

        // Both the retry control and the current target's shortcut send it again.
        for event in [Session.Event.retry, .targetPressed(.english)] {
            var retried = session
            let effects = retried.handle(event)
            let again = TranslationRequest(tag: TranslationTag(session: 3, revision: 2, target: .english), source: "你好，世界")
            #expect(effects == [.cancelPending, .start(again), .render])
            #expect(retried.phase == .translating)
        }
    }

    @Test func retryDoesNothingUnlessTheRequestFailed() {
        var session = ready()
        #expect(session.handle(.retry).isEmpty)
        var (translating, _) = started()
        #expect(translating.handle(.retry).isEmpty)
    }

    // MARK: - Replace

    @Test func replaceWritesTheTranslationOverTheCapturedRangeOnly() {
        #expect(check(ready()) == .replace(NSRange(location: 7, length: 5), "Hello, world"))
    }

    @Test func replaceNeedsAFinishedTranslationOfTheCurrentTarget() {
        let (translating, _) = started()
        #expect(check(translating) == .blocked(.notReady))
        var retargeted = ready()
        _ = retargeted.handle(.targetPressed(.japanese))
        #expect(check(retargeted) == .blocked(.notReady))
        // Not being ready is not remembered: it replaces once the answer is in.
        _ = retargeted.handle(.replaceRefused(.notReady))
        _ = retargeted.handle(.completed(retargeted.currentTag, .success("こんにちは")))
        #expect(check(retargeted) == .replace(NSRange(location: 7, length: 5), "こんにちは"))
    }

    @Test func replaceIsRefusedWhenAnotherFieldIsActive() {
        let field = Fixture.field
        let others: [SelectionContext?] = [
            nil,
            SelectionContext(owner: ObjectIdentifier(Fixture.otherController), client: field.client, bundleID: field.bundleID),
            SelectionContext(owner: field.owner, client: ObjectIdentifier(Fixture.otherClient), bundleID: field.bundleID),
            SelectionContext(owner: field.owner, client: field.client, bundleID: "com.example.chat"),
        ]
        for active in others {
            var asked = false
            let decision = ready().checkReplace(active: active, isSecure: false) { asked = true; return "你好，世界" }
            #expect(decision == .blocked(.contextChanged))
            // Whatever has the keyboard now is not read.
            #expect(!asked)
        }
    }

    @Test func replaceIsRefusedWhenTheRangeNoLongerHoldsTheCapturedText() {
        for current in [nil, "", "你好，世界！", "你好, 世界", "Hello"] as [String?] {
            #expect(check(ready(), current: current) == .blocked(.sourceChanged))
        }
    }

    @Test func secureContextDiscardsBeforeAnythingIsRead() {
        var asked = false
        let decision = ready().checkReplace(active: Fixture.field, isSecure: true) { asked = true; return "你好，世界" }
        #expect(decision == .discard)
        #expect(!asked)
    }

    /// After a refusal the translation stays for reading and copying; replacing stays off
    /// and the preview says why.
    @Test(arguments: [SelectionReplaceBlock.sourceChanged, .contextChanged])
    func refusalKeepsCopyAndDisablesReplace(reason: SelectionReplaceBlock) {
        var session = ready()
        #expect(session.handle(.replaceRefused(reason)) == [.render])
        let snapshot = session.snapshot
        #expect(snapshot.status == .ready && snapshot.text == "Hello, world")
        #expect(!snapshot.canSubmit && snapshot.canCopy)
        #expect(snapshot.message == reason.message)
        #expect(session.validTranslation == "Hello, world")
        // The field looks fine again: still refused, and not read.
        var asked = false
        #expect(session.checkReplace(active: Fixture.field, isSecure: false) { asked = true; return "你好，世界" } == .blocked(reason))
        #expect(!asked)
        #expect(session.handle(.replaceRefused(.sourceChanged)).isEmpty)
    }

    @Test func blockMessages() {
        #expect(SelectionReplaceBlock.sourceChanged.message == "原文已变化，无法替换")
        #expect(SelectionReplaceBlock.contextChanged.message == "输入位置已改变，无法替换")
        #expect(!SelectionReplaceBlock.notReady.isPermanent)
    }

    /// Deactivation or a client change: reading and copying go on, replacing is off.
    @Test func detachingKeepsCopyButDisablesReplace() {
        var session = ready()
        #expect(session.handle(.detached) == [.render])
        #expect(session.snapshot.canCopy && !session.snapshot.canSubmit)
        #expect(session.snapshot.message == "输入位置已改变，无法替换")
        #expect(check(session) == .blocked(.contextChanged))
        #expect(session.handle(.detached).isEmpty)

        // Detached while translating: the answer still arrives and can be copied.
        var (translating, request) = started()
        _ = translating.handle(.detached)
        #expect(translating.snapshot.status == .updating && translating.snapshot.message == "输入位置已改变，无法替换")
        _ = translating.handle(.completed(request.tag, .success("Hello")))
        #expect(translating.snapshot.canCopy && !translating.snapshot.canSubmit)
        // Another target still works on the detached preview.
        #expect(translating.handle(.targetPressed(.japanese)).count == 3)
        #expect(translating.replaceBlock == .contextChanged)
    }

    @Test func failureReasonIsShownInsteadOfTheBlock() {
        var (session, request) = started()
        _ = session.handle(.detached)
        _ = session.handle(.completed(request.tag, .failure(.requestFailed)))
        #expect(session.snapshot.message == "请求失败" && session.snapshot.canRetry)
    }

    // MARK: - Selection presence

    @Test func presenceTellsTheCapturedSelectionFromANewOne() {
        var session = ready()
        let other = SelectionContext(owner: ObjectIdentifier(Fixture.otherController),
                                     client: ObjectIdentifier(Fixture.otherClient), bundleID: "com.example.chat")
        let same: () -> String? = { "你好，世界" }
        #expect(session.presence(ofSelection: nil, in: Fixture.field, currentText: same) == .none)
        #expect(session.presence(ofSelection: Fixture.range, in: Fixture.field, currentText: same) == .captured)
        #expect(session.presence(ofSelection: NSRange(location: 7, length: 6), in: Fixture.field, currentText: same) == .new)
        #expect(session.presence(ofSelection: NSRange(location: 20, length: 5), in: Fixture.field, currentText: same) == .new)
        #expect(session.presence(ofSelection: Fixture.range, in: other, currentText: same) == .new)
        #expect(session.isAttached(to: Fixture.field) && !session.isAttached(to: other))
        // Once replacing is off the same selection is captured afresh.
        _ = session.handle(.replaceRefused(.sourceChanged))
        #expect(session.presence(ofSelection: Fixture.range, in: Fixture.field, currentText: same) == .new)
        #expect(session.isAttached(to: Fixture.field))
    }

    @Test func otherTextAtTheCapturedRangeIsANewSelection() {
        let session = ready()
        #expect(session.presence(ofSelection: Fixture.range, in: Fixture.field) { "再见，朋友" } == .new)
        #expect(session.presence(ofSelection: Fixture.range, in: Fixture.field) { nil } == .new)
    }

    /// The text is read only to confirm the captured range of the capture's own field.
    @Test func presenceReadsTheTextOnlyForTheCapturedRange() {
        var session = ready()
        let other = SelectionContext(owner: ObjectIdentifier(Fixture.otherController),
                                     client: ObjectIdentifier(Fixture.otherClient), bundleID: "com.example.chat")
        var reads = 0
        let read: () -> String? = { reads += 1; return "你好，世界" }
        _ = session.presence(ofSelection: nil, in: Fixture.field, currentText: read)
        _ = session.presence(ofSelection: NSRange(location: 20, length: 5), in: Fixture.field, currentText: read)
        _ = session.presence(ofSelection: Fixture.range, in: other, currentText: read)
        #expect(reads == 0)
        _ = session.presence(ofSelection: Fixture.range, in: Fixture.field, currentText: read)
        #expect(reads == 1)
        _ = session.handle(.replaceRefused(.sourceChanged))
        _ = session.presence(ofSelection: Fixture.range, in: Fixture.field, currentText: read)
        #expect(reads == 1)
    }

    // MARK: - Panel ownership

    @Test func aLiveSessionWithADraftTakesThePanelBack() {
        #expect(SelectionPreviewOwnership.yieldsToLiveSession(liveSessionActive: true, draftIsEmpty: false))
        // Suspended underneath while its draft is empty.
        #expect(!SelectionPreviewOwnership.yieldsToLiveSession(liveSessionActive: true, draftIsEmpty: true))
        // Without a session typing leaves the selection preview alone.
        #expect(!SelectionPreviewOwnership.yieldsToLiveSession(liveSessionActive: false, draftIsEmpty: false))
        #expect(!SelectionPreviewOwnership.yieldsToLiveSession(liveSessionActive: false, draftIsEmpty: true))
    }

    // MARK: - Keys

    private func key(_ keyCode: UInt16, option: Bool = false, command: Bool = false, control: Bool = false,
                     shift: Bool = false, marked: Bool = false) -> SelectionPreviewKey {
        SelectionPreviewKey.decision(keyCode: keyCode, option: option, command: command, control: control,
                                     shift: shift, hasMarkedText: marked)
    }

    @Test func optionReturnReplacesAndEscCloses() {
        #expect(key(36, option: true) == .replace)
        #expect(key(76, option: true) == .replace)
        #expect(key(53) == .close)
    }

    /// Option+Return never falls through to the draft, the engine or the application.
    @Test func optionReturnIsSwallowedWhileSomethingIsComposedOrDrafted() {
        #expect(key(36, option: true, marked: true) == .replaceBlocked)
        #expect(key(76, option: true, marked: true) == .replaceBlocked)
        #expect(!SelectionPreviewKey.pendingInputMessage.isEmpty)
    }

    @Test func otherKeysKeepTheirMeaningWhileSomethingIsComposedOrDrafted() {
        #expect(key(53, marked: true) == .none)
        #expect(key(36, marked: true) == .none)
        #expect(key(36, option: true, shift: true, marked: true) == .none)
        #expect(key(36, option: true, command: true, marked: true) == .none)
    }

    /// Typing is never captured by the preview.
    @Test func everythingElseTakesTheNormalPath() {
        #expect(key(36) == .none)
        #expect(key(36, option: true, shift: true) == .none)
        #expect(key(36, option: true, command: true) == .none)
        #expect(key(36, option: true, control: true) == .none)
        #expect(key(53, option: true) == .none)
        #expect(key(53, command: true) == .none)
        for keyCode: UInt16 in [0, 14, 38, 49, 51, 123, 124] {
            #expect(key(keyCode) == .none)
            #expect(key(keyCode, option: true) == .none)
        }
    }
}

@MainActor
struct SelectionTranslationCoordinatorTests {
    private let translator = ManualTranslator()
    private let coordinator: SelectionTranslationCoordinator
    private let log = Log()

    @MainActor final class Log {
        var snapshots: [LiveTranslationSnapshot?] = []
    }

    init() {
        coordinator = SelectionTranslationCoordinator(translate: { [translator] in await translator.translate($0) })
        coordinator.onChange = { [log] in log.snapshots.append($0) }
    }

    private func eventually(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("condition was not reached", sourceLocation: sourceLocation)
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Captures, waits for the request and answers it.
    private func translated(_ text: String = "Hello, world") async {
        coordinator.start(capture: Fixture.capture(), target: .english)
        await eventually { translator.requests.count == 1 }
        translator.answer(0, .success(text))
        await eventually { coordinator.validTranslation == text }
    }

    @Test func startTranslatesTheCaptureAndShowsTheResult() async {
        #expect(!coordinator.isActive)
        coordinator.start(capture: Fixture.capture(), target: .english)
        #expect(coordinator.isActive)
        #expect(log.snapshots.last??.status == .updating)
        await eventually { translator.requests.count == 1 }
        #expect(translator.requests[0].source == "你好，世界")
        #expect(translator.requests[0].tag.target == .english)
        translator.answer(0, .success("Hello, world"))
        await eventually { log.snapshots.last??.status == .ready }
        #expect(log.snapshots.last??.text == "Hello, world")
        #expect(log.snapshots.last??.canSubmit == true)
    }

    @Test func otherTargetCancelsTheRequestAndSendsTheSameText() async {
        coordinator.start(capture: Fixture.capture(), target: .english)
        await eventually { translator.requests.count == 1 }
        coordinator.targetPressed(.japanese)
        await eventually { translator.requests.count == 2 }
        #expect(translator.requests[1].source == translator.requests[0].source)
        #expect(translator.requests[1].tag.target == .japanese)
        await eventually { translator.cancellations == 1 }
        // The cancelled English answer arrives anyway and is dropped.
        translator.answer(0, .success("Hello"))
        await settle()
        #expect(coordinator.validTranslation == nil)
        translator.answer(1, .success("こんにちは"))
        await eventually { coordinator.validTranslation == "こんにちは" }
        #expect(log.snapshots.last??.targetLabel == "日语")
    }

    @Test func newCaptureDropsTheResultOfTheOldOne() async {
        coordinator.start(capture: Fixture.capture("旧的原文"), target: .english)
        await eventually { translator.requests.count == 1 }
        coordinator.start(capture: Fixture.capture("新的原文"), target: .english)
        await eventually { translator.requests.count == 2 }
        #expect(translator.requests[1].tag.session != translator.requests[0].tag.session)
        #expect(log.snapshots.contains { $0 == nil })
        translator.answer(0, .success("old"))
        await settle()
        #expect(coordinator.validTranslation == nil)
        translator.answer(1, .success("new"))
        await eventually { coordinator.validTranslation == "new" }
        #expect(coordinator.session?.capture.text == "新的原文")
    }

    @Test func cancelClosesThePreviewAndDropsLateResults() async {
        coordinator.start(capture: Fixture.capture(), target: .english)
        await eventually { translator.requests.count == 1 }
        coordinator.end()
        #expect(!coordinator.isActive)
        #expect(log.snapshots.last! == nil)
        await eventually { translator.cancellations == 1 }
        let count = log.snapshots.count
        translator.answer(0, .success("Hello"))
        await settle()
        #expect(log.snapshots.count == count)
        #expect(coordinator.validTranslation == nil)
        // Nothing is left to act on.
        coordinator.targetPressed(.japanese)
        coordinator.retry()
        #expect(coordinator.replace(active: Fixture.field, isSecure: false) { "你好，世界" } == nil)
        await settle()
        #expect(translator.requests.count == 1)
    }

    @Test func replaceReturnsTheWriteAndLeavesClosingToTheHost() async {
        await translated()
        let decision = coordinator.replace(active: Fixture.field, isSecure: false) { "你好，世界" }
        #expect(decision == .replace(NSRange(location: 7, length: 5), "Hello, world"))
        #expect(coordinator.isActive)
        coordinator.end()
        #expect(log.snapshots.last! == nil)
    }

    @Test func refusedReplaceStaysOnThePreview() async {
        await translated()
        #expect(coordinator.replace(active: Fixture.field, isSecure: false) { "改过的文字" } == .blocked(.sourceChanged))
        #expect(coordinator.isActive)
        #expect(log.snapshots.last??.canSubmit == false)
        #expect(log.snapshots.last??.canCopy == true)
        #expect(log.snapshots.last??.message == "原文已变化，无法替换")
        #expect(coordinator.validTranslation == "Hello, world")
    }

    @Test func replaceBeforeTheResultIsRefusedWithoutDisablingIt() async {
        coordinator.start(capture: Fixture.capture(), target: .english)
        await eventually { translator.requests.count == 1 }
        #expect(coordinator.replace(active: Fixture.field, isSecure: false) { "你好，世界" } == .blocked(.notReady))
        translator.answer(0, .success("Hello"))
        await eventually { coordinator.validTranslation == "Hello" }
        #expect(log.snapshots.last??.canSubmit == true)
    }

    @Test func deactivationKeepsThePreviewForCopying() async {
        await translated()
        coordinator.detach()
        #expect(coordinator.isActive)
        #expect(coordinator.validTranslation == "Hello, world")
        #expect(log.snapshots.last??.canCopy == true)
        #expect(log.snapshots.last??.canSubmit == false)
        #expect(coordinator.replace(active: Fixture.field, isSecure: false) { "你好，世界" } == .blocked(.contextChanged))
    }

    /// A secure context: capture and preview go, pending results are invalidated, and
    /// nothing comes back afterwards.
    @Test func secureContextDiscardsEverything() async {
        coordinator.start(capture: Fixture.capture(), target: .english)
        await eventually { translator.requests.count == 1 }
        #expect(coordinator.replace(active: Fixture.field, isSecure: true) { "你好，世界" } == .discard)
        #expect(!coordinator.isActive)
        #expect(log.snapshots.last! == nil)
        let count = log.snapshots.count
        translator.answer(0, .success("Hello"))
        await settle()
        #expect(log.snapshots.count == count)
        #expect(coordinator.session == nil)
    }
}
