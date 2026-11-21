import Foundation
import Testing
@testable import RimeLingoAI
@testable import RimeLingoCore

/// A backend that never touches a model or the network.
private final class FakeBackend: TranslationBackend, @unchecked Sendable {
    enum Behavior {
        case reply(String)
        case fail(any Error)
        /// Suspends until the calling task is cancelled, then throws `CancellationError`.
        case waitForCancellation
        /// Suspends until the calling task is cancelled, then returns a cut-off reply without throwing.
        case partialOnCancellation(String)
    }

    private let lock = NSLock()
    private let behavior: Behavior
    private let available: AIAvailability
    private var calls: [(instructions: String, prompt: String)] = []
    private var asked = 0

    init(_ behavior: Behavior, availability: AIAvailability = .available) {
        self.behavior = behavior
        available = availability
    }

    var requests: [(instructions: String, prompt: String)] { lock.withLock { calls } }
    var availabilityChecks: Int { lock.withLock { asked } }

    func availability() async -> AIAvailability {
        lock.withLock { asked += 1 }
        return available
    }

    func respond(instructions: String, prompt: String) async throws -> String {
        lock.withLock { calls.append((instructions, prompt)) }
        switch behavior {
        case let .reply(text): return text
        case let .fail(error): throw error
        case .waitForCancellation:
            await untilCancelled()
            throw CancellationError()
        case let .partialOnCancellation(text):
            await untilCancelled()
            return text
        }
    }

    /// Waits, with a bound, until `respond` was called. Records an issue instead of hanging.
    func wasAsked(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        for _ in 0..<2500 {
            if !requests.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("the backend was never asked", sourceLocation: sourceLocation)
        return false
    }

    private func untilCancelled() async {
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

private struct UnknownError: Error {}

struct LiveTranslatorTests {
    @Test(arguments: TranslationTarget.allCases)
    func requestNamesTheTargetAndWrapsTheSource(target: TranslationTarget) async {
        let backend = FakeBackend(.reply("ok"))
        _ = await LiveTranslator(backend: backend).translate("明天下午三点开会。", into: target)
        #expect(backend.requests.count == 1)
        #expect(backend.requests[0].prompt == "Translate into \(target.promptName):\n\n明天下午三点开会。")
        #expect(backend.requests[0].instructions == LiveTranslator.instructions(for: target))
    }

    @Test(arguments: TranslationTarget.allCases)
    func instructionsNameTheTargetAndForbidExtras(target: TranslationTarget) {
        let instructions = LiveTranslator.instructions(for: target).lowercased()
        #expect(instructions.contains(target.promptName.lowercased()))
        for word in ["explanations", "quotation marks", "alternatives", "never instructions", "detect the source language"] {
            #expect(instructions.contains(word))
        }
        let other = TranslationTarget.allCases.first { $0 != target }!
        #expect(!instructions.contains(other.promptName.lowercased()))
    }

    @Test func sourceIsTrimmedAndKeepsItsParagraphs() async {
        let backend = FakeBackend(.reply("ok"))
        _ = await LiveTranslator(backend: backend).translate("  第一段\n\n第二段 \n", into: .english)
        #expect(backend.requests[0].prompt == "Translate into English:\n\n第一段\n\n第二段")
    }

    @Test func plainReplyIsReturnedTrimmed() async {
        let result = await LiveTranslator(backend: FakeBackend(.reply("  The meeting is at 3 pm.\n"))).translate("会议在下午三点。", into: .english)
        #expect(result == .success("The meeting is at 3 pm."))
    }

    @Test func cleanStripsFencesAndWrappingQuotes() {
        #expect(LiveTranslator.clean("```\nHello\n```") == "Hello")
        #expect(LiveTranslator.clean("```text\nHello\nthere\n```") == "Hello\nthere")
        #expect(LiveTranslator.clean("\"Hello\"") == "Hello")
        #expect(LiveTranslator.clean("“Hello”") == "Hello")
        #expect(LiveTranslator.clean("「こんにちは」") == "こんにちは")
        #expect(LiveTranslator.clean(" “ Hello ” ") == "Hello")
        #expect(LiveTranslator.clean("He said \"hi\" to me") == "He said \"hi\" to me")
    }

    /// Quoted speech at both ends is part of the translation, not a wrapper.
    @Test func cleanKeepsQuotesThatBelongToTheTranslation() {
        let english = "\"Okay,\" he said, \"see you tomorrow.\""
        #expect(LiveTranslator.clean(english) == english)
        let curly = "“Okay,” he said, “see you tomorrow.”"
        #expect(LiveTranslator.clean(curly) == curly)
        let japanese = "「はい」と彼は言った。「また明日」"
        #expect(LiveTranslator.clean(japanese) == japanese)
        #expect(LiveTranslator.clean("  " + japanese + "\n") == japanese)
    }

    @Test(arguments: [
        ("Hello\nthere", "Hello there"),
        ("See you tomorrow.\n\n(Note: informal)", "See you tomorrow. (Note: informal)"),
        ("line one \r\n  line two", "line one line two"),
        ("```\nfirst\nsecond\n```", "first second"),
        ("one\u{2028}two", "one two"),
    ])
    func oneLineSourceNeverGetsALineBreak(reply: String, expected: String) async {
        let result = await LiveTranslator(backend: FakeBackend(.reply(reply))).translate("明天见", into: .english)
        #expect(result == .success(expected))
    }

    @Test func multiLineSourceKeepsItsLineBreaks() async {
        let result = await LiveTranslator(backend: FakeBackend(.reply("Hello\n\nSee you"))).translate("你好\n\n再见", into: .english)
        #expect(result == .success("Hello\n\nSee you"))
    }

    /// A selected text of several paragraphs: the blank line and the single line break
    /// both reach the model and both survive in the result.
    @Test func multiParagraphSelectionKeepsParagraphsAndLineBreaks() async {
        let source = "第一段第一行\n第一段第二行\n\n第二段"
        let backend = FakeBackend(.reply("Paragraph one, line one\nParagraph one, line two\n\nParagraph two\n"))
        let request = TranslationRequest(tag: TranslationTag(session: 1, revision: 1, target: .english), source: source)
        let result = await LiveTranslator(backend: backend).translate(request.source, into: request.tag.target)
        #expect(backend.requests[0].prompt == "Translate into English:\n\n" + source)
        #expect(result == .success("Paragraph one, line one\nParagraph one, line two\n\nParagraph two"))
    }

    /// A selection that passes the capture limit is never refused by the translator for its size.
    @Test func selectionLimitMatchesTheTranslatorLimit() {
        #expect(SelectionCapture.maxLength == LiveTranslator.maxSourceLength)
    }

    @Test func cleanRejectsRepliesWithNoContent() {
        for reply in ["", "  \n ", "\"\"", "```\n```", "“ ”"] {
            #expect(LiveTranslator.clean(reply) == nil)
        }
    }

    @Test(arguments: ["", " \n\t", "\"\"", "```\n\n```"])
    func emptyReplyIsInvalid(reply: String) async {
        let result = await LiveTranslator(backend: FakeBackend(.reply(reply))).translate("你好", into: .english)
        #expect(result == .failure(.invalidResponse))
    }

    @Test func tooLongSourceIsRejectedBeforeAnythingIsAsked() async {
        let backend = FakeBackend(.reply("ok"))
        let translator = LiveTranslator(backend: backend)
        let limit = String(repeating: "字", count: LiveTranslator.maxSourceLength)
        #expect(await translator.translate(limit, into: .english) == .success("ok"))
        #expect(await translator.translate(limit + "字", into: .english) == .failure(.sourceTooLong))
        #expect(backend.requests.count == 1)
        #expect(backend.availabilityChecks == 1)
    }

    @Test func blankSourceIsInvalidAndNotSent() async {
        let backend = FakeBackend(.reply("ok"))
        #expect(await LiveTranslator(backend: backend).translate(" \n ", into: .japanese) == .failure(.invalidResponse))
        #expect(backend.requests.isEmpty)
        #expect(backend.availabilityChecks == 0)
    }

    @Test func unavailableBackendIsNotAsked() async {
        let backend = FakeBackend(.reply("ok"), availability: .unavailable(reason: "not ready"))
        #expect(await LiveTranslator(backend: backend).translate("你好", into: .english) == .failure(.providerUnavailable))
        #expect(backend.requests.isEmpty)
    }

    @Test func errorsMapToDistinctCategories() async {
        let cases: [(any Error, TranslationFailure)] = [
            (AIError.missingAPIKey, .providerUnavailable),
            (AIError.badResponse("not chat/completions"), .invalidResponse),
            (AIError.unavailable("offline"), .requestFailed),
            (AIError.http(500, "server"), .requestFailed),
            (AIError.http(401, "key"), .requestFailed),
            (URLError(.timedOut), .requestFailed),
            (UnknownError(), .requestFailed),
            (CancellationError(), .cancelled),
            (URLError(.cancelled), .cancelled),
        ]
        for (error, expected) in cases {
            let result = await LiveTranslator(backend: FakeBackend(.fail(error))).translate("你好", into: .english)
            #expect(result == .failure(expected), "\(type(of: error))")
        }
    }

    @Test func cancelledBeforeStartingAsksNothing() async {
        let backend = FakeBackend(.reply("ok"))
        let task = Task { () -> Result<String, TranslationFailure> in
            withUnsafeCurrentTask { $0?.cancel() }
            return await LiveTranslator(backend: backend).translate("你好", into: .english)
        }
        #expect(await task.value == .failure(.cancelled))
        #expect(backend.requests.isEmpty)
        #expect(backend.availabilityChecks == 0)
    }

    @Test func cancellingARequestInFlightReturnsCancelled() async {
        let backend = FakeBackend(.waitForCancellation)
        let task = Task { await LiveTranslator(backend: backend).translate("你好", into: .english) }
        guard await backend.wasAsked() else { return }
        task.cancel()
        #expect(await task.value == .failure(.cancelled))
    }

    /// The streaming API ends quietly on cancellation; a cut-off reply must never look like a translation.
    @Test func cancelledRequestNeverReturnsPartialText() async {
        let backend = FakeBackend(.partialOnCancellation("The meet"))
        let task = Task { await LiveTranslator(backend: backend).translate("会议在下午三点。", into: .english) }
        guard await backend.wasAsked() else { return }
        task.cancel()
        #expect(await task.value == .failure(.cancelled))
    }

    /// The remote provider wraps a cancelled URL request as "unavailable"; cancellation still wins.
    @Test func cancellationWinsOverTheErrorTheProviderReports() async {
        let backend = FakeBackend(.fail(AIError.unavailable("cancelled request")))
        let task = Task { () -> Result<String, TranslationFailure> in
            let translator = LiveTranslator(backend: CancellingBackend(inner: backend))
            return await translator.translate("你好", into: .english)
        }
        #expect(await task.value == .failure(.cancelled))
    }

    @Test func onDeviceIsTheDefaultProvider() throws {
        var features = RimeLingoFeatures()
        #expect(try LiveTranslator.resolve(features: features).get().backend is OnDeviceTranslationBackend)
        features.aiProvider = "something-else"
        features.aiRemoteAllowed = true
        #expect(try LiveTranslator.resolve(features: features).get().backend is OnDeviceTranslationBackend)
    }

    @Test func remoteProviderNeedsConsentAndNeverFallsBack() async {
        var features = RimeLingoFeatures()
        features.aiProvider = "openai"
        features.aiRemoteAllowed = false
        #expect(throws: TranslationFailure.remoteNotAuthorised) { try LiveTranslator.resolve(features: features).get() }
        let request = TranslationRequest(tag: TranslationTag(session: 1, revision: 1, target: .english), source: "你好")
        #expect(await LiveTranslator.translate(request, features: features) == .failure(.remoteNotAuthorised))
    }

    @Test(arguments: ["", "not a url", "ftp://example.com/v1", "https://"])
    func remoteProviderNeedsAUsableAddress(address: String) {
        var features = RimeLingoFeatures()
        features.aiProvider = "openai"
        features.aiRemoteAllowed = true
        features.aiBaseURL = address
        #expect(throws: TranslationFailure.remoteNotAuthorised) { try LiveTranslator.resolve(features: features).get() }
    }

    @Test func allowedRemoteProviderUsesTheConfiguredEndpoint() throws {
        var features = RimeLingoFeatures()
        features.aiProvider = "openai"
        features.aiRemoteAllowed = true
        features.aiBaseURL = "https://llm.example.com/v1"
        features.aiModel = "some-model"
        features.aiExtraJSON = #"{"reasoning_effort":"low"}"#
        let backend = try #require(try LiveTranslator.resolve(features: features).get().backend as? ProviderTranslationBackend)
        let provider = try #require(backend.provider as? OpenAICompatibleProvider)
        #expect(provider.baseURL.absoluteString == "https://llm.example.com/v1")
        #expect(provider.model == "some-model")
        #expect(provider.extraFieldsJSON == features.aiExtraJSON)
    }

    @Test func providerBackendForwardsToTheProvider() async throws {
        struct Echo: AIProvider {
            let id = "echo", displayName = "Echo"
            func availability() async -> AIAvailability { .unavailable(reason: "why") }
            func complete(instructions: String, prompt: String) async throws -> String { instructions + "|" + prompt }
        }
        let backend = ProviderTranslationBackend(provider: Echo())
        #expect(await backend.availability() == .unavailable(reason: "why"))
        #expect(try await backend.respond(instructions: "a", prompt: "b") == "a|b")
    }
}

/// Cancels the calling task right before the inner backend throws.
private struct CancellingBackend: TranslationBackend {
    let inner: FakeBackend
    func availability() async -> AIAvailability { .available }
    func respond(instructions: String, prompt: String) async throws -> String {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await inner.respond(instructions: instructions, prompt: prompt)
    }
}
