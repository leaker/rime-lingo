public import Foundation

/// Written before the first file of an install lands in the bundle and removed once the
/// installed bundle has been verified: its presence without a lock holder means an
/// install was interrupted.
public struct InstallMarker: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case prepare, commit, cleanup, rollback }
    public struct Version: Codable, Sendable, Equatable {
        public var version: String
        public var build: Int?
        public var description: String { AppVersion(version, build: build).description }
    }

    public var schema = 1
    public var pid: Int32
    public var from: Version
    public var to: Version
    public var bundle: String
    public var phase: Phase
    public var startedAt: Date

    static func read(_ url: URL) -> InstallMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstallMarker.self, from: data)
    }

    func write(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try BundleTree.writeDurably(try encoder.encode(self), to: url)
    }
}

public enum RecoveryOutcome: Equatable, Sendable {
    /// No interrupted install.
    case none
    /// An install is running in another process.
    case busy
    /// Interrupted before anything was replaced; leftovers removed.
    case cleaned
    /// Interrupted while replacing; the previous version was restored.
    case rolledBack(from: String, to: String)
    /// Interrupted after the new version was completely in place and verified; finished.
    /// The backup is kept as after any other install.
    case completed(version: String, build: Int?)
    case failed(String)
}

/// Installs a verified, staged bundle over the installed one, in place, and puts the
/// previous contents back when anything goes wrong. The caller holds `UpdateLock`.
public struct UpdateInstaller: Sendable {
    public var paths: UpdatePaths
    public var signature: any CodeSignatureEvaluating
    public var fs: any UpdateFileSystem
    public var process: any ProcessControlling
    public var now: @Sendable () -> Date

    public init(paths: UpdatePaths, signature: any CodeSignatureEvaluating, fs: any UpdateFileSystem = LocalUpdateFileSystem(),
                process: any ProcessControlling, now: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.signature = signature
        self.fs = fs
        self.process = process
        self.now = now
    }

    private var replacer: BundleReplacer { BundleReplacer(fs: fs) }

    /// What strict validation calls "resource fork, Finder information, or similar detritus".
    static let finderAttributes = [XATTR_FINDERINFO_NAME, XATTR_RESOURCEFORK_NAME]

    /// Throws an `UpdateFailure`. On `.installFailed` the previous version is back in
    /// place; on `.backupFailed`, `.notNewer` and the verification failures nothing was
    /// touched; on `.rollbackFailed` the marker and the backup are kept for the next launch.
    ///
    /// After a successful install the previous version stays in `paths.backupApp`
    /// (`updates/backup` in the cache) without a marker: a release can pass every signature
    /// check and still not start. It is removed by `discardKeptBackup` once the new version
    /// has confirmed that it runs, and replaced by the next install. Nothing restores it
    /// automatically: the new version confirms as soon as it has launched, so one that
    /// dies before that never runs any code of ours. Putting it back is manual for now
    /// (copy it over the installed bundle); the relaunch helper or the settings app could
    /// do it later.
    public func install(staged: URL, release: AppRelease, into bundle: URL, current: AppVersion, bundleID: String) throws {
        // An install that could not be undone left its marker and the only good backup
        // behind: finish that first, and never build a new backup from a mixed bundle.
        if FileManager.default.fileExists(atPath: paths.marker.path),
           case let .failed(detail) = recoverHoldingLock(bundle: bundle, bundleID: bundleID) {
            throw UpdateFailure.rollbackFailed(detail)
        }
        // The staging directory is user-writable: verify again right before using it.
        try BundleVerification.verify(signature.evaluate(bundle: staged), release: release, bundleID: bundleID, installed: current)

        do {
            // A colour tag or custom icon given in Finder puts these on the bundle's
            // directory. They are outside the seal, but strict validation rejects a bundle
            // that carries them, and the copy below would take them into the backup.
            for name in Self.finderAttributes { try fs.removeExtendedAttribute(name, at: bundle) }
            try fs.removeItem(at: paths.backup)
            try fs.createDirectory(at: paths.backup)
            try fs.copyItem(at: bundle, to: paths.backupApp)
        } catch {
            try? fs.removeItem(at: paths.backup)
            throw UpdateFailure.backupFailed(Self.describe(error))
        }
        // The backup is what a rollback puts back, so it has to be a release of ours, and
        // its sealed version (what is on disk, not what this process was started from) is
        // the one the update must be newer than.
        let backup = signature.evaluate(bundle: paths.backupApp)
        guard Self.isRelease(backup, bundleID: bundleID), let installedVersion = backup.version else {
            try? fs.removeItem(at: paths.backup)
            throw UpdateFailure.backupFailed("untrusted")
        }
        guard AppVersion(installedVersion, build: backup.build) < release.appVersion else {
            try? fs.removeItem(at: paths.backup)
            throw UpdateFailure.notNewer
        }

        var marker = InstallMarker(pid: getpid(), from: .init(version: installedVersion, build: backup.build),
                                   to: .init(version: release.version, build: release.build),
                                   bundle: bundle.path, phase: .prepare, startedAt: now())
        let replacer = replacer
        do {
            try marker.write(paths.marker)
            replacer.cleanTemporaries(in: bundle)
            let plan = try replacer.plan(from: staged, into: bundle)
            try replacer.prepare(plan)
            marker.phase = .commit
            do { try marker.write(paths.marker) } catch {
                replacer.cleanTemporaries(in: bundle)
                throw error
            }
            do {
                try replacer.commit(plan)
                marker.phase = .cleanup
                try marker.write(paths.marker)
                try replacer.removeStale(plan)
                try BundleVerification.verify(signature.evaluate(bundle: bundle), release: release, bundleID: bundleID, installed: nil)
            } catch {
                try rollback(bundle: bundle, bundleID: bundleID, marker: marker, reason: Self.describe(error))
            }
        } catch let failure as UpdateFailure {
            throw failure
        } catch {
            // Nothing was replaced: prepare only added temporary copies, now removed.
            try? fs.removeItem(at: paths.marker)
            try? fs.removeItem(at: paths.backup)
            throw UpdateFailure.installFailed(Self.describe(error))
        }

        process.registerWithLaunchServices(bundle)
        // The backup stays until the new version has confirmed that it runs.
        try? fs.removeItem(at: paths.marker)
        try? fs.removeItem(at: paths.staged)
        if let name = release.archive?.name { try? fs.removeItem(at: paths.archive(name)) }
    }

    /// Restores the backup. Always throws: `.installFailed` when the previous version is
    /// back, `.rollbackFailed` (marker and backup kept for the next launch) when not.
    private func rollback(bundle: URL, bundleID: String, marker: InstallMarker, reason: String) throws -> Never {
        var marker = marker
        marker.phase = .rollback
        try? marker.write(paths.marker)
        do {
            try restore(bundle: bundle, bundleID: bundleID, marker: marker)
        } catch {
            throw UpdateFailure.rollbackFailed("\(reason); \(Self.describe(error))")
        }
        try? fs.removeItem(at: paths.marker)
        try? fs.removeItem(at: paths.backup)
        throw UpdateFailure.installFailed(reason)
    }

    /// A valid Developer ID release of the team with the expected identity.
    private static func isRelease(_ info: SignatureInfo, bundleID: String) -> Bool {
        info.isValid && info.satisfiesDeveloperID && info.teamID == UpdateConfiguration.teamID && info.bundleID == bundleID
    }

    private static func requireRelease(_ info: SignatureInfo, bundleID: String, version: InstallMarker.Version) throws {
        guard info.isValid, info.satisfiesDeveloperID, info.teamID == UpdateConfiguration.teamID else {
            throw UpdateFailure.untrustedBundle
        }
        guard info.bundleID == bundleID else { throw UpdateFailure.wrongBundle }
        guard info.version == version.version, info.build == version.build else { throw UpdateFailure.versionMismatch }
    }

    /// The backup lies in a user-writable cache and the marker beside it is not
    /// authenticated: nothing is put into the bundle unless the backup is a release of
    /// ours, and the result is checked the same way.
    private func restore(bundle: URL, bundleID: String, marker: InstallMarker) throws {
        guard BundleTree.entry(at: paths.backupApp)?.kind == .directory else { throw CocoaError(.fileNoSuchFile) }
        try Self.requireRelease(signature.evaluate(bundle: paths.backupApp), bundleID: bundleID, version: marker.from)
        try replacer.replace(from: paths.backupApp, into: bundle)
        try Self.requireRelease(signature.evaluate(bundle: bundle), bundleID: bundleID, version: marker.from)
        process.registerWithLaunchServices(bundle)
    }

    /// Removes the previous version that `install` kept, for a caller that holds
    /// `UpdateLock`. While there is a marker the backup belongs to an install that is not
    /// over and is left alone.
    func discardKeptBackup() {
        guard !FileManager.default.fileExists(atPath: paths.marker.path) else { return }
        try? fs.removeItem(at: paths.backup)
    }

    /// Called at launch, before anything else uses the bundle. Does nothing while another
    /// process holds the lock. A backup without a marker is the previous version kept by
    /// `install`, not an interrupted install, and is not touched here.
    public func recoverIfNeeded(bundle: URL, bundleID: String) -> RecoveryOutcome {
        guard FileManager.default.fileExists(atPath: paths.marker.path) else { return .none }
        guard let lock = UpdateLock.acquire(paths) else { return .busy }
        defer { withExtendedLifetime(lock) {} }
        return recoverHoldingLock(bundle: bundle, bundleID: bundleID)
    }

    /// Whether an install into `bundle` stopped at a point where its files may be a mix of
    /// two versions. Only reads the marker.
    func wasInterruptedWhileReplacing(_ bundle: URL) -> Bool {
        guard let marker = InstallMarker.read(paths.marker),
              URL(fileURLWithPath: marker.bundle).standardizedFileURL.path == bundle.standardizedFileURL.path else { return false }
        switch marker.phase {
        case .prepare: return false
        case .commit, .cleanup, .rollback: return true
        }
    }

    /// The recovery itself, for a caller that already holds `UpdateLock`.
    func recoverHoldingLock(bundle: URL, bundleID: String) -> RecoveryOutcome {
        guard FileManager.default.fileExists(atPath: paths.marker.path) else { return .none }
        guard let marker = InstallMarker.read(paths.marker) else {
            // Unreadable: written by nothing we know. The bundle is left alone.
            try? fs.removeItem(at: paths.marker)
            return .none
        }
        guard URL(fileURLWithPath: marker.bundle).standardizedFileURL.path == bundle.standardizedFileURL.path else { return .none }
        if marker.phase == .prepare {
            replacer.cleanTemporaries(in: bundle)
            try? fs.removeItem(at: paths.marker)
            try? fs.removeItem(at: paths.backup)
            return .cleaned
        }
        if marker.phase == .cleanup {
            // Every file was in place; only removing leftovers and the final check were
            // cut short. When the bundle already is the complete new release (a stale file
            // left behind breaks its seal), finish instead of going back.
            replacer.cleanTemporaries(in: bundle)
            if (try? Self.requireRelease(signature.evaluate(bundle: bundle), bundleID: bundleID, version: marker.to)) != nil {
                process.registerWithLaunchServices(bundle)
                // As after any other install, the backup is kept until the new version runs.
                try? fs.removeItem(at: paths.marker)
                try? fs.removeItem(at: paths.staged)
                return .completed(version: marker.to.version, build: marker.to.build)
            }
        }
        do {
            try restore(bundle: bundle, bundleID: bundleID, marker: marker)
        } catch {
            return .failed(Self.describe(error))
        }
        try? fs.removeItem(at: paths.marker)
        try? fs.removeItem(at: paths.backup)
        return .rolledBack(from: marker.to.description, to: marker.from.description)
    }

    static func describe(_ error: any Error) -> String {
        if let failure = error as? UpdateFailure { return failure.code }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
