import CoreServices
public import Foundation
import Synchronization

/// A system action of the install that did not do what it was asked.
public struct SystemActionFailure: Error, Equatable, Sendable {
    public var detail: String
    public init(_ detail: String) { self.detail = detail }
}

/// One running process, as far as the install needs to know it.
public struct ProcessEntry: Equatable, Sendable {
    public var pid: Int32
    public var uid: UInt32
    /// Absolute path of the executable.
    public var path: String

    public init(pid: Int32, uid: UInt32, path: String) {
        self.pid = pid
        self.uid = uid
        self.path = path
    }
}

public enum ProcessTable {
    /// Every process whose owner and executable the current user may read (libproc).
    public static func snapshot() -> [ProcessEntry] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        var entries: [ProcessEntry] = []
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            entries.append(ProcessEntry(pid: pid, uid: info.pbi_uid, path: path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }))
        }
        return entries
    }

    public static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}

/// The per-user system agents that have to start over before a newly installed input
/// method can be launched on demand (otherwise `LaunchInputMethod()` fails with -50
/// until the next login). launchd starts them again.
public enum InputAgents {
    public static let names: Set<String> = ["imklaunchagent", "TextInputMenuAgent", "TextInputSwitcher"]

    /// Only Apple's own agents of this user: matched on the executable's name, below
    /// `/System/`, never on a substring.
    public static func targets(in processes: [ProcessEntry], uid: UInt32) -> [ProcessEntry] {
        processes.filter {
            $0.uid == uid && $0.path.hasPrefix("/System/") && names.contains(($0.path as NSString).lastPathComponent)
        }
    }

    /// The current user's other processes that run `executable` (links resolved on both sides).
    public static func instances(of executable: URL, in processes: [ProcessEntry], uid: UInt32, excluding own: Int32) -> [ProcessEntry] {
        let wanted = executable.resolvingSymlinksInPath().path
        return processes.filter {
            $0.uid == uid && $0.pid != own && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == wanted
        }
    }
}

public enum ProcessSignals {
    /// Asks each process to quit and waits for it; one that is still there after `grace`
    /// seconds is killed. A process that is already gone is not an error.
    public static func terminate(_ pids: [Int32], grace: TimeInterval) throws {
        var refused: [Int32] = []
        for pid in pids where pid > 1 && kill(pid, SIGTERM) != 0 && errno != ESRCH { refused.append(pid) }
        let deadline = Date().addingTimeInterval(grace)
        while pids.contains(where: isRunning), Date() < deadline { usleep(50_000) }
        for pid in pids where pid > 1 && isRunning(pid) { kill(pid, SIGKILL) }
        guard refused.isEmpty else {
            throw SystemActionFailure("could not signal \(refused.map(String.init).joined(separator: ", "))")
        }
    }

    private static func isRunning(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
}

/// `com.apple.quarantine`, which a download carries on every file. The system does not
/// start a quarantined input method.
public enum QuarantineAttribute {
    public static let name = "com.apple.quarantine"

    /// Removes the attribute from `root` and everything below it. Links are not followed
    /// and not touched; an item without the attribute is skipped.
    public static func remove(below root: URL) throws {
        try clear(root)
        guard BundleTree.entry(at: root)?.kind == .directory else { return }
        for name in try BundleTree.children(of: root) { try remove(below: root.appendingPathComponent(name)) }
    }

    private static func clear(_ url: URL) throws {
        guard let entry = BundleTree.entry(at: url), entry.kind != .symlink,
              getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 else { return }
        if removexattr(url.path, name, XATTR_NOFOLLOW) == 0 || errno == ENOATTR { return }
        // A read-only item refuses the change even to its owner: open it up for the moment.
        guard errno == EACCES || errno == EPERM, chmod(url.path, mode_t(entry.mode) | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let status = removexattr(url.path, name, XATTR_NOFOLLOW)
        let code = errno
        chmod(url.path, mode_t(entry.mode))
        guard status == 0 || code == ENOATTR else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
}

/// The real thing. Nothing here runs in tests.
public struct SystemInstallActions: InstallSystem {
    static let opener = URL(fileURLWithPath: "/usr/bin/open")

    public init() {}

    public func runningInputMethods(executable: URL) -> [Int32] {
        InputAgents.instances(of: executable, in: ProcessTable.snapshot(), uid: getuid(), excluding: getpid()).map(\.pid)
    }

    /// What `lsregister -f` does in scripts/install-dev.sh: the installed copy becomes the
    /// one LaunchServices resolves for the bundle identifier, so the system can start it.
    public func registerWithLaunchServices(_ bundle: URL) throws {
        let status = LSRegisterURL(bundle as CFURL, true)
        guard status == noErr else { throw SystemActionFailure("LSRegisterURL \(status)") }
        let settings = bundle.appendingPathComponent("Contents/Applications/RimeLingo Settings.app")
        if FileManager.default.fileExists(atPath: settings.path) { LSRegisterURL(settings as CFURL, true) }
    }

    public func enableInputSource(of bundle: URL, select: Bool) throws -> InputSourceActivation {
        let result = try Self.run(bundle.appendingPathComponent(AppInstaller.executablePath), [select ? "--install" : "--enable"],
                                  timeout: 30)
        return InputSourceActivation(exitCode: result.status, output: result.output)
    }

    public func restartInputAgents() throws {
        let agents = InputAgents.targets(in: ProcessTable.snapshot(), uid: getuid())
        try ProcessSignals.terminate(agents.map(\.pid), grace: 1)
    }

    public func terminate(_ pids: [Int32]) throws {
        // Only what still is a process of this user; the identifiers were collected a
        // moment ago, before the files were replaced.
        let mine = Set(ProcessTable.snapshot().filter { $0.uid == getuid() }.map(\.pid))
        try ProcessSignals.terminate(pids.filter { mine.contains($0) && $0 != getpid() }, grace: 2)
    }

    public func start(_ bundle: URL) throws {
        let executable = bundle.appendingPathComponent(AppInstaller.executablePath)
        // The restarted launcher may already have brought it up.
        if !runningInputMethods(executable: executable).isEmpty { return }
        let result = try Self.run(Self.opener, ["-g", bundle.path], timeout: 15)
        guard result.status == 0 else { throw SystemActionFailure("open: exit \(result.status) \(result.output)") }
        for _ in 0..<100 {
            if !runningInputMethods(executable: executable).isEmpty { return }
            usleep(50_000)
        }
        throw SystemActionFailure("the installed input method did not start")
    }

    /// Runs a tool to its end and returns its exit status with everything it printed. One
    /// that is still running after `timeout` seconds is ended.
    static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let pid = process.processIdentifier
        let finished = Mutex(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if !finished.withLock({ $0 }) { kill(pid, SIGKILL) }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        finished.withLock { $0 = true }
        guard process.terminationReason == .exit else {
            throw SystemActionFailure("\(tool.lastPathComponent) did not finish (signal \(process.terminationStatus))")
        }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
