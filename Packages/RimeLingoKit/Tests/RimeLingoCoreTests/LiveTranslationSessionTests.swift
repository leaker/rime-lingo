import Testing
@testable import RimeLingoCore

struct LiveTranslationSessionTests {
    typealias Session = LiveTranslationSession

    func tag(_ revision: Int, _ target: TranslationTarget = .english, session: UInt64 = 7) -> TranslationTag {
        TranslationTag(session: session, revision: revision, target: target)
    }

    /// A session that has translated "你好" (revision 1) into English.
    func readySession() -> Session {
        var session = Session(id: 7, target: .english)
        _ = session.handle(.sourceChanged("你好"))
        _ = session.handle(.debounceFired(tag(1)))
        _ = session.handle(.completed(tag(1), .success("Hello")))
        return session
    }

    func translatingSession() -> Session {
        var session = Session(id: 7, target: .english)
        _ = session.handle(.sourceChanged("你好"))
        _ = session.handle(.debounceFired(tag(1)))
        return session
    }

    @Test func startsWaitingWithNothingToSubmit() {
        let session = Session(id: 7, target: .japanese)
        #expect(session.phase == .waiting)
        #expect(session.revision == 0)
        #expect(session.source.isEmpty)
        #expect(session.translation == nil)
        #expect(session.validTranslation == nil)
        #expect(session.currentTag == tag(0, .japanese))
        #expect(session.snapshot == LiveTranslationSnapshot(
            targetLabel: "日语", status: .waiting, text: "", isStale: false, message: "等待输入",
            canSubmit: false, canCopy: false, canRetry: false))
    }

    /// Whitespace alone is no source: nothing is scheduled and no failure is shown.
    @Test(arguments: [" ", "   ", "\u{3000}", " \t "])
    func blankSourceWaitsInsteadOfTranslating(blank: String) {
        var session = Session(id: 7, target: .english)
        #expect(session.handle(.sourceChanged(blank)) == [.cancelPending, .render])
        #expect(session.phase == .waiting)
        #expect(session.revision == 1)
        #expect(session.snapshot.status == .waiting)
        #expect(!session.snapshot.canRetry)
        // Neither a target switch nor an explicit refresh sends it.
        #expect(session.handle(.targetPressed(.english)) == [.render])
        #expect(session.handle(.retry) == [])
        #expect(session.handle(.targetPressed(.japanese)) == [.cancelPending, .render])
        #expect(session.phase == .waiting)
        #expect(session.handle(.debounceFired(session.currentTag)) == [])
    }

    @Test func draftReducedToBlankDropsTheTranslation() {
        var session = readySession()
        #expect(session.handle(.sourceChanged(" ")) == [.cancelPending, .render])
        #expect(session.translation == nil)
        #expect(session.validTranslation == nil)
        #expect(session.phase == .waiting)
        // Text after the blank is translated as usual.
        #expect(session.handle(.sourceChanged(" 好")) == [.cancelPending, .scheduleDebounce(tag(3)), .render])
    }

    @Test func sourceChangeBumpsTheRevisionAndSchedulesADebounce() {
        var session = Session(id: 7, target: .english)
        let effects = session.handle(.sourceChanged("你好"))
        #expect(effects == [.cancelPending, .scheduleDebounce(tag(1)), .render])
        #expect(session.revision == 1)
        #expect(session.phase == .debouncing)
        #expect(session.snapshot.status == .updating)
        #expect(session.snapshot.message == "翻译中…")
    }

    @Test func unchangedSourceDoesNothing() {
        var session = Session(id: 7, target: .english)
        _ = session.handle(.sourceChanged("你好"))
        let before = session
        #expect(session.handle(.sourceChanged("你好")) == [])
        #expect(session == before)
        var empty = Session(id: 7, target: .english)
        #expect(empty.handle(.sourceChanged("")) == [])
        #expect(empty.revision == 0)
    }

    @Test func rapidChangesCoalesceIntoTheLastDebounce() {
        var session = Session(id: 7, target: .english)
        _ = session.handle(.sourceChanged("你"))
        _ = session.handle(.sourceChanged("你好"))
        #expect(session.handle(.sourceChanged("你好吗")) == [.cancelPending, .scheduleDebounce(tag(3)), .render])
        #expect(session.handle(.debounceFired(tag(1))) == [])
        #expect(session.handle(.debounceFired(tag(2))) == [])
        #expect(session.phase == .debouncing)
        #expect(session.handle(.debounceFired(tag(3))) == [.start(TranslationRequest(tag: tag(3), source: "你好吗")), .render])
        #expect(session.phase == .translating)
    }

    @Test func debounceFiresOnlyOnce() {
        var session = translatingSession()
        #expect(session.handle(.debounceFired(tag(1))) == [])
        #expect(session.phase == .translating)
    }

    @Test func debounceForAnotherSessionOrTargetIsIgnored() {
        var session = Session(id: 7, target: .english)
        _ = session.handle(.sourceChanged("你好"))
        #expect(session.handle(.debounceFired(tag(1, session: 6))) == [])
        #expect(session.handle(.debounceFired(tag(1, .japanese))) == [])
        #expect(session.phase == .debouncing)
    }

    @Test func successMakesTheTranslationValid() {
        var session = translatingSession()
        #expect(session.handle(.completed(tag(1), .success("Hello"))) == [.render])
        #expect(session.phase == .ready)
        #expect(session.validTranslation == "Hello")
        #expect(session.snapshot == LiveTranslationSnapshot(
            targetLabel: "英语", status: .ready, text: "Hello", isStale: false, message: "",
            canSubmit: true, canCopy: true, canRetry: false))
    }

    @Test(arguments: TranslationFailure.allCases)
    func failureShowsItsReasonAndOffersRetry(failure: TranslationFailure) {
        var session = translatingSession()
        #expect(session.handle(.completed(tag(1), .failure(failure))) == [.render])
        #expect(session.phase == .failed(failure))
        #expect(session.validTranslation == nil)
        let snapshot = session.snapshot
        #expect(snapshot.status == .failed)
        #expect(snapshot.message == failure.message)
        #expect(snapshot.text.isEmpty)
        #expect(!snapshot.isStale)
        #expect(!snapshot.canSubmit && !snapshot.canCopy && snapshot.canRetry)
    }

    @Test func failureHidesTheOlderTranslation() {
        var session = readySession()
        _ = session.handle(.sourceChanged("你好吗"))
        _ = session.handle(.debounceFired(tag(2)))
        _ = session.handle(.completed(tag(2), .failure(.requestFailed)))
        #expect(session.snapshot.text.isEmpty)
        #expect(session.validTranslation == nil)
    }

    @Test func editingKeepsThePreviousTranslationButMarksItStale() {
        var session = readySession()
        #expect(session.handle(.sourceChanged("你好吗")) == [.cancelPending, .scheduleDebounce(tag(2)), .render])
        #expect(session.validTranslation == nil)
        var snapshot = session.snapshot
        #expect(snapshot.status == .updating)
        #expect(snapshot.text == "Hello")
        #expect(snapshot.isStale)
        #expect(!snapshot.canSubmit && !snapshot.canCopy)
        _ = session.handle(.debounceFired(tag(2)))
        snapshot = session.snapshot
        #expect(snapshot.status == .updating && snapshot.text == "Hello" && snapshot.isStale)
    }

    @Test func aChangeDuringARequestCancelsItAndDropsItsResult() {
        var session = translatingSession()
        #expect(session.handle(.sourceChanged("你好吗")) == [.cancelPending, .scheduleDebounce(tag(2)), .render])
        #expect(session.handle(.completed(tag(1), .success("Hello"))) == [])
        #expect(session.translation == nil)
        #expect(session.phase == .debouncing)
    }

    @Test func resultsArrivingOutOfOrderKeepOnlyTheCurrentOne() {
        var session = translatingSession()
        _ = session.handle(.sourceChanged("你好吗"))
        _ = session.handle(.debounceFired(tag(2)))
        #expect(session.handle(.completed(tag(2), .success("How are you?"))) == [.render])
        #expect(session.handle(.completed(tag(1), .success("Hello"))) == [])
        #expect(session.handle(.completed(tag(1), .failure(.requestFailed))) == [])
        #expect(session.validTranslation == "How are you?")
        #expect(session.phase == .ready)
    }

    @Test func aResultIsAppliedOnlyOnce() {
        var session = readySession()
        #expect(session.handle(.completed(tag(1), .success("Hi"))) == [])
        #expect(session.handle(.completed(tag(1), .failure(.requestFailed))) == [])
        #expect(session.validTranslation == "Hello")
    }

    @Test func aResultBeforeTheDebounceFiresIsIgnored() {
        var session = Session(id: 7, target: .english)
        _ = session.handle(.sourceChanged("你好"))
        #expect(session.handle(.completed(tag(1), .success("Hello"))) == [])
        #expect(session.phase == .debouncing)
    }

    @Test func resultsForAnotherSessionOrTargetAreDropped() {
        var session = translatingSession()
        #expect(session.handle(.completed(tag(1, session: 6), .success("Hello"))) == [])
        #expect(session.handle(.completed(tag(1, .japanese), .success("こんにちは"))) == [])
        #expect(session.phase == .translating)
        #expect(session.translation == nil)
    }

    @Test func returningToAnEarlierTextDoesNotReviveItsRequest() {
        var session = translatingSession()
        _ = session.handle(.sourceChanged("你好吗"))
        _ = session.handle(.sourceChanged("你好"))
        #expect(session.revision == 3)
        #expect(session.handle(.completed(tag(1), .success("Hello"))) == [])
        #expect(session.validTranslation == nil)
    }

    @Test func switchingTheTargetTranslatesAtOnce() {
        var session = readySession()
        let effects = session.handle(.targetPressed(.japanese))
        #expect(effects == [.cancelPending, .start(TranslationRequest(tag: tag(1, .japanese), source: "你好")), .render])
        #expect(session.target == .japanese)
        #expect(session.revision == 1)
        #expect(session.phase == .translating)
        #expect(session.validTranslation == nil)
        let snapshot = session.snapshot
        #expect(snapshot.targetLabel == "日语")
        #expect(snapshot.status == .updating && snapshot.text == "Hello" && snapshot.isStale && !snapshot.canSubmit)
        #expect(session.handle(.completed(tag(1, .english), .success("Hello again"))) == [])
        #expect(session.handle(.completed(tag(1, .japanese), .success("こんにちは"))) == [.render])
        #expect(session.validTranslation == "こんにちは")
        #expect(!session.snapshot.isStale)
    }

    @Test func switchingTheTargetReplacesAPendingDebounceOrRequest() {
        var debouncing = Session(id: 7, target: .english)
        _ = debouncing.handle(.sourceChanged("你好"))
        #expect(debouncing.handle(.targetPressed(.japanese))
            == [.cancelPending, .start(TranslationRequest(tag: tag(1, .japanese), source: "你好")), .render])
        #expect(debouncing.handle(.debounceFired(tag(1, .english))) == [])
        #expect(debouncing.handle(.debounceFired(tag(1, .japanese))) == [])

        var translating = translatingSession()
        #expect(translating.handle(.targetPressed(.japanese))
            == [.cancelPending, .start(TranslationRequest(tag: tag(1, .japanese), source: "你好")), .render])
        #expect(translating.handle(.completed(tag(1, .english), .success("Hello"))) == [])
        #expect(translating.translation == nil)
    }

    @Test func switchingTheTargetWithoutSourceKeepsWaiting() {
        var session = Session(id: 7, target: .english)
        #expect(session.handle(.targetPressed(.japanese)) == [.cancelPending, .render])
        #expect(session.target == .japanese)
        #expect(session.phase == .waiting)
        #expect(session.snapshot.targetLabel == "日语")
    }

    @Test func pressingTheCurrentTargetOnlyShowsThePreviewAgain() {
        var waiting = Session(id: 7, target: .english)
        #expect(waiting.handle(.targetPressed(.english)) == [.render])
        #expect(waiting.phase == .waiting)

        var debouncing = Session(id: 7, target: .english)
        _ = debouncing.handle(.sourceChanged("你好"))
        #expect(debouncing.handle(.targetPressed(.english)) == [.render])
        #expect(debouncing.phase == .debouncing)

        var translating = translatingSession()
        #expect(translating.handle(.targetPressed(.english)) == [.render])
        #expect(translating.phase == .translating)

        var ready = readySession()
        let before = ready
        #expect(ready.handle(.targetPressed(.english)) == [.render])
        #expect(ready == before)
    }

    @Test func pressingTheCurrentTargetAfterAFailureTranslatesAgain() {
        var session = translatingSession()
        _ = session.handle(.completed(tag(1), .failure(.requestFailed)))
        #expect(session.handle(.targetPressed(.english))
            == [.cancelPending, .start(TranslationRequest(tag: tag(1), source: "你好")), .render])
        #expect(session.phase == .translating)
        #expect(session.handle(.completed(tag(1), .success("Hello"))) == [.render])
        #expect(session.validTranslation == "Hello")
    }

    @Test func clearingTheSourceClearsThePreview() {
        var session = readySession()
        #expect(session.handle(.sourceChanged("")) == [.cancelPending, .render])
        #expect(session.revision == 2)
        #expect(session.phase == .waiting)
        #expect(session.translation == nil)
        #expect(session.validTranslation == nil)
        #expect(session.snapshot == LiveTranslationSnapshot(
            targetLabel: "英语", status: .waiting, text: "", isStale: false, message: "等待输入",
            canSubmit: false, canCopy: false, canRetry: false))
    }

    @Test func clearingDuringARequestDropsItsResult() {
        var session = translatingSession()
        #expect(session.handle(.sourceChanged("")) == [.cancelPending, .render])
        #expect(session.handle(.completed(tag(1), .success("Hello"))) == [])
        #expect(session.handle(.debounceFired(tag(2))) == [])
        #expect(session.phase == .waiting)
    }

    @Test func theNextSentenceStartsFreshAfterClearing() {
        var session = readySession()
        _ = session.handle(.sourceChanged(""))
        #expect(session.handle(.sourceChanged("谢谢")) == [.cancelPending, .scheduleDebounce(tag(3)), .render])
        #expect(session.snapshot.text.isEmpty)
        #expect(!session.snapshot.isStale)
    }

    @Test func exactlyTwoHundredCharactersStillTranslateAutomatically() {
        var session = Session(id: 7, target: .english)
        let effects = session.handle(.sourceChanged(String(repeating: "字", count: 200)))
        #expect(effects == [.cancelPending, .scheduleDebounce(tag(1)), .render])
    }

    @Test func aboveTwoHundredCharactersAutomaticTranslationStops() {
        var session = readySession()
        let long = String(repeating: "字", count: 201)
        #expect(session.handle(.sourceChanged(long)) == [.cancelPending, .render])
        #expect(session.phase == .overLimit)
        #expect(session.validTranslation == nil)
        #expect(session.snapshot == LiveTranslationSnapshot(
            targetLabel: "英语", status: .overLimit, text: "Hello", isStale: true, message: "超过 200 字，按当前语言快捷键刷新",
            canSubmit: false, canCopy: false, canRetry: true))
        #expect(session.handle(.debounceFired(tag(2))) == [])
        #expect(session.handle(.sourceChanged(long + "字")) == [.cancelPending, .render])
        #expect(session.phase == .overLimit)
    }

    @Test func theLimitCountsCharactersNotCodeUnits() {
        var session = Session(id: 7, target: .english)
        _ = session.handle(.sourceChanged(String(repeating: "😀", count: 200)))
        #expect(session.phase == .debouncing)
    }

    @Test func pressingTheCurrentTargetRefreshesAboveTheLimit() {
        var session = Session(id: 7, target: .english)
        let long = String(repeating: "字", count: 250)
        _ = session.handle(.sourceChanged(long))
        #expect(session.handle(.targetPressed(.english)) == [.cancelPending, .start(TranslationRequest(tag: tag(1), source: long)), .render])
        #expect(session.handle(.completed(tag(1), .success("Long text"))) == [.render])
        #expect(session.validTranslation == "Long text")
        #expect(session.snapshot.status == .ready)
        #expect(session.handle(.targetPressed(.english)) == [.render])
    }

    @Test func switchingTheTargetAboveTheLimitTranslates() {
        var session = Session(id: 7, target: .english)
        let long = String(repeating: "字", count: 250)
        _ = session.handle(.sourceChanged(long))
        #expect(session.handle(.targetPressed(.japanese))
            == [.cancelPending, .start(TranslationRequest(tag: tag(1, .japanese), source: long)), .render])
    }

    @Test func shrinkingBelowTheLimitResumesAutomaticTranslation() {
        var session = Session(id: 7, target: .english)
        _ = session.handle(.sourceChanged(String(repeating: "字", count: 201)))
        #expect(session.handle(.sourceChanged(String(repeating: "字", count: 200))) == [.cancelPending, .scheduleDebounce(tag(2)), .render])
    }

    @Test func retryRestartsAfterAFailureOrAboveTheLimit() {
        var failed = translatingSession()
        _ = failed.handle(.completed(tag(1), .failure(.cancelled)))
        #expect(failed.handle(.retry) == [.cancelPending, .start(TranslationRequest(tag: tag(1), source: "你好")), .render])
        #expect(failed.phase == .translating)

        var over = Session(id: 7, target: .english)
        let long = String(repeating: "字", count: 201)
        _ = over.handle(.sourceChanged(long))
        #expect(over.handle(.retry) == [.cancelPending, .start(TranslationRequest(tag: tag(1), source: long)), .render])
    }

    @Test func retryDoesNothingInOtherPhases() {
        var waiting = Session(id: 7, target: .english)
        #expect(waiting.handle(.retry) == [])
        var debouncing = Session(id: 7, target: .english)
        _ = debouncing.handle(.sourceChanged("你好"))
        #expect(debouncing.handle(.retry) == [])
        var translating = translatingSession()
        #expect(translating.handle(.retry) == [])
        var ready = readySession()
        #expect(ready.handle(.retry) == [])
        #expect(ready.validTranslation == "Hello")
    }

    @Test func onlyAReadyResultForTheCurrentTagCanBeSubmitted() {
        var session = Session(id: 7, target: .english)
        #expect(session.validTranslation == nil)                       // waiting
        _ = session.handle(.sourceChanged("你好"))
        #expect(session.validTranslation == nil)                       // debouncing
        _ = session.handle(.debounceFired(tag(1)))
        #expect(session.validTranslation == nil)                       // translating
        _ = session.handle(.completed(tag(1), .success("Hello")))
        #expect(session.validTranslation == "Hello")                   // ready
        _ = session.handle(.sourceChanged("你好吗"))
        #expect(session.validTranslation == nil)                       // stale
        _ = session.handle(.debounceFired(tag(2)))
        _ = session.handle(.completed(tag(2), .failure(.invalidResponse)))
        #expect(session.validTranslation == nil)                       // failed
        _ = session.handle(.sourceChanged(String(repeating: "字", count: 300)))
        #expect(session.validTranslation == nil)                       // over the limit
        #expect(!session.snapshot.canSubmit)
    }

    @Test func failureMessagesAreShortAndDistinct() {
        let messages = TranslationFailure.allCases.map(\.message)
        #expect(Set(messages).count == TranslationFailure.allCases.count)
        #expect(messages.allSatisfy { !$0.isEmpty && $0.count <= 12 })
    }

    @Test func targetsNameThemselvesForPromptsAndLabels() {
        #expect(TranslationTarget.english.promptName == "English")
        #expect(TranslationTarget.japanese.promptName == "Japanese")
        #expect(TranslationTarget.english.displayName == "英语")
        #expect(TranslationTarget.japanese.displayName == "日语")
    }

    @Test func debounceIsFourHundredMilliseconds() {
        #expect(Session.debounce == .milliseconds(400))
        #expect(Session.autoTranslateLimit == 200)
    }
}
