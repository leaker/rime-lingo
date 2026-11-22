public import Foundation

public enum InstallOutcome: Equatable, Sendable {
    /// The new files are in place and verified; the process should now restart.
    case installed(version: String)
    /// Nothing staged, or automatic updates are off.
    case notReady
    /// The user is busy; try again later.
    case deferred
    case failed(UpdateFailure)
}

/// The update state machine: check, download and stage, install. Both apps drive the
/// same code; `UpdateLock` keeps them from doing it at once.
public actor UpdateCoordinator {
    public static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")

    private let paths: RimeLingoPaths
    private let updates: UpdatePaths
    private let bundle: URL
    private let bundleID: String
    private let current: AppVersion
    private let transport: any UpdateTransport
    private let signature: any CodeSignatureEvaluating
    private let fs: any UpdateFileSystem
    private let process: any ProcessControlling
    private let keys: ManifestKeys
    private let system: OperatingSystemVersion
    private let now: @Sendable () -> Date
    private var onChange: (@Sendable () -> Void)?
    private var checking = false
    private var working = false
    private var reportedProgress = -1.0

    public init(paths: RimeLingoPaths, bundle: URL, bundleID: String, current: AppVersion,
                transport: any UpdateTransport = URLSessionUpdateTransport(),
                signature: any CodeSignatureEvaluating = SecCodeSignatureEvaluator(),
                fs: any UpdateFileSystem = LocalUpdateFileSystem(),
                process: any ProcessControlling = SystemProcessControl(),
                keys: ManifestKeys = .shipped,
                system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.updates = UpdatePaths(paths)
        self.bundle = bundle
        self.bundleID = bundleID
        self.current = current
        self.transport = transport
        self.signature = signature
        self.fs = fs
        self.process = process
        self.keys = keys
        self.system = system
        self.now = now
    }

    /// Called after every change of the persisted state.
    public func setOnChange(_ handler: (@Sendable () -> Void)?) { onChange = handler }

    private var cachedEligibility: UpdateEligibility?
    public func eligibility() -> UpdateEligibility {
        if let cachedEligibility { return cachedEligibility }
        let value = UpdateEligibility.evaluate(bundle: bundle, signature: signature, fs: fs, keys: keys)
        cachedEligibility = value
        return value
    }

    private var isEligible: Bool {
        if case .eligible = eligibility() { return true }
        return false
    }

    /// Reads the state again before every change: the other app may have written it.
    @discardableResult
    private func mutate(_ change: (inout UpdateState) -> Void) -> UpdateState {
        var state = UpdateState.load(paths)
        let before = state
        change(&state)
        guard state != before else { return state }
        try? state.save(paths)
        onChange?()
        return state
    }

    /// What a release has to be newer than: the version this process was started from or
    /// the one in the bundle on disk, whichever is higher. They differ while a process
    /// outlives an update of its own files (the settings app with unsaved changes).
    private var installedVersion: AppVersion { max(current, Self.versionOnDisk(bundle) ?? current) }

    private func record(_ failure: UpdateFailure, version: String?) -> UpdateState.FailureRecord {
        .init(code: failure.code, detail: failure.detail, version: version, at: now())
    }

    // MARK: - Check

    /// Fetches and verifies the manifest. `force` is the user's "check now": it ignores
    /// the daily interval and the automatic-updates switch, and retries a failed version.
    @discardableResult
    public func check(force: Bool) async -> UpdateState {
        let state = UpdateState.load(paths)
        guard isEligible, !checking else { return state }
        guard force || state.isDue(now: now()) else { return state }
        // The new version is on disk already and this process only has to restart: a check
        // now would compare the release against the old running version.
        guard state.phase != .installing, !(state.phase == .restartPending && !runsInstalledVersion(state)) else { return state }
        checking = true
        defer { checking = false }

        let manifest: Data, signatureData: Data
        do {
            manifest = try await transport.data(from: UpdateConfiguration.manifestURL, maxBytes: UpdateConfiguration.maxManifestBytes)
            signatureData = try await transport.data(from: UpdateConfiguration.manifestSignatureURL, maxBytes: UpdateConfiguration.maxSignatureBytes)
        } catch {
            // Silent and not counted as a check, so the next hourly pass tries again.
            guard force else { return state }
            let failure = UpdateFailure.network(UpdateInstaller.describe(error))
            return mutate { $0.failure = record(failure, version: nil) }
        }

        let release: AppRelease
        do {
            release = try ManifestVerifier.release(manifest: manifest, signature: signatureData, keys: keys)
        } catch {
            let failure = error as? UpdateFailure ?? .malformedManifest("decode")
            return mutate {
                $0.lastCheck = now()
                $0.consecutiveFailures += 1
                $0.failure = record(failure, version: nil)
            }
        }

        let version = release.appVersion.description
        guard release.supportsThisSystem(system) else {
            discardDownloads()
            return mutate {
                $0.lastCheck = now()
                $0.phase = .idle
                $0.release = nil
                $0.progress = nil
                $0.failure = record(.unsupportedSystem(release.minimumSystemVersion ?? ""), version: version)
            }
        }
        // Same version, an older one, or the same version with an older build: refused.
        guard installedVersion < release.appVersion else {
            discardDownloads()
            return mutate {
                $0.lastCheck = now()
                $0.phase = .idle
                $0.release = nil
                $0.progress = nil
                $0.failure = nil
                $0.consecutiveFailures = 0
            }
        }

        var replaced = false
        let result = mutate { state in
            state.lastCheck = now()
            if let failed = state.failure, failed.version == version, let failure = failed.failure, !failure.isTransient {
                // This release already failed for a reason a retry does not fix. A failure
                // this Mac caused (interrupted, no room) is tried again on a later day, a
                // few times, so that a power cut does not end automatic updates.
                if !force {
                    let attempts = state.retry?.version == version ? state.retry?.count ?? 0 : 0
                    guard failure.isLocal, attempts < UpdateState.maxLocalRetries,
                          now().timeIntervalSince(failed.at) >= UpdateState.localRetryInterval else { return }
                    state.retry = .init(version: version, count: attempts + 1)
                }
            } else if state.release == release, state.phase == .downloading || state.phase == .ready {
                if state.failure?.failure?.isTransient == true, state.failure?.code != UpdateFailure.checksumMismatch.code {
                    state.failure = nil
                }
                return
            }
            replaced = state.release != release
            state.release = release
            state.phase = .downloading
            state.progress = nil
            state.failure = nil
        }
        if replaced { discardDownloads(keeping: release.archive?.name) }
        return result
    }

    private func discardDownloads(keeping name: String? = nil) {
        guard FileManager.default.fileExists(atPath: updates.root.path), let lock = UpdateLock.acquire(updates) else { return }
        defer { withExtendedLifetime(lock) {} }
        try? fs.removeItem(at: updates.staged)
        try? fs.removeItem(at: updates.stagingTemporary)
        for file in (try? BundleTree.children(of: updates.root)) ?? []
        where (file.hasSuffix(".zip") || file.hasSuffix(".part")) && file != name {
            try? fs.removeItem(at: updates.archive(file))
        }
    }

    // MARK: - Download and stage

    /// Downloads, extracts and verifies the release found by `check`. A verified archive
    /// or staged bundle left by an earlier run is reused instead of downloaded again.
    @discardableResult
    public func downloadIfNeeded(userRequested: Bool = false) async -> UpdateState {
        let state = UpdateState.load(paths)
        guard isEligible, state.phase == .downloading, let release = state.release, let file = release.archive,
              userRequested || state.automaticUpdates, !working else { return state }
        guard let lock = UpdateLock.acquire(updates) else { return state }
        working = true
        defer {
            working = false
            withExtendedLifetime(lock) {}
        }
        let version = release.appVersion.description
        do {
            if BundleTree.entry(at: updates.stagedApp) != nil {
                if (try? verifyStaged(updates.stagedApp, release)) != nil { return markReady() }
                try fs.removeItem(at: updates.staged)
            }
            let archive = updates.archive(file.name)
            if !Self.matches(archive, file) {
                try fs.removeItem(at: archive)
                let partial = updates.archive(file.name + ".part")
                try fs.removeItem(at: partial)
                reportedProgress = -1
                do {
                    try await transport.download(from: UpdateConfiguration.assetURL(version: release.version, name: file.name),
                                                 to: partial, maxBytes: file.size,
                                                 allowsConstrainedNetwork: userRequested) { [weak self] value in
                        Task { await self?.report(progress: value) }
                    }
                } catch {
                    try? fs.removeItem(at: partial)
                    // The phase stays `downloading`: the next pass tries again.
                    guard userRequested else { return mutate { $0.progress = nil } }
                    let failure = UpdateFailure.network(UpdateInstaller.describe(error))
                    return mutate {
                        $0.progress = nil
                        $0.failure = record(failure, version: nil)
                    }
                }
                guard Self.matches(partial, file) else {
                    try? fs.removeItem(at: partial)
                    throw UpdateFailure.checksumMismatch
                }
                try fs.rename(partial, to: archive)
            }
            try fs.removeItem(at: updates.stagingTemporary)
            guard (try? process.run(Self.ditto, ["-x", "-k", archive.path, updates.stagingTemporary.path])) == 0 else {
                throw UpdateFailure.badArchive("extract")
            }
            let extracted = try StagedArchive.locateBundle(in: updates.stagingTemporary)
            try verifyStaged(extracted, release)
            try fs.rename(updates.stagingTemporary, to: updates.staged)
            return markReady()
        } catch {
            let failure = error as? UpdateFailure ?? .installFailed(UpdateInstaller.describe(error))
            try? fs.removeItem(at: updates.stagingTemporary)
            try? fs.removeItem(at: updates.staged)
            // Kept after a failure of this Mac's making: the retry does not download again.
            if !failure.isLocal { try? fs.removeItem(at: updates.archive(file.name)) }
            return mutate {
                $0.phase = .failed
                $0.release = nil
                $0.progress = nil
                $0.failure = record(failure, version: version)
                if failure == .checksumMismatch { $0.consecutiveFailures += 1 }
            }
        }
    }

    private func markReady() -> UpdateState {
        mutate {
            $0.phase = .ready
            $0.progress = nil
            $0.failure = nil
            $0.consecutiveFailures = 0
        }
    }

    private func report(progress: Double) {
        guard working, progress - reportedProgress >= 0.05 || progress >= 1 else { return }
        reportedProgress = progress
        mutate { if $0.phase == .downloading { $0.progress = progress } }
    }

    private func verifyStaged(_ app: URL, _ release: AppRelease) throws {
        try BundleVerification.verify(signature.evaluate(bundle: app), release: release, bundleID: bundleID, installed: installedVersion)
    }

    static func matches(_ url: URL, _ file: AppRelease.File) -> Bool {
        guard let entry = BundleTree.entry(at: url), entry.kind == .file, entry.size == Int64(file.size) else { return false }
        return (try? BundleTree.sha256(of: url)) == file.sha256
    }

    // MARK: - Install

    /// Installs the staged release when the user is idle. After `.installed` the caller
    /// restarts the process with `relaunch`; until that happened every call answers
    /// `.installed` again.
    public func installIfReady(idle: UpdateIdleSnapshot, userRequested: Bool) async -> InstallOutcome {
        let state = UpdateState.load(paths)
        if state.phase == .restartPending {
            // Restarting helps only while the bundle on disk really is the version that was
            // installed and this process is not it yet; anything else would restart forever.
            if let installed = state.installed, !runsInstalledVersion(state),
               Self.versionOnDisk(bundle) == AppVersion(installed.version, build: installed.build) {
                return .installed(version: installed.version)
            }
            mutate { if $0.phase == .restartPending { $0.phase = .idle } }
            return .notReady
        }
        guard isEligible, state.phase == .ready, let release = state.release,
              userRequested || state.automaticUpdates else { return .notReady }
        guard idle.allowsInstall(userRequested: userRequested) else { return .deferred }
        guard !working, let lock = UpdateLock.acquire(updates) else { return .failed(.busy) }
        working = true
        defer {
            working = false
            withExtendedLifetime(lock) {}
        }
        mutate { $0.phase = .installing }
        let installer = UpdateInstaller(paths: updates, signature: signature, fs: fs, process: process, now: now)
        do {
            try installer.install(staged: updates.stagedApp, release: release, into: bundle, current: installedVersion, bundleID: bundleID)
        } catch {
            let failure = error as? UpdateFailure ?? .installFailed(UpdateInstaller.describe(error))
            try? fs.removeItem(at: updates.staged)
            if !failure.isLocal, let name = release.archive?.name { try? fs.removeItem(at: updates.archive(name)) }
            mutate {
                $0.phase = .failed
                $0.release = nil
                $0.failure = record(failure, version: release.appVersion.description)
            }
            return .failed(failure)
        }
        mutate {
            $0.phase = .restartPending
            $0.release = nil
            $0.failure = nil
            $0.progress = nil
            $0.installed = .init(version: release.version, build: release.build, at: now(), notified: false)
        }
        return .installed(version: release.version)
    }

    /// Starts the helper that reopens `target` (the input method by default) once `pid`
    /// has exited. False when it could not be started: the caller keeps running and the
    /// state stays `restartPending`.
    public func relaunch(pid: Int32, target: URL? = nil, background: Bool) -> Bool {
        do {
            try process.relaunchAfterExit(pid: pid, bundle: target ?? bundle, background: background)
            return true
        } catch {
            return false
        }
    }

    /// Called by the freshly started input method. When it is the version that was just
    /// installed, the pending restart is over and the version is returned exactly once,
    /// for the "updated" notification. This is also where the previous version kept by the
    /// install is given up: a process that got here did start.
    public func confirmRelaunch() -> String? {
        let state = UpdateState.load(paths)
        guard let installed = state.installed, runsInstalledVersion(state) else { return nil }
        var announce: String?
        mutate {
            if $0.phase == .restartPending { $0.phase = .idle }
            if $0.installed?.notified == false {
                $0.installed?.notified = true
                announce = installed.version
            }
        }
        discardKeptBackup()
        return announce
    }

    /// Skipped while anyone holds the lock; the next launch removes it then.
    private func discardKeptBackup() {
        guard FileManager.default.fileExists(atPath: updates.backup.path), let lock = UpdateLock.acquire(updates) else { return }
        defer { withExtendedLifetime(lock) {} }
        UpdateInstaller(paths: updates, signature: signature, fs: fs, process: process, now: now).discardKeptBackup()
    }

    private func runsInstalledVersion(_ state: UpdateState) -> Bool {
        state.installed.map { AppVersion($0.version, build: $0.build) == current } ?? false
    }

    /// Read from the file, not through `Bundle`, which caches what it read first.
    static func versionOnDisk(_ bundle: URL) -> AppVersion? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return AppVersion(version, build: (info["CFBundleVersion"] as? String).flatMap { Int($0) })
    }

    /// The failure the user should be told about now, at most once per failure and version.
    public func takeFailureNotice() -> UpdateFailure? {
        let state = UpdateState.load(paths)
        guard let recorded = state.failure, let failure = recorded.failure else { return nil }
        let threshold = failure.notificationThreshold
        guard threshold > 0, threshold == 1 || state.consecutiveFailures >= threshold else { return nil }
        let key = "\(recorded.code)@\(recorded.version ?? "-")"
        guard state.notifiedFailure != key else { return nil }
        mutate { $0.notifiedFailure = key }
        return failure
    }

    public func setAutomaticUpdates(_ enabled: Bool) -> UpdateState {
        mutate { $0.automaticUpdates = enabled }
    }

    // MARK: - Launch

    /// Run once at launch, before the bundle is used: finishes or undoes an interrupted
    /// install and brings the persisted state back in line with what is on disk. Like
    /// everything else here it is for release builds with a manifest key only: a
    /// development build never rewrites its own bundle, whatever an earlier release build
    /// left in the cache. The one exception is a process whose own signature is broken
    /// while the marker says an install was cut short replacing the files of this very
    /// bundle: that is what a release looks like when it starts from a mix of two
    /// versions, and it is the only one left to put the previous version back. Nothing
    /// but a backup that is a release of ours is ever restored.
    @discardableResult
    public static func recoverAtLaunch(paths: RimeLingoPaths, bundle: URL, bundleID: String = RimeLingoInstallations.bundleID,
                                       signature: any CodeSignatureEvaluating = SecCodeSignatureEvaluator(),
                                       fs: any UpdateFileSystem = LocalUpdateFileSystem(),
                                       process: any ProcessControlling = SystemProcessControl(),
                                       keys: ManifestKeys = .shipped,
                                       now: @Sendable () -> Date = { Date() }) -> RecoveryOutcome {
        let updates = UpdatePaths(paths)
        guard FileManager.default.fileExists(atPath: updates.root.path) else { return .none }
        let installer = UpdateInstaller(paths: updates, signature: signature, fs: fs, process: process)
        switch UpdateEligibility.evaluate(bundle: bundle, signature: signature, fs: fs, keys: keys) {
        case .eligible: break
        // A valid signature that is not a release's stays a development build.
        case .developmentBuild where !signature.evaluateRunningProcess().isValid
            && UpdateEligibility.isReplaceable(bundle, fs: fs) && installer.wasInterruptedWhileReplacing(bundle): break
        default: return .none
        }
        let outcome = installer.recoverIfNeeded(bundle: bundle, bundleID: bundleID)
        guard outcome != .busy, let lock = UpdateLock.acquire(updates) else { return outcome }
        defer { withExtendedLifetime(lock) {} }
        // Nobody holds the lock: whatever was in progress is over.
        try? fs.removeItem(at: updates.stagingTemporary)
        for file in (try? BundleTree.children(of: updates.root)) ?? [] where file.hasSuffix(".part") {
            try? fs.removeItem(at: updates.archive(file))
        }
        var state = UpdateState.load(paths)
        let before = state
        let stagedExists = BundleTree.entry(at: updates.stagedApp) != nil
        switch outcome {
        case let .rolledBack(from, _):
            try? fs.removeItem(at: updates.staged)
            state.phase = .failed
            state.release = nil
            state.installed = nil
            state.failure = .init(code: UpdateFailure.installFailed("").code, detail: "interrupted", version: from, at: now())
        case let .failed(detail):
            state.phase = .failed
            state.release = nil
            state.failure = .init(code: UpdateFailure.rollbackFailed("").code, detail: detail, version: nil, at: now())
        case let .completed(version, build):
            // The process starting now runs the new files; the input method confirms and
            // announces it as after any other install.
            for file in (try? BundleTree.children(of: updates.root)) ?? [] where file.hasSuffix(".zip") {
                try? fs.removeItem(at: updates.archive(file))
            }
            state.phase = .restartPending
            state.release = nil
            state.failure = nil
            state.installed = .init(version: version, build: build ?? 0, at: now(), notified: false)
        case .cleaned, .none, .busy:
            if state.phase == .installing { state.phase = stagedExists && state.release != nil ? .ready : .idle }
            if state.phase == .ready, !stagedExists { state.phase = state.release == nil ? .idle : .downloading }
        }
        state.progress = nil
        // The previous version is kept, without a marker, from an install until the new
        // version has confirmed that it runs. In any other phase it is a leftover (the
        // pending restart was dropped, or the confirming process could not get the lock).
        if state.phase != .restartPending { installer.discardKeptBackup() }
        if state != before { try? state.save(paths) }
        return outcome
    }
}
