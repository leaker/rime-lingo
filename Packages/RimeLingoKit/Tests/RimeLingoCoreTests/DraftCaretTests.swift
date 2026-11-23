import Foundation
@testable import RimeLingoCore
import Testing

struct DraftCaretTests {
    private func draft(_ text: String) -> DraftBuffer {
        var draft = DraftBuffer()
        _ = draft.insertForLiveSession(text)
        return draft
    }

    // MARK: - Caret position

    @Test func caretFollowsTheEndUntilItIsMoved() {
        var draft = DraftBuffer()
        #expect(draft.caret == 0)
        _ = draft.append("今天")
        #expect(draft.caret == 2)
        _ = draft.append("开会")
        #expect(draft.caret == 4)
        _ = draft.deleteBackward()
        #expect(draft.caret == 3)
        draft.replace(with: "明天下午三点")
        #expect(draft.caret == 6)
        _ = draft.take()
        #expect(draft.caret == 0)
    }

    @Test func leftAndRightMoveByOneCharacterAndStopAtTheBoundaries() {
        var draft = draft("今天开会")
        let step1 = draft.moveCaret(.left)
        #expect(step1 && draft.caret == 3)
        let step2 = draft.moveCaret(.left)
        #expect(step2 && draft.caret == 2)
        let step3 = draft.moveCaret(.right)
        #expect(step3 && draft.caret == 3)
        let step4 = draft.moveCaret(.right)
        #expect(step4 && draft.caret == 4)
        let step5 = draft.moveCaret(.right)
        #expect(!step5 && draft.caret == 4)
        let step6 = draft.moveCaret(.start)
        #expect(step6 && draft.caret == 0)
        let step7 = draft.moveCaret(.left)
        #expect(!step7 && draft.caret == 0)
        let step8 = draft.moveCaret(.start)
        #expect(!step8)
        let step9 = draft.moveCaret(.end)
        #expect(step9 && draft.caret == 4)
        let step10 = draft.moveCaret(.end)
        #expect(!step10)
        #expect(draft.text == "今天开会")
    }

    @Test func caretNeverSplitsASurrogatePairOrACombiningSequence() {
        // 😀 is two UTF-16 units, e + U+0301 one character, the family emoji one cluster.
        let family = "👨‍👩‍👧"
        var draft = draft("a😀e\u{301}" + family + "z")
        let offsets = [0, 1, 3, 5, 5 + family.utf16.count, 6 + family.utf16.count]
        #expect(draft.caret == offsets[5])
        for expected in offsets.dropLast().reversed() {
            let step11 = draft.moveCaret(.left)
            #expect(step11)
            #expect(draft.caret == expected)
        }
        for expected in offsets.dropFirst() {
            let step12 = draft.moveCaret(.right)
            #expect(step12)
            #expect(draft.caret == expected)
        }
    }

    @Test func textAroundTheCaretSplitsTheDraft() {
        var draft = draft("今天开会")
        #expect(draft.textBeforeCaret == "今天开会" && draft.textAfterCaret == "")
        _ = draft.moveCaret(.left)
        _ = draft.moveCaret(.left)
        #expect(draft.textBeforeCaret == "今天" && draft.textAfterCaret == "开会")
        _ = draft.moveCaret(.start)
        #expect(draft.textBeforeCaret == "" && draft.textAfterCaret == "今天开会")
    }

    // MARK: - Editing at the caret

    @Test func committedTextIsInsertedAtTheCaretAndTheCaretMovesAfterIt() {
        var draft = draft("今天开会")
        _ = draft.moveCaret(.left)
        _ = draft.moveCaret(.left)
        _ = draft.insertForLiveSession("下午😀")
        #expect(draft.text == "今天下午😀开会")
        #expect(draft.caret == 6)
        _ = draft.insertForLiveSession("三点")
        #expect(draft.text == "今天下午😀三点开会")
        #expect(draft.textAfterCaret == "开会")
    }

    @Test func insertionThatJoinsTheNextCharacterLeavesTheCaretAfterTheJoinedCharacter() {
        var draft = draft("\u{301}x")
        _ = draft.moveCaret(.start)
        _ = draft.insertForLiveSession("e")
        #expect(draft.text == "e\u{301}x")
        #expect(draft.caret == 2)
    }

    @Test func backspaceDeletesTheCharacterBeforeTheCaret() {
        var draft = draft("今😀天e\u{301}")
        _ = draft.moveCaret(.left)
        let step13 = draft.deleteBackward()
        #expect(step13)
        #expect(draft.text == "今😀e\u{301}" && draft.caret == 3)
        let step14 = draft.deleteBackward()
        #expect(step14)
        #expect(draft.text == "今e\u{301}" && draft.caret == 1)
        let step15 = draft.deleteBackward()
        #expect(step15)
        #expect(draft.text == "e\u{301}" && draft.caret == 0)
        let step16 = draft.deleteBackward()
        #expect(!step16)
        #expect(draft.text == "e\u{301}" && draft.caret == 0)
    }

    @Test func forwardDeleteDeletesTheCharacterAfterTheCaret() {
        var draft = draft("今😀e\u{301}天")
        let step17 = draft.deleteForward()
        #expect(!step17)
        _ = draft.moveCaret(.start)
        _ = draft.moveCaret(.right)
        let step18 = draft.deleteForward()
        #expect(step18)
        #expect(draft.text == "今e\u{301}天" && draft.caret == 1)
        let step19 = draft.deleteForward()
        #expect(step19)
        #expect(draft.text == "今天" && draft.caret == 1)
        let step20 = draft.deleteForward()
        #expect(step20)
        #expect(draft.text == "今" && draft.caret == 1)
        let step21 = draft.deleteForward()
        #expect(!step21)
    }

    @Test func ordinaryAppendOutsideASessionGoesToTheEnd() {
        var draft = draft("今天开会")
        _ = draft.moveCaret(.start)
        _ = draft.append("了")
        #expect(draft.text == "今天开会了" && draft.caret == 5)
    }

    @Test func lengthLimitCountsTheWholeDraftWhereverTextIsInserted() {
        var draft = draft(String(repeating: "字", count: DraftBuffer.maxLength - 1))
        _ = draft.moveCaret(.start)
        #expect(!draft.isFullForLiveSession)
        let full = draft.insertForLiveSession("好")
        #expect(full && draft.isFullForLiveSession)
        #expect(draft.text.hasPrefix("好字") && draft.text.utf16.count == DraftBuffer.maxLength)
        #expect(draft.caret == 1)
    }

    // MARK: - Keys

    private func key(
        _ keyCode: UInt16, option: Bool = false, command: Bool = false, control: Bool = false, shift: Bool = false,
        sessionActive: Bool = true, draftIsEmpty: Bool = false, isComposing: Bool = false
    ) -> LiveDraftKey? {
        LiveDraftKey.decision(
            keyCode: keyCode, option: option, command: command, control: control, shift: shift,
            sessionActive: sessionActive, draftIsEmpty: draftIsEmpty, isComposing: isComposing)
    }

    @Test func caretKeysAreNotTakenOutsideASessionWithAnEmptyDraftOrWhileComposing() {
        let keys: [(UInt16, Bool, Bool)] = [   // key code, command, control
            (123, false, false), (124, false, false), (115, false, false), (119, false, false),
            (123, true, false), (124, true, false), (0, false, true), (14, false, true),
            (51, false, false), (117, false, false)
        ]
        for (keyCode, command, control) in keys {
            #expect(key(keyCode, command: command, control: control) != nil)
            #expect(key(keyCode, command: command, control: control, sessionActive: false) == nil)
            #expect(key(keyCode, command: command, control: control, draftIsEmpty: true) == nil)
            #expect(key(keyCode, command: command, control: control, isComposing: true) == nil)
        }
    }

    @Test func codeLeftOnFocusLossStaysAtTheCaret() {
        var draft = draft("今天开会")
        _ = draft.apply(.move(.left))
        _ = draft.apply(.move(.left))
        _ = draft.insertForLiveSession("xiawu")
        #expect(draft.take() == "今天xiawu开会")
        #expect(draft.isEmpty)
    }

    @Test func arrowsHomeAndEndMoveTheCaret() {
        #expect(key(123) == .move(.left))
        #expect(key(124) == .move(.right))
        #expect(key(115) == .move(.start))
        #expect(key(119) == .move(.end))
        #expect(key(123, command: true) == .move(.start))
        #expect(key(124, command: true) == .move(.end))
        #expect(key(0, control: true) == .move(.start))   // ⌃A
        #expect(key(14, control: true) == .move(.end))    // ⌃E
    }

    @Test func deleteKeysEditAtTheCaret() {
        #expect(key(51) == .deleteBackward)
        #expect(key(117) == .deleteForward)
        // As before a session had a caret: ⌥⌫ and ⇧⌫ still delete one character.
        #expect(key(51, option: true) == .deleteBackward)
        #expect(key(51, shift: true) == .deleteBackward)
        #expect(key(51, command: true) == nil)
        #expect(key(117, control: true) == nil)
    }

    @Test func everythingElseKeepsItsDraftBehavior() {
        // Up, Down, Page Up, Page Down, Tab, Return, Esc, letters.
        for keyCode: UInt16 in [125, 126, 116, 121, 48, 36, 76, 53, 0, 14, 38] {
            #expect(key(keyCode) == nil)
        }
        // Word and selection movement, and other shortcuts, are not caret keys.
        #expect(key(123, option: true) == nil)
        #expect(key(124, shift: true) == nil)
        #expect(key(123, command: true, shift: true) == nil)
        #expect(key(123, control: true) == nil)
        #expect(key(115, command: true) == nil)
        #expect(key(0, command: true) == nil)             // ⌘A
        #expect(key(0, option: true, control: true) == nil)
        #expect(key(14, option: true, command: true, control: true) == nil) // the English shortcut
        #expect(key(9, command: true) == nil)             // ⌘V
    }

    @Test func applyingAKeyReportsWhetherAnythingChanged() {
        var draft = draft("今天")
        let step22 = draft.apply(.move(.left))
        #expect(step22 && draft.caret == 1)
        let step23 = draft.apply(.deleteForward)
        #expect(step23 && draft.text == "今")
        let step24 = draft.apply(.deleteForward)
        #expect(!step24)
        let step25 = draft.apply(.move(.right))
        #expect(!step25)
        let step26 = draft.apply(.deleteBackward)
        #expect(step26 && draft.isEmpty)
        let step27 = draft.apply(.deleteBackward)
        #expect(!step27)
    }

    // MARK: - Source revisions

    @Test func movingTheCaretIsNotASourceRevisionButEditingAtItIs() {
        var draft = draft("今天开会")
        var session = LiveTranslationSession(id: 1, target: .english)
        _ = session.handle(.sourceChanged(draft.text))
        #expect(session.revision == 1)
        _ = draft.apply(.move(.left))
        _ = draft.apply(.move(.start))
        let effects = session.handle(.sourceChanged(draft.text))
        #expect(effects.isEmpty)
        #expect(session.revision == 1)
        _ = draft.insertForLiveSession("我们")
        _ = session.handle(.sourceChanged(draft.text))
        #expect(session.revision == 2)
        _ = draft.apply(.deleteForward)
        _ = session.handle(.sourceChanged(draft.text))
        #expect(session.revision == 3 && session.source == "我们天开会")
    }
}
