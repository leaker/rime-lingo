public import Foundation

/// The steps of a first install (or of installing over an existing copy), in order.
public enum InstallStep: Int, CaseIterable, Sendable {
    case checkPackage, copyFiles, verifySignature, clearQuarantine, registerApp, enableInputSource,
         restartInputAgents, startInputMethod

    public var title: String {
        switch self {
        case .checkPackage: "正在检查安装包…"
        case .copyFiles: "正在复制到「输入法」文件夹…"
        case .verifySignature: "正在校验签名…"
        case .clearQuarantine: "正在解除下载隔离标记…"
        case .registerApp: "正在向系统登记…"
        case .enableInputSource: "正在启用输入法…"
        case .restartInputAgents: "正在重启系统的输入法服务…"
        case .startInputMethod: "正在启动灵译输入法…"
        }
    }
}

/// What the installed copy's own `--install` / `--enable` reported.
public struct InputSourceActivation: Equatable, Sendable {
    public var exitCode: Int32
    public var output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

/// Everything an install does besides moving files, behind a seam so that tests never
/// register, signal or start anything.
public protocol InstallSystem: Sendable {
    /// Process identifiers of the current user's processes that run `executable`.
    func runningInputMethods(executable: URL) -> [Int32]
    func registerWithLaunchServices(_ bundle: URL) throws
    /// Runs the copy's own registration (`--install` with `select`, else `--enable`).
    func enableInputSource(of bundle: URL, select: Bool) throws -> InputSourceActivation
    /// Ends the current user's input method launcher and menu agents; launchd starts new
    /// ones, which know the input method that was just installed.
    func restartInputAgents() throws
    func terminate(_ pids: [Int32]) throws
    /// Makes sure the installed copy runs.
    func start(_ bundle: URL) throws
}

public struct InstallFailure: Error, Equatable, Sendable {
    public enum Reason: String, Sendable {
        case damagedPackage, folder, notWritable, busy, copy, signature, quarantine, registration, enable, agents, start
    }

    /// What is at the destination after the failure.
    public enum BundleState: Equatable, Sendable {
        /// Nothing was changed: no copy if there was none, the previous one otherwise.
        case untouched
        /// The previous version was put back.
        case restored
        /// The previous version could not be put back; a copy of it is kept at `backup`.
        case damaged(backup: String)
        /// The new version is completely in place; a later step failed.
        case installed
    }

    public var step: InstallStep
    public var reason: Reason
    /// Technical detail for a bug report; not shown as the main text.
    public var detail: String
    public var bundle: BundleState

    public init(step: InstallStep, reason: Reason, detail: String = "", bundle: BundleState) {
        self.step = step
        self.reason = reason
        self.detail = detail
        self.bundle = bundle
    }

    /// What failed, in plain words.
    public var message: String {
        let what = switch reason {
        case .damagedPackage: "这个安装包不完整或已损坏，请重新下载后再试。"
        case .folder: "无法创建「输入法」文件夹（个人资料库里的 Input Methods）。"
        case .notWritable: "当前用户没有权限修改「输入法」文件夹里的灵译输入法。"
        case .busy: "灵译输入法正在自动更新，请稍等片刻再试。"
        case .copy: "复制文件时出错。"
        case .signature: "复制过去的文件没有通过签名校验。"
        case .quarantine: "文件已复制，但没能解除系统对下载文件的隔离标记。"
        case .registration: "文件已复制，但系统没有接受这个应用的登记。"
        case .enable: "文件已复制，但没能启用输入法。也可以到「系统设置 › 键盘 › 输入法」里手动添加灵译输入法。"
        case .agents: "输入法已安装并启用，但没能重启系统的输入法服务。注销后重新登录即可使用。"
        case .start: "输入法已安装并启用，但没能启动。注销后重新登录即可使用。"
        }
        return switch bundle {
        case .untouched, .installed: what
        case .restored: what + "已恢复为原来的版本。"
        case .damaged: what + "原来的版本没能恢复，请点「重试」。"
        }
    }
}

/// The rule the installed copy must pass before anything is told about it.
public enum InstalledCopyCheck {
    /// Nil when `installed` is an intact copy of the build that is running; a short reason otherwise.
    public static func problem(installed: SignatureInfo, running: SignatureInfo, bundleID: String) -> String? {
        guard installed.isValid else { return "invalid signature" }
        guard installed.bundleID == bundleID else { return "identifier \(installed.bundleID ?? "none")" }
        if let version = running.version, installed.version != version || installed.build != running.build {
            return "version \(installed.version ?? "none") (\(installed.build.map(String.init) ?? "none"))"
        }
        // A release stays a release: the copy has to satisfy the requirement the updater
        // holds every later version to.
        if running.satisfiesDeveloperID, !installed.satisfiesDeveloperID || installed.teamID != UpdateConfiguration.teamID {
            return "not a Developer ID release"
        }
        return nil
    }
}

/// Installs the bundle this process runs from into the user's Input Methods folder and
/// makes the system use it, without a logout.
///
/// A copy that is already installed keeps its bundle directory: macOS drops an input
/// source whose bundle was deleted and recreated from the menu until the next login. Its
/// contents are replaced item by item (`BundleReplacer`), with a copy of the previous
/// contents beside it to put back when the replacement or the check after it fails.
public struct AppInstaller: Sendable {
    /// Relative path of the input method's executable.
    public static let executablePath = "Contents/MacOS/RimeLingo"
    /// Working directories beside the destination. Not named `*.app`: nothing may take
    /// what is staged in them for an installed input method.
    static let workPrefix = ".rimelingo-install-"

    public var source: URL
    public var destination: URL
    public var bundleID: String
    /// Select the input source after enabling it (a first install); otherwise the user's
    /// current input source is left alone.
    public var select: Bool
    /// The updater's files, to stay out of its way and to keep it from undoing this install.
    public var updates: UpdatePaths?
    public var signature: any CodeSignatureEvaluating
    public var fs: any UpdateFileSystem
    public var system: any InstallSystem
    public var clearQuarantine: @Sendable (URL) throws -> Void

    public init(source: URL, destination: URL, bundleID: String, select: Bool, updates: UpdatePaths?,
                signature: any CodeSignatureEvaluating, fs: any UpdateFileSystem = LocalUpdateFileSystem(),
                system: any InstallSystem,
                clearQuarantine: @escaping @Sendable (URL) throws -> Void = { try QuarantineAttribute.remove(below: $0) }) {
        self.source = source
        self.destination = destination
        self.bundleID = bundleID
        self.select = select
        self.updates = updates
        self.signature = signature
        self.fs = fs
        self.system = system
        self.clearQuarantine = clearQuarantine
    }

    private enum Placement {
        case created(work: URL)
        case replaced(work: URL, backup: URL)
    }

    /// Runs every step in order and reports each before it starts. Throws `InstallFailure`.
    public func install(progress: @Sendable (InstallStep) -> Void = { _ in }) throws {
        // Asked before any file changes: once the executable has been replaced, the file a
        // running copy was started from no longer has a path to find it by.
        let previous = system.runningInputMethods(executable: destination.appendingPathComponent(Self.executablePath))

        progress(.checkPackage)
        let lock = try prepare()
        defer { withExtendedLifetime(lock) {} }

        progress(.copyFiles)
        let placement = try place()
        progress(.verifySignature)
        if let problem = InstalledCopyCheck.problem(installed: signature.evaluate(bundle: destination),
                                                    running: signature.evaluateRunningProcess(), bundleID: bundleID) {
            throw undo(placement, InstallFailure(step: .verifySignature, reason: .signature, detail: problem, bundle: .installed))
        }
        finish(placement, holdingUpdateLock: lock != nil)

        try run(.clearQuarantine, .quarantine, progress) { try clearQuarantine(destination) }
        try run(.registerApp, .registration, progress) { try system.registerWithLaunchServices(destination) }
        try run(.enableInputSource, .enable, progress) {
            let result = try system.enableInputSource(of: destination, select: select)
            guard result.exitCode == 0 else {
                throw InstallFailure(step: .enableInputSource, reason: .enable,
                                     detail: "exit \(result.exitCode)\n\(result.output)", bundle: .installed)
            }
        }
        try run(.restartInputAgents, .agents, progress) { try system.restartInputAgents() }
        // A copy that was running still executes the previous files. It is ended only now
        // that the new ones are in place, and the installed copy is started right away:
        // applications with an open text field must not be left without an input method.
        try run(.startInputMethod, .start, progress) {
            try system.terminate(previous)
            try system.start(destination)
        }
    }

    private func run(_ step: InstallStep, _ reason: InstallFailure.Reason, _ progress: (InstallStep) -> Void,
                     _ body: () throws -> Void) throws {
        progress(step)
        do {
            try body()
        } catch let failure as InstallFailure {
            throw failure
        } catch {
            throw InstallFailure(step: step, reason: reason, detail: Self.describe(error), bundle: .installed)
        }
    }

    /// Checks that do not change anything but the folder itself. Returns the updater's
    /// lock when there is an updater to exclude.
    private func prepare() throws -> UpdateLock? {
        func failure(_ reason: InstallFailure.Reason, _ detail: String = "") -> InstallFailure {
            InstallFailure(step: .checkPackage, reason: reason, detail: detail, bundle: .untouched)
        }
        // A damaged download must not get as far as replacing a copy that works.
        guard signature.evaluateRunningProcess().isValid else { throw failure(.damagedPackage) }
        let folder = destination.deletingLastPathComponent()
        do { try fs.createDirectory(at: folder) } catch { throw failure(.folder, Self.describe(error)) }
        guard fs.isUserWritable(folder) else { throw failure(.notWritable, folder.path) }
        switch BundleTree.entry(at: destination)?.kind {
        case nil: break
        case .directory:
            let contents = destination.appendingPathComponent("Contents")
            guard fs.isUserWritable(destination), BundleTree.entry(at: contents) == nil || fs.isUserWritable(contents) else {
                throw failure(.notWritable, destination.path)
            }
        default: throw failure(.copy, "the destination is not a folder")
        }
        // An updater exists only once an installed copy has run. It is never created here.
        guard let updates, FileManager.default.fileExists(atPath: updates.root.path) else { return nil }
        guard let lock = UpdateLock.acquire(updates) else { throw failure(.busy) }
        return lock
    }

    private func place() throws -> Placement {
        func untouched(_ error: any Error) -> InstallFailure {
            InstallFailure(step: .copyFiles, reason: .copy, detail: Self.describe(error), bundle: .untouched)
        }
        let folder = destination.deletingLastPathComponent()
        // Left by an install that was cut short. The source is complete, so whatever such
        // an install did to the destination is replaced below.
        for name in (try? BundleTree.children(of: folder)) ?? [] where name.hasPrefix(Self.workPrefix) {
            try? fs.removeItem(at: folder.appendingPathComponent(name))
        }
        let work = folder.appendingPathComponent(Self.workPrefix + UUID().uuidString, isDirectory: true)

        guard BundleTree.entry(at: destination) != nil else {
            do {
                // Copied beside the destination and moved into place in one step: the
                // system never sees a bundle that is half there.
                try fs.createDirectory(at: work)
                let payload = work.appendingPathComponent("payload", isDirectory: true)
                try fs.copyItem(at: source, to: payload)
                try fs.rename(payload, to: destination)
            } catch {
                try? fs.removeItem(at: work)
                throw untouched(error)
            }
            return .created(work: work)
        }

        let replacer = BundleReplacer(fs: fs)
        let backup = work.appendingPathComponent("previous", isDirectory: true)
        let plan: BundleReplacer.Plan
        do {
            try fs.createDirectory(at: work)
            replacer.cleanTemporaries(in: destination)
            try fs.copyItem(at: destination, to: backup)
            plan = try replacer.plan(from: source, into: destination)
            try replacer.prepare(plan)
        } catch {
            try? fs.removeItem(at: work)
            throw untouched(error)
        }
        let placement = Placement.replaced(work: work, backup: backup)
        do {
            try replacer.commit(plan)
            try replacer.removeStale(plan)
        } catch {
            throw undo(placement, InstallFailure(step: .copyFiles, reason: .copy, detail: Self.describe(error), bundle: .installed))
        }
        return placement
    }

    /// Takes the destination back to what it was and returns `failure` saying how that went.
    private func undo(_ placement: Placement, _ failure: InstallFailure) -> InstallFailure {
        var failure = failure
        switch placement {
        case let .created(work):
            // Nothing was installed before: the copy that failed its check is removed.
            do {
                try fs.removeItem(at: destination)
                failure.bundle = .untouched
            } catch {
                failure.detail += "; could not remove the copy: \(Self.describe(error))"
            }
            try? fs.removeItem(at: work)
        case let .replaced(work, backup):
            do {
                try BundleReplacer(fs: fs).replace(from: backup, into: destination)
                try? fs.removeItem(at: work)
                failure.bundle = .restored
            } catch {
                failure.detail += "; restore: \(Self.describe(error))"
                failure.bundle = .damaged(backup: backup.path)
            }
        }
        return failure
    }

    private func finish(_ placement: Placement, holdingUpdateLock: Bool) {
        switch placement {
        case let .created(work), let .replaced(work, _): try? fs.removeItem(at: work)
        }
        // An update that was interrupted would be "recovered" at the next launch by
        // putting its backup over the copy that was just installed and verified.
        guard holdingUpdateLock, let updates else { return }
        try? fs.removeItem(at: updates.marker)
        try? fs.removeItem(at: updates.backup)
    }

    static func describe(_ error: any Error) -> String {
        if let failure = error as? InstallFailure { return failure.detail }
        if let failure = error as? SystemActionFailure { return failure.detail }
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
