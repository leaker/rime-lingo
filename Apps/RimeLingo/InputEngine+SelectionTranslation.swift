import RimeLingoCore
import RimeLingoPanel
import AppKit
import Carbon
import InputMethodKit

// Selected-text translation in editable fields: with text selected, ⌃⌥⌘E / ⌃⌥⌘J capture
// the selection through the input client, translate it and show the result in the
// preview panel. The selection is replaced only on request, after the field was checked
// again. Decisions live in RimeLingoCore (SelectionCapture, SelectionTranslationSession,
// SelectionPreviewKey, TranslationDispatch); this file adapts them to the client and the
// panel. Nothing here logs the selected text or its translation, and the pasteboard is
// never touched.
//
// Panel ownership: there is one preview panel. While a selection capture is open it owns
// the panel; a live translation session of the same field stays active underneath
// without drawing, and gets the panel back when the selection preview closes. The
// preview has no controls: its footnote names the keys that act on it, so it closes with
// the field it was captured in (nothing could close it once that field lost the keyboard).

extension RimeLingoInputController {
    private var selectionClient: (any IMKTextInput)? { client() }

    /// Identity of this field for a capture: this controller, its client object and the
    /// application. Nil when the client does not identify itself.
    var selectionContext: SelectionContext? {
        guard let client = selectionClient, let bundleID = client.bundleIdentifier() else { return nil }
        return SelectionContext(owner: ObjectIdentifier(self), client: ObjectIdentifier(client as AnyObject), bundleID: bundleID)
    }

    /// The open selection preview was captured in this field as it is now.
    var selectionPreviewIsAttached: Bool {
        guard let session = InputEngine.shared.selection.session, session.capture.context.owner == ObjectIdentifier(self),
              let context = selectionContext else { return false }
        return session.isAttached(to: context)
    }

    /// How the client's selection relates to the open preview, and whether that preview
    /// belongs to this field. The range is read; the text only when the selection is
    /// the captured range, to tell it from other text now at that place (the caller has
    /// passed the secure-context gate). While a composition or a draft of ours is
    /// pending nothing counts as a selection.
    func selectionState() -> (SelectionPresence, attached: Bool) {
        var selected: NSRange?
        if !hasPendingInput, let range = selectionClient?.selectedRange(), range.location != NSNotFound, range.length > 0 {
            selected = range
        }
        guard let session = InputEngine.shared.selection.session, let context = selectionContext else {
            return (selected == nil ? .none : .new, false)
        }
        let presence = session.presence(ofSelection: selected, in: context) {
            selected.flatMap { self.selectionClient?.attributedSubstring(from: $0)?.string }
        }
        return (presence, session.isAttached(to: context))
    }

    /// Captures the selection and starts translating it. The caller has passed the
    /// secure-context gate. A selection that cannot be read or is too long gets a short
    /// notice and nothing else: no dialog, no clipboard, no truncation.
    func captureSelection(_ target: TranslationTarget) {
        let engine = InputEngine.shared
        guard let client = selectionClient, let context = selectionContext else {
            return engine.showStatus(SelectionCaptureFailure.unreadable.message)
        }
        let range = client.selectedRange()
        switch SelectionCapture.read(context: context, range: range, text: { client.attributedSubstring(from: range)?.string }) {
        case let .failure(failure):
            DebugLog.write("selection capture failed reason=\(failure) length=\(range.length)")
            engine.showStatus(failure.message)
        case let .success(capture):
            DebugLog.write("selection start target=\(target.code) length=\(range.length)")
            engine.cancelStatus()
            engine.selectionAnchor = selectionRect(range, client: client)
            engine.selection.start(capture: capture, target: target)
        }
    }

    /// Where the captured range is on screen. Clients differ in which query they answer,
    /// so several are tried in turn; the pointer is the last resort (never a screen corner).
    private func selectionRect(_ range: NSRange, client: any IMKTextInput) -> NSRect {
        func firstRect(_ range: NSRange) -> NSRect {
            var actual = NSRange(location: NSNotFound, length: 0)
            return client.firstRect(forCharacterRange: range, actualRange: &actual)
        }
        func lineRect(_ index: Int) -> NSRect {
            var rect = NSRect.zero
            client.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
            return rect
        }
        let candidates = [
            firstRect(range),
            firstRect(NSRange(location: range.location, length: 0)),
            lineRect(range.location),
            lineRect(max(range.location, NSMaxRange(range) - 1)),
            cursorRect(client: client),
        ]
        let anchor = TranslationPreviewPanel.anchor(candidates: candidates, pointer: NSEvent.mouseLocation,
                                                    screens: NSScreen.screens.map(\.frame))
        DebugLog.write("selection anchor source=\(anchor.index.map(String.init) ?? "pointer")")
        return anchor.rect
    }

    /// This field was deactivated, gave up the panels or lost its client: a preview
    /// captured here closes. State and panel only: this runs while IMK is activating
    /// another field, so the client is not asked anything (which rules out
    /// `closeSelectionPreview`, whose redraw reads the cursor).
    func detachSelectionPreview() {
        let selection = InputEngine.shared.selection
        guard selection.session?.capture.context.owner == ObjectIdentifier(self) else { return }
        DebugLog.write("selection close reason=detached")
        selection.end()
    }

    /// Reads the captured range back and, when it still holds the captured text, puts
    /// the translation there. Called by the engine once it has checked everything else.
    fileprivate func currentSelectionText(_ range: NSRange) -> String? {
        selectionClient?.attributedSubstring(from: range)?.string
    }

    fileprivate func writeSelectionReplacement(_ text: String, range: NSRange) {
        guard let client = selectionClient else { return }
        // Text only, over the captured range only: no key event reaches the application.
        client.insertText(text, replacementRange: range)
        recentText.reset()
        recentText.append(text)
    }
}

extension InputEngine {
    /// Called once at start-up.
    func setUpSelectionTranslation() {
        selection.onChange = { [weak self] snapshot in self?.renderSelectionPreview(snapshot) }
    }

    /// True in a secure context, after dropping the capture and its preview. With no
    /// active field only the system-wide flag can tell.
    private func selectionBlockedBySecureContext() -> Bool {
        // The active field's own check already drops everything pending, this preview included.
        let secure = activeController?.blockedBySecureContext() ?? IsSecureEventInputEnabled()
        if secure { selection.end() }
        return secure
    }

    private func renderSelectionPreview(_ snapshot: LiveTranslationSnapshot?) {
        guard let snapshot else { return previewPanel.hide() }
        guard !selectionBlockedBySecureContext(), selection.isActive else { return }
        // The lock screen or an authentication surface is in front: like a secure context,
        // the capture ends. A translation that was never shown is not kept for replacing.
        guard bubbleAllowed else { return selection.end() }
        // The panel is this preview's now: a hint still pending is not drawn after it.
        cancelTranslationHint()
        let status: TranslationPreviewState.Status = switch snapshot.status {
        case .waiting: .waiting
        case .updating: .updating
        case .ready: .ready
        case .failed: .failed
        case .overLimit: .notice
        }
        DebugLog.write("selection render status=\(status) length=\(snapshot.text.count) replace=\(snapshot.canSubmit)")
        let state = TranslationPreviewState(
            targetLabel: snapshot.targetLabel, status: status, text: snapshot.text, isStale: snapshot.isStale,
            message: snapshot.message,
            footnote: translationBindings.selectionFootnote(canReplace: snapshot.canSubmit, canRetry: snapshot.canRetry),
            kind: .selection)
        previewPanel.show(state, caret: selectionAnchor, avoiding: panel.occupiedFrame)
    }

    /// Esc, or another translation taking over: the request is cancelled, nothing
    /// is written, and a live session of the active field gets the panel back.
    func closeSelectionPreview() {
        guard selection.isActive else { return }
        DebugLog.write("selection close")
        selection.end()
        activeController?.refreshLivePreview()
    }

    /// The submit shortcut. The field is checked again right before the write: the capture's
    /// controller is the active one with the same client, the context is not secure, and
    /// the captured range still holds exactly the captured text. Otherwise nothing is
    /// written anywhere, least of all into whatever field has the keyboard now.
    func replaceSelectedText() {
        let controller = activeController
        guard !selectionBlockedBySecureContext(), let session = selection.session else { return }
        // The quick menu or an action owns the keyboard and would write its own result.
        if let controller, controller.quickMenu != nil || controller.polish != nil { return }
        // A composition or a draft is marked text at the caret: finish it first.
        if let controller, controller.hasPendingInput { return showStatus(SelectionPreviewKey.pendingInputMessage) }
        let range = session.capture.range
        let decision = selection.replace(active: controller?.selectionContext, isSecure: false) {
            controller?.currentSelectionText(range)
        }
        switch decision {
        case let .replace(range, text):
            DebugLog.write("selection replace length=\(text.utf16.count)")
            controller?.writeSelectionReplacement(text, range: range)
            closeSelectionPreview()
        case let .blocked(reason):
            DebugLog.write("selection replace blocked reason=\(reason)")
            // A permanent reason is shown on the preview itself.
            if !reason.isPermanent { showStatus(reason.message) }
        case .discard, nil:
            break
        }
    }
}
