import AppKit
import InputMethodKit
import RimeLingoCore

// RimeLingo input method server. Runs as a background agent (LSUIElement) launched by the
// system's text input machinery; InputMethodKit instantiates RimeLingoInputController per
// client context.
// Installer entry points (run by scripts/install-dev.sh, or by hand after a first install).
let arguments = CommandLine.arguments
if arguments.contains("--install") || arguments.contains("--enable") {
    exit(InputSourceInstaller.install(select: arguments.contains("--install")))
}

// An update that was interrupted while replacing files is undone before anything else
// uses the bundle (release builds only; a development build leaves its bundle alone). The
// files of this very process may then be the ones that were just replaced again, so it
// starts over from the restored bundle instead of going on.
if case .rolledBack = UpdateCoordinator.recoverAtLaunch(paths: .standard, bundle: Bundle.main.bundleURL),
   (try? SystemProcessControl().relaunchAfterExit(pid: getpid(), bundle: Bundle.main.bundleURL, background: true)) != nil {
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate

guard let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
      let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier) else {
    fatalError("RimeLingo: failed to start IMKServer")
}
delegate.server = server
application.run()
