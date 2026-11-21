public import Foundation

/// Why an update did not happen. `code` is what gets persisted and exported.
public enum UpdateFailure: Error, Equatable, Sendable, LocalizedError {
    case notConfigured
    case developmentBuild
    case unsupportedLocation(String)
    case network(String)
    case untrustedManifest
    case malformedManifest(String)
    case unsupportedSystem(String)
    case checksumMismatch
    case badArchive(String)
    case untrustedBundle
    case wrongBundle
    case versionMismatch
    case notNewer
    case busy
    case backupFailed(String)
    case installFailed(String)
    case rollbackFailed(String)

    public var code: String {
        switch self {
        case .notConfigured: "notConfigured"
        case .developmentBuild: "developmentBuild"
        case .unsupportedLocation: "unsupportedLocation"
        case .network: "network"
        case .untrustedManifest: "untrustedManifest"
        case .malformedManifest: "malformedManifest"
        case .unsupportedSystem: "unsupportedSystem"
        case .checksumMismatch: "checksumMismatch"
        case .badArchive: "badArchive"
        case .untrustedBundle: "untrustedBundle"
        case .wrongBundle: "wrongBundle"
        case .versionMismatch: "versionMismatch"
        case .notNewer: "notNewer"
        case .busy: "busy"
        case .backupFailed: "backupFailed"
        case .installFailed: "installFailed"
        case .rollbackFailed: "rollbackFailed"
        }
    }

    public var detail: String? {
        switch self {
        case let .unsupportedLocation(detail), let .network(detail), let .malformedManifest(detail),
             let .unsupportedSystem(detail), let .badArchive(detail), let .backupFailed(detail),
             let .installFailed(detail), let .rollbackFailed(detail): detail
        default: nil
        }
    }

    public init?(code: String, detail: String? = nil) {
        let detail = detail ?? ""
        switch code {
        case "notConfigured": self = .notConfigured
        case "developmentBuild": self = .developmentBuild
        case "unsupportedLocation": self = .unsupportedLocation(detail)
        case "network": self = .network(detail)
        case "untrustedManifest": self = .untrustedManifest
        case "malformedManifest": self = .malformedManifest(detail)
        case "unsupportedSystem": self = .unsupportedSystem(detail)
        case "checksumMismatch": self = .checksumMismatch
        case "badArchive": self = .badArchive(detail)
        case "untrustedBundle": self = .untrustedBundle
        case "wrongBundle": self = .wrongBundle
        case "versionMismatch": self = .versionMismatch
        case "notNewer": self = .notNewer
        case "busy": self = .busy
        case "backupFailed": self = .backupFailed(detail)
        case "installFailed": self = .installFailed(detail)
        case "rollbackFailed": self = .rollbackFailed(detail)
        default: return nil
        }
    }

    /// Clears by itself on a later attempt; never blocks a version.
    public var isTransient: Bool {
        switch self {
        case .network, .checksumMismatch, .busy, .untrustedManifest, .malformedManifest, .unsupportedSystem: true
        default: false
        }
    }

    /// Caused by this Mac at that moment (an install cut short, no room for the backup or
    /// the extraction), not by the release: the same version is tried again on a later
    /// day, at most `UpdateState.maxLocalRetries` times.
    public var isLocal: Bool {
        switch self {
        case let .backupFailed(detail): detail != "untrusted"
        case let .installFailed(detail): detail == "interrupted" || Self.outOfSpace.contains { detail.hasPrefix($0) }
        case let .badArchive(detail): detail == "extract"
        default: false
        }
    }

    /// ENOSPC and NSFileWriteOutOfSpaceError as `UpdateInstaller.describe` writes them.
    private static let outOfSpace = ["NSPOSIXErrorDomain 28", "NSCocoaErrorDomain 640"]

    /// How many consecutive occurrences it takes before the user is told (0: never).
    public var notificationThreshold: Int {
        switch self {
        case .untrustedManifest, .malformedManifest, .checksumMismatch: 3
        case .badArchive, .untrustedBundle, .wrongBundle, .versionMismatch, .notNewer,
             .backupFailed, .installFailed, .rollbackFailed: 1
        default: 0
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "尚未配置更新签名"
        case .developmentBuild: "开发版不会自动更新"
        case .unsupportedLocation: "当前安装位置不可写，无法自动更新"
        case .network: "无法连接更新服务器"
        case .untrustedManifest: "版本清单签名校验失败，已忽略"
        case .malformedManifest: "版本清单格式不正确，已忽略"
        case let .unsupportedSystem(minimum): "新版本需要 macOS \(minimum) 或更高版本"
        case .checksumMismatch: "下载的更新校验失败（SHA-256 不一致），已删除"
        case .badArchive: "更新包内容异常，已删除"
        case .untrustedBundle: "更新包的开发者签名不可信，已删除"
        case .wrongBundle: "更新包不是灵译输入法，已删除"
        case .versionMismatch: "更新包的版本与清单不一致，已删除"
        case .notNewer: "更新包不比当前版本新，已删除"
        case .busy: "另一项更新正在进行"
        case .backupFailed: "无法备份当前版本，未做任何改动"
        case .installFailed: "安装失败，已恢复原版本"
        case .rollbackFailed: "更新失败且未能恢复，请重新安装"
        }
    }
}

/// Update preferences and progress shared by the input method and the settings app,
/// stored in `rimelingo/update.json` (schema 2).
public struct UpdateState: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case idle, downloading, ready, installing, restartPending, failed
    }

    public struct FailureRecord: Codable, Sendable, Equatable {
        public var code: String
        public var detail: String?
        /// "version (build)" the failure refers to, when it is about one release.
        public var version: String?
        public var at: Date

        public var failure: UpdateFailure? { UpdateFailure(code: code, detail: detail) }
    }

    public struct Installed: Codable, Sendable, Equatable {
        public var version: String
        public var build: Int
        public var at: Date
        /// Set once the relaunched input method has told the user.
        public var notified: Bool
    }

    /// Automatic attempts after a failure of this Mac's making, counted per version.
    public struct Retry: Codable, Sendable, Equatable {
        public var version: String
        public var count: Int
    }

    public static let maxLocalRetries = 3
    public static let localRetryInterval: TimeInterval = 12 * 3600
    public static let currentSchema = 2
    public var schema = currentSchema
    public var automaticUpdates = true
    public var lastCheck: Date?
    public var consecutiveFailures = 0
    public var phase = Phase.idle
    /// The signed manifest content `phase` refers to.
    public var release: AppRelease?
    public var progress: Double?
    public var failure: FailureRecord?
    /// "code@version" of the last failure the user was notified about.
    public var notifiedFailure: String?
    public var installed: Installed?
    public var retry: Retry?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schema, automaticUpdates, lastCheck, consecutiveFailures, phase, release, progress, failure
        case notifiedFailure, installed, retry
        case autoCheck  // schema 1
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastCheck = try? container.decodeIfPresent(Date.self, forKey: .lastCheck)
        guard (try? container.decodeIfPresent(Int.self, forKey: .schema)) == Self.currentSchema else {
            // Schema 1 (inherited): keep the preference and the last check; the cached
            // release, the beta channel and the skipped version no longer apply.
            automaticUpdates = (try? container.decodeIfPresent(Bool.self, forKey: .autoCheck)) ?? true
            return
        }
        automaticUpdates = (try? container.decodeIfPresent(Bool.self, forKey: .automaticUpdates)) ?? true
        consecutiveFailures = (try? container.decodeIfPresent(Int.self, forKey: .consecutiveFailures)) ?? 0
        release = try? container.decodeIfPresent(AppRelease.self, forKey: .release)
        phase = (try? container.decodeIfPresent(Phase.self, forKey: .phase)) ?? .idle
        progress = try? container.decodeIfPresent(Double.self, forKey: .progress)
        failure = try? container.decodeIfPresent(FailureRecord.self, forKey: .failure)
        notifiedFailure = try? container.decodeIfPresent(String.self, forKey: .notifiedFailure)
        installed = try? container.decodeIfPresent(Installed.self, forKey: .installed)
        retry = try? container.decodeIfPresent(Retry.self, forKey: .retry)
        // A phase about a release is meaningless without that release.
        if release == nil, phase == .downloading || phase == .ready || phase == .installing { phase = .idle }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchema, forKey: .schema)
        try container.encode(automaticUpdates, forKey: .automaticUpdates)
        try container.encodeIfPresent(lastCheck, forKey: .lastCheck)
        try container.encode(consecutiveFailures, forKey: .consecutiveFailures)
        try container.encode(phase, forKey: .phase)
        try container.encodeIfPresent(release, forKey: .release)
        try container.encodeIfPresent(progress, forKey: .progress)
        try container.encodeIfPresent(failure, forKey: .failure)
        try container.encodeIfPresent(notifiedFailure, forKey: .notifiedFailure)
        try container.encodeIfPresent(installed, forKey: .installed)
        try container.encodeIfPresent(retry, forKey: .retry)
    }

    public static func load(_ paths: RimeLingoPaths) -> UpdateState {
        guard let data = try? Data(contentsOf: file(paths)),
              let state = try? decoder.decode(UpdateState.self, from: data) else { return UpdateState() }
        return state
    }

    public func save(_ paths: RimeLingoPaths) throws {
        try FileManager.default.createDirectory(at: paths.rimelingoDir, withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: Self.file(paths), options: .atomic)
    }

    /// Whether the automatic daily check should run now.
    public func isDue(now: Date = Date(), interval: TimeInterval = 24 * 3600) -> Bool {
        automaticUpdates && (lastCheck.map { now.timeIntervalSince($0) >= interval } ?? true)
    }

    public static func file(_ paths: RimeLingoPaths) -> URL { paths.rimelingoDir.appendingPathComponent("update.json") }
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// "Install now" from Settings, as the input method remembers it. It stays in force until
/// an install succeeded, failed or turned out to have nothing to install, not for a fixed
/// time: someone who goes on typing for minutes still gets the update they asked for,
/// with automatic updates off as well.
public struct UserInstallRequest: Sendable, Equatable {
    public private(set) var isActive = false

    public init() {}

    public mutating func make() { isActive = true }

    public mutating func settle(_ outcome: InstallOutcome) {
        switch outcome {
        // Still to come: a quiet moment, the other process' turn, or the restart, which
        // waits for the user under the same request.
        case .deferred, .installed, .failed(.busy): break
        case .notReady, .failed: isActive = false
        }
    }
}

/// What the input method is doing, for the decision whether an install may interrupt it.
public struct UpdateIdleSnapshot: Sendable, Equatable {
    public static let requiredIdleSeconds: TimeInterval = 30

    public var secondsSinceLastKey: TimeInterval
    public var isComposing = false
    public var hasPendingInput = false
    public var hasDraft = false
    public var liveSessionActive = false
    public var selectionPreviewActive = false
    public var aiActionActive = false
    public var quickMenuOpen = false
    public var secureContext = false
    public var deployInProgress = false

    public init(secondsSinceLastKey: TimeInterval, isComposing: Bool = false, hasPendingInput: Bool = false,
                hasDraft: Bool = false, liveSessionActive: Bool = false, selectionPreviewActive: Bool = false,
                aiActionActive: Bool = false, quickMenuOpen: Bool = false, secureContext: Bool = false,
                deployInProgress: Bool = false) {
        self.secondsSinceLastKey = secondsSinceLastKey
        self.isComposing = isComposing
        self.hasPendingInput = hasPendingInput
        self.hasDraft = hasDraft
        self.liveSessionActive = liveSessionActive
        self.selectionPreviewActive = selectionPreviewActive
        self.aiActionActive = aiActionActive
        self.quickMenuOpen = quickMenuOpen
        self.secureContext = secureContext
        self.deployInProgress = deployInProgress
    }

    /// A process that is not an input method has nothing to interrupt.
    public static let notAnInputMethod = UpdateIdleSnapshot(secondsSinceLastKey: .infinity)

    /// "Install now" waives only the 30 s rule; nothing else is ever interrupted.
    public func allowsInstall(userRequested: Bool) -> Bool {
        guard !isComposing, !hasPendingInput, !hasDraft, !liveSessionActive, !selectionPreviewActive,
              !aiActionActive, !quickMenuOpen, !secureContext, !deployInProgress else { return false }
        return userRequested || secondsSinceLastKey >= Self.requiredIdleSeconds
    }
}
