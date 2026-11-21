import FoundationModels
public import RimeLingoCore

/// One-shot text generation for live translation.
public protocol TranslationBackend: Sendable {
    func availability() async -> AIAvailability
    /// A single complete reply.
    func respond(instructions: String, prompt: String) async throws -> String
}

/// Apple's on-device model with the guardrails meant for content transformation.
/// Every request gets a session of its own: nothing is kept, reused or run concurrently.
public struct OnDeviceTranslationBackend: TranslationBackend {
    public init() {}

    public func availability() async -> AIAvailability {
        await FoundationModelsProvider().availability()
    }

    public func respond(instructions: String, prompt: String) async throws -> String {
        guard #available(macOS 26, *) else { throw AIError.unavailable("Apple Intelligence") }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        // `respond` throws on cancellation. `streamResponse` does not: if this ever streams,
        // call `try Task.checkCancellation()` after the loop, or a cut-off reply looks complete.
        return try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy)).content
    }
}

/// Adapts an existing provider (the OpenAI-compatible endpoint).
public struct ProviderTranslationBackend: TranslationBackend {
    let provider: any AIProvider

    public init(provider: any AIProvider) { self.provider = provider }

    public func availability() async -> AIAvailability { await provider.availability() }

    public func respond(instructions: String, prompt: String) async throws -> String {
        try await provider.complete(instructions: instructions, prompt: prompt)
    }
}
