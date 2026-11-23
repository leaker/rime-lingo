@testable import RimeLingoCore
import Testing

struct TranslationShortcutsTests {
    private func decide(
        _ target: TranslationTarget, enabled: Bool = true, isRepeat: Bool = false, menuOrActionOpen: Bool = false,
        selection: SelectionPresence = .none, previewAttached: Bool = false, activeTarget: TranslationTarget? = nil
    ) -> TranslationDispatch {
        TranslationDispatch.decide(
            target: target, featureEnabled: enabled, isRepeat: isRepeat, menuOrActionOpen: menuOrActionOpen,
            selection: selection, selectionPreviewAttached: previewAttached, activeTarget: activeTarget)
    }

    private func key(
        _ keyCode: UInt16, option: Bool = false, command: Bool = false, control: Bool = false, shift: Bool = false,
        isComposing: Bool = false, hasValidTranslation: Bool = true, selectionPreviewOpen: Bool = false,
        draftIsEmpty: Bool = false, canRetry: Bool = false
    ) -> LiveSessionKey {
        LiveSessionKey.decision(
            keyCode: keyCode, option: option, command: command, control: control, shift: shift,
            isComposing: isComposing, hasValidTranslation: hasValidTranslation,
            selectionPreviewOpen: selectionPreviewOpen, draftIsEmpty: draftIsEmpty, canRetry: canRetry)
    }

    private static let french = TranslationTarget(code: "fr")!
    /// Live translation off, on with the pressed target, on with another one.
    private static let activeTargets: [TranslationTarget?] = [nil, .english, .japanese, french]

    /// A translation hidden under a selection preview is never inserted; the key is
    /// still swallowed.
    @Test func submitIsBlockedWhileASelectionPreviewOwnsThePanel() {
        for keyCode: UInt16 in [36, 76] {
            #expect(key(keyCode, option: true, selectionPreviewOpen: true) == .submitBlocked(.previewHidden))
            #expect(key(keyCode, option: true, isComposing: true, selectionPreviewOpen: true) == .submitBlocked(.previewHidden))
        }
        #expect(LiveSubmitBlock.check(isComposing: false, hasValidTranslation: true, selectionPreviewOpen: true) == .previewHidden)
        #expect(!LiveSubmitBlock.previewHidden.message.isEmpty)
        // A failure hidden under the preview is not retried either.
        #expect(key(36, option: true, hasValidTranslation: false, selectionPreviewOpen: true, canRetry: true)
            == .submitBlocked(.previewHidden))
        // Esc is not a submit: it keeps exiting the session.
        #expect(key(53, selectionPreviewOpen: true) == .exit)
    }

    /// With the mode left on, a terminal, launcher or password manager gets no session
    /// behind the user's back: its keys must reach it as with translation off.
    @Test func silentResumeSkipsExemptApplications() {
        func resume(
            _ mode: TranslationTarget?, enabled: Bool = true, sessionActive: Bool = false, exempt: Bool = false
        ) -> TranslationTarget? {
            LiveFieldPolicy.silentResumeTarget(
                mode: mode, featureEnabled: enabled, sessionActive: sessionActive, appExempt: exempt)
        }
        #expect(resume(.english) == .english)
        #expect(resume(Self.french) == Self.french)
        #expect(resume(.english, exempt: true) == nil)
        // Nothing to resume: the mode is off, the feature is off, or the field has a session.
        #expect(resume(nil) == nil)
        #expect(resume(nil, exempt: true) == nil)
        #expect(resume(.english, enabled: false) == nil)
        #expect(resume(.english, sessionActive: true) == nil)
        // The exemption is the input layer's own: an application set to start in English
        // (terminals, editors, launchers) and the password managers.
        let terminal = DraftBuffer.isExempt(appStartsInEnglish: true, bundleID: "com.mitchellh.ghostty", secureInput: false)
        let passwords = DraftBuffer.isExempt(appStartsInEnglish: false, bundleID: "com.1password.1password", secureInput: false)
        let notes = DraftBuffer.isExempt(appStartsInEnglish: false, bundleID: "com.apple.Notes", secureInput: false)
        #expect(resume(.japanese, exempt: terminal) == nil)
        #expect(resume(.japanese, exempt: passwords) == nil)
        #expect(resume(.japanese, exempt: notes) == .japanese)
    }

    /// A language shortcut pressed in an exempt application is the user asking for
    /// translation there: it starts a session whatever the mode is, and from then on it
    /// toggles like anywhere else.
    @Test func aShortcutPressedInAnExemptApplicationStartsASessionThere() {
        func toggled(
            _ pressed: TranslationTarget, mode: TranslationTarget?, sessionActive: Bool, exempt: Bool
        ) -> TranslationDispatch {
            decide(pressed, activeTarget: LiveFieldPolicy.toggleTarget(
                mode: mode, sessionActive: sessionActive, appExempt: exempt))
        }
        for mode in Self.activeTargets {
            #expect(toggled(.english, mode: mode, sessionActive: false, exempt: true) == .start(.english))
        }
        // With a session there the table applies unchanged.
        #expect(toggled(.english, mode: .english, sessionActive: true, exempt: true) == .stop)
        #expect(toggled(.japanese, mode: .english, sessionActive: true, exempt: true) == .switchTarget(.japanese))
        // Elsewhere the mode alone decides (a field resumes before the shortcut is looked at).
        #expect(toggled(.english, mode: .english, sessionActive: false, exempt: false) == .stop)
        #expect(toggled(.japanese, mode: .english, sessionActive: false, exempt: false) == .switchTarget(.japanese))
        #expect(toggled(.english, mode: nil, sessionActive: false, exempt: false) == .start(.english))
    }

    @Test func dispatchIgnoresEverythingWhenTheFeatureIsOff() {
        for bits in 0..<16 {
            for activeTarget in Self.activeTargets {
                #expect(decide(.english, enabled: false, isRepeat: bits & 1 != 0, menuOrActionOpen: bits & 2 != 0,
                               selection: bits & 4 != 0 ? .new : .none, previewAttached: bits & 8 != 0,
                               activeTarget: activeTarget) == .ignore)
            }
        }
    }

    /// A non-empty selection wins over starting, stopping or switching live translation.
    @Test func dispatchCapturesASelectionBeforeLookingAtTheLiveSession() {
        for activeTarget in Self.activeTargets {
            #expect(decide(.english, selection: .new, activeTarget: activeTarget) == .captureSelection(.english))
            // Also while a preview of another selection is open.
            #expect(decide(.japanese, selection: .new, previewAttached: true, activeTarget: activeTarget)
                == .captureSelection(.japanese))
        }
    }

    /// With a preview open in this field the shortcut goes to it, whether the captured
    /// text is still selected or nothing is: the live session underneath is left alone.
    @Test func dispatchHandsTheTargetToAnOpenSelectionPreview() {
        for activeTarget in Self.activeTargets {
            #expect(decide(.japanese, selection: .captured, previewAttached: true, activeTarget: activeTarget)
                == .retargetSelection(.japanese))
            #expect(decide(.english, selection: .none, previewAttached: true, activeTarget: activeTarget)
                == .retargetSelection(.english))
        }
    }

    /// A language shortcut is a toggle: on, off with the same language, over to another one.
    @Test func dispatchTogglesLiveTranslation() {
        for target in [TranslationTarget.english, .japanese, Self.french] {
            #expect(decide(target) == .start(target))
            #expect(decide(target, activeTarget: target) == .stop)
        }
        #expect(decide(.english, activeTarget: .japanese) == .switchTarget(.english))
        #expect(decide(.japanese, activeTarget: .english) == .switchTarget(.japanese))
        #expect(decide(Self.french, activeTarget: .english) == .switchTarget(Self.french))
    }

    /// Turning off writes the draft into the app; with candidates open that would move
    /// the unfinished pinyin behind the text it was typed into. The toggle is refused with
    /// the notice the submit shortcut gives there; starting and switching write nothing.
    @Test func dispatchRefusesToTurnOffWhileComposing() {
        func composing(_ target: TranslationTarget, active: TranslationTarget?) -> TranslationDispatch {
            TranslationDispatch.decide(
                target: target, featureEnabled: true, isRepeat: false, menuOrActionOpen: false,
                selection: .none, selectionPreviewAttached: false, activeTarget: active, isComposing: true)
        }
        for target in [TranslationTarget.english, .japanese, Self.french] {
            #expect(composing(target, active: target) == .stopBlocked)
            #expect(composing(target, active: nil) == .start(target))
        }
        #expect(composing(.japanese, active: .english) == .switchTarget(.japanese))
        #expect(LiveSubmitBlock.composing.message == "请先完成选词")
    }

    /// A held shortcut acts once: every repeat is swallowed, whatever else is going on.
    @Test func dispatchConsumesKeyRepeats() {
        for selection in [SelectionPresence.none, .captured, .new] {
            for activeTarget in Self.activeTargets {
                #expect(decide(.english, isRepeat: true, selection: selection, previewAttached: selection == .captured,
                               activeTarget: activeTarget) == .consume)
            }
        }
    }

    @Test func dispatchConsumesTheShortcutWhileAMenuOrActionIsOpen() {
        for activeTarget in Self.activeTargets {
            #expect(decide(.japanese, menuOrActionOpen: true, activeTarget: activeTarget) == .consume)
            #expect(decide(.japanese, menuOrActionOpen: true, selection: .new, activeTarget: activeTarget) == .consume)
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

    /// Live translation stays on between sentences: with nothing typed the submit shortcut
    /// and Esc are the app's keys again.
    @Test func anEmptyDraftLeavesSubmitAndEscToTheApp() {
        for keyCode: UInt16 in [36, 76] {
            #expect(key(keyCode, option: true, hasValidTranslation: false, draftIsEmpty: true) == .none)
            // Whatever else is going on.
            #expect(key(keyCode, option: true, hasValidTranslation: false, selectionPreviewOpen: true, draftIsEmpty: true) == .none)
            // Unfinished pinyin is input of ours: the key is swallowed with a reason.
            #expect(key(keyCode, option: true, isComposing: true, hasValidTranslation: false, draftIsEmpty: true)
                == .submitBlocked(.composing))
        }
        #expect(key(53, hasValidTranslation: false, draftIsEmpty: true) == .none)
        #expect(key(53, isComposing: true, hasValidTranslation: false, draftIsEmpty: true) == .none)
        // With a draft Esc commits the source and turns live translation off.
        #expect(key(53, hasValidTranslation: false) == .exit)
    }

    /// After a failure or above the automatic limit the submit shortcut translates now.
    @Test func submitRetriesWhenThereIsNothingValidToSubmit() {
        for keyCode: UInt16 in [36, 76] {
            #expect(key(keyCode, option: true, hasValidTranslation: false, canRetry: true) == .retry)
            // Still translating, or a draft of white space only: swallowed.
            #expect(key(keyCode, option: true, hasValidTranslation: false) == .submitBlocked(.notReady))
            #expect(key(keyCode, option: true, isComposing: true, hasValidTranslation: false, canRetry: true)
                == .submitBlocked(.composing))
        }
        // A valid translation is submitted, never retried.
        #expect(key(36, option: true, hasValidTranslation: true, canRetry: true) == .submit)
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
        let belowLimit = draft.insertForLiveSession(String(repeating: "字", count: DraftBuffer.maxLength - 1))
        #expect(!belowLimit)
        #expect(!draft.isFullForLiveSession)
        let atLimit = draft.insertForLiveSession("好")
        #expect(atLimit)
        #expect(draft.isFullForLiveSession)
        _ = draft.deleteBackward()
        #expect(!draft.isFullForLiveSession)
    }

    /// Text the engine already committed is kept whole: no spill into the app and no loss.
    @Test func sessionDraftKeepsACommitThatCrossesTheLimit() {
        var draft = DraftBuffer()
        let head = String(repeating: "字", count: DraftBuffer.maxLength - 4)
        _ = draft.insertForLiveSession(head)
        let crossed = draft.insertForLiveSession("明天下午开会")
        #expect(crossed)
        #expect(draft.text == head + "明天下午开会")
        let stillFull = draft.insertForLiveSession("😀")
        #expect(stillFull)
        #expect(draft.text == head + "明天下午开会😀")
    }

    /// `#expect` cannot hold a mutating call.
    private func swallows(_ gate: inout ConsumedKeyRepeat, _ keyCode: UInt16, isRepeat: Bool) -> Bool {
        gate.swallows(keyCode: keyCode, isRepeat: isRepeat)
    }

    /// Submitting empties the draft, so the held submit shortcut no longer belongs to the
    /// session by the time it repeats. The repeats are swallowed all the same: in the app
    /// they would add a line break or send the message.
    @Test func repeatsOfAConsumedSubmitDoNotReachTheApp() {
        for keyCode: UInt16 in [36, 76] {
            var gate = ConsumedKeyRepeat()
            // The press: a draft with a finished translation.
            #expect(!swallows(&gate, keyCode, isRepeat: false))
            #expect(key(keyCode, option: true) == .submit)
            gate.consumed(keyCode: keyCode)
            // The repeats: the draft is empty and the session lets the key go.
            #expect(key(keyCode, option: true, hasValidTranslation: false, draftIsEmpty: true) == .none)
            #expect(swallows(&gate, keyCode, isRepeat: true))
            #expect(swallows(&gate, keyCode, isRepeat: true))
            // Released and pressed again with nothing drafted: the key is the app's.
            #expect(!swallows(&gate, keyCode, isRepeat: false))
            #expect(!swallows(&gate, keyCode, isRepeat: true))
        }
    }

    /// A press the session did not take keeps repeating in the app, and a record never
    /// covers another key or outlives the next press.
    @Test func onlyRepeatsOfTheConsumedPressAreSwallowed() {
        var gate = ConsumedKeyRepeat()
        #expect(!swallows(&gate, 36, isRepeat: false))
        #expect(!swallows(&gate, 36, isRepeat: true))

        gate.consumed(keyCode: 53) // Esc closed a preview or turned live translation off
        #expect(swallows(&gate, 53, isRepeat: true))
        #expect(!swallows(&gate, 36, isRepeat: true))
        #expect(!swallows(&gate, 0, isRepeat: false))
        #expect(!swallows(&gate, 53, isRepeat: true))
    }
}
