/// Decides whether an input context is secure: in a secure context the input method
/// passes every key through untouched and neither reads from nor writes to the client.
/// Pure logic. It sees only who the client is and the system-wide Secure Event Input
/// flag, never the text, selection or surroundings of the field.
public enum SecureContextPolicy {
    public enum Decision: Sendable, Equatable, CaseIterable {
        /// Ordinary input may proceed.
        case eligible
        /// The client is a system authentication surface (see `secureClients`).
        case secureClient
        /// Some process holds Secure Event Input; which one is not known.
        case secureEventInput
        /// The client did not identify itself, so eligibility cannot be established.
        case unknownClient

        public var isSecure: Bool { self != .eligible }

        /// Whether the user is told that Chinese input is paused. Never on the system
        /// authentication surfaces: nothing of ours may appear over them.
        public var showsPausedHint: Bool { self == .secureEventInput || self == .unknownClient }
    }

    /// Clients that are always secure, whatever the system-wide flag says: the flag may
    /// only turn on after the first keys have arrived. Lowercased bundle identifiers,
    /// read from the bundles shipped in /System/Library (none of them was launched).
    public static let secureClients: Set<String> = [
        // CoreServices/loginwindow.app: lock-screen unlock and the login window.
        "com.apple.loginwindow",
        // Security.framework SecurityAgent.bundle: system authorization dialogs.
        "com.apple.securityagent",
        // Security.framework authorizationhost.bundle: runs the authorization plug-ins
        // (SecurityAgentPlugins) behind those dialogs.
        "com.apple.authorizationhost",
        // LocalAuthentication.framework coreautha.bundle: Touch ID / password sheets.
        "com.apple.localauthentication.uiagent",
        // LocalAuthenticationUI.framework XPC service: the same sheets drawn out of process.
        "com.apple.localauthenticationremoteservice",
        // CoreServices/ScreenSaverEngine.app: keys typed over a screen saver are an unlock.
        "com.apple.screensaver.engine",
    ]

    /// - Parameters:
    ///   - bundleID: the client's bundle identifier as it reports it now.
    ///   - secureEventInput: `IsSecureEventInputEnabled()` sampled now.
    public static func decision(bundleID: String?, secureEventInput: Bool) -> Decision {
        guard let bundleID, !bundleID.isEmpty else { return .unknownClient }
        if secureClients.contains(bundleID.lowercased()) { return .secureClient }
        return secureEventInput ? .secureEventInput : .eligible
    }

    /// Whether a status bubble may be put on screen at all, from what the system says
    /// about the login session rather than from any client: never over a locked screen,
    /// never while an authentication surface is the frontmost application. A session off
    /// the console (screen sharing into another account) is ordinary input as long as the
    /// frontmost application is known; with none known it forbids the bubble.
    /// - Parameter onConsole: false only when the session reports it explicitly.
    public static func allowsBubble(frontmostBundleID: String?, screenLocked: Bool, onConsole: Bool) -> Bool {
        guard !screenLocked else { return false }
        guard let frontmostBundleID else { return onConsole }
        return !secureClients.contains(frontmostBundleID.lowercased())
    }
}

/// Limits the "Chinese input is paused" hint to one per activation of a text field.
public struct SecureInputHint: Sendable {
    private var shown = false

    public init() {}

    /// The field became active: the next secure key may show the hint again.
    public mutating func activated() { shown = false }

    /// True when the hint should be shown now; counts it as shown.
    public mutating func shouldShow(for decision: SecureContextPolicy.Decision) -> Bool {
        guard decision.showsPausedHint, !shown else { return false }
        shown = true
        return true
    }
}
