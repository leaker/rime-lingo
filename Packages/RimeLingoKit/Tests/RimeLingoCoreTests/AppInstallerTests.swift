import Foundation
import Testing
@testable import RimeLingoCore

/// Records what an install asks of the system, in order, and does none of it.
final class FakeInstallSystem: InstallSystem, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var log: [String] = []
    private var failing: Set<String> = []
    private var observer: (@Sendable (String) -> Void)?
    private var activation = InputSourceActivation(exitCode: 0, output: "enabled: true")
    private var pids: [Int32] = []

    var calls: [String] { lock.withLock { log } }
    var running: [Int32] {
        get { lock.withLock { pids } }
        set { lock.withLock { pids = newValue } }
    }
    var enableResult: InputSourceActivation {
        get { lock.withLock { activation } }
        set { lock.withLock { activation = newValue } }
    }
    func fail(_ call: String) { lock.withLock { _ = failing.insert(call) } }
    /// Called with the name of every action before it is recorded.
    func observe(_ handler: @escaping @Sendable (String) -> Void) { lock.withLock { observer = handler } }

    private func record(_ call: String) throws {
        let name = String(call.split(separator: " ").first ?? "")
        lock.withLock { observer }?(name)
        try lock.withLock {
            log.append(call)
            if failing.contains(name) { throw Refused() }
        }
    }

    func runningInputMethods(executable: URL) -> [Int32] {
        lock.withLock {
            log.append("running")
            return pids
        }
    }
    func registerWithLaunchServices(_ bundle: URL) throws { try record("register \(bundle.lastPathComponent)") }
    func enableInputSource(of bundle: URL, select: Bool) throws -> InputSourceActivation {
        try record("enable select=\(select)")
        return enableResult
    }
    func restartInputAgents() throws { try record("agents") }
    func terminate(_ pids: [Int32]) throws { try record("terminate \(pids)") }
    func start(_ bundle: URL) throws { try record("start \(bundle.lastPathComponent)") }
}

@Suite struct LaunchContextTests {
    @Test func aCopyInAnInputMethodsFolderServesInput() {
        for path in ["/Users/someone/Library/Input Methods/RimeLingo.app", "/Library/Input Methods/RimeLingo.app",
                     "/Users/someone/Library/Input Methods/RimeLingo.app/"] {
            #expect(LaunchContext.classify(bundle: URL(fileURLWithPath: path), arguments: [path]) == .inputMethod)
        }
    }

    @Test func aCopyAnywhereElseOffersToInstall() {
        for path in ["/Users/someone/Downloads/RimeLingo.app", "/Volumes/RimeLingo 0.3.0/RimeLingo.app",
                     "/private/var/folders/ab/cd/T/AppTranslocation/6E0F0D3B-0000-4000-8000-000000000000/d/RimeLingo.app",
                     "/Applications/RimeLingo.app", "/Users/someone/Library/Input Methods/Old/RimeLingo.app",
                     "/Users/someone/code/build/Release/RimeLingo.app"] {
            #expect(LaunchContext.classify(bundle: URL(fileURLWithPath: path), arguments: [path]) == .installer, "\(path)")
        }
    }

    @Test func registrationArgumentsWinWhereverTheCopyLies() {
        let installed = URL(fileURLWithPath: "/Users/someone/Library/Input Methods/RimeLingo.app")
        let download = URL(fileURLWithPath: "/Users/someone/Downloads/RimeLingo.app")
        for bundle in [installed, download] {
            #expect(LaunchContext.classify(bundle: bundle, arguments: ["x", "--install"]) == .registerInputSource(select: true))
            #expect(LaunchContext.classify(bundle: bundle, arguments: ["x", "--enable"]) == .registerInputSource(select: false))
        }
        // What Xcode and Finder may add is not a request of ours.
        #expect(LaunchContext.classify(bundle: download, arguments: ["x", "-NSDocumentRevisionsDebugMode", "YES"]) == .installer)
        #expect(LaunchContext.classify(bundle: installed, arguments: ["x", "-psn_0_12345"]) == .inputMethod)
    }

    @Test func linksAreResolved() throws {
        let scratch = Scratch()
        let folder = scratch.url("home/Library/Input Methods")
        try makeBundle(folder.appendingPathComponent("RimeLingo.app"), version: "0.3.0", build: 21)
        // The whole folder reached through a link with another name.
        try FileManager.default.createSymbolicLink(at: scratch.url("methods"), withDestinationURL: folder)
        #expect(LaunchContext.isInstalled(scratch.url("methods/RimeLingo.app")))
        // A link in Downloads to the installed bundle is the installed bundle.
        try FileManager.default.createDirectory(at: scratch.url("Downloads"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scratch.url("Downloads/RimeLingo.app"),
                                                   withDestinationURL: folder.appendingPathComponent("RimeLingo.app"))
        #expect(LaunchContext.isInstalled(scratch.url("Downloads/RimeLingo.app")))
        try makeBundle(scratch.url("Downloads/Copy/RimeLingo.app"), version: "0.3.0", build: 21)
        #expect(!LaunchContext.isInstalled(scratch.url("Downloads/Copy/RimeLingo.app")))
    }

    /// `~/Library/Input Methods` kept elsewhere (dotfiles, another volume) under another
    /// name: LaunchServices reports the resolved path of a copy started through the link.
    @Test func anInputMethodsFolderLinkedToAnotherNameIsStillInstalled() throws {
        let scratch = Scratch()
        let target = scratch.url("real/IMs")
        try makeBundle(target.appendingPathComponent("RimeLingo.app"), version: "0.3.0", build: 21)
        try FileManager.default.createDirectory(at: scratch.url("home/Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scratch.url("home/Library/Input Methods"), withDestinationURL: target)
        let location = scratch.url("home/Library/Input Methods/RimeLingo.app")
        let real = target.appendingPathComponent("RimeLingo.app").resolvingSymlinksInPath()
        let unrelated = [scratch.url("other/Library/Input Methods/RimeLingo.app")]

        #expect(real.deletingLastPathComponent().lastPathComponent == "IMs")
        #expect(LaunchContext.isInstalled(real, locations: [location]))
        #expect(LaunchContext.classify(bundle: real, arguments: ["x"], locations: [location]) == .inputMethod)
        // Through the link the name alone settles it.
        #expect(LaunchContext.isInstalled(location, locations: unrelated))
        // The same real path is a download when no install location leads to it.
        #expect(!LaunchContext.isInstalled(real, locations: unrelated))
        #expect(LaunchContext.classify(bundle: real, arguments: ["x"], locations: unrelated) == .installer)
        // Another bundle next to the installed one is not installed.
        try makeBundle(target.appendingPathComponent("Other.app"), version: "0.3.0", build: 21)
        #expect(!LaunchContext.isInstalled(target.appendingPathComponent("Other.app"), locations: [location]))
    }
}

@Suite struct InstallOfferTests {
    let new = AppVersion("0.3.0", build: 21)

    @Test func nothingInstalled() {
        let offer = InstallOffer(new: new, installed: nil, exists: false)
        #expect(offer.kind == .fresh && offer.actionTitle == "安装" && offer.title == "安装灵译输入法")
        #expect(!offer.requiresConfirmation && offer.versionSummary == nil)
    }

    @Test func olderCopyIsUpdated() {
        for installed in [AppVersion("0.2.0", build: 20), AppVersion("0.3.0", build: 20), AppVersion("0.3.0-beta.1", build: 30)] {
            let offer = InstallOffer(new: new, installed: installed, exists: true)
            #expect(offer.kind == .update && offer.actionTitle == "更新" && !offer.requiresConfirmation, "\(installed)")
        }
        #expect(InstallOffer(new: new, installed: AppVersion("0.2.0", build: 20), exists: true).versionSummary
            == "已安装 0.2.0 (20)  →  将安装 0.3.0 (21)")
    }

    @Test func sameVersionIsReinstalled() {
        let offer = InstallOffer(new: new, installed: AppVersion("0.3.0", build: 21), exists: true)
        #expect(offer.kind == .reinstall && offer.actionTitle == "重新安装" && !offer.requiresConfirmation)
    }

    @Test func newerCopyNeedsConfirmation() {
        for installed in [AppVersion("0.3.1", build: 22), AppVersion("0.3.0", build: 22), AppVersion("1.0", build: 1)] {
            let offer = InstallOffer(new: new, installed: installed, exists: true)
            #expect(offer.kind == .downgrade && offer.requiresConfirmation && offer.actionTitle == "安装旧版本", "\(installed)")
        }
    }

    @Test func aCopyWithoutAReadableVersionIsReplaced() {
        let offer = InstallOffer(new: new, installed: nil, exists: true)
        #expect(offer.kind == .reinstall && offer.versionSummary == "已安装 未知版本  →  将安装 0.3.0 (21)")
    }

    @Test func readsTheVersionOfACopyOnDisk() throws {
        let scratch = Scratch()
        try makeBundle(scratch.url("RimeLingo.app"), version: "0.2.0", build: 20)
        #expect(InstallOffer.version(of: scratch.url("RimeLingo.app"), bundleID: fixtureBundleID)?.description == "0.2.0 (20)")
        #expect(InstallOffer.version(of: scratch.url("RimeLingo.app"), bundleID: "another.product") == nil)
        #expect(InstallOffer.version(of: scratch.url("Missing.app"), bundleID: fixtureBundleID) == nil)
    }
}

@Suite struct InstalledCopyCheckTests {
    func info(valid: Bool = true, developerID: Bool = true, team: String? = UpdateConfiguration.teamID,
              version: String? = "0.3.0", build: Int? = 21) -> SignatureInfo {
        SignatureInfo(isValid: valid, satisfiesDeveloperID: developerID, teamID: team, bundleID: fixtureBundleID,
                      version: version, build: build)
    }

    @Test func acceptsAnIntactCopyOfTheRunningBuild() {
        #expect(InstalledCopyCheck.problem(installed: info(), running: info(), bundleID: fixtureBundleID) == nil)
        // A development build installs a development build.
        let development = info(developerID: false, team: nil)
        #expect(InstalledCopyCheck.problem(installed: development, running: development, bundleID: fixtureBundleID) == nil)
    }

    @Test func rejectsEverythingElse() {
        #expect(InstalledCopyCheck.problem(installed: info(valid: false), running: info(), bundleID: fixtureBundleID) != nil)
        #expect(InstalledCopyCheck.problem(installed: info(), running: info(), bundleID: "another.product") != nil)
        #expect(InstalledCopyCheck.problem(installed: info(version: "0.2.0"), running: info(), bundleID: fixtureBundleID) != nil)
        #expect(InstalledCopyCheck.problem(installed: info(build: 20), running: info(), bundleID: fixtureBundleID) != nil)
        // A release must not turn into something that is not one on the way.
        #expect(InstalledCopyCheck.problem(installed: info(developerID: false), running: info(), bundleID: fixtureBundleID) != nil)
        #expect(InstalledCopyCheck.problem(installed: info(team: "OTHERTEAM1"), running: info(), bundleID: fixtureBundleID) != nil)
    }
}

@Suite struct AppInstallerTests {
    let scratch = Scratch()
    let fs = FaultyFileSystem()
    let signature = FakeSignature()
    let system = FakeInstallSystem()
    var source: URL { scratch.url("Downloads/RimeLingo.app") }
    var folder: URL { scratch.url("home/Library/Input Methods") }
    var destination: URL { folder.appendingPathComponent("RimeLingo.app") }
    var updates: UpdatePaths { UpdatePaths(root: scratch.url("home/Library/RimeLingo/Rime/rimelingo/cache/updates")) }

    static let afterFiles = ["register RimeLingo.app", "agents", "start RimeLingo.app"]

    init() throws {
        try makeBundle(source, version: "0.3.0", build: 21, extra: ["Contents/Resources/added.txt": "new"])
        signature.running = SignatureInfo(isValid: true, satisfiesDeveloperID: true, teamID: UpdateConfiguration.teamID,
                                          bundleID: fixtureBundleID, version: "0.3.0", build: 21)
    }

    func installer(select: Bool = true) -> AppInstaller {
        AppInstaller(source: source, destination: destination, bundleID: fixtureBundleID, select: select, updates: updates,
                     signature: signature, fs: fs, system: system, clearQuarantine: { _ in })
    }

    func installOld() throws {
        try makeBundle(destination, version: "0.2.0", build: 20, extra: ["Contents/Resources/removed.txt": "old"])
    }

    func failure(of installer: AppInstaller) -> InstallFailure? {
        do {
            try installer.install()
            return nil
        } catch {
            return error as? InstallFailure
        }
    }

    var leftovers: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != "RimeLingo.app" }
    }

    @Test func firstInstallCopiesAndRunsEveryStepInOrder() throws {
        let steps = StepLog()
        try installer().install { steps.append($0) }
        #expect(steps.all == InstallStep.allCases)
        #expect(snapshot(destination) == snapshot(source))
        #expect(system.calls == ["running", "register RimeLingo.app", "enable select=true", "agents", "terminate []", "start RimeLingo.app"])
        #expect(leftovers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: updates.root.path), "the installer never creates the updater's folder")
    }

    @Test func anInstalledCopyIsReplacedInPlace() throws {
        try installOld()
        system.running = [4242]
        let bundleInode = inode(destination), contentsInode = inode(destination.appendingPathComponent("Contents"))
        let dictionaryInode = inode(destination.appendingPathComponent("Contents/SharedSupport/dictionary.bin"))
        // The copy that was running is ended only once the new files are there.
        let executable = destination.appendingPathComponent("Contents/MacOS/RimeLingo")
        let seen = StepLog()
        system.observe { call in
            guard call == "terminate" else { return }
            if (try? String(contentsOf: executable, encoding: .utf8)) == "executable 0.3.0" { seen.append(.startInputMethod) }
        }
        try installer(select: false).install()
        #expect(snapshot(destination) == snapshot(source))
        #expect(inode(destination) == bundleInode && inode(destination.appendingPathComponent("Contents")) == contentsInode)
        #expect(inode(destination.appendingPathComponent("Contents/SharedSupport/dictionary.bin")) == dictionaryInode)
        #expect(system.calls == ["running", "register RimeLingo.app", "enable select=false", "agents", "terminate [4242]",
                                 "start RimeLingo.app"])
        #expect(seen.all == [.startInputMethod])
        #expect(leftovers.isEmpty && temporaries(in: destination).isEmpty)
    }

    @Test func aDamagedPackageChangesNothing() throws {
        try installOld()
        let before = snapshot(destination)
        signature.running = .unsigned
        let failure = failure(of: installer())
        #expect(failure?.reason == .damagedPackage && failure?.bundle == .untouched)
        #expect(snapshot(destination) == before && system.calls == ["running"] && leftovers.isEmpty)
    }

    @Test func aFolderOrCopyTheUserCannotChangeIsRefused() throws {
        try installOld()
        let before = snapshot(destination)
        fs.userWritable = false
        let failure = failure(of: installer())
        #expect(failure?.reason == .notWritable && failure?.bundle == .untouched && failure?.step == .checkPackage)
        #expect(snapshot(destination) == before && leftovers.isEmpty)
    }

    @Test func somethingElseAtTheDestinationIsRefused() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a bundle".utf8).write(to: destination)
        #expect(failure(of: installer())?.bundle == .untouched)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "not a bundle")
    }

    @Test func aFirstCopyThatFailsLeavesNothingBehind() throws {
        fs.fail(.copy, at: 0)
        var failure = failure(of: installer())
        #expect(failure?.reason == .copy && failure?.bundle == .untouched && failure?.step == .copyFiles)
        #expect(!FileManager.default.fileExists(atPath: destination.path) && leftovers.isEmpty)

        fs.fail(.rename, at: 0)
        failure = self.failure(of: installer())
        #expect(failure?.reason == .copy && failure?.bundle == .untouched)
        #expect(!FileManager.default.fileExists(atPath: destination.path) && leftovers.isEmpty)
        #expect(!system.calls.contains { Self.afterFiles.contains($0) })
    }

    @Test func aFirstCopyThatFailsItsCheckIsRemoved() throws {
        signature.breakEvaluation(0)
        let failure = failure(of: installer())
        #expect(failure?.reason == .signature && failure?.step == .verifySignature && failure?.bundle == .untouched)
        #expect(!FileManager.default.fileExists(atPath: destination.path) && leftovers.isEmpty)
        #expect(system.calls == ["running"])
    }

    @Test func aFailedBackupOrPrepareLeavesTheInstalledCopyUntouched() throws {
        try installOld()
        let before = snapshot(destination)
        for index in [0, 2, 5] {
            fs.fail(.copy, at: index)
            let failure = failure(of: installer())
            #expect(failure?.reason == .copy && failure?.bundle == .untouched, "copy \(index)")
            #expect(snapshot(destination) == before && leftovers.isEmpty, "copy \(index)")
        }
        // The rename that gives the finished backup its name.
        fs.fail(.rename, at: 0)
        let failure = failure(of: installer())
        #expect(failure?.reason == .copy && failure?.bundle == .untouched)
        #expect(snapshot(destination) == before && leftovers.isEmpty)
        #expect(system.calls.allSatisfy { $0 == "running" })
    }

    @Test func aReplacementThatFailsHalfwayIsRolledBack() throws {
        try installOld()
        let before = snapshot(destination)
        let bundleInode = inode(destination)
        for index in [1, 2, 4, 7] {
            fs.fail(.rename, at: index)
            let failure = failure(of: installer())
            #expect(failure?.reason == .copy && failure?.bundle == .restored, "rename \(index)")
            #expect(snapshot(destination) == before && leftovers.isEmpty, "rename \(index)")
        }
        // Removing what the new version no longer has can fail as well.
        fs.reset()
        fs.observe { [fs] operation, url in
            if operation == .remove, url.lastPathComponent == "removed.txt" { fs.fail(.remove, at: 0) }
        }
        let failure = failure(of: installer())
        fs.observe(nil)
        #expect(failure?.bundle == .restored && snapshot(destination) == before && leftovers.isEmpty)
        #expect(inode(destination) == bundleInode, "the bundle directory itself is never recreated")
        #expect(system.calls.allSatisfy { $0 == "running" })
    }

    @Test func aReplacementThatFailsItsCheckIsRolledBack() throws {
        try installOld()
        let before = snapshot(destination)
        signature.breakEvaluation(0)
        let failure = failure(of: installer())
        #expect(failure?.reason == .signature && failure?.bundle == .restored)
        #expect(failure?.message.contains("已恢复为原来的版本") == true)
        #expect(snapshot(destination) == before && leftovers.isEmpty && temporaries(in: destination).isEmpty)
        #expect(system.calls == ["running"])
    }

    /// Replaces a part of the installed copy and then fails that replacement and its
    /// rollback. Returns where the previous version was kept.
    func damage() throws -> URL {
        // Rename 0 names the backup; the bundle is mixed after the next two.
        fs.fail(.rename, at: 3, persistent: true)
        let failure = failure(of: installer())
        fs.reset()
        guard case let .damaged(backup)? = failure?.bundle else {
            Issue.record("expected a damaged bundle, got \(String(describing: failure))")
            throw CocoaError(.featureUnsupported)
        }
        #expect(failure?.message.contains("请点「重试」") == true)
        return URL(fileURLWithPath: backup)
    }

    @Test func aRollbackThatFailsKeepsTheBackupAndARetryRepairs() throws {
        try installOld()
        let before = snapshot(destination)
        let backup = try damage()
        #expect(snapshot(destination) != before, "the fixture has to leave a mixed bundle")
        #expect(snapshot(backup) == before, "the previous version is still there to put back")
        try installer().install()
        #expect(snapshot(destination) == snapshot(source) && leftovers.isEmpty && temporaries(in: destination).isEmpty)
    }

    @Test func aRetryThatFailsAgainNeverLosesThePreviousVersion() throws {
        try installOld()
        let before = snapshot(destination)
        let backup = try damage()

        // Nothing can be moved into place: neither the previous version nor the new one.
        fs.fail(.rename, at: 0, persistent: true)
        var failure = failure(of: installer())
        fs.reset()
        #expect(failure?.bundle == .damaged(backup: backup.path), "the same copy is kept, not a copy of the mixed bundle")
        #expect(snapshot(backup) == before)
        #expect(leftovers == [backup.deletingLastPathComponent().lastPathComponent])

        // The new version cannot even be prepared, and the previous one cannot be put back.
        fs.fail(.copy, at: 0, persistent: true)
        failure = self.failure(of: installer())
        fs.reset()
        #expect(failure?.bundle == .damaged(backup: backup.path) && failure?.step == .copyFiles)
        #expect(snapshot(backup) == before)

        try installer().install()
        #expect(snapshot(destination) == snapshot(source) && leftovers.isEmpty && temporaries(in: destination).isEmpty)
    }

    @Test func aRetryPutsThePreviousVersionBackBeforeAnythingElse() throws {
        try installOld()
        let before = snapshot(destination)
        _ = try damage()
        // The retry fails its check: what it rolls back to is the previous version, not
        // the mixed bundle the first attempt left.
        signature.breakEvaluation(0)
        var failure = failure(of: installer())
        #expect(failure?.reason == .signature && failure?.bundle == .restored)
        #expect(snapshot(destination) == before && leftovers.isEmpty && temporaries(in: destination).isEmpty)

        // The same when the retry does not get as far as replacing anything.
        _ = try damage()
        try Data("x".utf8).write(to: source.appendingPathComponent("Contents/.rlu-not-installable"))
        failure = self.failure(of: installer())
        #expect(failure?.reason == .copy && failure?.bundle == .restored)
        #expect(snapshot(destination) == before && leftovers.isEmpty && temporaries(in: destination).isEmpty)
    }

    @Test func aRetryInstallsEvenWhenThePreviousVersionCannotBePutBackFirst() throws {
        try installOld()
        _ = try damage()
        // Only the restore is refused (its first copy); the install after it goes through.
        fs.fail(.copy, at: 0)
        try installer().install()
        #expect(snapshot(destination) == snapshot(source) && leftovers.isEmpty && temporaries(in: destination).isEmpty)
    }

    @Test func aBackupThatWasCutShortIsNeverPutBack() throws {
        try installOld()
        let before = snapshot(destination)
        try makeBundle(folder.appendingPathComponent(".rimelingo-install-OLD/previous.partial"), version: "0.1.0", build: 10)
        signature.breakEvaluation(0)
        let failure = failure(of: installer())
        #expect(failure?.bundle == .restored && snapshot(destination) == before && leftovers.isEmpty)
    }

    @Test func aKeptCopyOutlivesAFirstInstallThatFails() throws {
        // The user removed the damaged bundle by hand; the copy of the previous version
        // is all that is left of it.
        try makeBundle(folder.appendingPathComponent(".rimelingo-install-OLD/previous"), version: "0.2.0", build: 20)
        signature.breakEvaluation(0)
        let failure = failure(of: installer())
        #expect(failure?.bundle == .untouched && leftovers == [".rimelingo-install-OLD"])
        try installer().install()
        #expect(snapshot(destination) == snapshot(source) && leftovers.isEmpty)
    }

    @Test func laterFailuresKeepTheInstalledFilesAndStop() throws {
        let expected: [(String, InstallFailure.Reason, InstallStep, [String])] = [
            ("register", .registration, .registerApp, ["enable select=true", "agents", "start RimeLingo.app"]),
            ("enable", .enable, .enableInputSource, ["agents", "start RimeLingo.app"]),
            ("agents", .agents, .restartInputAgents, ["start RimeLingo.app"]),
            ("terminate", .start, .startInputMethod, ["start RimeLingo.app"]),
            ("start", .start, .startInputMethod, []),
        ]
        for (call, reason, step, skipped) in expected {
            let system = FakeInstallSystem()
            system.fail(call)
            var installer = installer()
            installer.system = system
            let failure = failure(of: installer)
            #expect(failure?.reason == reason && failure?.step == step && failure?.bundle == .installed, "\(call)")
            #expect(snapshot(destination) == snapshot(source), "\(call)")
            #expect(skipped.allSatisfy { !system.calls.contains($0) }, "\(call)")
        }
    }

    @Test func registrationThatReportsFailureIsAFailure() throws {
        system.enableResult = InputSourceActivation(exitCode: 1, output: "enabled com.example: false")
        let failure = failure(of: installer())
        #expect(failure?.reason == .enable && failure?.bundle == .installed)
        #expect(failure?.detail.contains("enabled com.example: false") == true)
        #expect(!system.calls.contains("agents"))
    }

    @Test func aQuarantineThatCannotBeClearedIsAFailure() throws {
        var installer = installer()
        installer.clearQuarantine = { _ in throw POSIXError(.EACCES) }
        let failure = failure(of: installer)
        #expect(failure?.reason == .quarantine && failure?.step == .clearQuarantine && failure?.bundle == .installed)
        #expect(system.calls == ["running"])
    }

    @Test func staysOutOfTheWayOfARunningUpdate() throws {
        try installOld()
        let before = snapshot(destination)
        let lock = try #require(UpdateLock.acquire(updates))
        let failure = failure(of: installer())
        #expect(failure?.reason == .busy && failure?.bundle == .untouched && snapshot(destination) == before)
        withExtendedLifetime(lock) {}
    }

    @Test func anInterruptedUpdateCannotUndoTheInstall() throws {
        try installOld()
        try FileManager.default.createDirectory(at: updates.root, withIntermediateDirectories: true)
        try makeBundle(updates.backupApp, version: "0.1.0", build: 10)
        try Data("{}".utf8).write(to: updates.marker)
        try makeBundle(updates.stagedApp, version: "0.4.0", build: 30)
        try installer().install()
        #expect(snapshot(destination) == snapshot(source))
        #expect(!FileManager.default.fileExists(atPath: updates.marker.path))
        #expect(!FileManager.default.fileExists(atPath: updates.backup.path))
        #expect(FileManager.default.fileExists(atPath: updates.stagedApp.path), "a downloaded update is verified again before use")
        #expect(UpdateLock.acquire(updates) != nil, "the lock is released")
    }

    @Test func leftoversOfAnInstallThatWasCutShortAreRemoved() throws {
        try installOld()
        try makeBundle(folder.appendingPathComponent(".rimelingo-install-OLD/previous"), version: "0.1.0", build: 10)
        try Data("junk".utf8).write(to: destination.appendingPathComponent("Contents/MacOS/.rlu-OLD-RimeLingo"))
        try makeBundle(folder.appendingPathComponent("Other.app"), version: "9", build: 9, bundleID: "another.input.method")
        let other = snapshot(folder.appendingPathComponent("Other.app"))
        try installer().install()
        #expect(snapshot(destination) == snapshot(source))
        #expect(leftovers == ["Other.app"] && snapshot(folder.appendingPathComponent("Other.app")) == other)
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [InstallStep] = []
    var all: [InstallStep] { lock.withLock { steps } }
    func append(_ step: InstallStep) { lock.withLock { steps.append(step) } }
}

@Suite struct InstallSystemTests {
    @Test func onlyTheUsersOwnSystemAgentsAreRestarted() {
        let processes = [
            ProcessEntry(pid: 10, uid: 501, path: "/System/Library/Frameworks/InputMethodKit.framework/Resources/imklaunchagent"),
            ProcessEntry(pid: 11, uid: 501, path: "/System/Library/CoreServices/TextInputMenuAgent.app/Contents/MacOS/TextInputMenuAgent"),
            ProcessEntry(pid: 12, uid: 501, path: "/System/Library/CoreServices/TextInputSwitcher.app/Contents/MacOS/TextInputSwitcher"),
            ProcessEntry(pid: 13, uid: 502, path: "/System/Library/Frameworks/InputMethodKit.framework/Resources/imklaunchagent"),
            ProcessEntry(pid: 14, uid: 501, path: "/Users/me/bin/imklaunchagent"),
            ProcessEntry(pid: 15, uid: 501, path: "/System/Library/CoreServices/TextInputMenuAgentHelper"),
            ProcessEntry(pid: 16, uid: 501, path: "/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"),
            ProcessEntry(pid: 17, uid: 501, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
        ]
        #expect(InputAgents.targets(in: processes, uid: 501).map(\.pid) == [10, 11, 12])
        #expect(InputAgents.targets(in: processes, uid: 503).isEmpty)
    }

    @Test func findsOnlyOtherInstancesOfTheInstalledExecutable() {
        let executable = URL(fileURLWithPath: "/Users/me/Library/Input Methods/RimeLingo.app/Contents/MacOS/RimeLingo")
        let processes = [
            ProcessEntry(pid: 20, uid: 501, path: executable.path),
            ProcessEntry(pid: 21, uid: 501, path: "/Users/me/Downloads/RimeLingo.app/Contents/MacOS/RimeLingo"),
            ProcessEntry(pid: 22, uid: 502, path: executable.path),
            ProcessEntry(pid: 23, uid: 501, path: executable.path),
            ProcessEntry(pid: 24, uid: 501, path: "/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"),
        ]
        #expect(InputAgents.instances(of: executable, in: processes, uid: 501, excluding: 23).map(\.pid) == [20])
    }

    @Test func theProcessTableListsThisProcess() {
        let own = ProcessTable.snapshot().first { $0.pid == getpid() }
        #expect(own?.uid == getuid())
        #expect(own?.path.hasPrefix("/") == true)
        #expect(ProcessTable.isAlive(getpid()))
    }

    @Test func removesQuarantineFromEverythingButLinks() throws {
        let scratch = Scratch()
        let bundle = scratch.url("RimeLingo.app")
        try makeBundle(bundle, version: "0.3.0", build: 21)
        let value = Array("0081;00000000;Safari;".utf8)
        func mark(_ path: String) throws {
            let item = path.isEmpty ? bundle : bundle.appendingPathComponent(path)
            guard setxattr(item.path, QuarantineAttribute.name, value, value.count, 0, XATTR_NOFOLLOW) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let readOnly = "Contents/SharedSupport/dictionary.bin"
        for path in ["", "Contents", "Contents/MacOS/RimeLingo", readOnly, "Contents/Applications/RimeLingo Settings.app"] {
            try mark(path)
        }
        guard setxattr(bundle.appendingPathComponent("Contents/Info.plist").path, "com.example.kept", value, value.count, 0, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: bundle.appendingPathComponent(readOnly).path)
        // A link out of the bundle: its target is none of the installer's business.
        let outside = scratch.url("outside.txt")
        try Data("outside".utf8).write(to: outside)
        guard setxattr(outside.path, QuarantineAttribute.name, value, value.count, 0, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.createSymbolicLink(atPath: bundle.appendingPathComponent("Contents/Resources-link").path,
                                                   withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: bundle.appendingPathComponent("Contents/dangling").path,
                                                   withDestinationPath: "nowhere")
        let before = snapshot(bundle)

        try QuarantineAttribute.remove(below: bundle)
        try QuarantineAttribute.remove(below: bundle)

        func attributes(_ url: URL) -> [String] { extendedAttributes(of: url).filter { $0 != "com.apple.provenance" } }
        var all = [attributes(bundle)]
        for path in snapshot(bundle).keys where !path.hasSuffix("-link") && path != "Contents/dangling" {
            all.append(attributes(bundle.appendingPathComponent(path)))
        }
        #expect(all.flatMap { $0 } == ["com.example.kept"])
        #expect(attributes(outside) == [QuarantineAttribute.name])
        #expect(snapshot(bundle) == before, "modes and contents are as they were")
    }
}
