import RimeLingoAI
import RimeLingoCore
import RimeLingoPanel
import AppKit
import InputMethodKit

// Live translation input: a session translates the draft (never the unfinished pinyin)
// and shows the result in a second panel. The mode (`InputEngine.liveTarget`) is
// process-wide and stays on until a language shortcut or Esc turns it off; a session
// belongs to one field and ends when that field loses the keyboard. The panel is on
// screen only while the draft has text, or briefly for a hint when the mode changes.
// Decisions live in RimeLingoCore (TranslationDispatch, LiveSessionKey,
// LiveTranslationSession, TranslationPreviewContent); this file only adapts them to the
// client and the panels. Nothing here logs source text or translations.
extension RimeLingoInputController {
    private var liveEngine: InputEngine { InputEngine.shared }

    // MARK: - Shortcut

    /// A live translation shortcut was pressed. Returns nil when the key is not consumed
    /// and takes its usual path (feature off), else what `handle` returns.
    func handleTranslationShortcut(_ target: TranslationTarget, isRepeat: Bool, client: (any IMKTextInput)?) -> Bool? {
        let enabled = liveEngine.features.liveTranslation
        // Secure by now: the key goes to the app untouched.
        if enabled, blockedBySecureContext(client: client) { return false }
        // The menu and a running action own the keyboard; repeats never act twice.
        let menuOrActionOpen = quickMenu != nil || polish != nil
        // The client is asked for its selection only when the shortcut can act on it.
        let asksClient = enabled && !isRepeat && !menuOrActionOpen
        let (selection, attached) = asksClient ? selectionState() : (.none, false)
        let dispatch = TranslationDispatch.decide(
            target: target, featureEnabled: enabled, isRepeat: isRepeat, menuOrActionOpen: menuOrActionOpen,
            selection: selection, selectionPreviewAttached: attached,
            activeTarget: LiveFieldPolicy.toggleTarget(
                mode: liveEngine.liveTarget, sessionActive: live != nil, appExempt: draftLayerExempt),
            isComposing: isComposing)
        switch dispatch {
        case .ignore:
            return nil
        case .consume:
            break
        case let .captureSelection(target):
            captureSelection(target)
        case let .retargetSelection(target):
            liveEngine.selection.targetPressed(target)
        case let .start(target):
            // A selection preview left over from another field ends with a new translation.
            liveEngine.closeSelectionPreview()
            startLive(target, announce: true)
        case .stop:
            exitLive(client: client)
        case .stopBlocked:
            liveEngine.showStatus(LiveSubmitBlock.composing.message)
        case let .switchTarget(target):
            liveEngine.closeSelectionPreview()
            DebugLog.write("live switch target=\(target.code)")
            liveEngine.liveTarget = target
            live?.targetPressed(target)
            // With text to translate the preview shows the new target itself.
            if live?.session?.snapshot.showsPanel != true {
                liveEngine.showTranslationHint(TranslationShortcutBindings.liveSwitchedHint(to: target))
            }
        }
        return true
    }

    private var liveTextClient: (any IMKTextInput)? { client() as? (any IMKTextInput) }

    // MARK: - Session

    /// Turns the mode on with `target` and starts this field's session. `announce`: the
    /// user pressed the shortcut, so the keys are explained once; a session resumed in
    /// another field says nothing.
    private func startLive(_ target: TranslationTarget, announce: Bool) {
        endLive()
        liveEngine.liveTarget = target
        let coordinator = LiveTranslationCoordinator(translate: { request in
            let features = await MainActor.run { InputEngine.shared.features }
            return await LiveTranslator.translate(request, features: features)
        })
        coordinator.onChange = { [weak self] _ in self?.refreshLivePreview() }
        live = coordinator
        DebugLog.write("live start target=\(target.code)")
        coordinator.start(target: target)
        // A draft already pending is the first source.
        draftDidChange()
        // Over an empty draft the hint is the panel; over a draft its keys are the
        // footnote of the translation.
        if announce { liveEngine.showTranslationHint(liveEngine.translationBindings.liveStartedHint(for: target)) }
    }

    /// The mode is on and this field has no session yet (it got the keyboard after the
    /// mode was turned on, or its session ended with a click or a deploy): one starts
    /// with the next key, silently. Not in an application the input layer leaves alone:
    /// there keys pass through as with translation off, nothing is shown, and only a
    /// language shortcut pressed in that field starts a session.
    func resumeLiveIfNeeded(client: (any IMKTextInput)?) {
        guard let target = LiveFieldPolicy.silentResumeTarget(
            mode: liveEngine.liveTarget, featureEnabled: liveEngine.features.liveTranslation,
            sessionActive: live != nil, appExempt: draftLayerExempt),
            !blockedBySecureContext(client: client) else { return }
        startLive(target, announce: false)
    }

    /// Ends this field's session and invalidates whatever is pending; the mode stays on.
    /// State and panel only: nothing is written to the client and it is not asked anything.
    func endLive() {
        // A hint and the preview go with the field that showed them, session or not.
        if ownsPanel {
            liveEngine.cancelTranslationHint()
            if !liveEngine.selection.isActive { liveEngine.previewPanel.hide() }
        }
        guard let ending = live else { return }
        live = nil
        // Without a session a draft is edited at its end only.
        _ = draft.moveCaret(.end)
        ending.onChange = nil
        ending.end()
        DebugLog.write("live end")
    }

    /// Esc with a draft, the mode's own language shortcut, or the settings no longer
    /// allowing the mode: the source text goes into the app, the session ends and the
    /// mode is off. Nothing typed is dropped.
    func exitLive(client: (any IMKTextInput)?, announce: Bool = true) {
        // First, so the mode cannot outlive a field that has no session.
        liveEngine.liveTarget = nil
        guard live != nil else { return }
        let hadDraft = !draft.isEmpty
        DebugLog.write("live off draft=\(hadDraft)")
        let target = client ?? liveTextClient
        // An action still open on the draft (the feature switched off mid-action) is dropped
        // first, so its result cannot be inserted after the source.
        closeMenu()
        cancelPolish()
        flushDraft(client: target)
        endLive()
        // A composition goes on without the session; its marked text lost the draft prefix.
        if isComposing { sync(client: target) }
        if announce { liveEngine.showTranslationHint(TranslationShortcutBindings.liveStoppedHint(committedSource: hadDraft)) }
    }

    /// The draft is the only source of a session.
    func draftDidChange() {
        // A session with text to translate is no longer suspended under a selection
        // preview: that preview closes first, so the translation is drawn before it can
        // be submitted.
        if liveEngine.selection.isActive, SelectionPreviewOwnership.yieldsToLiveSession(
            liveSessionActive: live != nil, draftIsEmpty: draft.isEmpty) {
            liveEngine.closeSelectionPreview()
        }
        live?.sourceChanged(draft.text)
    }

    // MARK: - Submit

    /// Replaces the draft with the translation of exactly this draft and target. The text
    /// is inserted and nothing else: no Return reaches the app.
    func submitLive(client: (any IMKTextInput)?) {
        guard let live, !blockedBySecureContext(client: client) else { return }
        if let block = LiveSubmitBlock.check(
            isComposing: isComposing, hasValidTranslation: live.validTranslation != nil,
            selectionPreviewOpen: liveEngine.selection.isActive) {
            return liveEngine.showStatus(block.message)
        }
        guard let text = live.validTranslation, let target = client ?? liveTextClient else { return }
        DebugLog.write("live submit length=\(text.count)")
        replaceDraft(with: text, client: target)
        repositionLivePreview(client: target)
    }

    // MARK: - Preview panel

    /// The one rule for what the preview panel shows in this field: a selection preview,
    /// else the translation of the draft, else a hint, else nothing. Called whenever the
    /// session, the hint or the panel's owner changes. May ask the client for the cursor.
    func refreshLivePreview() {
        let engine = liveEngine, panel = engine.previewPanel
        // An open selection preview owns the panel: the session goes on underneath and is
        // drawn again when that preview closes.
        guard !engine.selection.isActive else { return }
        guard ownsPanel, !blockedBySecureContext() else { return }
        let snapshot = live?.session?.snapshot
        let state: TranslationPreviewState
        switch TranslationPreviewContent.decide(
            selectionPreviewOpen: false, sessionShowsPanel: snapshot?.showsPanel == true, hint: engine.translationHint) {
        case .selection:
            return
        case .hidden:
            return panel.hide()
        case let .hint(hint):
            state = TranslationPreviewState(
                targetLabel: hint.targetLabel, status: .notice, text: "", isStale: false,
                message: hint.title, footnote: hint.keys)
        case let .translation(footnote):
            guard let snapshot else { return panel.hide() }
            let status: TranslationPreviewState.Status = switch snapshot.status {
            case .waiting: .waiting
            case .updating: .updating
            case .ready: .ready
            case .failed: .failed
            case .overLimit: .notice
            }
            DebugLog.write("live render status=\(status) length=\(snapshot.text.count) stale=\(snapshot.isStale)")
            state = TranslationPreviewState(
                targetLabel: snapshot.targetLabel, status: status, text: snapshot.text, isStale: snapshot.isStale,
                message: engine.translationBindings.liveMessage(snapshot), footnote: footnote)
        }
        // While visible the panel stays where the last key put it (see `repositionLivePreview`);
        // the client is asked for the cursor only when the panel appears.
        panel.show(state, caret: panel.isVisible ? .zero : cursorRect(client: liveTextClient),
                   avoiding: engine.panel.occupiedFrame)
    }

    /// After every sync: the preview follows the caret and keeps clear of the candidate panel.
    func repositionLivePreview(client: (any IMKTextInput)?) {
        let panel = liveEngine.previewPanel
        guard live != nil, ownsPanel, panel.isVisible, !liveEngine.selection.isActive,
              !blockedBySecureContext(client: client) else { return }
        panel.reposition(caret: cursorRect(client: client), avoiding: liveEngine.panel.occupiedFrame)
    }
}
