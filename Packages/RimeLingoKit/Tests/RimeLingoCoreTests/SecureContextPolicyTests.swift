@testable import RimeLingoCore
import Testing

struct SecureContextPolicyTests {
    typealias Decision = SecureContextPolicy.Decision

    @Test func ordinaryAppWithoutSecureEventInputIsEligible() {
        let decision = SecureContextPolicy.decision(bundleID: "com.apple.Safari", secureEventInput: false)
        #expect(decision == .eligible)
        #expect(!decision.isSecure)
    }

    @Test func ordinaryAppIsSecureWhileAnyProcessHoldsSecureEventInput() {
        let decision = SecureContextPolicy.decision(bundleID: "com.apple.Safari", secureEventInput: true)
        #expect(decision == .secureEventInput)
        #expect(decision.isSecure)
    }

    /// The system-wide flag may lag behind the first keys on the lock screen, so identity
    /// alone must be enough; and with the flag on, identity still decides the reason.
    @Test(arguments: [
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.authorizationhost",
        "com.apple.LocalAuthentication.UIAgent", "com.apple.LocalAuthenticationRemoteService",
        "com.apple.ScreenSaver.Engine"
    ], [false, true])
    func authenticationSurfacesAreSecureWhateverTheFlagSays(bundleID: String, flag: Bool) {
        let decision = SecureContextPolicy.decision(bundleID: bundleID, secureEventInput: flag)
        #expect(decision == .secureClient)
        #expect(decision.isSecure)
    }

    @Test func clientIdentityIgnoresLetterCase() {
        #expect(SecureContextPolicy.decision(bundleID: "COM.APPLE.LOGINWINDOW", secureEventInput: false) == .secureClient)
    }

    @Test(arguments: [nil, ""] as [String?], [false, true])
    func unidentifiedClientIsSecure(bundleID: String?, flag: Bool) {
        let decision = SecureContextPolicy.decision(bundleID: bundleID, secureEventInput: flag)
        #expect(decision == .unknownClient)
        #expect(decision.isSecure)
    }

    @Test func aSimilarLookingBundleIdentifierIsNotAnAuthenticationSurface() {
        #expect(SecureContextPolicy.decision(bundleID: "com.apple.loginwindow.helper", secureEventInput: false) == .eligible)
        #expect(SecureContextPolicy.decision(bundleID: "org.example.com.apple.loginwindow", secureEventInput: false) == .eligible)
    }

    @Test func pausedHintIsNeverOfferedOnAuthenticationSurfacesOrEligibleFields() {
        #expect(Decision.allCases.filter(\.showsPausedHint) == [.secureEventInput, .unknownClient])
    }

    @Test func bubbleIsAllowedOnAnUnlockedConsoleSessionWithAnOrdinaryOrUnknownAppInFront() {
        #expect(SecureContextPolicy.allowsBubble(frontmostBundleID: "com.apple.Safari", screenLocked: false, onConsole: true))
        #expect(SecureContextPolicy.allowsBubble(frontmostBundleID: nil, screenLocked: false, onConsole: true))
    }

    @Test func noBubbleOverALockedScreen() {
        #expect(!SecureContextPolicy.allowsBubble(frontmostBundleID: "com.apple.Safari", screenLocked: true, onConsole: true))
        #expect(!SecureContextPolicy.allowsBubble(frontmostBundleID: nil, screenLocked: true, onConsole: true))
    }

    @Test func offTheConsoleForbidsTheBubbleOnlyWithoutAKnownFrontmostApp() {
        #expect(SecureContextPolicy.allowsBubble(frontmostBundleID: "com.apple.Safari", screenLocked: false, onConsole: false))
        #expect(!SecureContextPolicy.allowsBubble(frontmostBundleID: nil, screenLocked: false, onConsole: false))
        #expect(!SecureContextPolicy.allowsBubble(frontmostBundleID: "com.apple.loginwindow", screenLocked: false, onConsole: false))
    }

    @Test(arguments: ["com.apple.loginwindow", "com.apple.SecurityAgent", "COM.APPLE.LOCALAUTHENTICATION.UIAGENT"])
    func noBubbleWhileAnAuthenticationSurfaceIsFrontmost(bundleID: String) {
        #expect(!SecureContextPolicy.allowsBubble(frontmostBundleID: bundleID, screenLocked: false, onConsole: true))
    }

    @Test func hintShowsOncePerActivation() {
        var hint = SecureInputHint()
        let shown = [
            hint.shouldShow(for: .secureEventInput),
            hint.shouldShow(for: .secureEventInput),
            hint.shouldShow(for: .unknownClient)
        ]
        #expect(shown == [true, false, false])
        hint.activated()
        let afterActivation = hint.shouldShow(for: .unknownClient)
        #expect(afterActivation)
    }

    @Test func hintIsNotSpentByContextsThatDoNotShowIt() {
        var hint = SecureInputHint()
        let shown = [
            hint.shouldShow(for: .secureClient),
            hint.shouldShow(for: .eligible),
            hint.shouldShow(for: .secureEventInput)
        ]
        #expect(shown == [false, false, true])
    }
}
