import AppKit
import InputMethodKit
import RimeLingoCore

// RimeLingo input method server. Runs as a background agent (LSUIElement) launched by the
// system's text input machinery; InputMethodKit instantiates RimeLingoInputController per
// client context.
//
// The same executable has two other jobs, told apart before anything else happens:
// registering the input source (`--install` / `--enable`, run by the installer below and by
// scripts/install-dev.sh), and, when it is opened from anywhere but an Input Methods
// folder (a download, a disk image), offering to install itself. A copy the system starts
// from an Input Methods folder never gets there.
switch LaunchContext.classify(bundle: Bundle.main.bundleURL, arguments: CommandLine.arguments) {
case let .registerInputSource(select): exit(InputSourceInstaller.install(select: select))
case .installer: InstallerApp.run()
case .inputMethod: break
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
