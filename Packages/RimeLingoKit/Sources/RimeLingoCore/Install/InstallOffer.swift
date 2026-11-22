public import Foundation

/// What a start of the input method's executable is for.
public enum LaunchContext: Equatable, Sendable {
    /// `--install` / `--enable`: register and enable the input source, then exit.
    case registerInputSource(select: Bool)
    /// Started by the system (or by hand) from an Input Methods folder: serve input.
    case inputMethod
    /// Opened from anywhere else (a download, a disk image, a translocated copy): offer
    /// to install it.
    case installer

    public static let inputMethodsFolder = "Input Methods"

    public static func classify(
        bundle: URL, arguments: [String],
        locations: [URL] = [RimeLingoInstallations.userURL(), RimeLingoInstallations.systemURL]
    ) -> LaunchContext {
        if arguments.contains("--install") { return .registerInputSource(select: true) }
        if arguments.contains("--enable") { return .registerInputSource(select: false) }
        return isInstalled(bundle, locations: locations) ? .inputMethod : .installer
    }

    /// Whether the bundle is an installed copy: it lies directly in a folder named
    /// "Input Methods" (`~/Library/Input Methods`, `/Library/Input Methods`), as given or
    /// once links are resolved, or it is the very bundle one of the two known install
    /// locations leads to. The second rule covers an Input Methods folder that is itself a
    /// link to a folder of another name: LaunchServices hands a copy started through it
    /// the resolved path, in which nothing is called "Input Methods" any more.
    ///
    /// The folder is matched by name as well as against the known paths: an installed copy
    /// that is wrongly taken for a download would never serve input again, which is far
    /// worse than an installer that does not show up for a copy someone put into a folder
    /// of that name elsewhere.
    public static func isInstalled(
        _ bundle: URL,
        locations: [URL] = [RimeLingoInstallations.userURL(), RimeLingoInstallations.systemURL]
    ) -> Bool {
        let resolved = bundle.resolvingSymlinksInPath()
        if [bundle.standardizedFileURL, resolved].contains(where: {
            $0.deletingLastPathComponent().lastPathComponent == inputMethodsFolder
        }) { return true }
        return locations.contains { $0.resolvingSymlinksInPath().path == resolved.path }
    }
}

/// What the installer offers to do, given the copy that is already installed (if any).
public struct InstallOffer: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Nothing is installed.
        case fresh
        /// The installed copy is older.
        case update
        /// The installed copy is the same version, or its version cannot be read.
        case reinstall
        /// The installed copy is newer: only after the user confirms.
        case downgrade
    }

    public var kind: Kind
    public var new: AppVersion
    public var installed: AppVersion?

    /// `exists` without `installed`: something is at the destination, but it has no
    /// readable version.
    public init(new: AppVersion, installed: AppVersion?, exists: Bool) {
        self.new = new
        self.installed = installed
        if let installed {
            kind = installed < new ? .update : (new < installed ? .downgrade : .reinstall)
        } else {
            kind = exists ? .reinstall : .fresh
        }
    }

    public var requiresConfirmation: Bool { kind == .downgrade }

    /// Label of the button that starts the install.
    public var actionTitle: String {
        switch kind {
        case .fresh: "安装"
        case .update: "更新"
        case .reinstall: "重新安装"
        case .downgrade: "安装旧版本"
        }
    }

    public var title: String {
        switch kind {
        case .fresh: "安装灵译输入法"
        case .update: "更新灵译输入法"
        case .reinstall: "重新安装灵译输入法"
        case .downgrade: "已安装的版本更新"
        }
    }

    public var explanation: String {
        switch kind {
        case .fresh: "将把灵译输入法复制到「输入法」文件夹并启用，不需要管理员密码。"
        case .update: "将把已安装的灵译输入法更新到这个版本，你的设置和词库保持不变。"
        case .reinstall: "将用这个版本替换已安装的灵译输入法，你的设置和词库保持不变。"
        case .downgrade: "这台 Mac 上的灵译输入法比这个安装包新。通常不需要换回旧版本。"
        }
    }

    /// "已安装 0.2.0 (20) → 将安装 0.3.0 (21)"; nil when nothing is installed.
    public var versionSummary: String? {
        guard kind != .fresh else { return nil }
        return "已安装 \(installed?.description ?? "未知版本")  →  将安装 \(new.description)"
    }

    /// Reads the version of a copy on disk; nil when it is not this product's bundle.
    public static func version(of bundle: URL, bundleID: String) -> AppVersion? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return AppVersion(version, build: (info["CFBundleVersion"] as? String).flatMap { Int($0) })
    }
}
