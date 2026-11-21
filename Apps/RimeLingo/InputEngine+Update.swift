import RimeLingoCore
import AppKit
import Carbon
@preconcurrency import UserNotifications

/// Automatic updates in the input method: a daily check of the public release manifest,
/// a background download, an in-place install when the user is idle, then a restart.
/// All decisions live in `UpdateCoordinator` (RimeLingoCore); this file only supplies what
/// the input method knows (is the user busy?) and does what only it can do (notify, quit).
/// Nothing typed is ever sent: the manifest and the archive are the only requests.
@MainActor
final class UpdateService {
    static let shared = UpdateService()

    private let paths = InputEngine.shared.paths
    private let coordinator: UpdateCoordinator
    private var started = false
    private var running = false
    private var installTimer: Timer?
    /// "Install now" from Settings: waives the 30 s idle rule until that install is over.
    private var installRequest = UserInstallRequest()
    private var announcedInstall = false
    /// Whether this build updates itself at all (false for development builds).
    private(set) var isEligible = false

    private init() {
        coordinator = UpdateCoordinator(paths: paths, bundle: Bundle.main.bundleURL,
                                        bundleID: Bundle.main.bundleIdentifier ?? RimeLingoInstallations.bundleID,
                                        current: .current())
    }

    func start() {
        guard !started else { return }
        started = true
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init(UpdateNotifications.check), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UpdateService.shared.pass(force: true) }
        }
        center.addObserver(forName: .init(UpdateNotifications.install), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UpdateService.shared.installNow() }
        }
        Task {
            await coordinator.setOnChange {
                DistributedNotificationCenter.default().postNotificationName(
                    .init(UpdateNotifications.changed), object: nil, userInfo: nil, deliverImmediately: true)
            }
            if case .eligible = await coordinator.eligibility() { isEligible = true }
            if let version = await coordinator.confirmRelaunch() {
                // This process is the new version, started by the relaunch helper. Register
                // the bundle again so the input source keeps pointing at it; this neither
                // enables nor selects anything.
                TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
                InputEngine.shared.logger.info("updated to \(version, privacy: .public)")
                notify(title: String(localized: "灵译输入法已更新到 \(version)"), body: nil)
            }
            await reportFailure()
            scheduleInstall()
        }
    }

    /// Hourly and shortly after launch; the coordinator checks at most once a day.
    func pass(force: Bool = false) {
        guard started, isEligible, !running else { return }
        running = true
        Task {
            defer { running = false }
            await Task.detached(priority: .utility) { [coordinator] in
                await coordinator.check(force: force)
                await coordinator.downloadIfNeeded(userRequested: force)
            }.value
            await reportFailure()
            scheduleInstall()
        }
    }

    private func installNow() {
        guard started, isEligible else { return }
        installRequest.make()
        scheduleInstall()
        attemptInstall()
    }

    /// While an update is staged, look every 10 s for a moment in which nothing is interrupted.
    private func scheduleInstall() {
        let phase = UpdateState.load(paths).phase
        guard isEligible, phase == .ready || phase == .restartPending else {
            installTimer?.invalidate()
            installTimer = nil
            return
        }
        guard installTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateService.shared.attemptInstall() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        installTimer = timer
    }

    private func attemptInstall() {
        guard !running else { return }
        let userRequested = installRequest.isActive
        let idle = InputEngine.shared.updateIdleSnapshot()
        // Decided here as well, so that a busy user costs no file access at all.
        guard idle.allowsInstall(userRequested: userRequested) else { return }
        running = true
        Task {
            defer { running = false }
            let outcome = await Task.detached(priority: .utility) { [coordinator] in
                await coordinator.installIfReady(idle: idle, userRequested: userRequested)
            }.value
            installRequest.settle(outcome)
            switch outcome {
            case let .installed(version):
                if !announcedInstall {
                    announcedInstall = true
                    DistributedNotificationCenter.default().postNotificationName(
                        .init(UpdateNotifications.installed), object: nil, userInfo: ["version": version], deliverImmediately: true)
                }
                // The install took a moment: restart only if the user still is idle by the
                // rule the install started under (30 s without a key unless they asked for
                // it). Otherwise the timer comes back here; the new files stay in place.
                guard InputEngine.shared.updateIdleSnapshot().allowsInstall(userRequested: userRequested) else { return }
                // Quit only once the helper that brings this process back is running.
                guard await coordinator.relaunch(pid: getpid(), background: true) else {
                    InputEngine.shared.logger.error("update installed but the relaunch helper did not start")
                    return
                }
                InputEngine.shared.logger.info("restarting into \(version, privacy: .public)")
                NSApp.terminate(nil)
            case .failed:
                await reportFailure()
                scheduleInstall()
            case .notReady:
                scheduleInstall()
            case .deferred:
                break
            }
        }
    }

    private func reportFailure() async {
        guard let failure = await coordinator.takeFailureNotice() else { return }
        InputEngine.shared.logger.error("update failed: \(failure.code, privacy: .public)")
        notify(title: String(localized: "灵译输入法更新失败"), body: failure.errorDescription)
    }

    /// One quiet (provisional) notification; never a dialog.
    private func notify(title: String, body: String?) {
        let center = UNUserNotificationCenter.current()
        center.delegate = UpdateNotificationDelegate.shared
        center.requestAuthorization(options: [.alert, .provisional]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if let body { content.body = body }
            center.add(UNNotificationRequest(identifier: "io.github.leaker.rimelingo.update", content: content, trigger: nil))
        }
    }

    /// The input menu entry, shown only when there is something to see in Settings.
    var menuTitle: String? {
        guard isEligible else { return nil }
        let state = UpdateState.load(paths)
        if state.phase == .ready, let release = state.release {
            return String(localized: "更新 \(release.version) 已就绪，空闲时自动安装")
        }
        if state.phase == .failed, let failure = state.failure?.failure, failure.notificationThreshold > 0 {
            return String(localized: "更新失败，查看详情…")
        }
        return nil
    }
}

extension InputEngine {
    func checkForAppUpdate() { UpdateService.shared.pass() }
}

/// Opens the overview in Settings when the notification is clicked.
final class UpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = UpdateNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { RimeLingoInputController.openSettings(pane: "overview") }
    }
}
