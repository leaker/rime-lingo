import AppKit
import InputMethodKit

// TEMPORARY — Phase 2 probe. Remove this file when real shortcut dispatch lands.
//
// Answers two questions in real applications: do ⌃⌥⌘E and ⌃⌥⌘J reach handle(_:client:),
// and what selection does the client expose. One line of metadata per press goes to
// probe.log in the log directory, with no debug switch. Only ranges, lengths and counts
// are recorded or shown — never a character of the client's text.
//
// The caller runs this only after the secure-context gate has passed.
extension RimeLingoInputController {
    private static let probeKeys: [UInt16: String] = [14: "E", 38: "J"]
    private static let probeReadLimit = 4000

    /// The probe key of a keyDown with exactly Control+Option+Command, or nil.
    func probeKey(for event: NSEvent) -> String? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
        guard flags == [.control, .option, .command] else { return nil }
        return Self.probeKeys[event.keyCode]
    }

    /// Records what the client exposes and shows a one-line summary.
    /// Returns false, leaving the key unconsumed, when a secure context has begun.
    @discardableResult
    func runSelectionProbe(key: String, client: (any IMKTextInput)?) -> Bool {
        // Asked again right before the client is read; a secure context gets nothing.
        guard !blockedBySecureContext(client: client) else { return false }
        let engine = InputEngine.shared
        var fields = ["key=\(key)", "bundle=\(client?.bundleIdentifier() ?? "-")"]
        let summary: String

        if let client {
            let selected = client.selectedRange()
            let marked = client.markedRange()
            let valid = selected.location != NSNotFound
            fields.append("client=\(valid ? "ok" : "no-selection-range")")
            fields.append("docLength=\(client.length())")
            fields.append("selLocation=\(valid ? String(selected.location) : "NSNotFound")")
            fields.append("selLength=\(selected.length)")
            fields.append("markedLength=\(marked.location == NSNotFound ? "NSNotFound" : String(marked.length))")
            if !valid {
                fields.append("substring=not-asked")
                summary = "客户端未提供选区"
            } else if selected.length == 0 {
                fields.append("substring=not-asked")
                summary = "无选区"
            } else if selected.length > Self.probeReadLimit {
                fields.append("substring=not-asked-too-long")
                summary = "选中 \(selected.length) 字，超过 \(Self.probeReadLimit) 未读取"
            } else if let text = client.attributedSubstring(from: selected)?.string {
                // Measured and dropped here: the text itself goes nowhere.
                let length = text.utf16.count
                fields.append("substring=ok")
                fields.append("substringLength=\(length)")
                fields.append("lengthMatches=\(length == selected.length)")
                fields.append("lineBreaks=\(Self.probeLineBreaks(in: text))")
                summary = length == selected.length
                    ? "选中 \(selected.length) 字，可读取"
                    : "选中 \(selected.length) 字，读到 \(length) 字"
            } else {
                fields.append("substring=nil")
                summary = "有选区但读不到"
            }
        } else {
            fields.append("client=none")
            summary = "无客户端"
        }

        Self.appendProbeLine(fields.joined(separator: " "), to: engine.paths.logDir)
        engine.showStatus("探测 \(key)：\(summary)")
        return true
    }

    /// Line breaks in the text; CR LF counts once.
    private static func probeLineBreaks(in text: String) -> Int {
        var count = 0
        var previous: UInt16 = 0
        for unit in text.utf16 {
            switch unit {
            case 0x0A: if previous != 0x0D { count += 1 }
            case 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029: count += 1
            default: break
            }
            previous = unit
        }
        return count
    }

    private static func appendProbeLine(_ message: String, to directory: URL) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
        let url = directory.appendingPathComponent("probe.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
