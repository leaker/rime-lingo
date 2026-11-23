import CryptoKit
import Foundation
@testable import RimeLingoCore
import Testing

/// An installed 0.2.0 (20), a published 0.3.0 (21), and fakes for everything outside.
final class UpdateRig {
    let scratch = Scratch()
    let key = Curve25519.Signing.PrivateKey()
    let transport = FakeTransport()
    let signature = FakeSignature()
    let fs = FaultyFileSystem()
    let process = FakeProcess()
    let clock = TestClock()
    let payload = Data("zip bytes of 0.3.0".utf8)
    let paths: RimeLingoPaths
    let updates: UpdatePaths
    let installed: URL
    let published: URL
    let assetURL = UpdateConfiguration.assetURL(version: "0.3.0", name: "RimeLingo-0.3.0.zip")
    var publicKey: String
    var backupKey = UpdateConfiguration.placeholderPublicKey

    init() throws {
        paths = RimeLingoPaths(userDataDir: scratch.url("Rime"))
        updates = UpdatePaths(paths)
        installed = scratch.url("Input Methods/RimeLingo.app")
        published = scratch.url("published/RimeLingo.app")
        publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        try makeBundle(installed, version: "0.2.0", build: 20)
        try makeBundle(published, version: "0.3.0", build: 21, extra: ["Contents/Resources/added.txt": "new"])
        process.archiveContents = published
        try publish()
    }

    func publish(version: String = "0.3.0", build: Int = 21, sha: String? = nil, minimum: String = "15.0", signed: Bool = true) throws {
        let manifest = Data("""
        {"product":"rimelingo","version":"\(version)","build":\(build),"minimumSystemVersion":"\(minimum)",
         "files":{"zip":{"name":"RimeLingo-\(version).zip","size":\(payload.count),"sha256":"\(sha ?? sha256Hex(payload))"}}}
        """.utf8)
        transport.serve(UpdateConfiguration.manifestURL, manifest)
        transport.serve(UpdateConfiguration.manifestSignatureURL,
                        signed ? Data(try key.signature(for: manifest).base64EncodedString().utf8) : Data("AAAA".utf8))
        transport.serve(UpdateConfiguration.assetURL(version: version, name: "RimeLingo-\(version).zip"), payload)
    }

    func coordinator(current: AppVersion = AppVersion("0.2.0", build: 20)) -> UpdateCoordinator {
        let clock = clock
        return UpdateCoordinator(paths: paths, bundle: installed, bundleID: fixtureBundleID, current: current, transport: transport,
                                 signature: signature, fs: fs, process: process, keys: ManifestKeys(publicKey, backup: backupKey),
                                 system: OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0),
                                 now: { clock.now })
    }

    var state: UpdateState { UpdateState.load(paths) }
    let idle = UpdateIdleSnapshot(secondsSinceLastKey: 120)
    let typing = UpdateIdleSnapshot(secondsSinceLastKey: 2)
}

@Suite struct UpdateCoordinatorTests {
    let rig: UpdateRig

    init() throws { rig = try UpdateRig() }

    @Test func staysInertWhileTheKeyIsThePlaceholder() async {
        rig.publicKey = UpdateConfiguration.placeholderPublicKey
        let coordinator = rig.coordinator()
        #expect(await coordinator.eligibility() == .notConfigured)
        _ = await coordinator.check(force: true)
        _ = await coordinator.downloadIfNeeded(userRequested: true)
        #expect(await coordinator.installIfReady(idle: rig.idle, userRequested: true) == .notReady)
        #expect(rig.transport.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: UpdateState.file(rig.paths).path), "nothing is written either")
    }

    /// The everyday key was lost or replaced: a release signed with the backup key is
    /// still found, and one signed with neither is not.
    @Test func acceptsAReleaseSignedWithTheBackupKey() async {
        let everyday = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        rig.backupKey = rig.publicKey
        rig.publicKey = everyday
        var state = await rig.coordinator().check(force: true)
        #expect(state.phase == .downloading && state.release?.version == "0.3.0" && state.failure == nil)

        rig.backupKey = everyday
        state = await rig.coordinator().check(force: true)
        #expect(state.failure?.code == "untrustedManifest")
    }

    /// A backup key alone does not switch the updater on.
    @Test func staysInertWithOnlyABackupKey() async {
        rig.backupKey = rig.publicKey
        rig.publicKey = UpdateConfiguration.placeholderPublicKey
        let coordinator = rig.coordinator()
        #expect(await coordinator.eligibility() == .notConfigured)
        _ = await coordinator.check(force: true)
        #expect(rig.transport.requests.isEmpty)
    }

    @Test func developmentBuildsNeverCheckDownloadOrInstall() async throws {
        rig.signature.running = SignatureInfo(isValid: true, satisfiesDeveloperID: false, teamID: UpdateConfiguration.teamID)
        // Even with a verified update already staged by a release build.
        var state = UpdateState()
        state.phase = .ready
        state.release = AppRelease(version: "0.3.0", build: 21, files: ["zip": .init(name: "RimeLingo-0.3.0.zip", size: 1, sha256: "x")])
        try state.save(rig.paths)
        try makeBundle(rig.updates.stagedApp, version: "0.3.0", build: 21)
        let before = snapshot(rig.installed)
        let coordinator = rig.coordinator()
        #expect(await coordinator.eligibility() == .developmentBuild)
        _ = await coordinator.check(force: true)
        _ = await coordinator.downloadIfNeeded(userRequested: true)
        #expect(await coordinator.installIfReady(idle: rig.idle, userRequested: true) == .notReady)
        #expect(rig.transport.requests.isEmpty && snapshot(rig.installed) == before)
    }

    @Test func aBundleInAnUnwritableLocationIsNotUpdated() async {
        rig.fs.userWritable = false
        let coordinator = rig.coordinator()
        #expect(await coordinator.eligibility() == .unsupportedLocation(rig.installed.path))
        _ = await coordinator.check(force: true)
        #expect(rig.transport.requests.isEmpty)
    }

    @Test func checksDownloadsStagesInstallsAndRestartsOnce() async throws {
        let coordinator = rig.coordinator()
        var state = await coordinator.check(force: false)
        #expect(state.phase == .downloading && state.release?.version == "0.3.0" && state.lastCheck == rig.clock.now)
        #expect(snapshot(rig.installed)["Contents/MacOS/RimeLingo"] == "file 755 executable 0.2.0")

        state = await coordinator.downloadIfNeeded()
        #expect(state.phase == .ready && state.progress == nil)
        #expect(rig.transport.requestCount(rig.assetURL) == 1)
        #expect(rig.transport.constrainedNetworkAllowed == [false], "a background download stays off Low Data Mode networks")
        #expect(snapshot(rig.updates.stagedApp) == snapshot(rig.published))
        #expect(BundleTree.entry(at: rig.updates.stagingTemporary) == nil)

        // Within the day nothing is asked again, and nothing is downloaded twice.
        rig.clock.advance(3600)
        _ = await coordinator.check(force: false)
        _ = await coordinator.downloadIfNeeded()
        #expect(rig.transport.requestCount(UpdateConfiguration.manifestURL) == 1 && rig.transport.requestCount(rig.assetURL) == 1)

        // A restart of the process keeps the staged update.
        let restarted = rig.coordinator()
        rig.clock.advance(24 * 3600)
        state = await restarted.check(force: false)
        _ = await restarted.downloadIfNeeded()
        #expect(state.phase == .ready && rig.transport.requestCount(rig.assetURL) == 1)

        #expect(await restarted.installIfReady(idle: rig.typing, userRequested: false) == .deferred)
        var busy = rig.idle
        busy.secureContext = true
        #expect(await restarted.installIfReady(idle: busy, userRequested: true) == .deferred)
        #expect(snapshot(rig.installed)["Contents/MacOS/RimeLingo"] == "file 755 executable 0.2.0")

        let bundleInode = inode(rig.installed)
        #expect(await restarted.installIfReady(idle: rig.idle, userRequested: false) == .installed(version: "0.3.0"))
        #expect(snapshot(rig.installed) == snapshot(rig.published) && inode(rig.installed) == bundleInode)
        #expect(rig.state.phase == .restartPending && rig.state.installed?.notified == false && rig.state.release == nil)
        #expect(rig.process.registered == [rig.installed])
        #expect((try? BundleTree.children(of: rig.updates.root))?.sorted() == ["backup", "lock"], "archive and staging are gone")
        #expect(snapshot(rig.updates.backupApp)["Contents/MacOS/RimeLingo"] == "file 755 executable 0.2.0")

        // Until the restart happened, the answer stays the same and nothing is fetched.
        rig.process.refuseRelaunch = true
        #expect(await restarted.relaunch(pid: 77, background: true) == false)
        #expect(await restarted.installIfReady(idle: rig.typing, userRequested: false) == .installed(version: "0.3.0"))
        rig.clock.advance(48 * 3600)
        _ = await restarted.check(force: true)
        #expect(rig.state.phase == .restartPending && rig.transport.requestCount(UpdateConfiguration.manifestURL) == 2)
        #expect(await restarted.confirmRelaunch() == nil, "the old process is not the new version")
        #expect(BundleTree.entry(at: rig.updates.backupApp) != nil, "and the previous version stays until the new one runs")
        rig.process.refuseRelaunch = false
        #expect(await restarted.relaunch(pid: 77, background: true))
        #expect(rig.process.relaunches == [.init(pid: 77, bundle: rig.installed, background: true)])

        // The new process announces the update exactly once.
        let relaunched = rig.coordinator(current: AppVersion("0.3.0", build: 21))
        #expect(await relaunched.installIfReady(idle: rig.idle, userRequested: false) == .notReady, "the new process does not restart again")
        var pending = rig.state
        pending.phase = .restartPending
        try pending.save(rig.paths)
        #expect(BundleTree.entry(at: rig.updates.backupApp) != nil)
        #expect(await relaunched.confirmRelaunch() == "0.3.0")
        #expect(rig.state.phase == .idle && rig.state.installed?.notified == true)
        #expect(BundleTree.entry(at: rig.updates.backup) == nil, "the new version runs: the previous one is given up")
        #expect(await relaunched.confirmRelaunch() == nil)
        let final = await relaunched.check(force: true)
        #expect(final.phase == .idle && final.release == nil && final.failure == nil)
    }

    /// The bundle was put back to another version by hand while a restart was pending.
    @Test func aPendingRestartIsDroppedWhenTheBundleOnDiskIsNotTheInstalledVersion() async throws {
        var state = UpdateState()
        state.phase = .restartPending
        state.installed = .init(version: "0.3.0", build: 21, at: rig.clock.now, notified: false)
        try state.save(rig.paths)
        let coordinator = rig.coordinator()
        #expect(await coordinator.installIfReady(idle: rig.idle, userRequested: false) == .notReady)
        #expect(rig.state.phase == .idle && rig.process.relaunches.isEmpty)
        #expect(await coordinator.check(force: false).phase == .downloading, "and updating goes on")
    }

    @Test func refusesTheSameVersionOlderVersionsAndOlderBuilds() async throws {
        for (version, build) in [("0.2.0", 20), ("0.2.0", 19), ("0.1.9", 99), ("0.2.0", 20)] {
            try rig.publish(version: version, build: build)
            let state = await rig.coordinator().check(force: true)
            #expect(state.phase == .idle && state.release == nil && state.failure == nil && state.lastCheck != nil, "\(version) (\(build))")
        }
        _ = await rig.coordinator().downloadIfNeeded(userRequested: true)
        #expect(rig.transport.requests.allSatisfy { $0.lastPathComponent.hasPrefix("latest.json") })
        // A re-signed build of the same version is an update.
        try rig.publish(version: "0.2.0", build: 21)
        #expect(await rig.coordinator().check(force: true).phase == .downloading)
    }

    @Test func aReleaseForANewerSystemIsNotDownloaded() async throws {
        try rig.publish(minimum: "16.0")
        let state = await rig.coordinator().check(force: false)
        #expect(state.phase == .idle && state.failure?.code == "unsupportedSystem" && state.release == nil)
        #expect(await rig.coordinator().takeFailureNotice() == nil)
    }

    @Test func anUnsignedManifestIsIgnoredAndReportedOnlyAfterThreeDays() async throws {
        try rig.publish(signed: false)
        let coordinator = rig.coordinator()
        for day in 1...3 {
            let state = await coordinator.check(force: false)
            #expect(state.failure?.code == "untrustedManifest" && state.consecutiveFailures == day && state.phase == .idle)
            #expect(state.lastCheck == rig.clock.now, "counted as today's check")
            let notice = await coordinator.takeFailureNotice()
            #expect(notice == (day == 3 ? .untrustedManifest : nil))
            rig.clock.advance(24 * 3600)
        }
        _ = await coordinator.check(force: false)
        #expect(await coordinator.takeFailureNotice() == nil, "told once")
        #expect(rig.transport.requestCount(rig.assetURL) == 0)
        // A good manifest clears it.
        try rig.publish()
        rig.clock.advance(24 * 3600)
        let state = await coordinator.check(force: false)
        #expect(state.phase == .downloading && state.failure == nil)
    }

    @Test func networkErrorsAreSilentAndRetried() async throws {
        rig.transport.serve(UpdateConfiguration.manifestSignatureURL, nil)
        let coordinator = rig.coordinator()
        var state = await coordinator.check(force: false)
        #expect(state.lastCheck == nil && state.failure == nil, "not counted: the next hourly pass tries again")
        state = await coordinator.check(force: true)
        #expect(state.failure?.code == "network" && state.lastCheck == nil)
        #expect(await coordinator.takeFailureNotice() == nil)

        try rig.publish()
        rig.transport.serve(rig.assetURL, nil)
        _ = await coordinator.check(force: false)
        state = await coordinator.downloadIfNeeded()
        #expect(state.phase == .downloading && state.failure == nil)
        rig.transport.serve(rig.assetURL, rig.payload)
        #expect(await coordinator.downloadIfNeeded().phase == .ready)
    }

    @Test func aDownloadThatDoesNotMatchTheManifestIsDeleted() async throws {
        try rig.publish(sha: String(repeating: "0", count: 64))
        let coordinator = rig.coordinator()
        for attempt in 1...3 {
            _ = await coordinator.check(force: false)
            let state = await coordinator.downloadIfNeeded()
            #expect(state.phase == .failed && state.failure?.code == "checksumMismatch" && state.consecutiveFailures == attempt)
            #expect((try? BundleTree.children(of: rig.updates.root)) == ["lock"])
            #expect(rig.process.runs.isEmpty, "never extracted")
            #expect(await coordinator.takeFailureNotice() == (attempt == 3 ? .checksumMismatch : nil))
            rig.clock.advance(24 * 3600)
        }
        #expect(rig.transport.requestCount(rig.assetURL) == 3, "retried the next day")
        // A wrong size is caught the same way.
        try rig.publish()
        rig.transport.serve(rig.assetURL, rig.payload + Data("x".utf8))
        _ = await coordinator.check(force: false)
        #expect(await coordinator.downloadIfNeeded().phase == .downloading, "an oversized body is cut off like a network error")
        rig.transport.serve(rig.assetURL, Data(rig.payload.dropLast()))
        #expect(await coordinator.downloadIfNeeded().failure?.code == "checksumMismatch")
    }

    @Test func aVerifiedArchiveIsReusedInsteadOfDownloadedAgain() async throws {
        try FileManager.default.createDirectory(at: rig.updates.root, withIntermediateDirectories: true)
        try rig.payload.write(to: rig.updates.archive("RimeLingo-0.3.0.zip"))
        let coordinator = rig.coordinator()
        _ = await coordinator.check(force: false)
        #expect(await coordinator.downloadIfNeeded().phase == .ready)
        #expect(rig.transport.requestCount(rig.assetURL) == 0)
        // A corrupt one is replaced.
        var state = rig.state
        state.phase = .downloading
        try state.save(rig.paths)
        try FileManager.default.removeItem(at: rig.updates.staged)
        try Data("corrupt".utf8).write(to: rig.updates.archive("RimeLingo-0.3.0.zip"))
        #expect(await coordinator.downloadIfNeeded().phase == .ready)
        #expect(rig.transport.requestCount(rig.assetURL) == 1)
    }

    @Test func aStagedBundleThatFailsVerificationIsDeletedAndNotRetried() async throws {
        let coordinator = rig.coordinator()
        let cases: [(String, UpdateFailure, () throws -> Void)] = [
            ("layout", .badArchive("layout"), { rig.process.archiveExtras = ["extra"] }),
            ("development signature", .untrustedBundle, {
                rig.process.archiveExtras = []
                rig.signature.markDevelopmentSigned(rig.updates.stagingTemporary.appendingPathComponent("RimeLingo.app"))
            })
        ]
        for (name, expected, arrange) in cases {
            try arrange()
            _ = await coordinator.check(force: true)
            let state = await coordinator.downloadIfNeeded()
            #expect(state.phase == .failed && state.failure?.failure == expected && state.failure?.version == "0.3.0 (21)", "\(name)")
            #expect((try? BundleTree.children(of: rig.updates.root)) == ["lock"], "\(name)")
            #expect(await coordinator.takeFailureNotice() == expected, "\(name)")
        }
        #expect(await coordinator.takeFailureNotice() == nil, "one notification per failure and version")
        // The daily check does not download the same broken release again…
        let downloads = rig.transport.requestCount(rig.assetURL)
        rig.clock.advance(24 * 3600)
        #expect(await coordinator.check(force: false).phase == .failed)
        _ = await coordinator.downloadIfNeeded()
        #expect(rig.transport.requestCount(rig.assetURL) == downloads)
        // …a newer build, or "check now", does.
        #expect(await coordinator.check(force: true).phase == .downloading)
    }

    @Test func stagedBundlesAreCheckedForIdentityAndVersion() async throws {
        let coordinator = rig.coordinator()
        try makeBundle(rig.scratch.url("other/RimeLingo.app"), version: "0.3.0", build: 21, bundleID: "com.example.other")
        rig.process.archiveContents = rig.scratch.url("other/RimeLingo.app")
        _ = await coordinator.check(force: true)
        #expect(await coordinator.downloadIfNeeded().failure?.failure == .wrongBundle)
        try makeBundle(rig.scratch.url("older/RimeLingo.app"), version: "0.2.5", build: 21)
        rig.process.archiveContents = rig.scratch.url("older/RimeLingo.app")
        _ = await coordinator.check(force: true)
        #expect(await coordinator.downloadIfNeeded().failure?.failure == .versionMismatch)
    }

    @Test func withAutomaticUpdatesOffOnlyTheUserStartsAnything() async throws {
        let coordinator = rig.coordinator()
        #expect(await coordinator.setAutomaticUpdates(false).automaticUpdates == false)
        _ = await coordinator.check(force: false)
        #expect(rig.transport.requests.isEmpty)
        #expect(await coordinator.check(force: true).phase == .downloading)
        #expect(await coordinator.downloadIfNeeded().phase == .downloading)
        #expect(rig.transport.requestCount(rig.assetURL) == 0)
        #expect(await coordinator.downloadIfNeeded(userRequested: true).phase == .ready)
        #expect(rig.transport.constrainedNetworkAllowed == [true], "the user asked for this one")
        #expect(await coordinator.installIfReady(idle: rig.idle, userRequested: false) == .notReady)
        #expect(await coordinator.installIfReady(idle: rig.typing, userRequested: true) == .installed(version: "0.3.0"))
        #expect(rig.state.automaticUpdates == false)
    }

    @Test func onlyOneProcessDownloadsOrInstalls() async throws {
        let coordinator = rig.coordinator()
        _ = await coordinator.check(force: false)
        var other = UpdateLock.acquire(rig.updates)
        #expect(other != nil)
        #expect(await coordinator.downloadIfNeeded().phase == .downloading)
        #expect(rig.transport.requestCount(rig.assetURL) == 0)
        other = nil
        #expect(await coordinator.downloadIfNeeded().phase == .ready)
        other = UpdateLock.acquire(rig.updates)
        #expect(other != nil)
        let before = snapshot(rig.installed)
        #expect(await coordinator.installIfReady(idle: rig.idle, userRequested: true) == .failed(.busy))
        #expect(snapshot(rig.installed) == before && rig.state.phase == .ready)
        #expect(await coordinator.takeFailureNotice() == nil)
        withExtendedLifetime(other) {}
    }

    @Test func aFailedInstallRestoresThePreviousVersionAndReportsOnce() async throws {
        let coordinator = rig.coordinator()
        _ = await coordinator.check(force: false)
        _ = await coordinator.downloadIfNeeded()
        let before = snapshot(rig.installed)
        rig.signature.breakEvaluation(2)  // staged, backup, then the installed bundle
        #expect(await coordinator.installIfReady(idle: rig.idle, userRequested: false) == .failed(.installFailed("untrustedBundle")))
        #expect(snapshot(rig.installed) == before)
        #expect(rig.state.phase == .failed && rig.state.failure?.version == "0.3.0 (21)" && rig.state.installed == nil)
        #expect(await coordinator.takeFailureNotice() == .installFailed("untrustedBundle"))
        #expect(await coordinator.takeFailureNotice() == nil)
        #expect(await coordinator.installIfReady(idle: rig.idle, userRequested: true) == .notReady)
        #expect(rig.process.relaunches.isEmpty)
    }

    @Test func aNewerReleaseReplacesAStagedOne() async throws {
        let coordinator = rig.coordinator()
        _ = await coordinator.check(force: false)
        _ = await coordinator.downloadIfNeeded()
        try rig.publish(version: "0.4.0", build: 22)
        try makeBundle(rig.scratch.url("next/RimeLingo.app"), version: "0.4.0", build: 22)
        rig.process.archiveContents = rig.scratch.url("next/RimeLingo.app")
        rig.clock.advance(24 * 3600)
        let state = await coordinator.check(force: false)
        #expect(state.phase == .downloading && state.release?.version == "0.4.0")
        #expect(BundleTree.entry(at: rig.updates.staged) == nil && BundleTree.entry(at: rig.updates.archive("RimeLingo-0.3.0.zip")) == nil)
        #expect(await coordinator.downloadIfNeeded().phase == .ready)
        #expect(await coordinator.installIfReady(idle: rig.idle, userRequested: false) == .installed(version: "0.4.0"))
    }

    // MARK: Launch

    @Test func launchWithoutAnUpdateDirectoryTouchesNothing() {
        #expect(UpdateCoordinator.recoverAtLaunch(paths: rig.paths, bundle: rig.installed, bundleID: fixtureBundleID, signature: rig.signature, fs: rig.fs,
                                                  process: rig.process, keys: ManifestKeys(rig.publicKey)) == .none)
        #expect(!FileManager.default.fileExists(atPath: rig.paths.userDataDir.path))
    }

    @Test func launchAfterACrashWhileInstallingRestoresAndRecordsIt() async throws {
        let coordinator = rig.coordinator()
        _ = await coordinator.check(force: false)
        _ = await coordinator.downloadIfNeeded()
        let before = snapshot(rig.installed)
        // The process died half-way through the commit.
        try FileManager.default.createDirectory(at: rig.updates.backup, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: rig.installed, to: rig.updates.backupApp)
        let replacer = BundleReplacer()
        var plan = try replacer.plan(from: rig.updates.stagedApp, into: rig.installed)
        try replacer.prepare(plan)
        plan.places = Array(plan.places.prefix(3))
        try replacer.commit(plan)
        try InstallMarker(pid: 1, from: .init(version: "0.2.0", build: 20), to: .init(version: "0.3.0", build: 21),
                          bundle: rig.installed.path, phase: .commit, startedAt: rig.clock.now).write(rig.updates.marker)
        var state = rig.state
        state.phase = .installing
        try state.save(rig.paths)
        try Data("partial".utf8).write(to: rig.updates.archive("RimeLingo-0.3.0.zip.part"))

        let outcome = UpdateCoordinator.recoverAtLaunch(paths: rig.paths, bundle: rig.installed, bundleID: fixtureBundleID, signature: rig.signature,
                                                        fs: rig.fs, process: rig.process, keys: ManifestKeys(rig.publicKey),
                                                        now: { [clock = rig.clock] in clock.now })
        #expect(outcome == .rolledBack(from: "0.3.0 (21)", to: "0.2.0 (20)"))
        #expect(snapshot(rig.installed) == before)
        #expect(rig.state.phase == .failed && rig.state.failure?.code == "installFailed" && rig.state.failure?.version == "0.3.0 (21)")
        #expect(BundleTree.entry(at: rig.updates.archive("RimeLingo-0.3.0.zip.part")) == nil)
        #expect(await rig.coordinator().takeFailureNotice() == .installFailed("interrupted"))
        // An interruption says nothing against the release: it is tried again another day.
        rig.clock.advance(24 * 3600)
        let retried = await rig.coordinator().check(force: false)
        #expect(retried.phase == .downloading && retried.retry == .init(version: "0.3.0 (21)", count: 1))
    }

    @Test func launchRecoveryIsForConfiguredReleaseBuildsOnly() throws {
        // What an interrupted install of a release build leaves behind…
        try FileManager.default.createDirectory(at: rig.updates.backup, withIntermediateDirectories: true)
        try makeBundle(rig.updates.backupApp, version: "0.1.0", build: 9)
        try InstallMarker(pid: 1, from: .init(version: "0.1.0", build: 9), to: .init(version: "0.2.0", build: 20),
                          bundle: rig.installed.path, phase: .commit, startedAt: rig.clock.now).write(rig.updates.marker)
        let before = snapshot(rig.installed)
        func launch(key: String) -> RecoveryOutcome {
            UpdateCoordinator.recoverAtLaunch(paths: rig.paths, bundle: rig.installed, bundleID: fixtureBundleID, signature: rig.signature, fs: rig.fs,
                                              process: rig.process, keys: ManifestKeys(key))
        }
        // …is not acted on by a build without a manifest key,
        #expect(launch(key: UpdateConfiguration.placeholderPublicKey) == .none)
        // by a development build of the same team,
        rig.signature.running = SignatureInfo(isValid: true, satisfiesDeveloperID: false, teamID: UpdateConfiguration.teamID)
        #expect(launch(key: rig.publicKey) == .none)
        // or by an ad-hoc build.
        rig.signature.running = SignatureInfo(isValid: true, satisfiesDeveloperID: false)
        #expect(launch(key: rig.publicKey) == .none)
        #expect(snapshot(rig.installed) == before && rig.fs.count(.rename) == 0 && rig.fs.count(.remove) == 0)
        #expect(BundleTree.entry(at: rig.updates.marker) != nil && rig.signature.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: UpdateState.file(rig.paths).path))
    }

    /// Info.plist and the seal are the new version's, the executable still the old one:
    /// the process started from that mix has no valid signature of its own.
    @Test func launchFromAMixedBundleRestoresDespiteTheBrokenRunningSignature() async throws {
        let coordinator = rig.coordinator()
        _ = await coordinator.check(force: false)
        _ = await coordinator.downloadIfNeeded()
        let before = snapshot(rig.installed)
        try FileManager.default.createDirectory(at: rig.updates.backup, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: rig.installed, to: rig.updates.backupApp)
        let replacer = BundleReplacer()
        var plan = try replacer.plan(from: rig.updates.stagedApp, into: rig.installed)
        try replacer.prepare(plan)
        plan.places = Array(plan.places.prefix(3))
        try replacer.commit(plan)
        try InstallMarker(pid: 1, from: .init(version: "0.2.0", build: 20), to: .init(version: "0.3.0", build: 21),
                          bundle: rig.installed.path, phase: .commit, startedAt: rig.clock.now).write(rig.updates.marker)
        var state = rig.state
        state.phase = .installing
        try state.save(rig.paths)
        rig.signature.running = SignatureInfo(isValid: false, satisfiesDeveloperID: false, teamID: UpdateConfiguration.teamID)
        func launch(key: String? = nil) -> RecoveryOutcome {
            UpdateCoordinator.recoverAtLaunch(paths: rig.paths, bundle: rig.installed, bundleID: fixtureBundleID, signature: rig.signature,
                                              fs: rig.fs, process: rig.process, keys: ManifestKeys(key ?? rig.publicKey),
                                              now: { [clock = rig.clock] in clock.now })
        }
        // Still not without a manifest key or where the bundle cannot be replaced.
        let mixed = snapshot(rig.installed)
        #expect(launch(key: UpdateConfiguration.placeholderPublicKey) == .none)
        rig.fs.userWritable = false
        #expect(launch() == .none)
        rig.fs.userWritable = true
        #expect(snapshot(rig.installed) == mixed && BundleTree.entry(at: rig.updates.marker) != nil)

        #expect(launch() == .rolledBack(from: "0.3.0 (21)", to: "0.2.0 (20)"))
        #expect(snapshot(rig.installed) == before)
        #expect(BundleTree.entry(at: rig.updates.marker) == nil && BundleTree.entry(at: rig.updates.backup) == nil)
        #expect(rig.state.phase == .failed && rig.state.failure?.code == "installFailed" && rig.state.failure?.version == "0.3.0 (21)")
    }

    @Test func aBrokenRunningSignatureRecoversOnlyAnInstallCutShortInThisBundle() throws {
        try FileManager.default.createDirectory(at: rig.updates.backup, withIntermediateDirectories: true)
        try makeBundle(rig.updates.backupApp, version: "0.1.0", build: 9)
        let before = snapshot(rig.installed)
        func launch(phase: InstallMarker.Phase, bundle: URL) throws -> RecoveryOutcome {
            try InstallMarker(pid: 1, from: .init(version: "0.1.0", build: 9), to: .init(version: "0.2.0", build: 20),
                              bundle: bundle.path, phase: phase, startedAt: rig.clock.now).write(rig.updates.marker)
            return UpdateCoordinator.recoverAtLaunch(paths: rig.paths, bundle: rig.installed, bundleID: fixtureBundleID, signature: rig.signature,
                                                     fs: rig.fs, process: rig.process, keys: ManifestKeys(rig.publicKey))
        }
        rig.signature.running = .unsigned
        // Nothing was replaced yet: the broken signature has another cause.
        #expect(try launch(phase: .prepare, bundle: rig.installed) == .none)
        // The marker of an install into another copy.
        #expect(try launch(phase: .commit, bundle: rig.scratch.url("elsewhere/RimeLingo.app")) == .none)
        // A development build is validly signed and leaves a release's marker alone.
        rig.signature.running = SignatureInfo(isValid: true, satisfiesDeveloperID: false, teamID: UpdateConfiguration.teamID)
        for phase in [InstallMarker.Phase.commit, .cleanup, .rollback] {
            #expect(try launch(phase: phase, bundle: rig.installed) == .none)
        }
        #expect(snapshot(rig.installed) == before && rig.signature.isEmpty)
        #expect(BundleTree.entry(at: rig.updates.marker) != nil && BundleTree.entry(at: rig.updates.backupApp) != nil)
        #expect(!FileManager.default.fileExists(atPath: UpdateState.file(rig.paths).path))
        // A backup that is no release of ours is not restored by anyone.
        rig.signature.running = .unsigned
        rig.signature.markDevelopmentSigned(rig.updates.backupApp)
        #expect(try launch(phase: .commit, bundle: rig.installed) == .failed("untrustedBundle"))
        #expect(snapshot(rig.installed) == before)
    }

    @Test func launchAfterACrashBehindACompleteInstallGoesForward() async throws {
        let coordinator = rig.coordinator()
        _ = await coordinator.check(force: false)
        _ = await coordinator.downloadIfNeeded()
        try FileManager.default.createDirectory(at: rig.updates.backup, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: rig.installed, to: rig.updates.backupApp)
        try BundleReplacer().replace(from: rig.updates.stagedApp, into: rig.installed)
        try InstallMarker(pid: 1, from: .init(version: "0.2.0", build: 20), to: .init(version: "0.3.0", build: 21),
                          bundle: rig.installed.path, phase: .cleanup, startedAt: rig.clock.now).write(rig.updates.marker)
        var state = rig.state
        state.phase = .installing
        try state.save(rig.paths)

        let outcome = UpdateCoordinator.recoverAtLaunch(paths: rig.paths, bundle: rig.installed, bundleID: fixtureBundleID, signature: rig.signature,
                                                        fs: rig.fs, process: rig.process, keys: ManifestKeys(rig.publicKey), now: { [clock = rig.clock] in clock.now })
        #expect(outcome == .completed(version: "0.3.0", build: 21))
        #expect(snapshot(rig.installed) == snapshot(rig.published))
        #expect(rig.state.phase == .restartPending && rig.state.failure == nil && rig.state.release == nil)
        #expect(rig.state.installed == .init(version: "0.3.0", build: 21, at: rig.clock.now, notified: false))
        #expect((try? BundleTree.children(of: rig.updates.root))?.sorted() == ["backup", "lock"])
        // The process that starts now is the new version and says so once.
        let relaunched = rig.coordinator(current: AppVersion("0.3.0", build: 21))
        #expect(await relaunched.confirmRelaunch() == "0.3.0")
        #expect(rig.state.phase == .idle)
        #expect((try? BundleTree.children(of: rig.updates.root)) == ["lock"])
    }

    /// Between an install and the first launch of the new version the backup has no marker.
    @Test func launchKeepsTheBackupOfAnUnconfirmedInstallAndRemovesAStaleOne() async throws {
        let coordinator = rig.coordinator()
        _ = await coordinator.check(force: false)
        _ = await coordinator.downloadIfNeeded()
        #expect(await coordinator.installIfReady(idle: rig.idle, userRequested: false) == .installed(version: "0.3.0"))
        let bundle = snapshot(rig.installed), kept = snapshot(rig.updates.backupApp)
        func launch() -> RecoveryOutcome {
            UpdateCoordinator.recoverAtLaunch(paths: rig.paths, bundle: rig.installed, bundleID: fixtureBundleID, signature: rig.signature,
                                              fs: rig.fs, process: rig.process, keys: ManifestKeys(rig.publicKey))
        }
        #expect(launch() == .none)
        #expect(rig.state.phase == .restartPending && snapshot(rig.installed) == bundle && snapshot(rig.updates.backupApp) == kept)
        // While another process holds the lock the new version confirms without removing it…
        var other = UpdateLock.acquire(rig.updates)
        #expect(other != nil)
        #expect(await rig.coordinator(current: AppVersion("0.3.0", build: 21)).confirmRelaunch() == "0.3.0")
        #expect(rig.state.phase == .idle && BundleTree.entry(at: rig.updates.backupApp) != nil)
        withExtendedLifetime(other) {}
        other = nil
        // …and the next launch does, the restart being over.
        #expect(launch() == .none)
        #expect(BundleTree.entry(at: rig.updates.backup) == nil && snapshot(rig.installed) == bundle)
    }

    /// No room for the backup, an install cut short: the release is not to blame.
    @Test func aFailureOfThisMacsMakingIsRetriedOnLaterDaysButNotForever() async throws {
        let coordinator = rig.coordinator()
        for attempt in 0...UpdateState.maxLocalRetries {
            #expect(await coordinator.check(force: false).phase == .downloading, "attempt \(attempt)")
            #expect(await coordinator.downloadIfNeeded().phase == .ready)
            rig.fs.fail(.copy, at: 0)  // the backup
            guard case let .failed(failure) = await coordinator.installIfReady(idle: rig.idle, userRequested: false) else {
                Issue.record("attempt \(attempt): the install was meant to fail")
                return
            }
            #expect(failure.code == "backupFailed" && failure.isLocal)
            rig.fs.reset()
            #expect(rig.state.phase == .failed && rig.state.failure?.version == "0.3.0 (21)")
            #expect(BundleTree.entry(at: rig.updates.archive("RimeLingo-0.3.0.zip")) != nil, "kept for the retry")
            // Not again within hours, even when a check is due.
            var state = rig.state
            state.lastCheck = nil
            try state.save(rig.paths)
            #expect(await coordinator.check(force: false).phase == .failed)
            rig.clock.advance(24 * 3600)
        }
        #expect(await coordinator.check(force: false).phase == .failed, "three retries, then only on request")
        #expect(rig.transport.requestCount(rig.assetURL) == 1, "the archive was downloaded once")
        #expect(await coordinator.takeFailureNotice() != nil)
        #expect(await coordinator.takeFailureNotice() == nil, "told once, not once per retry")
        #expect(await coordinator.check(force: true).phase == .downloading)
    }

    /// The settings app can outlive an update of the bundle it runs from.
    @Test func aProcessOlderThanTheBundleOnDiskMeasuresAgainstTheBundle() async throws {
        try FileManager.default.removeItem(at: rig.installed)
        try makeBundle(rig.installed, version: "0.3.0", build: 21)
        let stale = rig.coordinator(current: AppVersion("0.2.0", build: 20))
        var state = await stale.check(force: true)
        #expect(state.phase == .idle && state.release == nil, "the published version is already on disk")
        // A replayed manifest of a release between the two is no update either.
        try rig.publish(version: "0.2.5", build: 21)
        state = await stale.check(force: true)
        #expect(state.phase == .idle && state.release == nil)
        _ = await stale.downloadIfNeeded(userRequested: true)
        #expect(rig.transport.requests.allSatisfy { $0.lastPathComponent.hasPrefix("latest.json") })
        // A staged older release is refused at the last moment as well.
        var ready = UpdateState()
        ready.phase = .ready
        ready.release = AppRelease(version: "0.2.5", build: 21, files: ["zip": .init(name: "RimeLingo-0.2.5.zip", size: 1, sha256: "x")])
        try ready.save(rig.paths)
        try makeBundle(rig.updates.stagedApp, version: "0.2.5", build: 21)
        let before = snapshot(rig.installed)
        #expect(await stale.installIfReady(idle: rig.idle, userRequested: true) == .failed(.notNewer))
        #expect(snapshot(rig.installed) == before)
    }

    @Test func launchWithAnUnreadableMarkerKeepsTheBackup() async throws {
        let coordinator = rig.coordinator()
        _ = await coordinator.check(force: false)
        _ = await coordinator.downloadIfNeeded()
        let before = snapshot(rig.installed)
        // An install was cut short and its marker damaged: the backup may be the only
        // copy of the previous version.
        try FileManager.default.createDirectory(at: rig.updates.backup, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: rig.installed, to: rig.updates.backupApp)
        try Data("{".utf8).write(to: rig.updates.marker)
        var state = rig.state
        state.phase = .installing
        try state.save(rig.paths)
        func launch() -> RecoveryOutcome {
            UpdateCoordinator.recoverAtLaunch(paths: rig.paths, bundle: rig.installed, bundleID: fixtureBundleID, signature: rig.signature,
                                              fs: rig.fs, process: rig.process, keys: ManifestKeys(rig.publicKey))
        }
        // Not only at the launch that finds it.
        for _ in 0..<2 {
            #expect(launch() == .none)
            #expect(BundleTree.entry(at: rig.updates.backupApp)?.kind == .directory)
            #expect(snapshot(rig.installed) == before)
        }
        #expect(rig.state.phase == .ready)
        // The next install starts over with a backup and a marker of its own.
        #expect(await rig.coordinator().installIfReady(idle: rig.idle, userRequested: true) == .installed(version: "0.3.0"))
        #expect(BundleTree.entry(at: rig.updates.marker) == nil)
        #expect(rig.signature.evaluate(bundle: rig.updates.backupApp).version == "0.2.0")
    }

    @Test func launchAfterAnInterruptedDownloadOrInstallResumes() async throws {
        let coordinator = rig.coordinator()
        _ = await coordinator.check(force: false)
        _ = await coordinator.downloadIfNeeded()
        var state = rig.state
        state.phase = .installing
        state.progress = 0.4
        try state.save(rig.paths)
        try FileManager.default.createDirectory(at: rig.updates.stagingTemporary, withIntermediateDirectories: true)
        #expect(UpdateCoordinator.recoverAtLaunch(paths: rig.paths, bundle: rig.installed, bundleID: fixtureBundleID, signature: rig.signature, fs: rig.fs,
                                                  process: rig.process, keys: ManifestKeys(rig.publicKey)) == .none)
        #expect(rig.state.phase == .ready && rig.state.progress == nil)
        #expect(BundleTree.entry(at: rig.updates.stagingTemporary) == nil)
        // The staged bundle vanished (cache cleaned): download again instead of failing.
        try FileManager.default.removeItem(at: rig.updates.staged)
        _ = UpdateCoordinator.recoverAtLaunch(paths: rig.paths, bundle: rig.installed, bundleID: fixtureBundleID, signature: rig.signature, fs: rig.fs, process: rig.process, keys: ManifestKeys(rig.publicKey))
        #expect(rig.state.phase == .downloading)
        // While another process works, nothing is changed.
        let other = try #require(UpdateLock.acquire(rig.updates))
        state.phase = .installing
        try state.save(rig.paths)
        _ = UpdateCoordinator.recoverAtLaunch(paths: rig.paths, bundle: rig.installed, bundleID: fixtureBundleID, signature: rig.signature, fs: rig.fs, process: rig.process, keys: ManifestKeys(rig.publicKey))
        #expect(rig.state.phase == .installing)
        withExtendedLifetime(other) {}
    }
}
