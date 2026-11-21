import Testing
@testable import RimeLingoCore

struct InputSourceReturnTests {
    @Test func recognizesOnlyRimeLingoSources() {
        #expect(InputSourceReturn.isRimeLingo("io.github.leaker.inputmethod.rimelingo.hans"))
        #expect(InputSourceReturn.isRimeLingo("io.github.leaker.inputmethod.rimelingo"))
        #expect(!InputSourceReturn.isRimeLingo("com.apple.keylayout.ABC"))
        #expect(!InputSourceReturn.isRimeLingo("im.rime.inputmethod.Squirrel.Hans"))
        #expect(!InputSourceReturn.isRimeLingo("io.github.leaker.inputmethod.rimelingox"))
    }

    /// The reset is written through the policy so the next app inherits Chinese too.
    @Test func resetRecordsChineseForSharedAndOwnState() {
        var policy = AsciiStatePolicy(scope: .global)
        policy.record(true, app: "com.apple.TextEdit", appDefault: nil)
        policy.record(false, app: "com.apple.TextEdit", appDefault: nil)
        #expect(policy.state(for: "com.apple.Notes", appDefault: nil, newSession: false) == false)

        var perApp = AsciiStatePolicy(scope: .app)
        perApp.record(true, app: "com.apple.TextEdit", appDefault: nil)
        perApp.record(false, app: "com.apple.TextEdit", appDefault: nil)
        #expect(perApp.state(for: "com.apple.TextEdit", appDefault: nil, newSession: false) == false)
    }
}
