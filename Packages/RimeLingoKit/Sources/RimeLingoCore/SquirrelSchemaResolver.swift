import Foundation

/// After an import every schema in the effective `schema_list` must be loadable. Squirrel
/// ships its stock schemas inside the application bundle, not in the user directory, so a
/// list that names one of them would leave librime with "missing input schema".
extension SquirrelImporter {
    /// Files one schema needs from the Squirrel bundle, in discovery order.
    struct SchemaRequirements {
        var files: [String] = []
        /// Optional extras (dependencies, presets, vocabulary) found nowhere.
        var missing: [String] = []
        var visited: Set<String> = []
    }

    /// Where a file librime will look for comes from.
    private enum Origin {
        /// Already in the RimeLingo user directory (imported, or from an earlier run).
        case user(URL)
        /// Part of RimeLingo's shared data, which is complete on its own.
        case shipped
        case bundle(URL)
    }

    private enum Lookup {
        case missing
        case satisfied
        /// The file's content, whose references still have to be followed.
        case follow(ConfigValue)
    }

    /// Makes every listed schema loadable: copies what only the Squirrel bundle provides,
    /// drops the schemas that cannot be completed and records both in the report. Skipped
    /// when the shipped data location is unknown: nothing could be told apart from
    /// "missing" then.
    func resolveListedSchemas(layers: ConfigLayers, report: inout Report) throws {
        guard let shared = paths.sharedDataDir else { return }
        // A list the previous import substituted is this importer's to recompute; a list
        // chosen in Settings since then differs from the recorded one and is left alone.
        if let previous = Report.load(paths)?.schemaListOverride,
           Self.schemaIDs(layers.generatedValue(.default, keypath: "schema_list")) == previous {
            try layers.setGenerated(.default, keypath: "schema_list", value: nil)
        }
        guard let listed = listedSchemas(layers: layers, shared: shared), !listed.ids.isEmpty else { return }
        let fm = FileManager.default
        let bundle = squirrelDataDirs.first { fm.fileExists(atPath: $0.path) }
        var kept: [String] = []
        for id in listed.ids where !kept.contains(id) {
            let name = "\(id).schema.yaml"
            // A schema file the user brought along stays listed, and so does everything
            // when the patch edits single list items: there is no whole list to rewrite.
            var droppable = listed.whole
            if case .user = locate(name, in: nil) { droppable = false }
            let outcome = droppable ? "已将它从方案列表中移除。" : "该方案可能无法使用。"
            var needs = SchemaRequirements()
            var usable = false
            if bundle == nil, locate(name, in: nil) == nil {
                report.warnings.append("未找到鼠须管应用，无法补齐输入方案 \(id) 的文件，\(outcome)")
            } else if !collect(schema: id, from: bundle, into: &needs) {
                report.warnings.append("输入方案 \(id) 所需的文件在导入目录、RimeLingo 自带数据和鼠须管应用中都找不全，\(outcome)")
            } else {
                do {
                    if let bundle { report.copied += try copy(needs.files, from: bundle).map { "\($0) (from Squirrel.app)" } }
                    if !needs.missing.isEmpty {
                        report.warnings.append("输入方案 \(id) 引用的 \(needs.missing.joined(separator: "、")) 未找到，反查、符号或预置词频等功能可能不可用。")
                    }
                    usable = true
                } catch {
                    report.warnings.append("从鼠须管应用复制输入方案 \(id) 所需的文件时出错，\(outcome)")
                }
            }
            if usable || !droppable { kept.append(id) }
        }
        guard listed.whole else { return }
        if kept.isEmpty, let fallback = shippedDefaultSchema(shared: shared) {
            report.warnings.append("导入的方案列表中没有可用的输入方案，已改用 RimeLingo 自带的 \(fallback)。")
            kept = [fallback]
        }
        // The imported layer stays verbatim; the corrected list goes into the generated layer.
        guard kept != listed.ids, !kept.isEmpty else { return }
        try layers.setGenerated(.default, keypath: "schema_list", value: .list(kept.map { .map([.init("schema", .string($0))]) }))
        report.schemaListOverride = kept
    }

    /// Copies bundle files into the user directory and returns the ones newly created.
    /// All or nothing: a failure removes what this call created, so no schema is left
    /// half-copied.
    private func copy(_ names: [String], from bundle: URL) throws -> [String] {
        let fm = FileManager.default
        var created: [String] = []
        do {
            for name in names {
                let destination = paths.userDataDir.appendingPathComponent(name)
                // Never overwrite: whatever is already there wins over Squirrel's stock file.
                guard !fm.fileExists(atPath: destination.path) else { continue }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: bundle.appendingPathComponent(name), to: destination)
                created.append(name)
            }
        } catch {
            for name in created { try? fm.removeItem(at: paths.userDataDir.appendingPathComponent(name)) }
            throw error
        }
        return created
    }

    private static func schemaIDs(_ list: ConfigValue?) -> [String] {
        (list?.listValue ?? []).compactMap { $0["schema"]?.stringValue }
    }

    /// `schema_list` as librime will see it: the composed patch, else `default.yaml`.
    /// `whole` is false when the patch edits single list items (`schema_list/+`,
    /// `schema_list/@0/schema`): the schemas it names are then checked, the list is not rewritten.
    private func listedSchemas(layers: ConfigLayers, shared: URL) -> (ids: [String], whole: Bool)? {
        let patch = (try? layers.composedPatch(.default)) ?? []
        if let entry = patch.last(where: { $0.key == "schema_list" || $0.key == "schema_list/=" }) {
            return (Self.schemaIDs(entry.value), true)
        }
        let base = Self.schemaIDs(Self.schemaList(in: [paths.userDataDir, shared]))
        let edits = patch.filter { $0.key.hasPrefix("schema_list/") }
        guard !edits.isEmpty else { return (base, true) }
        let named = edits.flatMap { entry -> [String] in
            if entry.key.hasSuffix("/schema"), let id = entry.value.stringValue { return [id] }
            if let id = entry.value["schema"]?.stringValue { return [id] }
            return Self.schemaIDs(entry.value)
        }
        return (base + named, false)
    }

    private static func schemaList(in directories: [URL]) -> ConfigValue? {
        directories.lazy.compactMap { try? ConfigValue.load(contentsOf: $0.appendingPathComponent("default.yaml")) }
            .first?["schema_list"]
    }

    private func shippedDefaultSchema(shared: URL) -> String? {
        Self.schemaIDs(Self.schemaList(in: [shared]))
            .first { FileManager.default.fileExists(atPath: shared.appendingPathComponent("\($0).schema.yaml").path) }
    }

    /// Finds `name` the way librime does (user directory, then shared data), then in the
    /// Squirrel bundle. Names that would leave those directories are never found.
    private func locate(_ name: String, in bundle: URL?) -> Origin? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let fm = FileManager.default
        let user = paths.userDataDir.appendingPathComponent(name)
        if fm.fileExists(atPath: user.path) { return .user(user) }
        if let shared = paths.sharedDataDir, fm.fileExists(atPath: shared.appendingPathComponent(name).path) { return .shipped }
        if let url = bundle?.appendingPathComponent(name), fm.fileExists(atPath: url.path) { return .bundle(url) }
        return nil
    }

    /// Visits `name` once. A bundle file is added to the files to copy; a file of the user
    /// directory is read in place, because what it refers to may still be missing.
    private func visit(
        _ name: String, in bundle: URL?, needs: inout SchemaRequirements, read: (URL) -> ConfigValue?
    ) -> Lookup {
        guard needs.visited.insert(name).inserted else { return .satisfied }
        switch locate(name, in: bundle) {
        case nil: return .missing
        case .shipped: return .satisfied
        case let .user(url): return read(url).map(Lookup.follow) ?? .satisfied
        case let .bundle(url):
            guard let document = read(url) else { return .missing }
            needs.files.append(name)
            return .follow(document)
        }
    }

    /// Runs `body` on a copy, so a failed optional requirement leaves no partial file list.
    private func attempt(_ needs: inout SchemaRequirements, _ body: (inout SchemaRequirements) -> Bool) -> Bool {
        var trial = needs
        guard body(&trial) else { return false }
        needs = trial
        return true
    }

    /// Schema file, the configs it includes, its dictionaries, presets and dependencies.
    /// False when something the schema cannot load without is missing.
    private func collect(schema id: String, from bundle: URL?, into needs: inout SchemaRequirements) -> Bool {
        let document: ConfigValue
        switch visit("\(id).schema.yaml", in: bundle, needs: &needs, read: { try? ConfigValue.load(contentsOf: $0) }) {
        case .missing: return false
        case .satisfied: return true
        case let .follow(found): document = found
        }
        guard collectReferences(of: document, from: bundle, into: &needs) else { return false }
        if let dictionary = document.value(at: "translator/dictionary")?.stringValue, !dictionary.isEmpty,
           !collect(dictionary: dictionary, from: bundle, into: &needs) {
            return false
        }
        // Reverse lookup and named translators: the schema still types without them.
        for dictionary in Self.strings(forKey: "dictionary", in: document) where !dictionary.isEmpty {
            if !attempt(&needs, { collect(dictionary: dictionary, from: bundle, into: &$0) }) {
                needs.missing.append("\(dictionary).dict.yaml")
            }
        }
        for preset in Self.strings(forKey: "import_preset", in: document) {
            if !attempt(&needs, { collect(config: preset, from: bundle, into: &$0) }) { needs.missing.append("\(preset).yaml") }
        }
        for dependency in (document.value(at: "schema/dependencies")?.listValue ?? []).compactMap(\.stringValue) {
            if !attempt(&needs, { collect(schema: dependency, from: bundle, into: &$0) }) {
                needs.missing.append("\(dependency).schema.yaml")
            }
        }
        return true
    }

    /// A plain config (`pinyin.yaml`, `symbols.yaml`) named by `__include`, `__patch` or `import_preset`.
    private func collect(config resource: String, from bundle: URL?, into needs: inout SchemaRequirements) -> Bool {
        switch visit("\(resource).yaml", in: bundle, needs: &needs, read: { try? ConfigValue.load(contentsOf: $0) }) {
        case .missing: false
        case .satisfied: true
        case let .follow(document): collectReferences(of: document, from: bundle, into: &needs)
        }
    }

    /// `resource:/key` references: `x.schema` is another schema, anything else a config file.
    /// Optional references (`…?`) that cannot be satisfied are skipped, as librime does.
    private func collectReferences(of document: ConfigValue, from bundle: URL?, into needs: inout SchemaRequirements) -> Bool {
        for reference in Self.strings(forKey: "__include", in: document) + Self.strings(forKey: "__patch", in: document) {
            guard let separator = reference.firstIndex(of: ":"), separator != reference.startIndex else { continue }
            var resource = String(reference[..<separator])
            if resource.hasSuffix(".yaml") { resource.removeLast(".yaml".count) }
            let found = attempt(&needs) { trial in
                resource.hasSuffix(".schema")
                    ? collect(schema: String(resource.dropLast(".schema".count)), from: bundle, into: &trial)
                    : collect(config: resource, from: bundle, into: &trial)
            }
            if !found, !reference.hasSuffix("?") { return false }
        }
        return true
    }

    /// `<name>.dict.yaml`, its `import_tables`, and the preset vocabulary when it uses one.
    private func collect(dictionary: String, from bundle: URL?, into needs: inout SchemaRequirements) -> Bool {
        let settings: ConfigValue
        switch visit("\(dictionary).dict.yaml", in: bundle, needs: &needs, read: Self.dictionaryHeader) {
        case .missing: return false
        case .satisfied: return true
        case let .follow(header): settings = header
        }
        for table in (settings["import_tables"]?.listValue ?? []).compactMap(\.stringValue) {
            guard collect(dictionary: table, from: bundle, into: &needs) else { return false }
        }
        if settings["use_preset_vocabulary"]?.boolValue == true {
            let vocabulary = "\(settings["vocabulary"]?.stringValue ?? "essay").txt"
            if needs.visited.insert(vocabulary).inserted {
                switch locate(vocabulary, in: bundle) {
                case nil: needs.missing.append(vocabulary)
                case .bundle: needs.files.append(vocabulary)
                case .user, .shipped: break
                }
            }
        }
        return true
    }

    /// Only the YAML header (up to the `...` line) is a document; the entries follow it, so
    /// the start of the file is enough. Nil when unreadable, empty when it does not parse.
    private static func dictionaryHeader(_ url: URL) -> ConfigValue? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 16) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let header = text.range(of: "\n...").map { String(text[..<$0.lowerBound]) } ?? text
        return (try? ConfigValue.parse(yaml: header)) ?? .map([])
    }

    /// Every string stored under `key` anywhere in the document (a scalar or a list of them).
    private static func strings(forKey key: String, in value: ConfigValue) -> [String] {
        switch value {
        case let .map(entries):
            entries.flatMap { entry -> [String] in
                guard entry.key == key else { return strings(forKey: key, in: entry.value) }
                if let single = entry.value.stringValue { return [single] }
                return (entry.value.listValue ?? []).compactMap(\.stringValue) + strings(forKey: key, in: entry.value)
            }
        case let .list(items): items.flatMap { strings(forKey: key, in: $0) }
        default: []
        }
    }
}
