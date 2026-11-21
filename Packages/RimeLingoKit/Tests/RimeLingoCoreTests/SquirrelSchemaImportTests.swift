import Foundation
import Testing
@testable import RimeLingoCore

/// Schemas the imported `schema_list` names but only the Squirrel application bundle ships.
struct SquirrelSchemaImportTests {
    let root: URL
    let source: URL
    let bundle: URL
    let shared: URL
    let paths: RimeLingoPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rimelingo-schema-import-\(UUID().uuidString)")
        source = root.appendingPathComponent("Rime")
        bundle = root.appendingPathComponent("Squirrel.app/Contents/SharedSupport")
        shared = root.appendingPathComponent("Shipped")
        paths = RimeLingoPaths(userDataDir: root.appendingPathComponent("RimeLingo"), sharedDataDir: shared)
        try write(shared, [
            "default.yaml": "schema_list:\n  - schema: house\n",
            "house.schema.yaml": "schema: {schema_id: house}\n",
        ])
        try write(bundle, [
            // Shipped by RimeLingo as well: must never be copied.
            "default.yaml": "schema_list:\n  - schema: alpha\n",
            "alpha_simp.schema.yaml": "__include: alpha.schema:/\nschema:\n  schema_id: alpha_simp\n",
            "alpha.schema.yaml": """
            schema:
              schema_id: alpha
              dependencies:
                - strokey
            speller:
              algebra:
                __patch:
                  - spell:/abbreviation
                  - grammar:/hant?
            translator:
              dictionary: alpha
            reverse_lookup:
              dictionary: lookup
            punctuator:
              import_preset: symbols
            key_binder:
              import_preset: default

            """,
            "alpha.dict.yaml": "# Rime dictionary\n---\nname: alpha\nimport_tables:\n  - alpha.ext\nuse_preset_vocabulary: true\n...\n\n啊\ta\n",
            "alpha.ext.dict.yaml": "---\nname: alpha.ext\n...\n\n阿\ta\n",
            "strokey.schema.yaml": "schema: {schema_id: strokey}\ntranslator: {dictionary: strokey}\n",
            "strokey.dict.yaml": "---\nname: strokey\n...\n\n一\th\n",
            // Reachable through `reverse_lookup/dictionary` only.
            "lookup.dict.yaml": "---\nname: lookup\n...\n\n一\ty\n",
            "spell.yaml": "abbreviation: []\n",
            "symbols.yaml": "punctuator: {}\n",
            "essay.txt": "啊\t1\n",
            // Its dictionary is not in the bundle.
            "broken.schema.yaml": "schema: {schema_id: broken}\ntranslator: {dictionary: nowhere}\n",
        ])
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    static let transitive = [
        "alpha_simp.schema.yaml", "alpha.schema.yaml", "alpha.dict.yaml", "alpha.ext.dict.yaml", "strokey.schema.yaml",
        "strokey.dict.yaml", "lookup.dict.yaml", "spell.yaml", "symbols.yaml", "essay.txt",
    ]

    private func write(_ directory: URL, _ files: [String: String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private func listSchemas(_ ids: [String]) throws {
        let list = ids.map { "    - schema: \($0)\n" }.joined()
        try write(source, ["default.custom.yaml": "patch:\n  schema_list:\n\(list)"])
    }

    private func runImport(bundles: [URL]? = nil) throws -> SquirrelImporter.Report {
        let importer = SquirrelImporter(paths: paths, source: source, squirrelDataDirs: bundles ?? [bundle])
        return try importer.execute(importer.plan())
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent(name).path)
    }

    private func text(_ name: String) throws -> String {
        try String(contentsOf: paths.userDataDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// `schema_list` as the composed `default.custom.yaml` hands it to librime.
    private func deployedSchemas() throws -> [String] {
        let shim = try ConfigValue.load(contentsOf: ConfigLayers(paths: paths).shimURL(.default))
        return (shim["patch"]?["schema_list"]?.listValue ?? []).compactMap { $0["schema"]?.stringValue }
    }

    private func bundleFingerprint() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: bundle.path) {
            result[name] = try Data(contentsOf: bundle.appendingPathComponent(name))
        }
        return result
    }

    @Test func copiesMissingSchemaWithItsTransitiveRequirements() throws {
        try listSchemas(["alpha_simp"])
        let before = try bundleFingerprint()
        let report = try runImport()
        for name in Self.transitive {
            #expect(exists(name), "\(name) should be copied")
            #expect(report.copied.contains { $0.hasPrefix(name + " ") }, "\(name) should be reported")
        }
        #expect(!exists("default.yaml"))
        #expect(!exists("broken.schema.yaml"))
        #expect(try deployedSchemas() == ["alpha_simp"])
        #expect(ConfigLayers(paths: paths).generatedValue(.default, keypath: "schema_list") == nil)
        #expect(!report.warnings.contains { $0.contains("alpha") })
        #expect(try bundleFingerprint() == before)
    }

    @Test func neverOverwritesExistingFiles() throws {
        try listSchemas(["alpha_simp"])
        // One file arrives with the imported directory, one is already in the workspace.
        try write(source, ["symbols.yaml": "# from the user directory\n"])
        try write(paths.userDataDir, ["essay.txt": "kept\t1\n"])
        let report = try runImport()
        #expect(try text("symbols.yaml") == "# from the user directory\n")
        #expect(try text("essay.txt") == "kept\t1\n")
        #expect(!report.copied.contains { $0.hasPrefix("essay.txt") })
        #expect(exists("alpha.dict.yaml"))
        #expect(try deployedSchemas() == ["alpha_simp"])
    }

    @Test func dropsSchemasThatCannotBeMadeLoadable() throws {
        try listSchemas(["alpha_simp", "ghost", "broken", "house"])
        let report = try runImport()
        #expect(try deployedSchemas() == ["alpha_simp", "house"])
        #expect(report.warnings.contains { $0.contains("ghost") })
        #expect(report.warnings.contains { $0.contains("broken") })
        #expect(!exists("broken.schema.yaml"))
        #expect(SquirrelImporter.Report.load(paths)?.warnings == report.warnings)
    }

    @Test func emptyListFallsBackToTheShippedDefaultSchema() throws {
        try listSchemas(["ghost"])
        let report = try runImport()
        #expect(try deployedSchemas() == ["house"])
        #expect(report.warnings.contains { $0.contains("house") })
    }

    @Test func schemasAlreadyPresentAreLeftAlone() throws {
        try listSchemas(["alpha_simp", "house"])
        try write(source, ["alpha_simp.schema.yaml": "schema: {schema_id: alpha_simp}\n"])
        let report = try runImport()
        #expect(try text("alpha_simp.schema.yaml") == "schema: {schema_id: alpha_simp}\n")
        #expect(!exists("alpha.schema.yaml"))
        #expect(!exists("house.schema.yaml"))
        #expect(!report.copied.contains { $0.contains("Squirrel") })
        #expect(try deployedSchemas() == ["alpha_simp", "house"])
        #expect(ConfigLayers(paths: paths).generatedValue(.default, keypath: "schema_list") == nil)
    }

    @Test func dropsMissingSchemasWhenNoSquirrelBundleIsFound() throws {
        try listSchemas(["alpha_simp", "house"])
        let report = try runImport(bundles: [root.appendingPathComponent("absent")])
        #expect(try deployedSchemas() == ["house"])
        #expect(!exists("alpha_simp.schema.yaml"))
        #expect(report.warnings.contains { $0.contains("alpha_simp") })
    }

    @Test func schemaListFromAnImportedDefaultYamlIsCheckedToo() throws {
        try write(source, ["default.yaml": "schema_list:\n  - schema: alpha_simp\n  - schema: ghost\n"])
        _ = try runImport()
        #expect(exists("alpha.dict.yaml"))
        #expect(try deployedSchemas() == ["alpha_simp"])
    }

    @Test func schemaFromTheUserDirectoryGetsItsMissingRequirements() throws {
        try listSchemas(["mine"])
        try write(source, ["mine.schema.yaml": "__include: alpha.schema:/\nschema:\n  schema_id: mine\n"])
        let report = try runImport()
        for name in Self.transitive where name != "alpha_simp.schema.yaml" {
            #expect(exists(name), "\(name) should be copied")
        }
        #expect(!report.copied.contains { $0.hasPrefix("mine.schema.yaml (from") })
        #expect(try deployedSchemas() == ["mine"])
        #expect(!report.warnings.contains { $0.contains("mine") })
    }

    @Test func incompleteSchemaFromTheUserDirectoryIsKeptWithAWarning() throws {
        try listSchemas(["mine", "house"])
        try write(source, ["mine.schema.yaml": "schema: {schema_id: mine}\ntranslator: {dictionary: nowhere}\n"])
        let report = try runImport()
        #expect(try deployedSchemas() == ["mine", "house"])
        #expect(report.warnings.contains { $0.contains("mine") && $0.contains("可能无法使用") })
    }

    @Test func namesThatLeaveTheDataDirectoriesAreNeverFollowed() throws {
        // Both exist one level above the bundle's shared data.
        try write(bundle.deletingLastPathComponent(), [
            "outside.schema.yaml": "schema: {schema_id: outside}\n",
            "secret.dict.yaml": "---\nname: secret\n...\n",
        ])
        try write(bundle, ["sneaky.schema.yaml": "schema: {schema_id: sneaky}\ntranslator: {dictionary: ../secret}\n"])
        try listSchemas(["../outside", "sneaky", "house"])
        let report = try runImport()
        #expect(try deployedSchemas() == ["house"])
        #expect(!exists("../outside.schema.yaml"))
        #expect(!exists("../secret.dict.yaml"))
        #expect(!exists("sneaky.schema.yaml"))
        #expect(report.warnings.contains { $0.contains("sneaky") })
    }

    @Test func importingAgainRestoresSchemasDroppedEarlier() throws {
        try listSchemas(["alpha_simp", "house"])
        let first = try runImport(bundles: [root.appendingPathComponent("absent")])
        #expect(first.schemaListOverride == ["house"])
        let second = try runImport()
        #expect(exists("alpha.dict.yaml"))
        #expect(try deployedSchemas() == ["alpha_simp", "house"])
        #expect(ConfigLayers(paths: paths).generatedValue(.default, keypath: "schema_list") == nil)
        #expect(second.schemaListOverride == nil)
        #expect(!second.warnings.contains { $0.contains("alpha_simp") })
    }

    @Test func importingAgainKeepsAListChosenInSettings() throws {
        try write(shared, ["cottage.schema.yaml": "schema: {schema_id: cottage}\n"])
        try listSchemas(["alpha_simp", "house"])
        _ = try runImport(bundles: [root.appendingPathComponent("absent")])
        let chosen = ConfigValue.list([.map([.init("schema", .string("cottage"))])])
        try ConfigLayers(paths: paths).setGenerated(.default, keypath: "schema_list", value: chosen)
        _ = try runImport()
        #expect(try deployedSchemas() == ["cottage"])
    }

    @Test func schemasNamedByListItemPatchesAreCopiedWithoutRewritingTheList() throws {
        try write(source, ["default.custom.yaml": "patch:\n  schema_list/+:\n    - schema: alpha_simp\n    - schema: ghost\n"])
        let report = try runImport()
        for name in Self.transitive { #expect(exists(name), "\(name) should be copied") }
        #expect(report.warnings.contains { $0.contains("ghost") && $0.contains("可能无法使用") })
        #expect(ConfigLayers(paths: paths).generatedValue(.default, keypath: "schema_list") == nil)
        #expect(report.schemaListOverride == nil)
    }

    @Test func failedCopyDropsTheSchemaAndStillWritesTheReport() throws {
        try listSchemas(["alpha_simp", "house"])
        try FileManager.default.createDirectory(at: paths.userDataDir, withIntermediateDirectories: true)
        // A dangling link: not an existing file, yet nothing can be copied onto it.
        try FileManager.default.createSymbolicLink(
            at: paths.userDataDir.appendingPathComponent("essay.txt"), withDestinationURL: root.appendingPathComponent("gone.txt")
        )
        let report = try runImport()
        #expect(try deployedSchemas() == ["house"])
        #expect(!exists("alpha_simp.schema.yaml"))
        #expect(!exists("alpha.dict.yaml"))
        #expect(report.warnings.contains { $0.contains("alpha_simp") && $0.contains("出错") })
        #expect(SquirrelImporter.Report.load(paths)?.warnings == report.warnings)
    }
}
