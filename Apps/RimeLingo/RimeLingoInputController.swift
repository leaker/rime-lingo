import RimeLingoCore
import RimeLingoPanel
import AppKit
import Carbon
import InputMethodKit
import RimeKit

/// One controller per client input context. Translates key events into librime calls
/// and mirrors librime's state back into the client (marked text, commits) and the panel.
@objc(RimeLingoInputController)
@MainActor
final class RimeLingoInputController: IMKInputController {
    private(set) var session: RimeSession?
    private var sessionGeneration = -1
    private var lastModifiers: NSEvent.ModifierFlags = []
    /// Unmasked flags of the last modifier event: device bits tell ⌥ left from right.
    private var lastDeviceFlags: UInt = 0
    private var appOptions = InputEngine.AppOptions()
    private var bundleID: String?
    private var hasMarkedText = false
    /// The client currently shows marked text of ours (a draft or a composition).
    var showsMarkedText: Bool { hasMarkedText }
    /// A composition or a draft is pending here, whether or not the client shows it.
    var hasPendingInput: Bool { hasMarkedText || isComposing || !draft.isEmpty }
    private(set) var isComposing = false
    /// Active ⌃⌥P rewrite of the selected text (see RimeLingoInputController+Polish.swift).
    var polish: PolishSession?
    /// Open quick menu (see RimeLingoInputController+Menu.swift).
    var quickMenu: QuickMenu?
    /// Holding one modifier on its own opens the quick menu (keyboard-only entry).
    var menuHold = ModifierHold()
    /// Caps Lock presses that macOS spends on switching to and from ABC.
    private var capsSwitch = CapsLockSourceSwitch()
    /// 输入图层: committed text waiting at the cursor (underlined) until it is confirmed.
    var draft = DraftBuffer()
    /// Active live translation session, nil when there is none
    /// (see RimeLingoInputController+LiveTranslation.swift).
    var live: LiveTranslationCoordinator?
    /// What was just inserted into this field, so AI actions can work on "what I just
    /// typed" without a selection. Memory only; verified against the app before use.
    var recentText = RecentText()
    /// Text of the latest commit (see `commitForAction`).
    private var lastCommitted = ""
    private var draftTimer: Task<Void, Never>?
    /// A full session draft refused text; said once the panel has been redrawn.
    private var liveDraftFull = false
    private static let liveDraftFullNotice = "原文已达上限，请先提交或上屏"
    /// At most one "Chinese input is paused" hint per activation.
    private var secureHint = SecureInputHint()
    /// A composition was dropped in a secure context without a librime call; the
    /// session is cleared before it is used again (see `clearDiscardedComposition`).
    private var compositionDiscarded = false
    /// This activation began in a secure context and its setup has not run yet; it runs
    /// on the first key handled in an eligible context (see `finishActivation`).
    private var activationDeferred = false
    /// Page depth and symbol category last drawn, to pick the menu's transition direction.
    var menuShown: (depth: Int, category: Int) = (0, 0)

    private var engine: InputEngine { InputEngine.shared }
    private var textClient: (any IMKTextInput)? { client() as? any IMKTextInput }
    var ownsPanel: Bool { engine.activeController === self }

    // MARK: - Secure context

    /// Whether this context is secure right now: lock screen, login window, system
    /// authorization dialogs, any field while Secure Event Input is on, or a client that
    /// does not identify itself. Sampled at every call and never cached; only the
    /// client's identity is asked for, never anything in the field.
    func secureContext(client: (any IMKTextInput)? = nil) -> SecureContextPolicy.Decision {
        SecureContextPolicy.decision(bundleID: (client ?? textClient)?.bundleIdentifier(),
                                     secureEventInput: IsSecureEventInputEnabled())
    }

    /// True in a secure context, after dropping everything pending here. Asked right
    /// before each client read or write, panel show and engine-initiated librime call.
    func blockedBySecureContext(client: (any IMKTextInput)? = nil) -> Bool {
        guard secureContext(client: client).isSecure else { return false }
        discardPendingState()
        return true
    }

    /// Drops the composition, draft, quick menu, hold and action state of this field
    /// without committing any of it. State only: no client call, no librime call.
    private func discardPendingState() {
        let showedPanel = isComposing || !draft.isEmpty || quickMenu != nil || polish != nil || menuHold.isArmed
        // The session and its preview go without a write; late results are invalidated
        // and nothing resumes once the context is eligible again. A selection preview
        // goes too, whichever field it was captured in.
        engine.selection.end()
        endLive()
        draftTimer?.cancel()
        _ = draft.take()
        recentText.reset()
        lastCommitted = ""
        menuHold.cancel()
        quickMenu = nil
        polish?.task?.cancel()
        polish = nil
        isComposing = false
        // The client is not asked to clear its marked text here, and may drop it on its
        // own; an empty setMarkedText sent later could replace a selection instead.
        hasMarkedText = false
        // Whatever librime holds or produces from here on (a key may already be in it
        // when the context turns secure mid-event) is dropped before the session is used.
        if session != nil { compositionDiscarded = true }
        if showedPanel, ownsPanel { engine.panel.hide() }
    }

    /// Back in an eligible context: librime forgets the composition dropped meanwhile,
    /// any text it had committed but not handed over, and its modifier-tap latch, so
    /// nothing from before is resumed, committed or replayed.
    private func clearDiscardedComposition() {
        guard compositionDiscarded else { return }
        compositionDiscarded = false
        guard let session = liveSession else { return }
        session.clearComposition()
        _ = session.consumeCommit()
        session.cancelModifierTap()
        // Settings changed meanwhile were not applied to this session.
        applyScriptOption()
        applyPunctOption()
    }

    // MARK: - Session

    @discardableResult
    private func ensureSession() -> RimeSession? {
        let rime = RimeEngine.shared
        guard rime.isInitialized, !rime.isMaintaining else { return nil }
        if let session, sessionGeneration == engine.generation, session.isAlive {
            applyArrowKeyLayout()
            return session
        }
        session = try? rime.createSession()
        sessionGeneration = engine.generation
        applyAppOptions(newSession: true)
        applyArrowKeyLayout()
        applyScriptOption()
        applyPunctOption()
        return session
    }

    /// The session if it belongs to the current engine generation.
    private var liveSession: RimeSession? {
        guard let session, sessionGeneration == engine.generation, session.isAlive else { return nil }
        return session
    }

    /// Commits whatever is being composed before the engine drops all sessions.
    func flushBeforeEngineRestart() {
        guard !blockedBySecureContext() else { return endLive() }
        if let session = liveSession, isComposing {
            session.commitComposition()
            sync(client: textClient)
            isComposing = false
        }
        flushDraft(client: textClient)
        endLive()
    }

    /// Chinese/English state for this client, per `AsciiStatePolicy`: by default the
    /// state shared by all apps, or the app's own state for apps that start in English.
    private func applyAppOptions(newSession: Bool) {
        guard let session,
              let desired = engine.asciiState.state(for: bundleID, appDefault: appOptions.asciiMode, newSession: newSession)
        else { return }
        DebugLog.write("ascii apply app=\(bundleID ?? "?") appDefault=\(appOptions.asciiMode.map(String.init) ?? "nil") new=\(newSession) scope=\(engine.asciiState.scope.rawValue) was=\(session.option("ascii_mode")) now=\(desired)")
        // Only write when it changes: every set_option makes librime post a notification.
        if session.option("ascii_mode") != desired { session.setOption("ascii_mode", desired) }
    }

    /// 简体 / 繁体 output as chosen in Settings (⌃⇧4 toggles it until the next session).
    func applyScriptOption() {
        guard let session = liveSession else { return }
        let traditional = engine.features.traditional
        if session.option("traditionalization") != traditional { session.setOption("traditionalization", traditional) }
    }

    /// Private Rime options are not persisted; synchronize new and reused sessions.
    func applyArrowKeyLayout() {
        guard let session = liveSession else { return }
        let horizontal = engine.arrowKeysFollowLayout && engine.panel.theme.layout == .linear
        if session.option("_horizontal") != horizontal { session.setOption("_horizontal", horizontal) }
    }

    /// Chinese/English punctuation: the app's own setting, else the state shared by all apps.
    func applyPunctOption() {
        guard let session = liveSession else { return }
        if engine.asciiPunct == nil {
            let remembered = (try? RimeEngine.shared.openConfig("default").stringList("switcher/save_options"))?
                .contains("ascii_punct") == true
            engine.asciiPunct = remembered ? session.option("ascii_punct") : engine.features.asciiPunct
        }
        let desired = appOptions.asciiPunct ?? engine.asciiPunct ?? false
        if session.option("ascii_punct") != desired { session.setOption("ascii_punct", desired) }
    }

    /// Records the current Chinese/English state (shared, or this app's own), and the
    /// punctuation state unless this app pins its own.
    private func rememberAsciiMode() {
        guard let session = liveSession else { return }
        if appOptions.asciiPunct == nil, engine.activeController === self {
            engine.asciiPunct = session.option("ascii_punct")
        }
        DebugLog.write("ascii record app=\(bundleID ?? "?") appDefault=\(appOptions.asciiMode.map(String.init) ?? "nil") ascii=\(session.option("ascii_mode"))")
        engine.asciiState.record(session.option("ascii_mode"), app: bundleID, appDefault: appOptions.asciiMode,
                                 isActive: engine.activeController === self)
    }

    /// A Caps Lock press right before deactivation was macOS switching to ABC; undo the
    /// 中/英 toggle librime made for it so switching back keeps the earlier state.
    private func undoCapsLockSourceSwitch() {
        guard let restore = capsSwitch.deactivated(at: Date()), engine.activeController === self,
              let session = liveSession, session.option("ascii_mode") != restore else { return }
        DebugLog.write("ascii caps-lock source switch: restore ascii=\(restore)")
        session.setOption("ascii_mode", restore)
    }

    // MARK: - IMKStateSetting

    nonisolated override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // IMK always calls on the main thread; the unsafe captures only cross the
        // compiler's isolation boundary, not a thread boundary.
        nonisolated(unsafe) let this = self, client = sender as? any IMKTextInput
        MainActor.assumeIsolated { this.activate(client: client) }
    }

    private func activate(client: (any IMKTextInput)?) {
        DebugLog.write("activate client=\(client?.bundleIdentifier() ?? "?")")
        // IMK may activate the next field before deactivating the last one (switching
        // apps). By then the old field no longer owns the panel and its deactivate cannot
        // hide it, so a quick menu opened there stayed on screen over the new app.
        if let previous = engine.activeController, previous !== self { previous.yieldPanel() }
        engine.activeController = self
        secureHint.activated()
        // A secure context gets no session, no Chinese/English state and no theme work,
        // and nothing pending in this controller survives into it.
        let context = secureContext(client: client)
        if context.isSecure {
            // The reason only (a case name): which kind of context paused input.
            DebugLog.write("activate secure context reason=\(context)")
            bundleID = client?.bundleIdentifier()
            discardPendingState()
            engine.panel.hide()
            engine.previewPanel.hide()
            // Modifier state is kept current (see `handle`) so the first modifier event
            // after the context turns eligible is compared against the truth.
            snapshotModifiers()
            activationDeferred = true
            return
        }
        activationDeferred = false
        bundleID = client?.bundleIdentifier()
        snapshotModifiers()
        finishActivation()
    }

    /// One snapshot for both views so a flag flip between reads can't desync them.
    private func snapshotModifiers() {
        let currentFlags = NSEvent.modifierFlags
        lastModifiers = currentFlags.intersection(.deviceIndependentFlagsMask)
        lastDeviceFlags = currentFlags.rawValue
    }

    /// The part of an activation that touches the session and shared state. Runs at
    /// activation, or at the first eligible key when the activation was in a secure context.
    private func finishActivation() {
        engine.refreshTheme()
        appOptions = engine.appOptions(for: bundleID)
        // Nothing here may call back into the client: it is blocked until activateServer
        // returns. A reused session may be stale if another window of the same app
        // switched Chinese/English meanwhile, so re-apply the remembered state.
        // Back from another input method with "reset to Chinese" on (#25): Chinese, and
        // remembered where this field's state lives so the next app does not undo it.
        let reset = engine.consumeReturnReset()
        if reset { engine.asciiState.record(false, app: bundleID, appDefault: appOptions.asciiMode) }
        if ensureSession() != nil {
            clearDiscardedComposition()
            applyAppOptions(newSession: false)
            applyPunctOption()
            if reset, let session = liveSession, session.option("ascii_mode") {
                DebugLog.write("ascii reset on return from another input source")
                session.setOption("ascii_mode", false)
            }
        }
    }

    /// Another field is taking over before this one was deactivated: drop the menu and any
    /// action result while this one still owns the panel, then clear the panel.
    /// State only: no sync, nothing sent to the old client while IMK is activating the new one.
    func yieldPanel() {
        menuHold.cancel()
        quickMenu = nil
        polish?.task?.cancel()
        polish = nil
        endLive()
        engine.panel.hide()
        // A selection preview stays for reading and copying; it can no longer replace.
        detachSelectionPreview()
        if !engine.selection.isActive { engine.previewPanel.hide() }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        nonisolated(unsafe) let this = self, client = sender as? any IMKTextInput
        MainActor.assumeIsolated {
            DebugLog.write("deactivate app=\(this.bundleID ?? "?")")
            // Leaving a secure context: its Chinese/English state is not recorded and
            // nothing is committed (`commitPending` checks again before it writes).
            // The same holds when the activation never left its deferred state: the
            // session was never brought in line with the shared state.
            if !this.blockedBySecureContext(client: client), !this.activationDeferred {
                this.undoCapsLockSourceSwitch()
                this.rememberAsciiMode()
                this.liveSession?.cancelModifierTap()
            }
            this.activationDeferred = false
            this.menuHold.cancel()
            this.recentText.reset()
            this.lastModifiers = []
            this.lastDeviceFlags = 0
            this.closeMenu()
            this.cancelPolish()
            this.commitPending(client)
            this.endLive()
            this.detachSelectionPreview()
            if this.ownsPanel { this.engine.panel.hide() }
            this.engine.usage.flush()
            if this.engine.activeController === this { this.engine.activeController = nil }
        }
        super.deactivateServer(sender)
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        nonisolated(unsafe) let this = self, client = sender as? any IMKTextInput
        MainActor.assumeIsolated {
            this.commitPending(client)
            this.endLive()
        }
    }

    /// An AI action chosen while composing: the highlighted candidate goes into the field
    /// first (as Space would put it), and the action then works on that text. The raw
    /// composition and the candidate list are never handed to the action.
    func commitForAction(client: (any IMKTextInput)?) -> String? {
        guard let session = liveSession, isComposing else { return nil }
        lastCommitted = ""
        session.commitComposition()
        sync(client: client ?? textClient)
        return lastCommitted.isEmpty ? nil : lastCommitted
    }

    private func commitPending(_ client: (any IMKTextInput)?) {
        guard !blockedBySecureContext(client: client) else { return }
        if let session = liveSession, isComposing {
            if engine.commitCodeOnLeave {
                // Switching input source or clicking away: the keys typed stay as typed (#20).
                let code = session.context().composition.textOnLeave(input: session.input)
                session.clearComposition()
                isComposing = false
                let target = client ?? textClient
                flushDraft(client: target)
                if !code.isEmpty {
                    DebugLog.write("commit-code length=\(code.count)")
                    target?.insertText(code, replacementRange: NSRange(location: NSNotFound, length: 0))
                    recentText.append(code)
                    hasMarkedText = false
                }
                if hasMarkedText { clearMarkedText(target) }
                if ownsPanel { engine.panel.hide() }
                return
            }
            session.commitComposition()
            sync(client: client ?? textClient)
        }
        // Leaving the field (click elsewhere, app switch): the draft goes into the app.
        if !draft.isEmpty {
            flushDraft(client: client ?? textClient)
        } else if hasMarkedText, !isComposing {
            clearMarkedText(client ?? textClient)
        }
    }

    nonisolated override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    // MARK: - Key handling

    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let received = event else { return false }
        nonisolated(unsafe) let this = self, client = sender as? any IMKTextInput, keyEvent = received
        return MainActor.assumeIsolated { this.handle(keyEvent, client: client) }
    }

    private func handle(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {
        // Secure context: every key passes through untouched. Nothing else happens —
        // no session, no librime call, no state change, no logging of the event.
        let context = secureContext(client: client)
        if context.isSecure {
            discardPendingState()
            // Memory only: which modifiers are down, so the comparison below is not
            // against stale flags once the context is eligible again.
            if event.type == .flagsChanged {
                lastModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                lastDeviceFlags = event.modifierFlags.rawValue
            }
            if event.type == .keyDown { engine.lastSecureKeyAt = Date() }
            if event.type == .keyDown, secureHint.shouldShow(for: context) { engine.showSecureInputHint(for: context) }
            return false
        }
        if activationDeferred {
            // Activated in a secure context that has since ended, with no new activation:
            // the setup skipped then runs now. The modifier snapshot is not retaken; it
            // would already include this event and make it look like a repeat.
            activationDeferred = false
            bundleID = client?.bundleIdentifier() ?? bundleID
            finishActivation()
        }
        // A key delivered without an activation first: the field that owned the panels gives
        // them up (session, menu, action result), as it does in `activate`. State only.
        if let previous = engine.activeController, previous !== self { previous.yieldPanel() }
        // Event type and session state only — never the characters typed.
        engine.activeController = self
        guard let session = ensureSession() else {
            DebugLog.write("event type=\(event.type.rawValue) no-session maintaining=\(RimeEngine.shared.isMaintaining) initialized=\(RimeEngine.shared.isInitialized)")
            // Deploying (first run ≈ 10 s): keys pass through; say why once per deploy.
            if RimeEngine.shared.isMaintaining, event.type == .keyDown { engine.noteKeyDuringDeploy() }
            return false
        }
        engine.activeController = self
        clearDiscardedComposition()
        // The client of this field changed under a selection preview captured here.
        if engine.selection.isActive, !selectionPreviewIsAttached { detachSelectionPreview() }
        var handled = false

        switch event.type {
        case .keyDown:
            // Menu/draft keys may return before reaching RIME. Its ascii_composer
            // still saw the modifier press; clear that tap latch so the release
            // cannot turn a consumed Shift+key into an accidental mode switch.
            var forwardedToRime = false
            defer { if !forwardedToRime { session.cancelModifierTap() } }
            engine.lastUserKeyAt = Date()
            if menuHold.isArmed { engine.panel.hideHoldCue(animated: true) }
            menuHold.keyPressed() // a key while the modifier is down is a shortcut, not a hold
            let flags = event.modifierFlags
            // Live translation shortcuts (⌃⌥⌘E / ⌃⌥⌘J), reached only past the secure-context gate.
            if let target = TranslationShortcuts.target(
                keyCode: event.keyCode, control: flags.contains(.control), option: flags.contains(.option),
                command: flags.contains(.command), shift: flags.contains(.shift)),
               let consumed = handleTranslationShortcut(target, isRepeat: event.isARepeat, client: client) {
                return consumed
            }
            if quickMenu != nil, handleMenuKey(event, client: client) { return true }
            if isMenuHotkey(event) {
                openMenu(client: client)
                return true
            }
            // Keys the polish flow does not consume go on to librime as usual.
            if polish != nil, handlePolishKey(event, client: client) { return true }
            if isPolishHotkey(event) { // AI actions, and 简繁转换 which needs no AI
                // Choose: translate, polish or one of the user's own. With nothing to work on, say so.
                if hasActionTarget(client: client) { openMenu(client: client, page: .ai) }
                else { engine.showStatus("没有可处理的文字：先打一段字，或选中一段文字") }
                return true
            }
            // A selection preview of this field takes ⌥↩ (replace the selection) and Esc
            // (close) while nothing is composed or drafted; with something pending ⌥↩ is
            // swallowed with a notice. Every other key, typing included, goes on as usual
            // and the preview stays.
            if quickMenu == nil, polish == nil, selectionPreviewIsAttached {
                switch SelectionPreviewKey.decision(
                    keyCode: event.keyCode, option: flags.contains(.option), command: flags.contains(.command),
                    control: flags.contains(.control), shift: flags.contains(.shift),
                    hasMarkedText: hasPendingInput) {
                case .replace:
                    engine.replaceSelectedText()
                    return true
                case .replaceBlocked:
                    engine.showStatus(SelectionPreviewKey.pendingInputMessage)
                    return true
                case .close:
                    engine.closeSelectionPreview()
                    return true
                case .none:
                    break
                }
            }
            // A pending draft (nothing being composed): Return / Esc confirm it, ⌫ edits
            // it, navigation and shortcuts confirm it and then reach the app.
            // A live session takes ⌥↩ (submit the translation) and Esc (exit). ⌥↩ never
            // reaches the app, composing or not: there it could send a message.
            if live != nil, quickMenu == nil, polish == nil {
                switch LiveSessionKey.decision(
                    keyCode: event.keyCode, option: flags.contains(.option), command: flags.contains(.command),
                    control: flags.contains(.control), shift: flags.contains(.shift),
                    isComposing: isComposing, hasValidTranslation: live?.validTranslation != nil,
                    selectionPreviewOpen: engine.selection.isActive) {
                case .submit:
                    submitLive(client: client)
                    return true
                case let .submitBlocked(reason):
                    engine.showStatus(reason.message)
                    return true
                case .exit:
                    exitLive(client: client)
                    return true
                case .none:
                    break
                }
            }
            if !draft.isEmpty, !isComposing {
                switch DraftBuffer.decision(keyCode: event.keyCode, command: flags.contains(.command), control: flags.contains(.control)) {
                case .commit:
                    flushDraft(client: client)
                    return true
                case .commitAndPass:
                    flushDraft(client: client)
                    recentText.reset()
                    return false
                case .deleteBackward:
                    _ = draft.deleteBackward()
                    sync(client: client)
                    return true
                case .toEngine:
                    break
                }
            }
            // A full session draft takes no more text. The key stops here, before librime:
            // once the engine has committed something it can no longer be refused.
            if live != nil, !isComposing, draft.isFullForLiveSession, Self.printableText(event) != nil {
                engine.showStatus(Self.liveDraftFullNotice)
                return true
            }
            guard let (keysym, mask) = RimeKey.translate(
                keyCode: event.keyCode,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                characters: event.characters,
                flags: event.modifierFlags.rawValue
            ) else { return false }
            if keysym == RimeKey.escape, appOptions.vimMode, !isComposing {
                session.setOption("ascii_mode", true)
                rememberAsciiMode()
                return false
            }
            engine.cancelStatus()
            forwardedToRime = true
            let wasComposing = isComposing
            handled = session.processKey(keysym, modifiers: mask)
            // IMK never delivers key-ups. Report the release of each real press (not
            // auto-repeats), as Weasel and fcitx do, so schemas can tell taps from a held
            // key: 万象's backspace limit otherwise swallows every ⌫ once the
            // composition is empty.
            if !event.isARepeat { session.processKey(keysym, modifiers: mask | RimeKey.releaseMask) }
            DebugLog.write("keyDown kind=\(keysym < 0x80 ? "ascii" : "special") mask=\(mask) handled=\(handled) ascii=\(session.option("ascii_mode"))")
            if !handled {
                // Keys librime leaves alone (English mode, spaces, punctuation): with the
                // layer on they join the draft; otherwise they go to the app and are
                // remembered as recently typed text.
                let typed = Self.printableText(event)
                // English punctuation while composing: librime commits the candidate and
                // leaves the key alone. The commit goes first, and the key is inserted
                // here rather than handed back: the app's own insertion races ours and
                // replaces the preedit, losing the committed text.
                if typed != nil, wasComposing {
                    lastCommitted = ""
                    sync(client: client)
                }
                let committedFirst = wasComposing && (!lastCommitted.isEmpty || !isComposing)
                // A draft opens on words only (letters typed in English mode); a space,
                // digits or punctuation join an open draft and otherwise go to the app.
                if let typed, collectsDraft, live != nil || !draft.isEmpty || DraftBuffer.opensDraft(typed) {
                    appendToDraft(typed, client: client)
                    sync(client: client)
                    guard !blockedBySecureContext(client: client) else { return false }
                    rememberAsciiMode()
                    return true
                }
                if let typed, committedFirst {
                    // Secure by now: the key goes to the app as it is.
                    guard !blockedBySecureContext(client: client) else { return false }
                    client?.insertText(typed, replacementRange: NSRange(location: NSNotFound, length: 0))
                    hasMarkedText = false
                    recentText.append(typed)
                    rememberAsciiMode()
                    return true
                }
                if let typed { recentText.append(typed) }
                else if event.keyCode == 51 { recentText.deleteBackward() }
                else { recentText.reset() }
            }

        case .flagsChanged:
            engine.lastUserKeyAt = Date()
            // Two views of the same event: the raw value keeps device-dependent bits
            // (left vs right ⌥/⌃/⌘) for the menu-hold state machine; librime only
            // understands the device-independent mask, which merges the sides.
            let deviceFlags = event.modifierFlags.rawValue
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Modifier transitions only (never character keys): safe to log for diagnosis.
            engine.logger.debug("flagsChanged keyCode=\(event.keyCode, privacy: .public) flags=\(flags.rawValue, privacy: .public) last=\(self.lastModifiers.rawValue, privacy: .public)")
            defer { lastModifiers = flags; lastDeviceFlags = deviceFlags }
            DebugLog.write("flagsChanged keyCode=\(event.keyCode) flags=\(flags.rawValue) last=\(lastModifiers.rawValue) ascii=\(session.option("ascii_mode"))")
            // Mac Catalyst apps (Messages) deliver every modifier event twice. A repeat
            // has the same flags as the last one and would read as "released", toggling
            // Chinese/English the moment Shift goes down.
            guard deviceFlags != lastDeviceFlags else { return false }
            // Hold-to-open for the quick menu. The release after a fired hold is kept from
            // librime, where a lone modifier tap can switch Chinese/English.
            menuHold.key = engine.features.menuHoldKey
            if menuHold.consumeRelease(deviceFlags) {
                // The release we just swallowed was part of the hold; clear librime's
                // tap latch so a surviving opposite-side key can't end the sequence
                // with a lone release that ascii_composer reads as a 中/英 toggle tap.
                session.cancelModifierTap()
                return true
            }
            if let token = menuHold.modifiersChanged(deviceFlags) {
                scheduleMenuHold(token: token)
            } else if !menuHold.isArmed {
                engine.panel.hideHoldCue(animated: true) // let go early, or another modifier joined
            }
            // Side-only changes (left ⌥ held, right ⌥ joins) carry no keysym for librime.
            guard flags != lastModifiers else { return false }
            guard let keysym = RimeKey.keysym(forVirtualKey: event.keyCode) else { return false }
            if keysym == RimeKey.capsLock {
                capsSwitch.pressed(asciiBefore: session.option("ascii_mode"), at: Date())
                // Caps Lock toggles on a single event; report press + release.
                let mask = RimeKey.capsLockMask(fromCocoaFlags: flags.rawValue)
                handled = session.processKey(keysym, modifiers: mask)
                session.processKey(keysym, modifiers: mask | RimeKey.releaseMask)
            } else {
                let pressed = flags.rawValue & ~lastModifiers.rawValue != 0
                let mask = pressed
                    ? RimeKey.mask(fromCocoaFlags: lastModifiers.rawValue)
                    : RimeKey.mask(fromCocoaFlags: lastModifiers.rawValue) | RimeKey.releaseMask
                handled = session.processKey(keysym, modifiers: mask)
            }

        default:
            return false
        }

        sync(client: client)
        // The context turned secure while this event was being handled: the key passes
        // through and no Chinese/English state is recorded.
        guard !blockedBySecureContext(client: client) else { return false }
        rememberAsciiMode()
        return handled
    }

    // MARK: - Draft layer (输入图层)

    /// The layer is on for this field: enabled in Settings, and the app is not one where
    /// keys must reach it at once (terminals, editors, launchers, password managers).
    var draftLayerActive: Bool {
        engine.features.draftLayer && !DraftBuffer.isExempt(
            appStartsInEnglish: appOptions.asciiMode == true, bundleID: bundleID, secureInput: IsSecureEventInputEnabled())
    }

    /// Committed text waits in the draft: the layer is on, or a live translation session
    /// is using the draft as its source (whatever the layer setting says).
    var collectsDraft: Bool { live != nil || draftLayerActive }

    /// The hint under a pending draft, led by a 中 / 英 chip: in English mode keys join
    /// the draft as letters, which must not look like a composition that lost its candidates.
    private var draftHint: PanelState {
        let hold: String = switch engine.features.menuHoldKey {
        case .option: "长按 ⌥ 动作"
        case .optionLeft: "长按左⌥ 动作"
        case .optionRight: "长按右⌥ 动作"
        case .control: "长按 ⌃ 动作"
        case .controlLeft: "长按左⌃ 动作"
        case .controlRight: "长按右⌃ 动作"
        case .command: "长按 ⌘ 动作"
        case .commandLeft: "长按左⌘ 动作"
        case .commandRight: "长按右⌘ 动作"
        case .off: "⌃⌥M 动作"
        }
        var state = PanelState(status: live != nil ? "↩ 原文   ⌥↩ 译文   esc 退出" : "↩ 上屏   \(hold)")
        state.statusBadge = liveSession?.option("ascii_mode") == true ? "英" : "中"
        return state
    }

    /// After a short status (中 / 英…) the panel goes back to what it showed: the draft
    /// hint while a draft is pending, nothing otherwise.
    func restorePanelAfterStatus() {
        if blockedBySecureContext() {
            if ownsPanel { engine.panel.hide() }
            return
        }
        guard ownsPanel else { return }
        if isComposing {
            // A session notice shown over the candidates: put them back.
            if live != nil, quickMenu == nil, polish == nil { sync(client: textClient) }
            return
        }
        if !draft.isEmpty, quickMenu == nil, polish == nil {
            engine.panel.show(draftHint, at: cursorRect(client: textClient))
        } else if draft.isEmpty {
            engine.panel.hide()
        }
    }

    /// Text a key event types on its own (no ⌘ / ⌃), or nil for control and function keys.
    static func printableText(_ event: NSEvent) -> String? {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let characters = event.characters, let scalar = characters.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7f, !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        return characters
    }

    private func appendToDraft(_ text: String, client: (any IMKTextInput)?) {
        guard !blockedBySecureContext(client: client) else { return }
        // A session never commits part of its source and never drops what the engine has
        // committed: the text joins the draft whole, and `handle` stops further keys.
        if live != nil {
            if draft.appendForLiveSession(text) {
                DebugLog.write("live draft full length=\(draft.text.utf16.count)")
                liveDraftFull = true
            }
            return
        }
        if let overflow = draft.append(text) {
            // Too long for one marked run: the older part goes into the app.
            client?.insertText(overflow, replacementRange: NSRange(location: NSNotFound, length: 0))
            hasMarkedText = false
            recentText.append(overflow)
        }
    }

    /// Puts the draft into the app (replacing the marked text that showed it).
    func flushDraft(client: (any IMKTextInput)?) {
        // Also the auto-commit timer's path: the context is judged when it fires.
        guard !blockedBySecureContext(client: client) else { return }
        draftTimer?.cancel()
        guard !draft.isEmpty else { return }
        let text = draft.take()
        (client ?? textClient)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        hasMarkedText = false
        recentText.append(text)
        draftDidChange()
        if ownsPanel, !isComposing, quickMenu == nil, polish == nil { engine.panel.hide() }
    }

    /// Puts `text` into the app in place of the pending draft (a submitted translation).
    /// The caller has checked the secure context; only text is inserted, never a key.
    func replaceDraft(with text: String, client: any IMKTextInput) {
        draftTimer?.cancel()
        _ = draft.take()
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        hasMarkedText = false
        recentText.append(text)
        draftDidChange()
        if ownsPanel, !isComposing, quickMenu == nil, polish == nil { engine.panel.hide() }
    }

    /// Restarts the auto-commit countdown; it only runs while a draft is pending and
    /// nothing is being composed, picked from a menu, or processed by AI.
    private func scheduleDraftAutoCommit() {
        draftTimer?.cancel()
        let delay = engine.features.draftAutoCommit
        // A session keeps its source until the user submits, commits or exits.
        guard live == nil, delay > 0, !draft.isEmpty, !isComposing, quickMenu == nil, polish == nil else { return }
        draftTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            // A session started after the countdown did: its source stays until the user acts.
            guard !Task.isCancelled, let self, self.live == nil, !self.isComposing,
                  self.quickMenu == nil, self.polish == nil else { return }
            self.flushDraft(client: nil)
        }
    }

    // MARK: - Output

    /// Menu text replaces unconfirmed composition, after preserving an existing draft.
    /// Both continuous and closing insertions must leave no old preedit to restore.
    func insertMenuText(_ text: String, client: (any IMKTextInput)?) {
        guard let client = client ?? textClient, !blockedBySecureContext(client: client) else { return }
        if isComposing { liveSession?.clearComposition() }
        isComposing = false
        flushDraft(client: client)
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        hasMarkedText = false
    }

    /// Marked text with InputMethodKit's own highlight attributes. Hand-made attributes
    /// (e.g. a raw underline style) do not survive the IMK XPC bridge on macOS 26+, and
    /// clients then insert the preedit as ordinary text — the raw pinyin stays in the
    /// document next to the committed characters.
    private func markedText(_ text: String, converted: Int, selectedEnd: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let length = (text as NSString).length
        guard length > 0 else { return result }
        let convertedEnd = max(0, min(converted, length))
        let selectionEnd = max(convertedEnd, min(selectedEnd, length))
        func apply(_ style: Int, _ range: NSRange) {
            guard range.length > 0,
                  let attributes = mark(forStyle: style, at: range) as? [NSAttributedString.Key: Any] else { return }
            result.addAttributes(attributes, range: range)
        }
        apply(kTSMHiliteConvertedText, NSRange(location: 0, length: convertedEnd))
        apply(kTSMHiliteSelectedRawText, NSRange(location: convertedEnd, length: selectionEnd - convertedEnd))
        apply(kTSMHiliteRawText, NSRange(location: selectionEnd, length: length - selectionEnd))
        return result
    }

    private func clearMarkedText(_ client: (any IMKTextInput)?) {
        guard !blockedBySecureContext(client: client) else { return }
        client?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
        hasMarkedText = false
        isComposing = false
        if ownsPanel { engine.panel.hide() }
    }

    func sync(client: (any IMKTextInput)?, commitToDraft: Bool = false) {
        guard !blockedBySecureContext(client: client) else { return }
        clearDiscardedComposition()
        guard let session = liveSession, let client else { return }

        if let text = session.consumeCommit() {
            DebugLog.write("commit length=\(text.count) hadMarked=\(hasMarkedText) draft=\(draftLayerActive)")
            engine.usage.record(text, app: bundleID)
            lastCommitted = text
            // A commit of only punctuation or digits does not open a draft.
            if commitToDraft {
                draft.replace(with: draft.text + text)
            } else if collectsDraft, live != nil || !draft.isEmpty || DraftBuffer.opensDraft(text) {
                appendToDraft(text, client: client)
            } else {
                // The layer was switched off with a draft pending: it goes first.
                let pending = draft.take()
                client.insertText(pending + text, replacementRange: NSRange(location: NSNotFound, length: 0))
                hasMarkedText = false
                recentText.append(pending + text)
            }
        }

        // Every draft edit (commit, ⌫) passes here: the session's source follows it.
        draftDidChange()

        let context = session.context()
        isComposing = context.isComposing
        let theme = engine.panel.theme
        let inline = appOptions.inline ?? theme.inlinePreedit

        // Marked text: the client shows the composition inline, or a placeholder
        // space when the panel carries the preedit (keeps cursor tracking alive).
        // A pending draft comes first, styled as converted text.
        let draftPrefix = draft.text
        let draftLength = draftPrefix.utf16.count
        if !isComposing, !draftPrefix.isEmpty {
            client.setMarkedText(markedText(draftPrefix, converted: draftLength, selectedEnd: draftLength),
                                 selectionRange: NSRange(location: draftLength, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            hasMarkedText = true
        } else if isComposing {
            let showsPreview = theme.inlineCandidate && context.commitTextPreview != nil
            let preedit = showsPreview ? context.commitTextPreview! : context.composition.preedit
            // Never hand the client an empty marked string while composing: terminals
            // (Ghostty, iTerm2…) then think no composition is active and print the raw
            // keys, so pinyin letters end up interleaved with committed characters.
            // Without inline preedit a single space stands in for the composition.
            let body = inline ? preedit : " "
            let display = draftPrefix + body
            // The caret must index the string actually shown: the librime cursor is a
            // byte offset into the preedit, meaningless for the candidate preview.
            let caret = draftLength + (!inline ? 0
                : showsPreview ? body.utf16.count
                : min(context.composition.utf16Offset(ofUTF8: context.composition.cursorPosition), body.utf16.count))
            let attributed = markedText(display, converted: draftLength + (showsPreview ? body.utf16.count
                : context.composition.utf16Offset(ofUTF8: context.composition.selectionStart)),
                selectedEnd: draftLength + (showsPreview ? body.utf16.count
                : context.composition.utf16Offset(ofUTF8: context.composition.selectionEnd)))
            DebugLog.write("marked length=\(display.count) inline=\(inline) caret=\(caret) attrs=\(attributed.length > 0 ? attributed.attributes(at: 0, effectiveRange: nil).count : 0)")
            client.setMarkedText(attributed, selectionRange: NSRange(location: caret, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            hasMarkedText = true
        } else if hasMarkedText {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            hasMarkedText = false
        }

        // A delayed old-context commit still reaches that client, but cannot replace
        // the shared panel belonging to the newly active field.
        guard ownsPanel else { return }
        defer {
            repositionLivePreview(client: client)
            if liveDraftFull {
                liveDraftFull = false
                engine.showStatus(Self.liveDraftFullNotice)
            }
        }
        scheduleDraftAutoCommit()
        // The quick menu or an action's result list owns the panel until it closes. A
        // modifier release (⌃⌥P lets go of ⌃ and ⌥) also lands here, and must not hide
        // or redraw over it (#31).
        guard quickMenu == nil, polish == nil else { return }
        guard isComposing else {
            // A pending draft shows a small hint under it (what the layer is waiting for).
            if draft.isEmpty {
                engine.panel.hide()
            } else {
                engine.panel.show(draftHint, at: cursorRect(client: client))
            }
            return
        }

        let composition = context.composition
        let start = composition.utf16Offset(ofUTF8: composition.selectionStart)
        let end = composition.utf16Offset(ofUTF8: composition.selectionEnd)
        let state = PanelState(
            preedit: composition.preedit,
            preeditSelection: NSRange(location: start, length: max(0, end - start)),
            candidates: context.candidates.enumerated().map { index, candidate in
                PanelState.Candidate(label: context.labels[safe: index] ?? "\(index + 1)", text: candidate.text, comment: candidate.comment)
            },
            highlightedIndex: context.highlightedIndex,
            pageNumber: context.pageNumber,
            isLastPage: context.isLastPage,
            showsMenuButton: engine.features.panelMenuButton
        )
        engine.panel.view.onMenu = { [weak self] in self?.openMenu(client: nil) }
        engine.panel.view.onSelect = { [weak self] index in self?.select(index) }
        engine.panel.view.onPage = { [weak self] backward in self?.page(backward: backward) }
        engine.panel.view.forcePreedit = !inline
        engine.panel.show(state, at: cursorRect(client: client))
    }

    private func select(_ index: Int) {
        guard !blockedBySecureContext(), let session = liveSession else { return }
        session.selectCandidate(onCurrentPage: index)
        sync(client: textClient)
    }

    private func page(backward: Bool) {
        guard !blockedBySecureContext(), let session = liveSession else { return }
        session.changePage(backward: backward)
        sync(client: textClient)
    }

    /// Cursor rectangle in screen coordinates.
    func cursorRect(client: (any IMKTextInput)? = nil) -> NSRect {
        guard let client = client ?? textClient else { return .zero }
        // With a pending draft the panel follows where typing continues — its end — not
        // its first character: a draft that wraps over several lines would otherwise be
        // covered by the panel sitting under its first line.
        let anchor = draft.isEmpty ? 0 : draft.text.utf16.count
        for index in Set([anchor, max(0, anchor - 1), 0]).sorted(by: >) {
            var rect = NSRect.zero
            client.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
            // Some apps answer an index they cannot place with an empty rect at the
            // screen origin: try the next candidate then.
            if rect != .zero, rect.origin != .zero { return rect }
        }
        return .zero
    }

    // MARK: - Menu

    nonisolated override func menu() -> NSMenu! {
        // NSMenu is not Sendable; IMK asks for it on the main thread.
        nonisolated(unsafe) var menu: NSMenu?
        nonisolated(unsafe) let this = self
        MainActor.assumeIsolated { menu = this.buildMenu() }
        return menu
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "RimeLingo")
        func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        // No key equivalent: input menu shortcuts are live in every app, so ⌘, here would
        // shadow each app's own Settings shortcut (#6).
        menu.addItem(item(String(localized: "灵译输入法设置…"), #selector(openSettings(_:))))
        if let update = engine.pendingUpdate {
            menu.addItem(item(String(localized: "更新到 \(update.version)…"), #selector(openUpdate(_:))))
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "重新部署"), #selector(deploy(_:))))
        menu.addItem(item(String(localized: "同步用户数据"), #selector(syncUserData(_:))))
        menu.addItem(item(String(localized: "打开用户文件夹"), #selector(openUserFolder(_:))))
        menu.addItem(item(String(localized: "打开日志文件夹"), #selector(openLogFolder(_:))))
        return menu
    }

    @objc func openSettings(_ sender: Any?) { openSettings(pane: nil) }

    /// Opens RimeLingo Settings, optionally on a pane ("stats", "ai", …). A running
    /// Settings app is told to switch through a distributed notification.
    func openSettings(pane: String?) { Self.openSettings(pane: pane) }

    static func openSettings(pane: String?) {
        let configuration = NSWorkspace.OpenConfiguration()
        if let pane { configuration.arguments = ["--pane", pane] }
        let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/Applications/RimeLingo Settings.app")
        let url = FileManager.default.fileExists(atPath: embedded.path) ? embedded
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.github.leaker.rimelingo.settings")
        guard let url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        if let pane {
            DistributedNotificationCenter.default().postNotificationName(
                .init("io.github.leaker.rimelingo.settings.showPane"), object: nil, userInfo: ["pane": pane], deliverImmediately: true)
        }
    }

    @objc func openUpdate(_ sender: Any?) { openSettings(pane: "overview") }
    @objc func deploy(_ sender: Any?) { engine.redeploy() }
    @objc func syncUserData(_ sender: Any?) { engine.syncUserData() }
    @objc func openUserFolder(_ sender: Any?) { NSWorkspace.shared.open(engine.paths.userDataDir) }
    @objc func openLogFolder(_ sender: Any?) { NSWorkspace.shared.open(engine.paths.logDir) }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
