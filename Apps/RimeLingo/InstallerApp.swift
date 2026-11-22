import AppKit
import RimeLingoCore
import SwiftUI

/// Installer mode: what the executable does when it is opened from anywhere but an Input
/// Methods folder (a download, a disk image). It shows one window that copies this bundle
/// into `~/Library/Input Methods` and enables it, so a first install needs no Terminal, no
/// logout and no administrator password. The steps themselves are `AppInstaller`
/// (RimeLingoCore); this file and InstallerView.swift only show them.
enum InstallerApp {
    @MainActor
    static func run() -> Never {
        let application = NSApplication.shared
        let delegate = InstallerAppDelegate()
        application.delegate = delegate
        // The bundle is a background agent (LSUIElement); the installer is an ordinary app.
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
        exit(0)
    }
}

@MainActor
final class InstallerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = InstallerModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        let controller = NSHostingController(rootView: InstallerView(model: model))
        // The window follows the height of what each state shows.
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.title = "安装灵译输入法"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files are being replaced: quitting waits until that is over.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.isInstalling ? .terminateCancel : .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.isInstalling }

    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ submenu: NSMenu) {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        let app = NSMenu()
        app.addItem(withTitle: "隐藏", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "退出安装程序", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app)
        // The technical detail of a failure can be selected and copied.
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit)
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        add(window)
        return main
    }
}

@MainActor
@Observable
final class InstallerModel {
    enum Phase: Equatable, Sendable {
        case ready
        case installing(InstallStep)
        case done
        case failed(InstallFailure)
    }

    /// `README.md`, section 「手动安装」.
    static let manualInstallURL = URL(string: "https://github.com/\(UpdateConfiguration.repository)#%E6%89%8B%E5%8A%A8%E5%AE%89%E8%A3%85")!

    let source = Bundle.main.bundleURL
    let destination = RimeLingoInstallations.userURL()
    let bundleID = Bundle.main.bundleIdentifier ?? RimeLingoInstallations.bundleID
    private(set) var phase = Phase.ready
    private(set) var offer: InstallOffer
    /// A system-wide copy shares the bundle identifier; macOS may then use either one.
    let hasSystemCopy = FileManager.default.fileExists(atPath: RimeLingoInstallations.systemURL.path)
    /// Whether the install that just finished was the first one on this Mac.
    private(set) var wasFirstInstall = false

    var isInstalling: Bool {
        if case .installing = phase { return true }
        return false
    }

    init() {
        offer = Self.currentOffer(destination: destination, bundleID: bundleID)
    }

    private static func currentOffer(destination: URL, bundleID: String) -> InstallOffer {
        InstallOffer(new: .current(), installed: InstallOffer.version(of: destination, bundleID: bundleID),
                     exists: FileManager.default.fileExists(atPath: destination.path))
    }

    func install() {
        guard !isInstalling else { return }
        // A failed attempt may have left a copy behind (or put the previous one back).
        offer = Self.currentOffer(destination: destination, bundleID: bundleID)
        wasFirstInstall = offer.kind == .fresh
        // An input source the user already uses stays as selected as it was. One that is
        // not enabled yet (a first install, or a copy that was only ever moved into the
        // folder by hand) is selected, so that typing works right away.
        let select = offer.kind == .fresh || !InputSourceInstaller.sources().contains(where: InputSourceInstaller.isEnabled)
        let installer = AppInstaller(source: source, destination: destination, bundleID: bundleID, select: select,
                                     updates: UpdatePaths(.standard), signature: SecCodeSignatureEvaluator(depth: .complete),
                                     system: SystemInstallActions())
        phase = .installing(.checkPackage)
        // In order: the main queue is serial, so the last step never overtakes the result.
        let report: @Sendable (Phase) -> Void = { [weak self] phase in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.phase = phase } }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try installer.install { report(.installing($0)) }
                report(.done)
            } catch let failure as InstallFailure {
                report(.failed(failure))
            } catch {
                report(.failed(InstallFailure(step: .checkPackage, reason: .copy, detail: "\(error)", bundle: .untouched)))
            }
        }
    }

    /// Opens the settings app of the installed copy (its first-run guide after a first
    /// install) and quits.
    func openSettingsAndQuit() {
        let settings = destination.appendingPathComponent("Contents/Applications/RimeLingo Settings.app")
        let configuration = NSWorkspace.OpenConfiguration()
        if wasFirstInstall { configuration.arguments = ["--onboarding"] }
        NSWorkspace.shared.openApplication(at: settings, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                // Staying open keeps 「完成」 within reach when the settings app did not start.
                if error == nil { NSApp.terminate(nil) } else { NSSound.beep() }
            }
        }
    }
}
