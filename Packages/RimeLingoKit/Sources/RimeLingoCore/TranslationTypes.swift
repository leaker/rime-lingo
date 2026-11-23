/// A language translations are made into: one entry of the built-in catalog, identified
/// by its BCP-47 code. Two targets are the same when their codes are.
public struct TranslationTarget: Sendable, Hashable, Codable, CaseIterable {
    /// Canonical BCP-47 code as the catalog writes it ("en", "zh-Hant").
    public let code: String

    /// Looks the code up in the catalog ignoring case and takes the catalog's spelling.
    /// Nil when the catalog has no such language.
    public init?(code: String) {
        guard let entry = Self.byLowercasedCode[code.lowercased()] else { return nil }
        self.code = entry.code
    }

    private init(entry: Entry) { code = entry.code }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let target = TranslationTarget(code: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown translation language code")
        }
        self = target
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }

    public static let english = TranslationTarget(entry: catalog[0])
    public static let japanese = TranslationTarget(entry: catalog[1])
    /// The whole catalog, in the order languages are offered.
    public static let allCases: [TranslationTarget] = catalog.map(TranslationTarget.init(entry:))

    /// English name used inside prompts.
    public var promptName: String { entry.promptName }

    /// Chinese label shown in the preview panel and in Settings.
    public var displayName: String { entry.displayName }

    /// The shortcut a language starts with, in the key recorder's notation (see
    /// `HotkeyFormatter`). Only English and Japanese have one; empty for the others.
    public var defaultShortcut: String { entry.defaultShortcut }

    private struct Entry: Sendable {
        let code: String
        let displayName: String
        let promptName: String
        var defaultShortcut = ""
    }

    private var entry: Entry {
        // Every value is built from the catalog, so the lookup cannot miss.
        Self.byLowercasedCode[code.lowercased()] ?? Self.catalog[0]
    }

    private static let byLowercasedCode = Dictionary(
        catalog.map { ($0.code.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

    /// No prompt name may contain another one: the prompt has to name exactly one language.
    private static let catalog: [Entry] = [
        Entry(code: "en", displayName: "英语", promptName: "English", defaultShortcut: "Control+Alt+Super+e"),
        Entry(code: "ja", displayName: "日语", promptName: "Japanese", defaultShortcut: "Control+Alt+Super+j"),
        Entry(code: "ko", displayName: "韩语", promptName: "Korean"),
        Entry(code: "fr", displayName: "法语", promptName: "French"),
        Entry(code: "de", displayName: "德语", promptName: "German"),
        Entry(code: "es", displayName: "西班牙语", promptName: "Spanish"),
        Entry(code: "pt", displayName: "葡萄牙语", promptName: "Portuguese"),
        Entry(code: "it", displayName: "意大利语", promptName: "Italian"),
        Entry(code: "ru", displayName: "俄语", promptName: "Russian"),
        Entry(code: "ar", displayName: "阿拉伯语", promptName: "Arabic"),
        Entry(code: "th", displayName: "泰语", promptName: "Thai"),
        Entry(code: "vi", displayName: "越南语", promptName: "Vietnamese"),
        Entry(code: "id", displayName: "印尼语", promptName: "Indonesian"),
        Entry(code: "ms", displayName: "马来语", promptName: "Malay"),
        Entry(code: "hi", displayName: "印地语", promptName: "Hindi"),
        Entry(code: "tr", displayName: "土耳其语", promptName: "Turkish"),
        Entry(code: "nl", displayName: "荷兰语", promptName: "Dutch"),
        Entry(code: "pl", displayName: "波兰语", promptName: "Polish"),
        Entry(code: "uk", displayName: "乌克兰语", promptName: "Ukrainian"),
        Entry(code: "zh-Hant", displayName: "繁体中文", promptName: "Traditional Chinese"),
        Entry(code: "zh-Hans", displayName: "简体中文", promptName: "Simplified Chinese"),
        Entry(code: "sv", displayName: "瑞典语", promptName: "Swedish"),
        Entry(code: "da", displayName: "丹麦语", promptName: "Danish"),
        Entry(code: "nb", displayName: "挪威语", promptName: "Norwegian"),
        Entry(code: "fi", displayName: "芬兰语", promptName: "Finnish"),
        Entry(code: "cs", displayName: "捷克语", promptName: "Czech"),
        Entry(code: "el", displayName: "希腊语", promptName: "Greek"),
        Entry(code: "he", displayName: "希伯来语", promptName: "Hebrew"),
        Entry(code: "hu", displayName: "匈牙利语", promptName: "Hungarian"),
        Entry(code: "ro", displayName: "罗马尼亚语", promptName: "Romanian"),
        Entry(code: "bn", displayName: "孟加拉语", promptName: "Bengali"),
        Entry(code: "fa", displayName: "波斯语", promptName: "Persian"),
        Entry(code: "fil", displayName: "菲律宾语", promptName: "Filipino")
    ]
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
