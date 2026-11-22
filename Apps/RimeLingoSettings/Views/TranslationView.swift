import RimeLingoCore
import SwiftUI

/// Live and selected-text translation: the switch, the target languages with a shortcut
/// each, the submit shortcut and the model. Saved through the features channel, so the
/// input method follows without a deploy or a restart.
struct TranslationView: View {
    @Environment(SettingsModel.self) private var model
    @Binding var selection: Pane?
    /// The AI assistant pane keeps the provider here and pushes it to the features file
    /// when it appears, so a change made on this pane is written to both.
    @AppStorage("ai.provider") private var storedProvider = "apple"
    /// Why the last recording or restore of a shortcut was refused.
    @State private var refusals: [TranslationShortcutAction: String] = [:]

    /// FoundationModels ships with macOS 26; older systems need a custom endpoint.
    private var onDeviceModelSupported: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    var body: some View {
        let features = model.features
        let bindings = TranslationShortcutBindings(features: features)
        Form {
            Section {
                PaneHeader(title: "翻译", subtitle: "边打字边翻译，或把选中的文字翻译后替换。", symbol: Pane.translation.symbol)
            }

            Section {
                Toggle(isOn: Binding(get: { features.liveTranslation }, set: { on in model.updateFeatures { $0.liveTranslation = on } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("实时翻译")
                        Text("按语言快捷键开启，再按一次关闭。开启后打出的字先停在光标处，译文显示在光标旁；没有在打字时不显示任何界面。选中了文字时，同一个快捷键翻译选中的部分。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("实时翻译")
            }

            Section {
                if bindings.languages.isEmpty {
                    Text("还没有目标语言。添加一种语言并为它设置快捷键。").foregroundStyle(.secondary)
                }
                ForEach(bindings.languages, id: \.code) { target in
                    languageRow(target, bindings: bindings)
                }
                let available = TranslationTarget.allCases.filter { !bindings.languages.contains($0) }
                Menu {
                    ForEach(available, id: \.code) { target in
                        Button(target.displayName) {
                            model.updateFeatures { $0.addTranslationLanguage(target, others: catalogHotkeys) }
                        }
                    }
                } label: {
                    Label("添加语言", systemImage: "plus")
                }
                .fixedSize()
                .disabled(available.isEmpty)
            } header: {
                Text("目标语言")
            } footer: {
                Text("没有快捷键的语言无法开启。无法检测与其他应用或系统快捷键的冲突。")
            }
            .disabled(!features.liveTranslation)

            Section {
                submitRow(bindings: bindings)
                keyNote("上屏原文", "↩")
                keyNote("关闭翻译", "再按一次语言快捷键")
                keyNote("切换语言", "按另一种语言的快捷键")
                keyNote("esc", "有未上屏的文字时：原文上屏并关闭翻译；没有时照常交给应用")
                keyNote("关闭选区译文", "esc")
            } header: {
                Text("按键")
            } footer: {
                Text("关闭翻译时，还没上屏的原文会先写进应用，不会丢失。")
            }

            Section {
                // Shows what the input method reads, which is the features file.
                Picker("提供方", selection: Binding(get: { features.aiProvider }, set: { id in
                    storedProvider = id
                    model.updateFeatures { $0.aiProvider = id }
                })) {
                    Text(onDeviceModelSupported ? "Apple 端侧模型（本机，推荐）" : "Apple 端侧模型（需要 macOS 26）").tag("apple")
                    Text("OpenAI 兼容接口（自备 Key）").tag("openai")
                }
                if features.aiProvider == "openai" {
                    Toggle(isOn: Binding(get: { features.aiRemoteAllowed }, set: { on in model.updateFeatures { $0.aiRemoteAllowed = on } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("允许把要翻译的文字发送到自备接口")
                            Text("翻译时会把那段文字发送到 \(URL(string: features.aiBaseURL)?.host() ?? features.aiBaseURL)。未允许时无法用自备接口翻译。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Button("在「AI 助手」中配置接口与模型…") { selection = .ai }
            } header: {
                Text("翻译模型")
            } footer: {
                Text("实时翻译与 AI 动作共用同一个模型设置。")
            }
        }
        .formStyle(.cards)
    }

    // MARK: - Rows

    private func languageRow(_ target: TranslationTarget, bindings: TranslationShortcutBindings) -> some View {
        let action = TranslationShortcutAction.language(target)
        let current = bindings[action]
        let index = bindings.languages.firstIndex(of: target) ?? 0
        return LabeledContent {
            HStack(spacing: 4) {
                KeyRecorder(value: current, placeholder: "未设置") { assign($0, to: action) }
                    .accessibilityLabel("\(action.title)快捷键")
                // Fixed slot so recorders line up whether or not the key is set.
                ZStack {
                    if !current.isEmpty {
                        Button {
                            refusals[action] = nil
                            model.updateFeatures { $0[shortcut: action] = "" }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("清除快捷键")
                        .accessibilityLabel("清除\(action.title)快捷键")
                    }
                }
                .frame(width: 18)
                Menu {
                    Button("上移") { model.updateFeatures { $0.moveTranslationLanguage(code: target.code, by: -1) } }
                        .disabled(index == 0)
                    Button("下移") { model.updateFeatures { $0.moveTranslationLanguage(code: target.code, by: 1) } }
                        .disabled(index == bindings.languages.count - 1)
                    Divider()
                    Button("移除", role: .destructive) {
                        refusals[action] = nil
                        model.updateFeatures { $0.removeTranslationLanguage(code: target.code) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多")
                .accessibilityLabel("更多")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
                Text(target.promptName).font(.caption).foregroundStyle(.secondary)
                refusal(for: action)
            }
        }
    }

    /// The submit shortcut cannot be cleared: it is the way to insert a translation.
    private func submitRow(bindings: TranslationShortcutBindings) -> some View {
        let action = TranslationShortcutAction.submit
        let current = bindings[action]
        return LabeledContent {
            HStack(spacing: 4) {
                KeyRecorder(value: current) { assign($0, to: action) }
                    .accessibilityLabel("\(action.title)快捷键")
                // The slot of a language row's clear button, so the recorders line up.
                Color.clear.frame(width: 18, height: 1)
                Button {
                    assign(action.defaultShortcut, to: action)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .disabled(current == action.defaultShortcut)
                .help("恢复默认：\(HotkeyFormatter.display(action.defaultShortcut))")
                .accessibilityLabel("恢复\(action.title)的默认快捷键")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                Text("把译文写进应用；翻译失败时再按一次重试。选中文字翻译时用它替换选区。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                refusal(for: action)
            }
        }
    }

    @ViewBuilder
    private func refusal(for action: TranslationShortcutAction) -> some View {
        if let refusal = refusals[action] {
            Text(refusal).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A key that is not configurable, shown for reference.
    private func keyNote(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) {
            Text(keys).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Writing

    /// The catalog's hotkey settings as stored, for duplicate detection.
    private var catalogHotkeys: [(shortcut: String, title: String)] {
        model.catalog.settings.flatMap { setting -> [(shortcut: String, title: String)] in
            switch setting.type {
            case .hotkey: [(model.value(setting)?.stringValue ?? "", setting.title)]
            case .hotkeyList: (model.value(setting)?.listValue ?? []).compactMap(\.stringValue).map { ($0, setting.title) }
            default: []
            }
        }
    }

    /// Recording and restoring take the same checks; a refused value is not saved.
    private func assign(_ shortcut: String, to action: TranslationShortcutAction) {
        if let issue = TranslationShortcutBindings(features: model.features).issue(recording: shortcut, for: action, others: catalogHotkeys) {
            refusals[action] = "未采用 \(HotkeyFormatter.display(shortcut))：\(issue.message)"
            return
        }
        refusals[action] = nil
        model.updateFeatures { $0[shortcut: action] = shortcut }
    }
}
