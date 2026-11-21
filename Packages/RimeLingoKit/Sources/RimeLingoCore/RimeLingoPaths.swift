public import Foundation

/// Well-known locations. Everything RimeLingo writes lives under `userDataDir`; the
/// Squirrel directory is only ever read.
public struct RimeLingoPaths: Sendable, Equatable {
    public var userDataDir: URL
    public var logDir: URL
    /// Read-only shipped data (RimeLingo.app/Contents/SharedSupport). Needed to compose the
    /// `rimelingo/defaults` layer; nil in contexts that only touch user layers.
    public var sharedDataDir: URL?

    public init(userDataDir: URL, logDir: URL? = nil, sharedDataDir: URL? = nil) {
        self.userDataDir = userDataDir
        self.logDir = logDir ?? userDataDir.appendingPathComponent("logs", isDirectory: true)
        self.sharedDataDir = sharedDataDir
    }

    /// `~/Library/RimeLingo/Rime`, overridable with `RIMELINGO_USER_DIR` for tests and scripting.
    public static var standard: RimeLingoPaths {
        let env = ProcessInfo.processInfo.environment
        if let override = env["RIMELINGO_USER_DIR"], !override.isEmpty {
            return RimeLingoPaths(userDataDir: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return RimeLingoPaths(
            userDataDir: library.appendingPathComponent("RimeLingo/Rime", isDirectory: true),
            logDir: library.appendingPathComponent("Logs/RimeLingo", isDirectory: true)
        )
    }

    /// The Squirrel (鼠须管) user directory, used as an import source only.
    public static var squirrelUserDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Rime", isDirectory: true)
    }

    /// Shared data of an installed Squirrel (system-wide, then per-user), read only.
    public static var squirrelSharedDataDirs: [URL] {
        let relative = "Library/Input Methods/Squirrel.app/Contents/SharedSupport"
        return [URL(fileURLWithPath: "/", isDirectory: true), FileManager.default.homeDirectoryForCurrentUser]
            .map { $0.appendingPathComponent(relative, isDirectory: true) }
    }

    public var stagingDir: URL { userDataDir.appendingPathComponent("build", isDirectory: true) }
    public var rimelingoDir: URL { userDataDir.appendingPathComponent("rimelingo", isDirectory: true) }
    public var importedDir: URL { rimelingoDir.appendingPathComponent("imported", isDirectory: true) }
    public var generatedDir: URL { rimelingoDir.appendingPathComponent("generated", isDirectory: true) }
    public var packagesDir: URL { rimelingoDir.appendingPathComponent("packages", isDirectory: true) }
    public var cacheDir: URL { rimelingoDir.appendingPathComponent("cache", isDirectory: true) }
    public var customPhraseFile: URL { userDataDir.appendingPathComponent("custom_phrase.txt") }

    public func builtConfig(_ configID: String) -> URL {
        stagingDir.appendingPathComponent("\(configID).yaml")
    }
}

/// Rime's own file-name convention for the configs RimeLingo manages.
public enum ConfigTarget: Sendable, Hashable, CustomStringConvertible {
    /// `default.yaml`
    case `default`
    /// `<id>.schema.yaml`
    case schema(String)
    /// `rimelingo.yaml` — the frontend config; same keys as Squirrel's `squirrel.yaml`.
    case frontend

    /// Config id as used by `config_open` / the `build/` directory.
    public var configID: String {
        switch self {
        case .default: "default"
        case let .schema(id): "\(id).schema"
        case .frontend: "rimelingo"
        }
    }

    /// Base name of the `*.custom.yaml` patch file Rime auto-applies.
    public var customName: String {
        switch self {
        case .default: "default"
        case let .schema(id): id
        case .frontend: "rimelingo"
        }
    }

    public var description: String { configID }

    public init?(file: String, schemaID: String?) {
        switch file {
        case "default": self = .default
        case "frontend", "rimelingo", "squirrel": self = .frontend
        case "schema":
            guard let schemaID else { return nil }
            self = .schema(schemaID)
        default: return nil
        }
    }
}
