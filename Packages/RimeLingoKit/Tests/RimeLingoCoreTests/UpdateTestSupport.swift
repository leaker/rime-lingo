import CryptoKit
import Foundation
@testable import RimeLingoCore

/// Not the real identifier: fixture bundles built under the temporary directory must never
/// be mistaken by LaunchServices for the installed input method.
let fixtureBundleID = "com.leelib.inputmethod.rimelingo.test-fixture"

/// A miniature RimeLingo.app: main executable, a library with a version link, a nested
/// settings app, shared data that does not change between versions, and a seal file.
func makeBundle(_ url: URL, version: String, build: Int, bundleID: String = fixtureBundleID,
                extra: [String: String] = [:]) throws {
    let fm = FileManager.default
    func put(_ path: String, _ text: String, mode: Int = 0o644) throws {
        let file = url.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }
    let plist = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": String(build)]
    try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("Contents/Info.plist"))
    try put("Contents/MacOS/RimeLingo", "executable \(version)", mode: 0o755)
    try put("Contents/Frameworks/librime.1.dylib", "library \(version)", mode: 0o755)
    try fm.createSymbolicLink(atPath: url.appendingPathComponent("Contents/Frameworks/librime.dylib").path,
                              withDestinationPath: "librime.1.dylib")
    try put("Contents/Helpers/rimelingo", "cli \(version)", mode: 0o755)
    try put("Contents/Applications/RimeLingo Settings.app/Contents/MacOS/RimeLingo Settings", "settings \(version)", mode: 0o755)
    try put("Contents/SharedSupport/dictionary.bin", "the same dictionary in every version")
    try put("Contents/_CodeSignature/CodeResources", "seal \(version)")
    for (path, text) in extra { try put(path, text) }
}

/// Every item below `url` as "path → kind, mode and content", for comparing trees.
func snapshot(_ url: URL) -> [String: String] {
    var result: [String: String] = [:]
    func walk(_ directory: String) {
        for name in (try? BundleTree.children(of: url.appendingPathComponent(directory))) ?? [] {
            let path = directory.isEmpty ? name : directory + "/" + name
            let item = url.appendingPathComponent(path)
            guard let entry = BundleTree.entry(at: item) else { continue }
            switch entry.kind {
            case .directory:
                result[path] = "directory"
                walk(path)
            case .symlink: result[path] = "link \(BundleTree.linkTarget(item) ?? "?")"
            case .file: result[path] = "file \(String(entry.mode, radix: 8)) \((try? String(contentsOf: item, encoding: .utf8)) ?? "?")"
            case .other: result[path] = "other"
            }
        }
    }
    walk("")
    return result
}

func inode(_ url: URL) -> UInt64 {
    var info = stat()
    return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : 0
}

func extendedAttributes(of url: URL) -> [String] {
    let size = listxattr(url.path, nil, 0, 0)
    guard size > 0 else { return [] }
    var buffer = [CChar](repeating: 0, count: size)
    let length = listxattr(url.path, &buffer, size, 0)
    guard length > 0 else { return [] }
    return buffer[..<length].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
}

func temporaries(in url: URL) -> [String] { snapshot(url).keys.filter { $0.contains(BundleTree.temporaryPrefix) } }

/// Reads identity and version from the fixture's Info.plist and calls every bundle a
/// valid Developer ID release, except where a test says otherwise.
final class FakeSignature: CodeSignatureEvaluating, @unchecked Sendable {
    private let lock = NSLock()
    private var evaluations = 0
    private var invalidEvaluations: Set<Int> = []
    private var developmentPaths: Set<String> = []
    private var runningInfo = SignatureInfo(isValid: true, satisfiesDeveloperID: true, teamID: UpdateConfiguration.teamID,
                                            bundleID: fixtureBundleID)

    var running: SignatureInfo {
        get { lock.withLock { runningInfo } }
        set { lock.withLock { runningInfo = newValue } }
    }
    var count: Int { lock.withLock { evaluations } }

    /// The n-th `evaluate(bundle:)` from now (0-based) reports a broken signature.
    func breakEvaluation(_ offsets: Int...) { lock.withLock { invalidEvaluations = Set(offsets.map { $0 + evaluations }) } }
    /// Bundles at this path are signed, but not with a Developer ID certificate.
    func markDevelopmentSigned(_ url: URL) { lock.withLock { _ = developmentPaths.insert(url.path) } }

    func evaluate(bundle: URL) -> SignatureInfo {
        let (index, development) = lock.withLock {
            defer { evaluations += 1 }
            return (evaluations, developmentPaths.contains(bundle.path))
        }
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return .unsigned }
        let valid = !lock.withLock { invalidEvaluations.contains(index) }
        return SignatureInfo(isValid: valid, satisfiesDeveloperID: valid && !development, teamID: UpdateConfiguration.teamID,
                             bundleID: plist["CFBundleIdentifier"], version: plist["CFBundleShortVersionString"],
                             build: plist["CFBundleVersion"].flatMap { Int($0) })
    }

    func evaluateRunningProcess() -> SignatureInfo { running }
}

/// The real file system with one operation made to fail.
final class FaultyFileSystem: UpdateFileSystem, @unchecked Sendable {
    enum Operation: Hashable { case createDirectory, copy, symlink, rename, remove, removeAttribute }
    struct Injected: Error {}

    private let real = LocalUpdateFileSystem()
    private let lock = NSLock()
    private var counts: [Operation: Int] = [:]
    private var fault: (operation: Operation, index: Int, persistent: Bool)?
    private var writable = true
    private var observer: (@Sendable (Operation, URL) -> Void)?

    /// Called before every operation with the item it is about to change.
    func observe(_ handler: (@Sendable (Operation, URL) -> Void)?) { lock.withLock { observer = handler } }

    var userWritable: Bool {
        get { lock.withLock { writable } }
        set { lock.withLock { writable = newValue } }
    }

    /// The `index`-th call of `operation` from now fails; with `persistent`, so does every later one.
    func fail(_ operation: Operation, at index: Int, persistent: Bool = false) {
        lock.withLock {
            counts = [:]
            fault = (operation, index, persistent)
        }
    }

    func count(_ operation: Operation) -> Int { lock.withLock { counts[operation] ?? 0 } }
    func reset() { lock.withLock { counts = [:]; fault = nil } }

    private func step(_ operation: Operation, _ url: URL) throws {
        lock.withLock { observer }?(operation, url)
        try lock.withLock {
            let index = counts[operation] ?? 0
            counts[operation] = index + 1
            if let fault, fault.operation == operation, fault.persistent ? index >= fault.index : index == fault.index {
                throw Injected()
            }
        }
    }

    func createDirectory(at url: URL) throws { try step(.createDirectory, url); try real.createDirectory(at: url) }
    func copyItem(at source: URL, to destination: URL) throws { try step(.copy, destination); try real.copyItem(at: source, to: destination) }
    func createSymbolicLink(at url: URL, destination: String) throws {
        try step(.symlink, url)
        try real.createSymbolicLink(at: url, destination: destination)
    }
    func rename(_ source: URL, to destination: URL) throws { try step(.rename, destination); try real.rename(source, to: destination) }
    func removeItem(at url: URL) throws { try step(.remove, url); try real.removeItem(at: url) }
    func removeExtendedAttribute(_ name: String, at url: URL) throws {
        try step(.removeAttribute, url)
        try real.removeExtendedAttribute(name, at: url)
    }
    func isUserWritable(_ url: URL) -> Bool { userWritable }
}

/// Records what the updater asks of other processes; "extracting" an archive copies a
/// prepared bundle instead of running ditto.
final class FakeProcess: ProcessControlling, @unchecked Sendable {
    struct Relaunch: Equatable { var pid: Int32; var bundle: URL; var background: Bool }
    struct Refused: Error {}

    private let lock = NSLock()
    private var state = (registered: [URL](), relaunches: [Relaunch](), runs: [[String]](), running: Set<String>(),
                         refuseRelaunch: false, extract: URL?.none, extractAs: UpdateConfiguration.bundleName, extra: [String]())

    var registered: [URL] { lock.withLock { state.registered } }
    var relaunches: [Relaunch] { lock.withLock { state.relaunches } }
    var runs: [[String]] { lock.withLock { state.runs } }
    var refuseRelaunch: Bool {
        get { lock.withLock { state.refuseRelaunch } }
        set { lock.withLock { state.refuseRelaunch = newValue } }
    }
    /// The bundle an archive "contains".
    var archiveContents: URL? {
        get { lock.withLock { state.extract } }
        set { lock.withLock { state.extract = newValue } }
    }
    /// Extra top-level files the archive "contains".
    var archiveExtras: [String] {
        get { lock.withLock { state.extra } }
        set { lock.withLock { state.extra = newValue } }
    }
    func setRunning(_ bundleID: String, _ running: Bool) {
        lock.withLock { if running { state.running.insert(bundleID) } else { state.running.remove(bundleID) } }
    }

    func run(_ tool: URL, _ arguments: [String]) throws -> Int32 {
        let (source, name, extras) = lock.withLock {
            state.runs.append([tool.path] + arguments)
            return (state.extract, state.extractAs, state.extra)
        }
        guard tool == UpdateCoordinator.ditto, arguments.count == 4, let source else { return 1 }
        let destination = URL(fileURLWithPath: arguments[3])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(name))
        for extra in extras { try Data().write(to: destination.appendingPathComponent(extra)) }
        return 0
    }

    func registerWithLaunchServices(_ bundle: URL) { lock.withLock { state.registered.append(bundle) } }
    func isRunning(bundleID: String) -> Bool { lock.withLock { state.running.contains(bundleID) } }
    func relaunchAfterExit(pid: Int32, bundle: URL, background: Bool) throws {
        try lock.withLock {
            if state.refuseRelaunch { throw Refused() }
            state.relaunches.append(.init(pid: pid, bundle: bundle, background: background))
        }
    }
}

final class FakeTransport: UpdateTransport, @unchecked Sendable {
    struct Offline: Error {}

    private let lock = NSLock()
    private var bodies: [URL: Data] = [:]
    private var log: [URL] = []
    private var constrained: [Bool] = []

    var requests: [URL] { lock.withLock { log } }
    /// `allowsConstrainedNetwork` of every download, in order.
    var constrainedNetworkAllowed: [Bool] { lock.withLock { constrained } }
    func serve(_ url: URL, _ data: Data?) { lock.withLock { bodies[url] = data } }
    func requestCount(_ url: URL) -> Int { requests.filter { $0 == url }.count }

    private func body(_ url: URL) throws -> Data {
        try lock.withLock {
            log.append(url)
            guard let data = bodies[url] else { throw Offline() }
            return data
        }
    }

    func data(from url: URL, maxBytes: Int) async throws -> Data {
        let data = try body(url)
        guard data.count <= maxBytes else { throw UpdateTransportError.tooLarge }
        return data
    }

    func download(from url: URL, to destination: URL, maxBytes: Int, allowsConstrainedNetwork: Bool,
                  progress: (@Sendable (Double) -> Void)?) async throws {
        lock.withLock { constrained.append(allowsConstrainedNetwork) }
        let data = try body(url)
        guard data.count <= maxBytes else { throw UpdateTransportError.tooLarge }
        progress?(0.5)
        try data.write(to: destination)
        progress?(1)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

/// A real Mach-O that does nothing for as long as its argument says, compiled with the
/// toolchain the tests are built with.
func buildSleeper(at url: URL) throws {
    let source = url.deletingLastPathComponent().appendingPathComponent("sleeper.c")
    try Data("#include <stdlib.h>\n#include <unistd.h>\nint main(int c, char **v) { sleep(c > 1 ? atoi(v[1]) : 30); return 0; }\n".utf8)
        .write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    compiler.arguments = ["-o", url.path, source.path]
    compiler.standardOutput = FileHandle.nullDevice
    compiler.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    compiler.terminationHandler = { _ in done.signal() }
    try compiler.run()
    done.wait()
    guard compiler.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
}

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// A temporary directory removed when the test ends.
final class Scratch {
    let root: URL
    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rimelingo-update-\(UUID().uuidString)").resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
}
