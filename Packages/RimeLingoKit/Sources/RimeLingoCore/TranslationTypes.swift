/// The language a live translation session translates into.
public enum TranslationTarget: String, Sendable, Codable, CaseIterable, Equatable {
    case english, japanese

    /// Name used inside prompts.
    public var promptName: String {
        switch self {
        case .english: "English"
        case .japanese: "Japanese"
        }
    }

    /// Label shown in the preview panel.
    public var displayName: String {
        switch self {
        case .english: "英语"
        case .japanese: "日语"
        }
    }
}

/// Why a translation request produced no usable text. Categories only: no case carries
/// source text, translated text or provider messages.
public enum TranslationFailure: Error, Sendable, Equatable, CaseIterable {
    /// The model or the API key is not available.
    case providerUnavailable
    /// The remote provider is selected but sending text to it was not allowed, or its address is invalid.
    case remoteNotAuthorised
    /// The network, the server or the model failed while handling the request.
    case requestFailed
    /// The reply was empty, or nothing was left after cleaning it.
    case invalidResponse
    /// The source is longer than the translator accepts.
    case sourceTooLong
    case cancelled

    /// Short reason for the preview panel.
    public var message: String {
        switch self {
        case .providerUnavailable: "模型不可用"
        case .remoteNotAuthorised: "未允许发送到自备接口"
        case .requestFailed: "请求失败"
        case .invalidResponse: "译文无效"
        case .sourceTooLong: "原文过长"
        case .cancelled: "已取消"
        }
    }
}

/// Identifies what a request or a result belongs to. A result is applied only when its
/// tag still equals the session's current tag.
public struct TranslationTag: Sendable, Equatable, Hashable {
    public let session: UInt64
    public let revision: Int
    public let target: TranslationTarget

    public init(session: UInt64, revision: Int, target: TranslationTarget) {
        self.session = session
        self.revision = revision
        self.target = target
    }
}

public struct TranslationRequest: Sendable, Equatable {
    public let tag: TranslationTag
    public let source: String

    public init(tag: TranslationTag, source: String) {
        self.tag = tag
        self.source = source
    }
}
