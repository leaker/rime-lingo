import AppKit
import RimeLingoCore
import SwiftUI

/// The settings app's colours (Apps/RimeLingoSettings/Views/Theme.swift), which this
/// target does not link: neutral surfaces, the brand in the vermilion accent.
private enum InstallerPalette {
    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) {
            let value = $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }

    static let canvas = dynamic(light: (246/255, 246/255, 245/255), dark: (28/255, 28/255, 29/255))
    static let accent = dynamic(light: (182/255, 64/255, 50/255), dark: (196/255, 80/255, 63/255))
    static let text = dynamic(light: (36/255, 35/255, 33/255), dark: (242/255, 242/255, 240/255))
    static let secondaryText = dynamic(light: (107/255, 106/255, 103/255), dark: (163/255, 163/255, 160/255))
    static let success = dynamic(light: (0.111, 0.530, 0.260), dark: (0.374, 0.829, 0.497))
    static let warning = dynamic(light: (0.664, 0.372, 0.089), dark: (0.967, 0.676, 0.301))
}

struct InstallerView: View {
    let model: InstallerModel
    @State private var confirmingDowngrade = false

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(InstallerPalette.text)
                .padding(.top, 14)
            content
                .padding(.top, 10)
                .frame(maxWidth: .infinity)
            buttons
                .padding(.top, 26)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(InstallerPalette.canvas)
        .tint(InstallerPalette.accent)
        .alert("要换回旧版本吗？", isPresented: $confirmingDowngrade) {
            Button("取消", role: .cancel) {}
            Button("安装旧版本", role: .destructive) { model.install() }
        } message: {
            Text(model.offer.versionSummary ?? "")
        }
    }

    private var title: String {
        switch model.phase {
        case .ready: model.offer.title
        case .installing: "正在安装…"
        case .done: "安装完成"
        case .failed: "安装没有完成"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .ready:
            VStack(spacing: 8) {
                Text(model.offer.explanation)
                    .foregroundStyle(InstallerPalette.secondaryText)
                Text(model.offer.versionSummary ?? "版本 \(model.offer.new.description)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(InstallerPalette.secondaryText)
                if model.hasSystemCopy {
                    Label("「/资源库/Input Methods」里还有一份灵译输入法。两份并存时系统可能用到旧的那一份，建议安装后请管理员删除它。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(InstallerPalette.warning)
                        .padding(.top, 4)
                }
            }
        case let .installing(step):
            VStack(spacing: 10) {
                ProgressView(value: Double(step.rawValue + 1), total: Double(InstallStep.allCases.count + 1))
                    .progressViewStyle(.linear)
                Text(step.title)
                    .font(.callout)
                    .foregroundStyle(InstallerPalette.secondaryText)
            }
            .padding(.top, 6)
        case .done:
            VStack(spacing: 8) {
                Label("灵译输入法已经可以使用", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(InstallerPalette.success)
                Text("点菜单栏的输入法图标选择「灵译输入法」，或者按 ⌃空格 切换。")
                    .foregroundStyle(InstallerPalette.secondaryText)
            }
        case let .failed(failure):
            VStack(spacing: 8) {
                Text(failure.message)
                    .foregroundStyle(InstallerPalette.text)
                if !failure.detail.isEmpty {
                    Text(verbatim: "\(failure.step) · \(failure.detail)")
                        .font(.caption.monospaced())
                        .foregroundStyle(InstallerPalette.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
                Link("查看手动安装方法", destination: InstallerModel.manualInstallURL)
                    .font(.callout)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .ready:
                if model.offer.requiresConfirmation {
                    // The safe choice is the default one.
                    Button(model.offer.actionTitle) { confirmingDowngrade = true }
                    Button("不安装") { NSApp.terminate(nil) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("取消") { NSApp.terminate(nil) }
                        .keyboardShortcut(.cancelAction)
                    Button(model.offer.actionTitle) { model.install() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            case .installing:
                // Keeps the window from changing height between states.
                Button("取消") {}
                    .hidden()
                    .accessibilityHidden(true)
            case .done:
                Button("完成") { NSApp.terminate(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(model.wasFirstInstall ? "开始设置" : "打开设置") { model.openSettingsAndQuit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button("退出") { NSApp.terminate(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("重试") { model.install() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }
}
