import Carbon
import Foundation

/// `RimeLingo --install`: registers, enables and selects the RimeLingo input source from the
/// input method's own process (scripts/install-dev.sh, or by hand after a first install).
/// Text Input Sources only lets an input method select its own modes reliably from
/// its own bundle.
enum InputSourceInstaller {
    static let modeID = "com.leelib.inputmethod.rimelingo.hans"

    static func property(_ source: TISInputSource, _ key: CFString) -> Any? {
        TISGetInputSourceProperty(source, key).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
    }

    static func sourceID(_ source: TISInputSource) -> String {
        property(source, kTISPropertyInputSourceID) as? String ?? ""
    }

    /// The input method's own sources: the input method itself and its modes.
    ///
    /// They are matched on the input source identifier, which is read from the bundle on every
    /// scan. `kTISPropertyBundleID` is not used: the system's input source cache can keep
    /// reporting a stale bundle identifier, and a filter on it then matches nothing.
    static func sources() -> [TISInputSource] {
        guard let own = Bundle.main.bundleIdentifier, !own.isEmpty else { return [] }
        let all = (TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
        return all.filter { sourceID($0) == own || sourceID($0).hasPrefix(own + ".") }
    }

    static func isEnabled(_ source: TISInputSource) -> Bool {
        property(source, kTISPropertyInputSourceIsEnabled) as? Bool ?? false
    }

    /// Returns a process exit code: 0 only when every own source is enabled afterwards and,
    /// with `select`, the mode was selected.
    static func install(select: Bool) -> Int32 {
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        print("register: \(status)")
        let found = sources()
        guard !found.isEmpty else {
            print("enable: no input source of \(Bundle.main.bundleIdentifier ?? "?") is known to the system")
            return 1
        }
        for source in found {
            print("enable \(sourceID(source)): \(TISEnableInputSource(source))")
        }
        // The call's status alone does not prove anything: ask the system again. The new
        // state can take a moment to show up, so allow it a short while.
        var allEnabled = false
        for attempt in 0..<10 {
            if attempt > 0 { usleep(200_000) }
            allEnabled = sources().allSatisfy(isEnabled)
            if allEnabled { break }
        }
        for source in sources() {
            print("enabled \(sourceID(source)): \(isEnabled(source))")
        }
        guard select else { return allEnabled ? 0 : 1 }
        guard let mode = sources().first(where: { sourceID($0) == modeID }) else {
            print("select: mode \(modeID) not found")
            return 1
        }
        let result = TISSelectInputSource(mode)
        print("select \(modeID): \(result)")
        return result == noErr && allEnabled ? 0 : 1
    }
}
