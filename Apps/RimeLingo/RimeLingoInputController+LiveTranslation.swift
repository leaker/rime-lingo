import RimeLingoAI
import RimeLingoCore
import RimeLingoPanel
import AppKit
import InputMethodKit

// Live translation input: a session translates the draft (never the unfinished pinyin)
// and shows the result in a second panel. Decisions live in RimeLingoCore
// (TranslationDispatch, LiveSessionKey, LiveTranslationSession); this file only adapts
// them to the client and the panels. Nothing here logs source text or translations.
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
            selection: selection, selectionPreviewAttached: attached, sessionActive: live != nil)
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
            startLive(target)
        case let .forward(target):
            liveEngine.closeSelectionPreview()
            live?.targetPressed(target)
        }
        return true
    }

    private var liveTextClient: (any IMKTextInput)? { client() as? (any IMKTextInput) }

    // MARK: - Session

    private func startLive(_ target: TranslationTarget) {
        endLive()
        let coordinator = LiveTranslationCoordinator(translate: { request in
            let features = await MainActor.run { InputEngine.shared.features }
            return await LiveTranslator.translate(request, features: features)
        })
        coordinator.onChange = { [weak self] snapshot in self?.renderLive(snapshot) }
        live = coordinator
        installLivePanelControls()
        DebugLog.write("live start target=\(target.code)")
        coordinator.start(target: target)
        // A draft already pending is the first source.
        draftDidChange()
    }

    private func installLivePanelControls() {
        let panel = liveEngine.previewPanel
        panel.onSubmit = { [weak self] in self?.livePanelAction(writesToClient: true) { $0.submitLive(client: nil) } }
        panel.onCopy = { [weak self] in self?.livePanelAction { $0.copyLive() } }
        panel.onExit = { [weak self] in self?.livePanelAction(writesToClient: true) { $0.exitLive(client: nil) } }
        panel.onRetry = { [weak self] in self?.livePanelAction { $0.live?.retry() } }
    }

    /// A selection preview closed: the session it covered takes the panel back and
    /// shows where it stands now.
    func resumeLivePreview() {
        guard let live else { return }
        installLivePanelControls()
        renderLive(live.session?.snapshot)
    }

    /// Runs a preview panel control for the field that owns the panel, outside a secure context.
    /// Controls that write the draft or the translation into the app wait, like the keys,
    /// while the quick menu or an action on the draft is open: that action would otherwise
    /// put its own result into the app as well.
    private func livePanelAction(writesToClient: Bool = false, _ action: (RimeLingoInputController) -> Void) {
        guard ownsPanel, live != nil, !liveEngine.selection.isActive, !blockedBySecureContext() else { return }
        // Ignored without a notice: the status bubble would replace the menu or result list.
        if writesToClient, quickMenu != nil || polish != nil { return }
        action(self)
    }

    /// Ends the session and invalidates whatever is pending. State and panel only:
    /// nothing is written to the client.
    func endLive() {
        guard let ending = live else { return }
        live = nil
        // Without a session a draft is edited at its end only.
        _ = draft.moveCaret(.end)
        ending.onChange = nil
        ending.end()
        DebugLog.write("live end")
        if ownsPanel, !liveEngine.selection.isActive { liveEngine.previewPanel.hide() }
    }

    /// Esc, the 退出 control, or the feature being switched off: the source text goes
    /// into the app and the session ends.
    func exitLive(client: (any IMKTextInput)?) {
        guard live != nil else { return }
        let target = client ?? liveTextClient
        // An action still open on the draft (the feature switched off mid-action) is dropped
        // first, so its result cannot be inserted after the source.
        closeMenu()
        cancelPolish()
        flushDraft(client: target)
        endLive()
        // A composition goes on without the session; its marked text lost the draft prefix.
        if isComposing { sync(client: target) }
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

    // MARK: - Submit / copy

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

    private func copyLive() {
        guard let text = live?.validTranslation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        liveEngine.showStatus("已复制译文")
    }

    // MARK: - Preview panel

    private func renderLive(_ snapshot: LiveTranslationSnapshot?) {
        let panel = liveEngine.previewPanel
        // An open selection preview owns the panel: the session goes on underneath and is
        // drawn again when that preview closes (`resumeLivePreview`).
        guard !liveEngine.selection.isActive else { return }
        guard let snapshot else {
            if ownsPanel { panel.hide() }
            return
        }
        guard ownsPanel, live != nil, !blockedBySecureContext() else { return }
        let status: TranslationPreviewState.Status = switch snapshot.status {
        case .waiting: .waiting
        case .updating: .updating
        case .ready: .ready
        case .failed: .failed
        case .overLimit: .notice
        }
        DebugLog.write("live render status=\(status) length=\(snapshot.text.count) stale=\(snapshot.isStale)")
        let state = TranslationPreviewState(
            targetLabel: snapshot.targetLabel, status: status, text: snapshot.text, isStale: snapshot.isStale,
            message: snapshot.message, canSubmit: snapshot.canSubmit, canCopy: snapshot.canCopy, canRetry: snapshot.canRetry)
        // While visible the panel stays where the last key put it (see `repositionLivePreview`);
        // the client is asked for the cursor only when the panel appears.
        panel.show(state, caret: panel.isVisible ? .zero : cursorRect(client: liveTextClient),
                   avoiding: liveEngine.panel.occupiedFrame)
    }

    /// After every sync: the preview follows the caret and keeps clear of the candidate panel.
    func repositionLivePreview(client: (any IMKTextInput)?) {
        let panel = liveEngine.previewPanel
        guard live != nil, ownsPanel, panel.isVisible, !liveEngine.selection.isActive,
              !blockedBySecureContext(client: client) else { return }
        panel.reposition(caret: cursorRect(client: client), avoiding: liveEngine.panel.occupiedFrame)
    }
}
