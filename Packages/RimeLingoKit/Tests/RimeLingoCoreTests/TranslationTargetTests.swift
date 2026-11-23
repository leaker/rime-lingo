import Foundation
@testable import RimeLingoCore
import Testing

struct TranslationTargetTests {
    @Test func theCatalogOffersManyLanguagesWithUniqueCodes() {
        let all = TranslationTarget.allCases
        #expect(all.count >= 20)
        #expect(Set(all.map(\.code)).count == all.count)
        #expect(Set(all.map { $0.code.lowercased() }).count == all.count)
        #expect(Set(all.map(\.displayName)).count == all.count)
        #expect(all.prefix(2) == [.english, .japanese])
        for target in all {
            #expect(!target.promptName.isEmpty && !target.displayName.isEmpty, "\(target.code)")
        }
    }

    /// A prompt names its language once; a name inside another one would make "the text is
    /// already in X" ambiguous and breaks checks that look for the name.
    @Test func noPromptNameContainsAnother() {
        let names = TranslationTarget.allCases.map { $0.promptName.lowercased() }
        for (index, name) in names.enumerated() {
            for (other, otherName) in names.enumerated() where other != index {
                #expect(!name.contains(otherName), "\(name) contains \(otherName)")
            }
        }
    }

    @Test func englishAndJapaneseKeepTheirNamesAndShortcuts() {
        #expect(TranslationTarget.english.code == "en")
        #expect(TranslationTarget.english.promptName == "English")
        #expect(TranslationTarget.english.displayName == "英语")
        #expect(TranslationTarget.english.defaultShortcut == "Control+Alt+Super+e")
        #expect(TranslationTarget.japanese.code == "ja")
        #expect(TranslationTarget.japanese.promptName == "Japanese")
        #expect(TranslationTarget.japanese.displayName == "日语")
        #expect(TranslationTarget.japanese.defaultShortcut == "Control+Alt+Super+j")
        for target in TranslationTarget.allCases.dropFirst(2) { #expect(target.defaultShortcut.isEmpty, "\(target.code)") }
        #expect(TranslationShortcutAction.english.title == "翻译为英语")
        #expect(TranslationShortcutAction.japanese.title == "翻译为日语")
        #expect(TranslationShortcutAction.submit.title == "提交译文")
        #expect(TranslationShortcutAction.english.target == .english)
        #expect(TranslationShortcutAction.submit.target == nil)
    }

    @Test func codesAreLookedUpIgnoringCase() throws {
        let traditional = try #require(TranslationTarget(code: "ZH-hant"))
        #expect(traditional.code == "zh-Hant")
        #expect(traditional.promptName == "Traditional Chinese")
        #expect(traditional.displayName == "繁体中文")
        #expect(TranslationTarget(code: "EN") == .english)
        #expect(TranslationTarget(code: "english") == nil)
        #expect(TranslationTarget(code: "") == nil)
        #expect(TranslationTarget(code: "xx") == nil)
    }

    @Test func encodesAsItsCode() throws {
        let all = TranslationTarget.allCases
        let data = try JSONEncoder().encode(all)
        #expect(try JSONDecoder().decode([String].self, from: data) == all.map(\.code))
        #expect(try JSONDecoder().decode([TranslationTarget].self, from: data) == all)
        #expect(try JSONDecoder().decode([TranslationTarget].self, from: Data(#"["JA"]"#.utf8)) == [.japanese])
    }

    @Test func anUnknownCodeFailsToDecode() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([TranslationTarget].self, from: Data(#"["xx"]"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([TranslationTarget].self, from: Data("[7]".utf8))
        }
    }
}
