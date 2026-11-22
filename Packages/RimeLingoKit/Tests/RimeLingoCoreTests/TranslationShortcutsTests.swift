import Testing
@testable import RimeLingoCore

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
}
