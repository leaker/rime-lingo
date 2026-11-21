import Testing
@testable import RimeLingoCore

struct TranslationShortcutsTests {
    @Test func matchesEAndJWithControlOptionCommand() {
        #expect(TranslationShortcuts.target(keyCode: 14, control: true, option: true, command: true, shift: false) == .english)
        #expect(TranslationShortcuts.target(keyCode: 38, control: true, option: true, command: true, shift: false) == .japanese)
    }

    @Test func otherKeysDoNotMatch() {
        for keyCode: UInt16 in [0, 13, 15, 36, 37, 40, 53] {
            #expect(TranslationShortcuts.target(keyCode: keyCode, control: true, option: true, command: true, shift: false) == nil)
        }
    }

    @Test func modifiersMustBeExact() {
        for keyCode in [TranslationShortcuts.englishKeyCode, TranslationShortcuts.japaneseKeyCode] {
            for bits in 0..<16 {
                let control = bits & 1 != 0, option = bits & 2 != 0, command = bits & 4 != 0, shift = bits & 8 != 0
                let matched = TranslationShortcuts.target(keyCode: keyCode, control: control, option: option, command: command, shift: shift)
                #expect((matched != nil) == (control && option && command && !shift))
            }
        }
    }

    private func decide(
        _ target: TranslationTarget, enabled: Bool = true, isRepeat: Bool = false, menuOrActionOpen: Bool = false,
        hasSelection: Bool = false, sessionActive: Bool = false
    ) -> TranslationDispatch {
        TranslationDispatch.decide(
            target: target, featureEnabled: enabled, isRepeat: isRepeat, menuOrActionOpen: menuOrActionOpen,
            hasSelection: hasSelection, sessionActive: sessionActive)
    }

    private func key(
        _ keyCode: UInt16, option: Bool = false, command: Bool = false, control: Bool = false, shift: Bool = false,
        isComposing: Bool = false, hasValidTranslation: Bool = true
    ) -> LiveSessionKey {
        LiveSessionKey.decision(
            keyCode: keyCode, option: option, command: command, control: control, shift: shift,
            isComposing: isComposing, hasValidTranslation: hasValidTranslation)
    }

    @Test func dispatchIgnoresEverythingWhenTheFeatureIsOff() {
        for bits in 0..<16 {
            #expect(decide(.english, enabled: false, isRepeat: bits & 1 != 0, menuOrActionOpen: bits & 2 != 0,
                           hasSelection: bits & 4 != 0, sessionActive: bits & 8 != 0) == .ignore)
        }
    }

    @Test func dispatchReportsASelectionBeforeLookingAtTheSession() {
        #expect(decide(.english, hasSelection: true, sessionActive: false) == .selectionNotSupported)
        #expect(decide(.japanese, hasSelection: true, sessionActive: true) == .selectionNotSupported)
    }

    @Test func dispatchStartsOrForwards() {
        #expect(decide(.japanese, sessionActive: false) == .start(.japanese))
        #expect(decide(.english, sessionActive: true) == .forward(.english))
    }

    /// A held shortcut acts once: every repeat is swallowed, whatever else is going on.
    @Test func dispatchConsumesKeyRepeats() {
        for hasSelection in [false, true] {
            for sessionActive in [false, true] {
                #expect(decide(.english, isRepeat: true, hasSelection: hasSelection, sessionActive: sessionActive) == .consume)
            }
        }
    }

    @Test func dispatchConsumesTheShortcutWhileAMenuOrActionIsOpen() {
        for sessionActive in [false, true] {
            #expect(decide(.japanese, menuOrActionOpen: true, sessionActive: sessionActive) == .consume)
            #expect(decide(.japanese, menuOrActionOpen: true, hasSelection: true, sessionActive: sessionActive) == .consume)
        }
    }

    @Test func optionReturnSubmitsAValidTranslation() {
        for keyCode: UInt16 in [36, 76] {
            #expect(key(keyCode, option: true) == .submit)
        }
    }

    @Test func submitNeedsOptionAlone() {
        #expect(key(36) == .none)
        #expect(key(36, option: true, command: true) == .none)
        #expect(key(36, option: true, control: true) == .none)
        #expect(key(36, option: true, shift: true) == .none)
    }

    /// Option+Return is never handed on: without a valid translation it is swallowed with a reason.
    @Test func optionReturnWithoutAValidTranslationIsBlockedNotPassedOn() {
        for keyCode: UInt16 in [36, 76] {
            #expect(key(keyCode, option: true, hasValidTranslation: false) == .submitBlocked(.notReady))
            #expect(key(keyCode, option: true, isComposing: true) == .submitBlocked(.composing))
            #expect(key(keyCode, option: true, isComposing: true, hasValidTranslation: false) == .submitBlocked(.composing))
        }
    }

    @Test func submitBlocksHaveDistinctMessages() {
        #expect(LiveSubmitBlock.check(isComposing: false, hasValidTranslation: true) == nil)
        #expect(LiveSubmitBlock.check(isComposing: false, hasValidTranslation: false) == .notReady)
        #expect(LiveSubmitBlock.check(isComposing: true, hasValidTranslation: true) == .composing)
        #expect(!LiveSubmitBlock.composing.message.isEmpty)
        #expect(LiveSubmitBlock.composing.message != LiveSubmitBlock.notReady.message)
    }

    @Test func escExitsWithoutCommandControlOrOption() {
        #expect(key(53) == .exit)
        #expect(key(53, hasValidTranslation: false) == .exit)
        #expect(key(53, option: true) == .none)
        #expect(key(53, command: true) == .none)
        #expect(key(53, control: true) == .none)
    }

    /// Esc while composing cancels the composition in the engine; the session goes on.
    @Test func escBelongsToTheEngineWhileComposing() {
        #expect(key(53, isComposing: true) == .none)
        #expect(key(53, isComposing: true, hasValidTranslation: false) == .none)
    }

    @Test func otherKeysAreNotSessionKeys() {
        for keyCode: UInt16 in [0, 14, 38, 48, 51, 123, 124] {
            for isComposing in [false, true] {
                #expect(key(keyCode, option: true, isComposing: isComposing) == .none)
                #expect(key(keyCode, isComposing: isComposing) == .none)
            }
        }
    }

    @Test func sessionDraftIsFullAtTheLimit() {
        var draft = DraftBuffer()
        #expect(!draft.isFullForLiveSession)
        let belowLimit = draft.appendForLiveSession(String(repeating: "字", count: DraftBuffer.maxLength - 1))
        #expect(!belowLimit)
        #expect(!draft.isFullForLiveSession)
        let atLimit = draft.appendForLiveSession("好")
        #expect(atLimit)
        #expect(draft.isFullForLiveSession)
        _ = draft.deleteBackward()
        #expect(!draft.isFullForLiveSession)
    }

    /// Text the engine already committed is kept whole: no spill into the app and no loss.
    @Test func sessionDraftKeepsACommitThatCrossesTheLimit() {
        var draft = DraftBuffer()
        let head = String(repeating: "字", count: DraftBuffer.maxLength - 4)
        _ = draft.appendForLiveSession(head)
        let crossed = draft.appendForLiveSession("明天下午开会")
        #expect(crossed)
        #expect(draft.text == head + "明天下午开会")
        let stillFull = draft.appendForLiveSession("😀")
        #expect(stillFull)
        #expect(draft.text == head + "明天下午开会😀")
    }
}
