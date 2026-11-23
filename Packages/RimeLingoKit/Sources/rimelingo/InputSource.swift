import Carbon
import Foundation
import RimeKit
import RimeLingoCore

enum RimeLingoIdentity {
    static let bundleID = "com.leelib.inputmethod.rimelingo"
    static let inputModeID = "com.leelib.inputmethod.rimelingo.hans"
    /// The copy in charge (newer build; the system-wide one on a tie), else the per-user path.
    static var installedApp: URL { RimeLingoInstallations().preferred?.url ?? RimeLingoInstallations.userURL() }
}

/// Text Input Sources registration (what System Settings › Keyboard › Input Sources lists).
enum InputSourceRegistrar {
    static func sources(includeAll: Bool = true) -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: RimeLingoIdentity.bundleID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, includeAll)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list
    }

    static func property(_ source: TISInputSource, _ key: CFString) -> Any? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }

    static func status() -> String {
        let all = sources()
        guard !all.isEmpty else { return "not registered (run `rimelingo register`)" }
        func enabled(_ id: String) -> Bool? {
            all.first { property($0, kTISPropertyInputSourceID) as? String == id }
                .map { (property($0, kTISPropertyInputSourceIsEnabled) as? Bool) == true }
        }
        guard enabled(RimeLingoIdentity.inputModeID) == true else {
            return "registered (enable it in System Settings › Keyboard › Input Sources)"
        }
        // The mode alone reports enabled right after a first install; macOS lists and selects
        // RimeLingo only once its input method is enabled too, which takes a log out (#8).
        return enabled(RimeLingoIdentity.bundleID) == false
            ? "registered, pending (log out and back in once so macOS lists RimeLingo)" : "registered, enabled"
    }

    @discardableResult
    static func register(appURL: URL) -> OSStatus {
        TISRegisterInputSource(appURL as CFURL)
    }

    static func enable() -> Bool {
        var ok = false
        for source in sources() {
            let id = property(source, kTISPropertyInputSourceID) as? String
            if id == RimeLingoIdentity.inputModeID || id == RimeLingoIdentity.bundleID {
                ok = TISEnableInputSource(source) == noErr || ok
            }
        }
        return ok
    }
}

enum PluginLocator {
    @MainActor static func plugins() -> [String] { RimeEngine.shared.availablePlugins }
}
