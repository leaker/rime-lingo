import Foundation
@testable import RimeLingoCore
import Synchronization
import Testing

@Suite struct BundleReplacerTests {
    let scratch = Scratch()
    var installed: URL { scratch.url("Input Methods/RimeLingo.app") }
    var staged: URL { scratch.url("staged/RimeLingo.app") }

    func fixtures(old: [String: String] = [:], new: [String: String] = [:]) throws {
        try makeBundle(installed, version: "0.2.0", build: 20, extra: old)
        try makeBundle(staged, version: "0.3.0", build: 21, extra: new)
    }

    @Test func addsOverwritesAndRemovesWithoutRecreatingTheBundle() throws {
        try fixtures(old: ["Contents/Resources/removed.txt": "old", "Contents/Resources/old-dir/a.txt": "old"],
                     new: ["Contents/Resources/added.txt": "new", "Contents/PlugIns/New.bundle/Contents/MacOS/New": "plugin"])
        let fm = FileManager.default
        // A link whose target changes, and one that stays.
        try fm.removeItem(at: staged.appendingPathComponent("Contents/Frameworks/librime.dylib"))
        try fm.createSymbolicLink(atPath: staged.appendingPathComponent("Contents/Frameworks/librime.dylib").path, withDestinationPath: "librime.2.dylib")
        try fm.removeItem(at: staged.appendingPathComponent("Contents/Frameworks/librime.1.dylib"))
        try Data("library 2".utf8).write(to: staged.appendingPathComponent("Contents/Frameworks/librime.2.dylib"))
        // Same content, but no longer executable.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staged.appendingPathComponent("Contents/Helpers/rimelingo").path)
        try Data("cli 0.2.0".utf8).write(to: staged.appendingPathComponent("Contents/Helpers/rimelingo"))

        let bundleInode = inode(installed), contentsInode = inode(installed.appendingPathComponent("Contents"))
        let dictionaryInode = inode(installed.appendingPathComponent("Contents/SharedSupport/dictionary.bin"))
        let executableInode = inode(installed.appendingPathComponent("Contents/MacOS/RimeLingo"))

        let replacer = BundleReplacer()
        let plan = try replacer.plan(from: staged, into: installed)
        #expect(plan.unchanged == 1, "only the dictionary is identical")
        #expect(Set(plan.stale) == ["Contents/Resources/removed.txt", "Contents/Resources/old-dir", "Contents/Frameworks/librime.1.dylib"])
        try replacer.prepare(plan)
        // Until the commit the bundle still is the old version.
        #expect(try String(contentsOf: installed.appendingPathComponent("Contents/MacOS/RimeLingo"), encoding: .utf8) == "executable 0.2.0")
        try replacer.commit(plan)
        try replacer.removeStale(plan)

        #expect(snapshot(installed) == snapshot(staged))
        #expect(inode(installed) == bundleInode && inode(installed.appendingPathComponent("Contents")) == contentsInode)
        #expect(inode(installed.appendingPathComponent("Contents/SharedSupport/dictionary.bin")) == dictionaryInode, "unchanged files are not touched")
        #expect(inode(installed.appendingPathComponent("Contents/MacOS/RimeLingo")) != executableInode, "changed files are replaced, not rewritten")
        #expect(fm.isExecutableFile(atPath: installed.appendingPathComponent("Contents/MacOS/RimeLingo").path))
        #expect(!fm.isExecutableFile(atPath: installed.appendingPathComponent("Contents/Helpers/rimelingo").path))
        #expect(temporaries(in: installed).isEmpty)
        // The source is only read.
        #expect(snapshot(staged)["Contents/Resources/added.txt"] == "file 644 new")
    }

    @Test func handlesItemsThatChangeType() throws {
        try fixtures(old: ["Contents/Resources/becomes-dir": "file", "Contents/Resources/becomes-file/inner.txt": "x"],
                     new: ["Contents/Resources/becomes-dir/inner.txt": "y", "Contents/Resources/becomes-file": "file"])
        let fm = FileManager.default
        // link → directory and file → link
        try fm.createSymbolicLink(atPath: installed.appendingPathComponent("Contents/Resources/link-to-dir").path, withDestinationPath: "becomes-file")
        try fm.createDirectory(at: staged.appendingPathComponent("Contents/Resources/link-to-dir"), withIntermediateDirectories: true)
        try Data("z".utf8).write(to: staged.appendingPathComponent("Contents/Resources/link-to-dir/z.txt"))
        try Data("was a file".utf8).write(to: installed.appendingPathComponent("Contents/Resources/file-to-link"))
        try fm.createSymbolicLink(atPath: staged.appendingPathComponent("Contents/Resources/file-to-link").path, withDestinationPath: "becomes-file")

        try BundleReplacer().replace(from: staged, into: installed)
        #expect(snapshot(installed) == snapshot(staged))
        #expect(temporaries(in: installed).isEmpty)
    }

    @Test func mainExecutableIsRenamedLast() throws {
        try fixtures(new: ["Contents/Resources/added.txt": "new"])
        let plan = try BundleReplacer().plan(from: staged, into: installed)
        let ranks = plan.places.map { BundleReplacer.rank($0.path) }
        #expect(ranks == ranks.sorted())
        #expect(plan.places.last?.path == "Contents/MacOS/RimeLingo")
        #expect(plan.places.first?.path == "Contents/Resources")
        let order = plan.places.map(\.path)
        #expect(order.firstIndex(of: "Contents/Info.plist")! > order.firstIndex(of: "Contents/Frameworks/librime.1.dylib")!)
        #expect(order.firstIndex(of: "Contents/_CodeSignature/CodeResources")! > order.firstIndex(of: "Contents/Info.plist")!)
    }

    @Test func aFailedPrepareLeavesTheBundleUntouched() throws {
        try fixtures(new: ["Contents/Resources/added.txt": "new"])
        let before = snapshot(installed)
        let fs = FaultyFileSystem()
        let replacer = BundleReplacer(fs: fs)
        let plan = try replacer.plan(from: staged, into: installed)
        fs.fail(.copy, at: 3)
        #expect(throws: FaultyFileSystem.Injected.self) { try replacer.prepare(plan) }
        #expect(snapshot(installed) == before)
    }

    @Test func leftoversOfAnInterruptedRunAreIgnoredAndRemoved() throws {
        try fixtures()
        try Data("junk".utf8).write(to: installed.appendingPathComponent("Contents/MacOS/.rlu-OLD-RimeLingo"))
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents/.rlu-OLD-old-Resources/x"), withIntermediateDirectories: true)
        let replacer = BundleReplacer()
        #expect(try replacer.plan(from: staged, into: installed).stale.allSatisfy { !$0.contains(".rlu-") })
        try replacer.replace(from: staged, into: installed)
        #expect(snapshot(installed) == snapshot(staged))
    }

    /// The reason nothing is written in place: a running executable keeps its old inode.
    @Test func replacingARunningExecutableDoesNotKillIt() throws {
        try fixtures()
        let executable = installed.appendingPathComponent("Contents/MacOS/RimeLingo")
        try FileManager.default.removeItem(at: executable)
        // Built here: macOS kills a copy of a system binary such as /bin/sleep soon after
        // it starts, whatever is done to its file.
        try buildSleeper(at: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        // Let it finish launching: the question is what happens to code that already runs.
        Thread.sleep(forTimeInterval: 0.3)
        #expect(process.isRunning)
        try BundleReplacer().replace(from: staged, into: installed)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(process.isRunning)
        #expect(try String(contentsOf: executable, encoding: .utf8) == "executable 0.3.0")
    }
}

@Suite struct UpdateInstallerTests {
    let scratch = Scratch()
    let signature = FakeSignature()
    let fs = FaultyFileSystem()
    let process = FakeProcess()
    let release = AppRelease(version: "0.3.0", build: 21, files: ["zip": .init(name: "RimeLingo-0.3.0.zip", size: 1, sha256: "x")])
    let current = AppVersion("0.2.0", build: 20)
    var installed: URL { scratch.url("Input Methods/RimeLingo.app") }
    var paths: UpdatePaths { UpdatePaths(root: scratch.url("cache/updates")) }
    var installer: UpdateInstaller { UpdateInstaller(paths: paths, signature: signature, fs: fs, process: process) }

    init() throws {
        try makeBundle(installed, version: "0.2.0", build: 20, extra: ["Contents/Resources/removed.txt": "old"])
        try makeBundle(paths.stagedApp, version: "0.3.0", build: 21, extra: ["Contents/Resources/added.txt": "new"])
        try Data("zip".utf8).write(to: paths.archive("RimeLingo-0.3.0.zip"))
    }

    func install() -> UpdateFailure? {
        do {
            try installer.install(staged: paths.stagedApp, release: release, into: installed, current: current, bundleID: fixtureBundleID)
            return nil
        } catch { return error as? UpdateFailure ?? .installFailed("unexpected \(error)") }
    }

    func backUp() throws {
        try FileManager.default.createDirectory(at: paths.backup, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: installed, to: paths.backupApp)
    }

    func exists(_ url: URL) -> Bool { BundleTree.entry(at: url) != nil }

    @Test func installsInPlaceAndCleansUp() throws {
        let expected = snapshot(paths.stagedApp), previous = snapshot(installed)
        let bundleInode = inode(installed)
        #expect(install() == nil)
        #expect(snapshot(installed) == expected)
        #expect(inode(installed) == bundleInode)
        #expect(process.registered == [installed])
        #expect(!exists(paths.marker) && !exists(paths.staged) && !exists(paths.archive("RimeLingo-0.3.0.zip")))
        #expect(snapshot(paths.backupApp) == previous, "the previous version is kept until the new one has started")
    }

    /// A version that never confirmed leaves its backup behind; the next install must not
    /// be stopped by it, nor keep it in place of the version it replaces.
    @Test func theNextInstallReplacesABackupKeptByTheLastOne() throws {
        #expect(install() == nil)
        #expect(snapshot(paths.backupApp)["Contents/MacOS/RimeLingo"] == "file 755 executable 0.2.0")
        let previous = snapshot(installed)
        try makeBundle(paths.stagedApp, version: "0.4.0", build: 22)
        let next = AppRelease(version: "0.4.0", build: 22, files: ["zip": .init(name: "RimeLingo-0.4.0.zip", size: 1, sha256: "x")])
        try installer.install(staged: paths.stagedApp, release: next, into: installed, current: AppVersion("0.3.0", build: 21),
                              bundleID: fixtureBundleID)
        #expect(snapshot(installed)["Contents/MacOS/RimeLingo"] == "file 755 executable 0.4.0")
        #expect(snapshot(paths.backupApp) == previous && !exists(paths.marker))
    }

    @Test func aKeptBackupIsDiscardedOnlyWhenNoInstallIsUnfinished() throws {
        try backUp()
        try marker(.commit)
        installer.discardKeptBackup()
        #expect(exists(paths.backupApp), "with a marker it is what a rollback needs")
        try FileManager.default.removeItem(at: paths.marker)
        installer.discardKeptBackup()
        #expect(!exists(paths.backup))
    }

    /// A colour tag or custom icon given in Finder: strict validation refuses a bundle
    /// whose directory carries it, so it must be gone before the backup is copied.
    @Test func finderInformationOnTheInstalledBundleDoesNotBlockTheUpdate() throws {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[9] = 0x0C
        #expect(setxattr(installed.path, XATTR_FINDERINFO_NAME, &finderInfo, finderInfo.count, 0, 0) == 0)
        #expect(extendedAttributes(of: installed).contains(XATTR_FINDERINFO_NAME))
        let expected = snapshot(paths.stagedApp)
        let installed = installed, backupApp = paths.backupApp
        let carriedIntoBackup = Mutex<[Bool]>([])
        fs.observe { operation, url in
            guard operation == .copy, url == backupApp else { return }
            carriedIntoBackup.withLock { $0.append(extendedAttributes(of: installed).contains(XATTR_FINDERINFO_NAME)) }
        }
        #expect(install() == nil)
        #expect(carriedIntoBackup.withLock { $0 } == [false], "removed before the backup was copied")
        #expect(!extendedAttributes(of: installed).contains(XATTR_FINDERINFO_NAME))
        #expect(snapshot(installed) == expected)
    }

    @Test func aBundleWhoseFinderInformationCannotBeRemovedIsLeftUntouched() {
        let before = snapshot(installed)
        fs.fail(.removeAttribute, at: 0)
        #expect(install()?.code == "backupFailed")
        #expect(snapshot(installed) == before && fs.count(.copy) == 0 && !exists(paths.backup) && !exists(paths.marker))
    }

    @Test func aStagedBundleTamperedWithAfterStagingIsRefusedBeforeAnythingChanges() {
        let before = snapshot(installed)
        signature.breakEvaluation(0)
        #expect(install() == .untrustedBundle)
        #expect(snapshot(installed) == before && fs.count(.copy) == 0 && !exists(paths.backup) && !exists(paths.marker))
        signature.markDevelopmentSigned(paths.stagedApp)
        #expect(install() == .untrustedBundle)
        #expect(snapshot(installed) == before)
    }

    @Test func aFailedBackupLeavesTheBundleUntouched() {
        let before = snapshot(installed)
        fs.fail(.copy, at: 0)
        #expect(install()?.code == "backupFailed")
        #expect(snapshot(installed) == before && !exists(paths.backup) && !exists(paths.marker))
        #expect(exists(paths.stagedApp), "the staged update is kept for the caller to decide")
    }

    @Test func aFailureWhilePreparingLeavesTheBundleUntouched() {
        let before = snapshot(installed)
        fs.fail(.copy, at: 2)  // 0 is the backup
        #expect(install()?.code == "installFailed")
        #expect(snapshot(installed) == before && !exists(paths.marker) && !exists(paths.backup))
        #expect(process.registered.isEmpty)
    }

    @Test func aFailureAtAnyRenameRollsBackToThePreviousVersion() throws {
        let before = snapshot(installed)
        let renames = try BundleReplacer().plan(from: paths.stagedApp, into: installed).places.count
        #expect(renames >= 6)
        for index in 0..<renames {
            fs.fail(.rename, at: index)
            #expect(install()?.code == "installFailed", "rename \(index)")
            #expect(snapshot(installed) == before, "rename \(index)")
            #expect(!exists(paths.marker) && !exists(paths.backup), "rename \(index)")
            fs.reset()
        }
        // The same staged bundle still installs afterwards.
        #expect(install() == nil)
        #expect(snapshot(installed)["Contents/MacOS/RimeLingo"] == "file 755 executable 0.3.0")
    }

    @Test func aFailureWhileRemovingStaleFilesRollsBack() {
        let before = snapshot(installed)
        fs.fail(.remove, at: 1)  // 0 clears an old backup
        #expect(install()?.code == "installFailed")
        #expect(snapshot(installed) == before)
    }

    @Test func aBrokenSignatureAfterInstallingRollsBack() {
        let before = snapshot(installed)
        signature.breakEvaluation(2)  // 0: staged, 1: backup, 2: installed bundle after the commit
        #expect(install() == .installFailed("untrustedBundle"))
        #expect(snapshot(installed) == before)
        #expect(process.registered == [installed], "the restored copy is registered again")
        #expect(signature.count == 5, "staged, backup, installed, backup before restoring, restored")
    }

    @Test func aFailedRollbackKeepsTheBackupAndTheMarker() throws {
        fs.fail(.rename, at: 3, persistent: true)
        #expect(install()?.code == "rollbackFailed")
        #expect(InstallMarker.read(paths.marker)?.phase == .rollback)
        #expect(snapshot(paths.backupApp)["Contents/MacOS/RimeLingo"] == "file 755 executable 0.2.0")
        // The next launch finishes the job.
        fs.reset()
        #expect(installer.recoverIfNeeded(bundle: installed, bundleID: fixtureBundleID) == .rolledBack(from: "0.3.0 (21)", to: "0.2.0 (20)"))
        #expect(snapshot(installed)["Contents/MacOS/RimeLingo"] == "file 755 executable 0.2.0")
        #expect(snapshot(installed)["Contents/Resources/removed.txt"] == "file 644 old")
        #expect(temporaries(in: installed).isEmpty && !exists(paths.marker) && !exists(paths.backup))
    }

    /// The files of the bundle may only start to change once the marker says so: a crash
    /// with the marker still at `prepare` deletes the backup.
    @Test func theMarkerNamesEachPhaseBeforeItsFirstStep() throws {
        let bundlePath = installed.path + "/", paths = paths
        let seen = Seen()
        fs.observe { operation, url in
            guard url.path.hasPrefix(bundlePath) else { return }
            let temporary = url.lastPathComponent.hasPrefix(BundleTree.temporaryPrefix)
            let step: String? = switch operation {
            case .copy, .symlink: "prepare"
            case .rename where !temporary: "commit"
            case .remove where !temporary: "cleanup"
            default: nil
            }
            guard let step, seen.insert(step) else { return }
            seen.record(step, phase: InstallMarker.read(paths.marker)?.phase, backup: BundleTree.entry(at: paths.backupApp) != nil)
        }
        #expect(install() == nil)
        #expect(seen.phases == ["prepare": .prepare, "commit": .commit, "cleanup": .cleanup])
        #expect(seen.backups == ["prepare": true, "commit": true, "cleanup": true], "the backup exists before anything changes")
    }

    @Test func theMarkerRecordsTheVersionOnDiskNotTheProcessVersion() throws {
        fs.fail(.rename, at: 3, persistent: true)
        do {
            try installer.install(staged: paths.stagedApp, release: release, into: installed,
                                  current: AppVersion("0.1.0", build: 7), bundleID: fixtureBundleID)
            Issue.record("the install was meant to fail")
        } catch {}
        #expect(InstallMarker.read(paths.marker)?.from == .init(version: "0.2.0", build: 20))
        fs.reset()
        #expect(installer.recoverIfNeeded(bundle: installed, bundleID: fixtureBundleID) == .rolledBack(from: "0.3.0 (21)", to: "0.2.0 (20)"))
    }

    @Test func aBundleOnDiskThatIsAlreadyThatVersionIsNotInstalledOver() throws {
        // The process is older than its files: something else updated them meanwhile.
        try FileManager.default.removeItem(at: installed)
        try makeBundle(installed, version: "0.3.0", build: 21)
        let before = snapshot(installed)
        #expect(install() == .notNewer)
        #expect(snapshot(installed) == before && !exists(paths.marker) && !exists(paths.backup))
    }

    @Test func anInstalledBundleThatIsNotAReleaseIsNotUpdated() {
        let before = snapshot(installed)
        signature.markDevelopmentSigned(paths.backupApp)
        #expect(install() == .backupFailed("untrusted"))
        #expect(snapshot(installed) == before && !exists(paths.marker) && !exists(paths.backup))
        #expect(fs.count(.rename) == 0)
    }

    @Test func anInstallThatCouldNotBeUndoneIsFinishedBeforeAnyNewInstall() throws {
        let before = snapshot(installed), expected = snapshot(paths.stagedApp)
        fs.fail(.rename, at: 3, persistent: true)
        #expect(install()?.code == "rollbackFailed")
        #expect(snapshot(installed) != before, "a mixed bundle")
        // Installing again while the fault lasts must not turn that mixed bundle into the backup.
        fs.fail(.rename, at: 0, persistent: true)
        #expect(install()?.code == "rollbackFailed")
        #expect(snapshot(paths.backupApp) == before, "the only good copy is still there")
        #expect(exists(paths.marker))
        // Once it works again the previous version comes back first, then the update goes in.
        fs.reset()
        #expect(install() == nil)
        #expect(snapshot(installed) == expected)
        #expect(process.registered == [installed, installed], "restored, then installed")
        #expect(!exists(paths.marker) && snapshot(paths.backupApp) == before)
    }

    // MARK: Crash recovery

    func marker(_ phase: InstallMarker.Phase, bundle: URL? = nil) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try InstallMarker(pid: 1, from: .init(version: "0.2.0", build: 20), to: .init(version: "0.3.0", build: 21),
                          bundle: (bundle ?? installed).path, phase: phase, startedAt: Date()).write(paths.marker)
    }

    @Test func noMarkerMeansNothingToRecover() {
        #expect(installer.recoverIfNeeded(bundle: installed, bundleID: fixtureBundleID) == .none)
        #expect(!exists(paths.lock), "a launch without an interrupted install touches nothing")
    }

    /// What a finished install leaves until the new version has started: not an
    /// interrupted install, and nothing to restore or remove.
    @Test func aBackupWithoutAMarkerIsLeftAlone() throws {
        #expect(install() == nil)
        let bundle = snapshot(installed), kept = snapshot(paths.backupApp)
        fs.reset()
        #expect(installer.recoverIfNeeded(bundle: installed, bundleID: fixtureBundleID) == .none)
        #expect(snapshot(installed) == bundle && snapshot(paths.backupApp) == kept)
        #expect(fs.count(.remove) == 0 && fs.count(.rename) == 0 && signature.count == 3, "nothing evaluated after the install")
    }

    @Test func aCrashWhilePreparingOnlyNeedsCleaning() throws {
        let before = snapshot(installed)
        try backUp()
        let replacer = BundleReplacer()
        try replacer.prepare(try replacer.plan(from: paths.stagedApp, into: installed))
        #expect(!temporaries(in: installed).isEmpty)
        try marker(.prepare)
        #expect(installer.recoverIfNeeded(bundle: installed, bundleID: fixtureBundleID) == .cleaned)
        #expect(snapshot(installed) == before && !exists(paths.marker) && !exists(paths.backup))
        #expect(exists(paths.stagedApp), "the verified update is still there to install")
    }

    @Test func aCrashInTheMiddleOfTheCommitIsRolledBack() throws {
        let before = snapshot(installed)
        for phase in [InstallMarker.Phase.commit, .cleanup, .rollback] {
            try backUp()
            let replacer = BundleReplacer()
            var plan = try replacer.plan(from: paths.stagedApp, into: installed)
            try replacer.prepare(plan)
            // Half of the renames happened, then the process died.
            plan.places = Array(plan.places.prefix(plan.places.count / 2))
            try replacer.commit(plan)
            #expect(snapshot(installed) != before)
            try marker(phase)
            #expect(installer.recoverIfNeeded(bundle: installed, bundleID: fixtureBundleID) == .rolledBack(from: "0.3.0 (21)", to: "0.2.0 (20)"), "\(phase)")
            #expect(snapshot(installed) == before, "\(phase)")
            #expect(!exists(paths.marker) && !exists(paths.backup))
        }
        #expect(process.registered.count == 3)
    }

    @Test func aCrashAfterTheNewVersionWasCompleteIsFinishedNotUndone() throws {
        let expected = snapshot(paths.stagedApp)
        try backUp()
        try BundleReplacer().replace(from: paths.stagedApp, into: installed)
        try marker(.cleanup)
        #expect(installer.recoverIfNeeded(bundle: installed, bundleID: fixtureBundleID) == .completed(version: "0.3.0", build: 21))
        #expect(snapshot(installed) == expected && process.registered == [installed])
        #expect(!exists(paths.marker) && !exists(paths.staged))
        #expect(snapshot(paths.backupApp)["Contents/MacOS/RimeLingo"] == "file 755 executable 0.2.0", "kept as after any install")
    }

    @Test func aCompleteLookingBundleWithABrokenSealIsStillUndone() throws {
        let before = snapshot(installed)
        try backUp()
        try BundleReplacer().replace(from: paths.stagedApp, into: installed)
        // What a stale file left behind does to the real signature check.
        signature.breakEvaluation(0)
        try marker(.cleanup)
        #expect(installer.recoverIfNeeded(bundle: installed, bundleID: fixtureBundleID) == .rolledBack(from: "0.3.0 (21)", to: "0.2.0 (20)"))
        #expect(snapshot(installed) == before)
    }

    /// The backup and the marker lie in a user-writable cache: nothing from there goes
    /// into the bundle unless it is a release of ours, for this bundle, of the recorded version.
    @Test func aBackupThatIsNotOurReleaseIsNeverPutIntoTheBundle() throws {
        let before = snapshot(installed)
        func refused(_ name: String) {
            fs.reset()
            guard case .failed = installer.recoverIfNeeded(bundle: installed, bundleID: fixtureBundleID) else {
                Issue.record("\(name): must be refused")
                return
            }
            #expect(snapshot(installed) == before, "\(name)")
            #expect(fs.count(.rename) == 0 && fs.count(.copy) == 0, "\(name): refused before anything is written")
            #expect(exists(paths.marker), "\(name)")
        }
        try marker(.commit)
        try makeBundle(paths.backupApp, version: "0.2.0", build: 20, bundleID: "com.example.other")
        refused("another bundle")
        try FileManager.default.removeItem(at: paths.backup)
        try makeBundle(paths.backupApp, version: "0.1.0", build: 3)
        refused("another version than the marker says")
        try FileManager.default.removeItem(at: paths.backup)
        try backUp()
        signature.breakEvaluation(0)
        refused("broken seal")
        signature.markDevelopmentSigned(paths.backupApp)
        refused("development signature")
        #expect(process.registered.isEmpty)
    }

    @Test func recoveryWaitsWhileAnInstallIsRunningElsewhere() throws {
        try backUp()
        try marker(.commit)
        let running = try #require(UpdateLock.acquire(paths))
        #expect(installer.recoverIfNeeded(bundle: installed, bundleID: fixtureBundleID) == .busy)
        #expect(exists(paths.marker) && exists(paths.backupApp))
        withExtendedLifetime(running) {}
    }

    @Test func aMarkerForAnotherBundleOrWithoutBackupIsNotActedOn() throws {
        let before = snapshot(installed)
        try marker(.commit, bundle: scratch.url("elsewhere/RimeLingo.app"))
        #expect(installer.recoverIfNeeded(bundle: installed, bundleID: fixtureBundleID) == .none)
        try marker(.commit)
        guard case .failed = installer.recoverIfNeeded(bundle: installed, bundleID: fixtureBundleID) else {
            Issue.record("a missing backup must be reported")
            return
        }
        #expect(snapshot(installed) == before && exists(paths.marker))
    }

    @Test func onlyOneHolderOfTheLock() throws {
        var first = UpdateLock.acquire(paths)
        #expect(first != nil)
        #expect(UpdateLock.acquire(paths) == nil)
        withExtendedLifetime(first) {}
        first = nil
        #expect(UpdateLock.acquire(paths) != nil)
    }
}

/// What `theMarkerNamesEachPhaseBeforeItsFirstStep` saw at the first operation of each step.
final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: Set<String> = []
    private var phaseAt: [String: InstallMarker.Phase] = [:]
    private var backupAt: [String: Bool] = [:]

    var phases: [String: InstallMarker.Phase] { lock.withLock { phaseAt } }
    var backups: [String: Bool] { lock.withLock { backupAt } }
    func insert(_ step: String) -> Bool { lock.withLock { steps.insert(step).inserted } }
    func record(_ step: String, phase: InstallMarker.Phase?, backup: Bool) {
        lock.withLock {
            phaseAt[step] = phase
            backupAt[step] = backup
        }
    }
}
