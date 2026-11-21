public import Foundation
import AppKit
import CoreServices

/// The few things the updater asks of other processes.
public protocol ProcessControlling: Sendable {
    /// Runs a system tool to completion and returns its exit status.
    func run(_ tool: URL, _ arguments: [String]) throws -> Int32
    func registerWithLaunchServices(_ bundle: URL)
    func isRunning(bundleID: String) -> Bool
    /// Starts a detached helper that waits for `pid` to exit (and ends it when it does not)
    /// and then opens `bundle`.
    /// Throws when the helper could not be started; the caller must then keep running.
    func relaunchAfterExit(pid: Int32, bundle: URL, background: Bool) throws
}

/// The helper that brings a process back after it quits: a `/bin/sh` in its own session,
/// so it survives the process it is waiting for.
public enum RelaunchHelper {
    public static let shell = URL(fileURLWithPath: "/bin/sh")
    public static let opener = "/usr/bin/open"
    /// How long a quitting process is waited for, in steps of 0.05 s (5 s).
    public static let defaultWaitTicks = 100
    /// $1 is the pid to wait for and $2 for how many steps; the rest is the command that
    /// reopens the bundle, tried up to three times. Paths travel as arguments, never
    /// inside the script.
    ///
    /// A process still alive after the wait hangs while quitting. Opening the bundle then
    /// would only find it "already running" and nothing would ever replace it, so it is
    /// killed, and the bundle is opened once it is really gone.
    public static let script = """
        pid=$1; ticks=$2; shift 2
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$ticks" ]; do /bin/sleep 0.05; i=$((i+1)); done
        if kill -0 "$pid" 2>/dev/null; then
          kill -9 "$pid" 2>/dev/null
          i=0
          while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do /bin/sleep 0.05; i=$((i+1)); done
        fi
        n=0
        until "$@"; do n=$((n+1)); [ "$n" -ge 3 ] && exit 1; /bin/sleep 0.5; done
        """

    public static func arguments(pid: Int32, bundle: URL, background: Bool, opener: String = RelaunchHelper.opener,
                                 waitTicks: Int = RelaunchHelper.defaultWaitTicks) -> [String] {
        ["-c", script, "sh", String(pid), String(waitTicks), opener] + (background ? ["-g"] : []) + [bundle.path]
    }

    /// posix_spawn with a new session and /dev/null for standard input and output.
    public static func spawnDetached(_ tool: URL, _ arguments: [String]) throws {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        // No inherited descriptor (the update lock least of all) may outlive this process.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
        }
        var argv: [UnsafeMutablePointer<CChar>?] = ([tool.path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, tool.path, &actions, &attributes, argv, environ)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
    }
}

public struct SystemProcessControl: ProcessControlling {
    public init() {}

    public func run(_ tool: URL, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// What `lsregister -f` does in scripts/install-dev.sh: the installed copy stays the
    /// one LaunchServices resolves for the bundle identifier.
    public func registerWithLaunchServices(_ bundle: URL) {
        LSRegisterURL(bundle as CFURL, true)
        let settings = bundle.appendingPathComponent("Contents/Applications/RimeLingo Settings.app")
        if FileManager.default.fileExists(atPath: settings.path) { LSRegisterURL(settings as CFURL, true) }
    }

    public func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    public func relaunchAfterExit(pid: Int32, bundle: URL, background: Bool) throws {
        try RelaunchHelper.spawnDetached(RelaunchHelper.shell, RelaunchHelper.arguments(pid: pid, bundle: bundle, background: background))
    }
}
