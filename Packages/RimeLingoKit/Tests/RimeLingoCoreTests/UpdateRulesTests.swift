import CryptoKit
import Foundation
import Testing
@testable import RimeLingoCore

@Suite struct AppVersionTests {
    @Test func comparesVersionsAndBuilds() {
        #expect(AppVersion("0.1.0") < AppVersion("0.1.1"))
        #expect(AppVersion("0.9.0") < AppVersion("0.10.0"))
        #expect(AppVersion("1.0") == AppVersion("1.0.0"))
        #expect(AppVersion("0.1.0", build: 1) < AppVersion("0.1.0", build: 2))
        // Without a build number on one side, the same version is not an update.
        #expect(!(AppVersion("0.1.0", build: 1) < AppVersion("0.1.0")))
        #expect(!(AppVersion("0.2.0", build: 9) < AppVersion("0.1.0", build: 10)))
        #expect(AppVersion("0.1.0", build: 2).description == "0.1.0 (2)")
    }

    @Test func ordersPrereleasesUsingSemver() {
        let versions = ["0.2.0-alpha", "0.2.0-alpha.1", "0.2.0-alpha.beta", "0.2.0-beta", "0.2.0-beta.1",
                        "0.2.0-beta.2", "0.2.0-beta.11", "0.2.0-rc.1", "0.2.0"]
        for (left, right) in zip(versions, versions.dropFirst()) {
            #expect(AppVersion(left, build: 999) < AppVersion(right, build: 1))
        }
        #expect(AppVersion("0.2.0+metadata") == AppVersion("0.2.0+other"))
    }

    /// The running version and the version the updater reads from a bundle on disk must
    /// be the same two keys, or a build could look older than itself and restart forever.
    @Test func theRunningVersionComesFromTheKeysTheUpdaterComparesOnDisk() throws {
        let scratch = Scratch()
        let root = scratch.url("Some.app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "test.rimelingo.beta", "CFBundleShortVersionString": "0.2.0",
                     "CFBundleVersion": "3", "RimeLingoReleaseVersion": "0.2.0-beta.2"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(url: root))
        #expect(AppVersion.current(bundle).description == "0.2.0 (3)")
        #expect(UpdateCoordinator.versionOnDisk(root) == AppVersion.current(bundle))
    }
}

@Suite struct ManifestVerifierTests {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    func manifest(product: String = "rimelingo", version: String = "0.3.0", build: String = "21",
                  name: String? = nil, size: String = "10", sha: String = String(repeating: "a", count: 64)) -> Data {
        Data("""
        {"product":"\(product)","version":"\(version)","build":\(build),"minimumSystemVersion":"15.0",
         "files":{"zip":{"name":"\(name ?? "RimeLingo-\(version).zip")","size":\(size),"sha256":"\(sha)"}}}
        """.utf8)
    }

    func signature(_ data: Data) throws -> Data { Data((try key.signature(for: data).base64EncodedString() + "\n").utf8) }

    func failure(_ data: Data, key: String? = nil, signature: Data? = nil) -> UpdateFailure? {
        do {
            _ = try ManifestVerifier.release(manifest: data, signature: try signature ?? self.signature(data), publicKey: key ?? publicKey)
            return nil
        } catch { return error as? UpdateFailure }
    }

    /// Holds before and after the real key is pasted in: the constant is the placeholder
    /// (inert) or a usable Ed25519 public key, never something in between.
    @Test func thePlaceholderKeyKeepsTheUpdaterInert() throws {
        let shipped = UpdateConfiguration.manifestPublicKey
        #expect(shipped == UpdateConfiguration.placeholderPublicKey || Data(base64Encoded: shipped)?.count == 32)
        #expect(UpdateConfiguration.isConfigured == (shipped != UpdateConfiguration.placeholderPublicKey))
        #expect(!UpdateConfiguration.isConfigured(UpdateConfiguration.placeholderPublicKey))
        let data = manifest()
        #expect(failure(data, key: UpdateConfiguration.placeholderPublicKey) == .notConfigured)
        #expect(!ManifestVerifier.verify(manifest: data, signature: try signature(data), publicKey: UpdateConfiguration.placeholderPublicKey))
        #expect(!UpdateConfiguration.isConfigured("") && !UpdateConfiguration.isConfigured("AAAA"))
        #expect(UpdateConfiguration.isConfigured(publicKey))
    }

    @Test func acceptsAManifestSignedByTheKey() throws {
        let data = manifest()
        let release = try ManifestVerifier.release(manifest: data, signature: try signature(data), publicKey: publicKey)
        #expect(release.appVersion == AppVersion("0.3.0", build: 21))
        #expect(release.archive == .init(name: "RimeLingo-0.3.0.zip", size: 10, sha256: String(repeating: "a", count: 64)))
    }

    @Test func rejectsBadSignatures() throws {
        let data = manifest()
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(failure(data, key: other) == .untrustedManifest)
        #expect(failure(data + Data(" ".utf8), signature: try signature(data)) == .untrustedManifest)
        #expect(failure(data, signature: Data("not base64".utf8)) == .untrustedManifest)
        #expect(failure(data, signature: Data()) == .untrustedManifest)
        // A manifest that is malformed AND unsigned is reported as untrusted: nothing is parsed first.
        #expect(failure(Data("{".utf8), signature: Data("AAAA".utf8)) == .untrustedManifest)
    }

    @Test func rejectsSignedButMalformedManifests() {
        #expect(failure(Data("{}".utf8)) == .malformedManifest("decode"))
        #expect(failure(manifest(product: "other")) == .malformedManifest("product"))
        #expect(failure(manifest(version: "0.3.0-beta.1")) == .malformedManifest("version"))
        #expect(failure(manifest(version: "0.3")) == .malformedManifest("version"))
        #expect(failure(manifest(build: "0")) == .malformedManifest("version"))
        #expect(failure(manifest(name: "RimeLingo-0.3.0.pkg")) == .malformedManifest("archive"))
        #expect(failure(manifest(name: "../RimeLingo-0.3.0.zip")) == .malformedManifest("archive"))
        #expect(failure(manifest(size: "0")) == .malformedManifest("checksum"))
        #expect(failure(manifest(size: "2000000000")) == .malformedManifest("checksum"))
        #expect(failure(manifest(sha: "abc")) == .malformedManifest("checksum"))
        #expect(failure(manifest(sha: String(repeating: "A", count: 64))) == .malformedManifest("checksum"))
        // size and sha256 are required.
        #expect(failure(Data(#"{"product":"rimelingo","version":"0.3.0","build":21,"files":{"zip":{"name":"RimeLingo-0.3.0.zip"}}}"#.utf8))
            == .malformedManifest("decode"))
    }

    @Test func respectsTheMinimumSystem() {
        var release = AppRelease(version: "0.3.0", build: 21, files: [:])
        release.minimumSystemVersion = "15.0"
        #expect(!release.supportsThisSystem(OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 6)))
        #expect(release.supportsThisSystem(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
        release.minimumSystemVersion = nil
        #expect(release.supportsThisSystem(OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)))
    }

    @Test func releaseURLsPointAtThePublicRepository() {
        #expect(UpdateConfiguration.manifestURL.absoluteString == "https://github.com/leaker/rime-lingo/releases/latest/download/latest.json")
        #expect(UpdateConfiguration.manifestSignatureURL.absoluteString == "https://github.com/leaker/rime-lingo/releases/latest/download/latest.json.sig")
        #expect(UpdateConfiguration.assetURL(version: "0.3.0", name: "RimeLingo-0.3.0.zip").absoluteString
            == "https://github.com/leaker/rime-lingo/releases/download/v0.3.0/RimeLingo-0.3.0.zip")
    }
}

@Suite struct RedirectPolicyTests {
    func url(_ string: String) -> URL { URL(string: string)! }

    @Test func firstRequestsGoOnlyToThisRepositorysReleases() {
        #expect(RedirectPolicy.allows(initial: UpdateConfiguration.manifestURL))
        #expect(RedirectPolicy.allows(initial: UpdateConfiguration.assetURL(version: "0.3.0", name: "RimeLingo-0.3.0.zip")))
        #expect(!RedirectPolicy.allows(initial: url("http://github.com/leaker/rime-lingo/releases/latest/download/latest.json")))
        #expect(!RedirectPolicy.allows(initial: url("https://github.com/someone/else/releases/latest/download/latest.json")))
        #expect(!RedirectPolicy.allows(initial: url("https://objects.githubusercontent.com/leaker/rime-lingo/releases/x")))
        #expect(!RedirectPolicy.allows(initial: url("https://github.com.evil.example/leaker/rime-lingo/releases/x")))
    }

    @Test func redirectsStayOnGitHubsAssetHosts() {
        #expect(RedirectPolicy.allows(redirectTo: url("https://github.com/leaker/rime-lingo/releases/download/v0.3.0/latest.json")))
        #expect(RedirectPolicy.allows(redirectTo: url("https://objects.githubusercontent.com/github-production-release-asset/1?x=1")))
        #expect(RedirectPolicy.allows(redirectTo: url("https://Release-Assets.githubusercontent.com/a")))
        #expect(!RedirectPolicy.allows(redirectTo: url("http://objects.githubusercontent.com/a")))
        #expect(!RedirectPolicy.allows(redirectTo: url("https://raw.githubusercontent.com/a")))
        #expect(!RedirectPolicy.allows(redirectTo: url("https://evil.example/objects.githubusercontent.com")))
        #expect(!RedirectPolicy.allows(redirectTo: url("https://user:secret@github.com/a")))
        #expect(!RedirectPolicy.allows(redirectTo: url("https://github.com:8443/a")))
        #expect(!RedirectPolicy.allows(redirectTo: url("file:///etc/passwd")))
    }
}

@Suite struct UpdateStateTests {
    @Test func migratesTheInheritedState() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = #"{"autoCheck":false,"receiveBeta":true,"skipped":"0.1.0 (3)","lastCheck":"2026-11-01T00:00:00Z","available":{"product":"rimelingo","version":"9.0.0","files":{}}}"#
        let state = try decoder.decode(UpdateState.self, from: Data(old.utf8))
        #expect(!state.automaticUpdates && state.phase == .idle && state.release == nil && state.schema == 2)
        #expect(state.lastCheck == ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        #expect(try decoder.decode(UpdateState.self, from: Data("{}".utf8)).automaticUpdates)
    }

    @Test func roundTripsAndDropsAPhaseWithoutItsRelease() throws {
        let scratch = Scratch()
        let paths = RimeLingoPaths(userDataDir: scratch.root)
        var state = UpdateState.load(paths)
        #expect(state == UpdateState() && state.isDue())
        state.phase = .ready
        state.release = AppRelease(version: "0.3.0", build: 21, files: ["zip": .init(name: "RimeLingo-0.3.0.zip", size: 1, sha256: "x")])
        state.lastCheck = Date(timeIntervalSince1970: 0)
        state.failure = .init(code: "network", detail: "d", version: nil, at: Date(timeIntervalSince1970: 5))
        state.installed = .init(version: "0.2.0", build: 20, at: Date(timeIntervalSince1970: 6), notified: true)
        state.retry = .init(version: "0.3.0 (21)", count: 2)
        try state.save(paths)
        #expect(UpdateState.load(paths) == state)
        #expect(!state.isDue(now: Date(timeIntervalSince1970: 3600)) && state.isDue(now: Date(timeIntervalSince1970: 90000)))
        state.automaticUpdates = false
        #expect(!state.isDue(now: Date(timeIntervalSince1970: 90000)))

        try Data(#"{"schema":2,"phase":"ready","release":{"broken":true}}"#.utf8).write(to: UpdateState.file(paths))
        #expect(UpdateState.load(paths).phase == .idle)
        try Data(#"{"schema":2,"phase":"somethingNew"}"#.utf8).write(to: UpdateState.file(paths))
        #expect(UpdateState.load(paths).phase == .idle)
    }

    @Test func everyFailureCodeRoundTrips() {
        let all: [UpdateFailure] = [.notConfigured, .developmentBuild, .unsupportedLocation("p"), .network("n"), .untrustedManifest,
                                    .malformedManifest("m"), .unsupportedSystem("15.0"), .checksumMismatch, .badArchive("b"),
                                    .untrustedBundle, .wrongBundle, .versionMismatch, .notNewer, .busy, .backupFailed("x"),
                                    .installFailed("y"), .rollbackFailed("z")]
        for failure in all {
            #expect(UpdateFailure(code: failure.code, detail: failure.detail) == failure)
            #expect(failure.errorDescription?.isEmpty == false)
        }
        #expect(UpdateFailure(code: "unknown") == nil)
    }

    @Test func onlyFailuresOfThisMacsMakingAreRetried() {
        let local: [UpdateFailure] = [.installFailed("interrupted"), .installFailed("NSPOSIXErrorDomain 28"),
                                      .installFailed("NSCocoaErrorDomain 640"), .backupFailed("NSPOSIXErrorDomain 28"), .badArchive("extract")]
        for failure in local { #expect(failure.isLocal && !failure.isTransient, "\(failure)") }
        let aboutTheRelease: [UpdateFailure] = [.installFailed("untrustedBundle"), .installFailed("NSPOSIXErrorDomain 13"),
                                                .backupFailed("untrusted"), .badArchive("layout"), .untrustedBundle, .wrongBundle,
                                                .versionMismatch, .notNewer, .rollbackFailed("x"), .checksumMismatch, .network("n")]
        for failure in aboutTheRelease { #expect(!failure.isLocal, "\(failure)") }
    }
}

@Suite struct UpdateIdleTests {
    @Test func installsOnlyWhenNothingIsInterrupted() {
        let idle = UpdateIdleSnapshot(secondsSinceLastKey: 30)
        #expect(idle.allowsInstall(userRequested: false))
        #expect(!UpdateIdleSnapshot(secondsSinceLastKey: 29.9).allowsInstall(userRequested: false))
        let busy: [WritableKeyPath<UpdateIdleSnapshot, Bool>] = [
            \.isComposing, \.hasPendingInput, \.hasDraft, \.liveSessionActive, \.selectionPreviewActive,
            \.aiActionActive, \.quickMenuOpen, \.secureContext, \.deployInProgress,
        ]
        for flag in busy {
            var snapshot = UpdateIdleSnapshot(secondsSinceLastKey: 3600)
            snapshot[keyPath: flag] = true
            #expect(!snapshot.allowsInstall(userRequested: false))
            #expect(!snapshot.allowsInstall(userRequested: true), "install now must not interrupt either")
        }
    }

    @Test func installNowWaivesOnlyTheThirtySeconds() {
        #expect(UpdateIdleSnapshot(secondsSinceLastKey: 1).allowsInstall(userRequested: true))
        #expect(UpdateIdleSnapshot.notAnInputMethod.allowsInstall(userRequested: false))
    }

    /// The request from Settings does not lapse while the user keeps typing.
    @Test func installNowLastsUntilThatInstallIsOver() {
        var request = UserInstallRequest()
        #expect(!request.isActive)
        request.make()
        for pending in [InstallOutcome.deferred, .failed(.busy), .installed(version: "0.3.0")] {
            request.settle(pending)
            #expect(request.isActive, "\(pending)")
        }
        request.settle(.failed(.installFailed("x")))
        #expect(!request.isActive)
        request.make()
        request.settle(.notReady)
        #expect(!request.isActive, "nothing to install: the request is spent")
    }
}

@Suite struct UpdateEligibilityTests {
    let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    let bundle = URL(fileURLWithPath: "/Users/someone/Library/Input Methods/RimeLingo.app")

    @Test func aReleaseBuildInAWritableLocationIsEligible() {
        #expect(UpdateEligibility.evaluate(bundle: bundle, signature: FakeSignature(), fs: FaultyFileSystem(), publicKey: key)
            == .eligible(bundle: bundle))
    }

    @Test func thePlaceholderKeyComesFirst() {
        #expect(UpdateEligibility.evaluate(bundle: bundle, signature: FakeSignature(), fs: FaultyFileSystem(),
                                           publicKey: UpdateConfiguration.placeholderPublicKey) == .notConfigured)
    }

    @Test func developmentBuildsOfTheSameTeamNeverUpdate() {
        let signature = FakeSignature()
        // Apple Development: valid, same team identifier, but not Developer ID.
        signature.running = SignatureInfo(isValid: true, satisfiesDeveloperID: false, teamID: UpdateConfiguration.teamID)
        #expect(UpdateEligibility.evaluate(bundle: bundle, signature: signature, fs: FaultyFileSystem(), publicKey: key) == .developmentBuild)
        signature.running = .unsigned  // ad hoc
        #expect(UpdateEligibility.evaluate(bundle: bundle, signature: signature, fs: FaultyFileSystem(), publicKey: key) == .developmentBuild)
        signature.running = SignatureInfo(isValid: true, satisfiesDeveloperID: true, teamID: "ABCDEFGHIJ")
        #expect(UpdateEligibility.evaluate(bundle: bundle, signature: signature, fs: FaultyFileSystem(), publicKey: key) == .developmentBuild)
    }

    @Test func aBundleTheUserCannotWriteIsLeftAlone() {
        let fs = FaultyFileSystem()
        fs.userWritable = false
        #expect(UpdateEligibility.evaluate(bundle: bundle, signature: FakeSignature(), fs: fs, publicKey: key)
            == .unsupportedLocation(bundle.path))
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/1/d/RimeLingo.app")
        #expect(UpdateEligibility.evaluate(bundle: translocated, signature: FakeSignature(), fs: FaultyFileSystem(), publicKey: key)
            == .unsupportedLocation(translocated.path))
    }

    @Test func writabilityIsReadFromTheRealFileSystem() throws {
        let scratch = Scratch()
        let fs = LocalUpdateFileSystem()
        #expect(fs.isUserWritable(scratch.root))
        #expect(!fs.isUserWritable(URL(fileURLWithPath: "/Library")))
        #expect(!fs.isUserWritable(scratch.url("missing")))
    }

    @Test func theRealEvaluatorDoesNotMistakeOtherCodeForARelease() throws {
        let scratch = Scratch()
        try makeBundle(scratch.url("RimeLingo.app"), version: "0.2.0", build: 20)
        let evaluator = SecCodeSignatureEvaluator()
        let unsigned = evaluator.evaluate(bundle: scratch.url("RimeLingo.app"))
        #expect(!unsigned.isValid && !unsigned.satisfiesDeveloperID)
        #expect(!SecCodeSignatureEvaluator.isDeveloperIDSigned(scratch.url("RimeLingo.app")))
        // The test runner is not signed with RimeLingo's Developer ID certificate.
        #expect(!evaluator.evaluateRunningProcess().satisfiesDeveloperID)
    }
}

@Suite struct BundleVerificationTests {
    let release = AppRelease(version: "0.3.0", build: 21, files: [:])
    let good = SignatureInfo(isValid: true, satisfiesDeveloperID: true, teamID: UpdateConfiguration.teamID,
                             bundleID: fixtureBundleID, version: "0.3.0", build: 21)

    func failure(_ info: SignatureInfo, installed: AppVersion? = AppVersion("0.2.0", build: 20)) -> UpdateFailure? {
        do { try BundleVerification.verify(info, release: release, bundleID: fixtureBundleID, installed: installed); return nil }
        catch { return error as? UpdateFailure }
    }

    @Test func checksSignatureThenIdentityThenVersion() {
        #expect(failure(good) == nil)
        // Everything wrong at once: the signature is what gets reported.
        var bad = SignatureInfo(isValid: false, satisfiesDeveloperID: false, teamID: "X", bundleID: "other", version: "9", build: 1)
        #expect(failure(bad, installed: AppVersion("9.9.9", build: 99)) == .untrustedBundle)
        bad.isValid = true
        #expect(failure(bad) == .untrustedBundle, "valid but not Developer ID")
        bad.satisfiesDeveloperID = true
        #expect(failure(bad) == .untrustedBundle, "another team")
        bad.teamID = UpdateConfiguration.teamID
        #expect(failure(bad, installed: AppVersion("9.9.9", build: 99)) == .wrongBundle)
        bad.bundleID = fixtureBundleID
        #expect(failure(bad, installed: AppVersion("9.9.9", build: 99)) == .versionMismatch)
        bad.version = "0.3.0"
        #expect(failure(bad) == .versionMismatch, "build differs from the manifest")
    }

    @Test func refusesSameAndOlderVersions() {
        #expect(failure(good, installed: AppVersion("0.3.0", build: 21)) == .notNewer)
        #expect(failure(good, installed: AppVersion("0.3.0", build: 22)) == .notNewer)
        #expect(failure(good, installed: AppVersion("0.4.0", build: 1)) == .notNewer)
        #expect(failure(good, installed: AppVersion("0.3.0", build: 20)) == nil)
        #expect(failure(good, installed: nil) == nil)
    }
}

@Suite struct StagedArchiveTests {
    let scratch = Scratch()

    func stage(_ change: (URL) throws -> Void = { _ in }) throws -> URL {
        let directory = scratch.url("staging.tmp")
        try makeBundle(directory.appendingPathComponent("RimeLingo.app"), version: "0.3.0", build: 21)
        try change(directory)
        return directory
    }

    func failure(_ directory: URL) -> UpdateFailure? {
        do { _ = try StagedArchive.locateBundle(in: directory); return nil } catch { return error as? UpdateFailure }
    }

    @Test func acceptsABundleWithInternalLinks() throws {
        let directory = try stage()
        #expect(try StagedArchive.locateBundle(in: directory).lastPathComponent == "RimeLingo.app")
    }

    @Test func rejectsAnythingBesideTheBundle() throws {
        #expect(failure(try stage { try Data().write(to: $0.appendingPathComponent("extra")) }) == .badArchive("layout"))
    }

    @Test func rejectsAnotherName() throws {
        let directory = try stage {
            try FileManager.default.moveItem(at: $0.appendingPathComponent("RimeLingo.app"), to: $0.appendingPathComponent("Other.app"))
        }
        #expect(failure(directory) == .badArchive("layout"))
        #expect(failure(scratch.url("missing")) == .badArchive("layout"))
    }

    @Test func rejectsLinksThatLeaveTheBundle() throws {
        for target in ["/etc/passwd", "../../../outside", "../../../../etc"] {
            let directory = try stage {
                try FileManager.default.createSymbolicLink(
                    atPath: $0.appendingPathComponent("RimeLingo.app/Contents/Frameworks/escape").path, withDestinationPath: target)
            }
            #expect(failure(directory) == .badArchive("link"), "\(target)")
            try FileManager.default.removeItem(at: directory)
        }
        #expect(StagedArchive.staysInside("../Resources/a", from: ["Contents", "Frameworks"]))
        #expect(StagedArchive.staysInside("Versions/Current", from: ["Contents", "Frameworks", "X.framework"]))
        #expect(!StagedArchive.staysInside("../..", from: ["Contents"]))
        #expect(!StagedArchive.staysInside("a/../../../b", from: ["Contents"]))
    }

    @Test func rejectsSetuidFilesAndSpecialFiles() throws {
        let setuid = try stage {
            try FileManager.default.setAttributes([.posixPermissions: 0o4755],
                                                  ofItemAtPath: $0.appendingPathComponent("RimeLingo.app/Contents/MacOS/RimeLingo").path)
        }
        #expect(failure(setuid) == .badArchive("setuid"))
        try FileManager.default.removeItem(at: setuid)
        let fifo = try stage { _ = mkfifo($0.appendingPathComponent("RimeLingo.app/Contents/pipe").path, 0o644) }
        #expect(failure(fifo) == .badArchive("special file"))
    }
}

@Suite struct RelaunchHelperTests {
    @Test func pathsTravelAsArgumentsNotInTheScript() {
        let bundle = URL(fileURLWithPath: "/Users/a b/Library/Input Methods/Rime'Lingo\".app")
        let arguments = RelaunchHelper.arguments(pid: 4242, bundle: bundle, background: true)
        #expect(arguments == ["-c", RelaunchHelper.script, "sh", "4242", "100", "/usr/bin/open", "-g", bundle.path])
        #expect(RelaunchHelper.arguments(pid: 1, bundle: bundle, background: false).suffix(2) == ["/usr/bin/open", bundle.path])
        #expect(!RelaunchHelper.script.contains("Input Methods"))
        #expect(RelaunchHelper.script.contains(#"kill -0 "$pid""#) && RelaunchHelper.script.contains(#""$@""#))
    }

    /// The helper outlives nothing here: it waits for a real process, then runs a harmless
    /// stand-in for `open` that only creates a file.
    @Test func waitsForTheProcessToExitThenReopens() async throws {
        let scratch = Scratch()
        let reopened = scratch.url("re opened")
        let waited = Process()
        waited.executableURL = URL(fileURLWithPath: "/bin/sleep")
        waited.arguments = ["1.5"]
        try waited.run()
        let arguments = RelaunchHelper.arguments(pid: waited.processIdentifier, bundle: reopened, background: false, opener: "/usr/bin/touch")
        try RelaunchHelper.spawnDetached(RelaunchHelper.shell, arguments)
        try await Task.sleep(for: .milliseconds(250))
        #expect(waited.isRunning && !FileManager.default.fileExists(atPath: reopened.path), "nothing is reopened while the process lives")
        for _ in 0..<100 where waited.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: reopened.path) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(FileManager.default.fileExists(atPath: reopened.path))
    }

    /// A process that hangs while quitting would be found "already running" by `open`,
    /// and nothing would ever replace it.
    @Test func aProcessThatDoesNotExitIsEndedBeforeTheBundleIsReopened() async throws {
        let scratch = Scratch()
        let reopened = scratch.url("reopened")
        let stuck = Process()
        stuck.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stuck.arguments = ["60"]
        try stuck.run()
        defer { if stuck.isRunning { stuck.terminate() } }
        let arguments = RelaunchHelper.arguments(pid: stuck.processIdentifier, bundle: reopened, background: false,
                                                 opener: "/usr/bin/touch", waitTicks: 15)
        try RelaunchHelper.spawnDetached(RelaunchHelper.shell, arguments)
        try await Task.sleep(for: .milliseconds(100))
        #expect(stuck.isRunning && !FileManager.default.fileExists(atPath: reopened.path), "it is given its time first")
        // Polled: `waitUntilExit` spins a run loop and can miss the exit on a pool thread.
        for _ in 0..<100 where stuck.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!stuck.isRunning)
        guard !stuck.isRunning else { return }
        #expect(stuck.terminationReason == .uncaughtSignal && stuck.terminationStatus == SIGKILL)
        for _ in 0..<60 where !FileManager.default.fileExists(atPath: reopened.path) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(FileManager.default.fileExists(atPath: reopened.path))
    }

    @Test func aHelperThatCannotStartIsReported() {
        #expect(throws: (any Error).self) {
            try RelaunchHelper.spawnDetached(URL(fileURLWithPath: "/nonexistent/sh"), [])
        }
    }
}

/// Serves canned responses (no network).
final class UpdateStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
    /// URL → the Location it answers with (302).
    nonisolated(unsafe) static var redirects: [String: String] = [:]
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    static var requested: [String] { lock.withLock { log } }
    static func reset() {
        responses = [:]
        redirects = [:]
        lock.withLock { log = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.withLock { Self.log.append(url.absoluteString) }
        if let location = Self.redirects[url.absoluteString], let target = URL(string: location) {
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": location])!
            // The session asks its delegate; when that refuses, the 302 itself is the answer.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let (status, body) = Self.responses[request.url!.absoluteString] ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct URLSessionUpdateTransportTests {
    let transport = URLSessionUpdateTransport(protocolClasses: [UpdateStubProtocol.self])
    let manifest = UpdateConfiguration.manifestURL
    let asset = UpdateConfiguration.assetURL(version: "0.3.0", name: "RimeLingo-0.3.0.zip")

    @Test func refusesURLsOutsideTheRepositoryWithoutARequest() async {
        UpdateStubProtocol.responses = ["https://example.com/latest.json": (200, Data("x".utf8))]
        await #expect(throws: UpdateTransportError.forbiddenURL) {
            _ = try await transport.data(from: URL(string: "https://example.com/latest.json")!, maxBytes: 100)
        }
        await #expect(throws: UpdateTransportError.forbiddenURL) {
            try await transport.download(from: URL(string: "http://github.com/leaker/rime-lingo/releases/x")!,
                                         to: URL(fileURLWithPath: "/dev/null"), maxBytes: 1, allowsConstrainedNetwork: true, progress: nil)
        }
    }

    @Test func fetchesSmallFilesWithinTheLimit() async throws {
        UpdateStubProtocol.responses = [manifest.absoluteString: (200, Data("manifest".utf8))]
        #expect(try await transport.data(from: manifest, maxBytes: 100) == Data("manifest".utf8))
        await #expect(throws: UpdateTransportError.tooLarge) { _ = try await transport.data(from: manifest, maxBytes: 4) }
        UpdateStubProtocol.responses = [:]
        await #expect(throws: UpdateTransportError.badResponse(404)) { _ = try await transport.data(from: manifest, maxBytes: 100) }
    }

    @Test func downloadsToDiskWithinTheLimit() async throws {
        let scratch = Scratch()
        let payload = Data(repeating: 7, count: 300_000)
        UpdateStubProtocol.responses = [asset.absoluteString: (200, payload)]
        let destination = scratch.url("archive.part")
        try await transport.download(from: asset, to: destination, maxBytes: payload.count, allowsConstrainedNetwork: true, progress: nil)
        #expect(try Data(contentsOf: destination) == payload)
        let refused = scratch.url("refused.part")
        await #expect(throws: UpdateTransportError.tooLarge) {
            try await transport.download(from: asset, to: refused, maxBytes: payload.count - 1, allowsConstrainedNetwork: true, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: refused.path))
        UpdateStubProtocol.responses = [:]
        await #expect(throws: UpdateTransportError.badResponse(404)) {
            try await transport.download(from: asset, to: refused, maxBytes: 10, allowsConstrainedNetwork: true, progress: nil)
        }
    }

    /// The policy is only worth something while the session really asks it.
    @Test func followsRedirectsToGitHubsAssetHostsOnly() async throws {
        let scratch = Scratch()
        let good = "https://release-assets.githubusercontent.com/asset/1?sig=abc"
        UpdateStubProtocol.reset()
        UpdateStubProtocol.redirects = [manifest.absoluteString: good, asset.absoluteString: good]
        UpdateStubProtocol.responses = [good: (200, Data("from the asset host".utf8))]
        #expect(try await transport.data(from: manifest, maxBytes: 100) == Data("from the asset host".utf8))
        let destination = scratch.url("archive.part")
        try await transport.download(from: asset, to: destination, maxBytes: 100, allowsConstrainedNetwork: true, progress: nil)
        #expect(try Data(contentsOf: destination) == Data("from the asset host".utf8))

        for evil in ["https://evil.example/asset", "http://release-assets.githubusercontent.com/asset/1"] {
            UpdateStubProtocol.reset()
            UpdateStubProtocol.redirects = [manifest.absoluteString: evil, asset.absoluteString: evil]
            UpdateStubProtocol.responses = [evil: (200, Data("from somewhere else".utf8))]
            await #expect(throws: UpdateTransportError.badResponse(302)) { _ = try await transport.data(from: manifest, maxBytes: 100) }
            let refused = scratch.url("refused.part")
            await #expect(throws: UpdateTransportError.badResponse(302)) {
                try await transport.download(from: asset, to: refused, maxBytes: 100, allowsConstrainedNetwork: true, progress: nil)
            }
            #expect(!FileManager.default.fileExists(atPath: refused.path))
            #expect(!UpdateStubProtocol.requested.contains(evil), "nothing is ever asked of \(evil)")
            #expect(UpdateStubProtocol.requested.count == 2)
        }
        UpdateStubProtocol.reset()
    }

    @Test func backgroundDownloadsStayOffLowDataModeNetworks() {
        #expect(!URLSessionUpdateTransport.downloadRequest(asset, allowsConstrainedNetwork: false).allowsConstrainedNetworkAccess)
        #expect(URLSessionUpdateTransport.downloadRequest(asset, allowsConstrainedNetwork: true).allowsConstrainedNetworkAccess)
    }
}
