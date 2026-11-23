import Foundation
@testable import RimeLingoCore
import Testing

struct SubscriptionTests {
    let root: URL
    let paths: RimeLingoPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rimelingo-sub-\(UUID().uuidString)")
        paths = RimeLingoPaths(userDataDir: root.appendingPathComponent("user"), sharedDataDir: root.appendingPathComponent("shared"))
        try FileManager.default.createDirectory(at: paths.sharedDataDir!.appendingPathComponent("rimelingo"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.userDataDir, withIntermediateDirectories: true)
        try "智能体\tzhi neng ti\tai_term\t95\nDeepSeek\tdeepseek\tai_company\t95\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("rimelingo/rimelingo_tech.tsv"), atomically: true, encoding: .utf8)
    }

    @Test func subscriptionPriorityMapping() {
        #expect(SubscriptionManager.subscriptionQuality(for: nil) == 1)
        #expect(SubscriptionManager.subscriptionQuality(for: "unknown") == 1)
        #expect(SubscriptionManager.subscriptionQuality(for: "supplement") == 1)
        #expect(SubscriptionManager.subscriptionQuality(for: "prefer") == 6)
    }

    @Test func priorityChangesRebuildTablesThroughDeploy() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try "schema_list:\n  - schema: rime_ice\n  - schema: double_pinyin_flypy\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        let layers = ConfigLayers(paths: paths)
        let setting = try #require(SettingCatalog.bundled.setting("vocabulary.subscription_priority"))
        let store = SettingsStore(paths: paths)
        func expectQuality(_ quality: Int) {
            for schema in ["rime_ice", "double_pinyin_flypy"] {
                #expect(layers.generatedValue(.schema(schema), keypath: "rimelingo_online")?["initial_quality"]?.intValue == quality)
            }
        }

        #expect(try manager.ensureTables())
        expectQuality(1)
        #expect(try manager.ensureTables() == false)

        // A real v3 signature had no quality component; its mounts used 6.
        let signatureURL = paths.rimelingoDir.appendingPathComponent("subscriptions/.signature")
        let signature = manager.tableSignature(schemas: manager.mountSchemas(), items: [])
        #expect(signature.hasPrefix("v4|"))
        let oldSignature = signature.split(separator: "|").filter { !$0.hasPrefix("quality=") }.dropFirst()
        try (["v3"] + oldSignature.map(String.init)).joined(separator: "|").write(
            to: signatureURL, atomically: true, encoding: .utf8)
        try layers.updateGenerated(.schema("rime_ice")) { patch in
            patch.removeAll { $0.key == "rimelingo_online" }
            patch.append(.init("rimelingo_online", .map([.init("initial_quality", 6)])))
        }
        #expect(try manager.ensureTables())
        expectQuality(1)
        #expect(try manager.ensureTables() == false)

        try store.set("prefer", for: setting)
        #expect(try manager.ensureTables())
        expectQuality(6)
        #expect(try manager.ensureTables() == false)
        try store.set("supplement", for: setting)
        #expect(try manager.ensureTables())
        expectQuality(1)
        #expect(try manager.ensureTables() == false)

        // Frontend edits must also dirty the mounted schemas before deployment.
        _ = try layers.prepareForDeploy()
        layers.markDeployed()
        try store.set("prefer", for: setting)
        let dirty = try layers.prepareForDeploy()
        #expect(dirty.contains("rime_ice.schema"))
        expectQuality(6)
        #expect(try manager.ensureTables() == false)
    }

    @Test func subscriptionPriorityUsesDefaultsAndGeneratedOverride() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = paths.sharedDataDir!.appendingPathComponent("rimelingo/defaults/rimelingo.yaml")
        try FileManager.default.createDirectory(at: defaults.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "patch:\n  vocabulary/subscription_priority: prefer\n".write(to: defaults, atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        let layers = ConfigLayers(paths: paths)
        try manager.rebuild(schemas: ["rime_ice"])
        #expect(layers.generatedValue(.schema("rime_ice"), keypath: "rimelingo_online")?["initial_quality"] == 6)
        let setting = try #require(SettingCatalog.bundled.setting("vocabulary.subscription_priority"))
        for priority in ["supplement", "unknown"] {
            try SettingsStore(paths: paths).set(.string(priority), for: setting)
            try manager.rebuild(schemas: ["rime_ice"])
            #expect(layers.generatedValue(.schema("rime_ice"), keypath: "rimelingo_online")?["initial_quality"] == 1)
        }
    }

    @Test func parsesDictYamlTablesAndWordLists() {
        let yaml = "---\nname: demo\nversion: \"1\"\n...\n具身智能\tju shen zhi neng\t80\n"
        #expect(VocabularyParser.parse(yaml).first == VocabularyEntry(text: "具身智能", pinyin: "ju shen zhi neng", weight: 80))
        let words = VocabularyParser.parse("# comment\n氛围编程\nClaude\n")
        #expect(words.map(\.pinyin) == ["fen wei bian cheng", "claude"])
        #expect(VocabularyParser.parse("绿色\n").first?.pinyin == "lv se")
    }

    @Test func normalizesGithubBlobURLs() {
        #expect(SubscriptionManager.normalize("https://github.com/foru17/words/blob/main/ai.txt")?.absoluteString
                == "https://raw.githubusercontent.com/foru17/words/main/ai.txt")
        #expect(SubscriptionManager.normalize("ftp://x") == nil)
    }

    @Test func addUpdateReportsNewWordsAndHonorsInterval() async throws {
        let source = root.appendingPathComponent("feed.txt")
        try "氛围编程\n智能体\n".write(to: source, atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        let added = try await manager.add(url: source.absoluteString, name: "我的词库")
        #expect(added.entryCount == 2 && added.lastError == nil)

        try "氛围编程\n智能体\n具身智能\n".write(to: source, atomically: true, encoding: .utf8)
        // Automatic update right after is throttled.
        let throttled = try await manager.update(id: added.id)
        #expect(throttled?.entryCount == 2)
        let forced = try await manager.update(id: added.id, force: true)
        #expect(forced?.entryCount == 3 && forced?.newEntries == 1 && forced?.recentWords == ["具身智能"])
    }

    @Test func rebuildWritesLayoutTablesAndMountsSchemas() async throws {
        let source = root.appendingPathComponent("feed.txt")
        try "氛围编程\n向量数据库\txiang liang shu ju ku\t80\n".write(to: source, atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        try await manager.add(url: source.absoluteString, name: nil)
        let count = try manager.rebuild(schemas: ["rime_ice", "double_pinyin_flypy", "double_pinyin", "double_pinyin_custom"])
        #expect(count == 4)
        let full = try String(contentsOf: paths.userDataDir.appendingPathComponent("rimelingo_online.txt"), encoding: .utf8)
        let flypy = try String(contentsOf: paths.userDataDir.appendingPathComponent("rimelingo_online_flypy.txt"), encoding: .utf8)
        let ziranma = try String(contentsOf: paths.userDataDir.appendingPathComponent("rimelingo_online_ziranma.txt"), encoding: .utf8)
        #expect(full.contains("智能体\tzhinengti") && full.contains("DeepSeek\tdeepseek"))
        #expect(flypy.contains("智能体\tvingti") && flypy.contains("氛围编程\tffwwbmig"))
        #expect(ziranma.contains("向量数据库\txdlduujuku\t80") && ziranma.contains("DeepSeek\tdeepseek"))
        let layers = ConfigLayers(paths: paths)
        #expect(layers.generatedValue(.schema("double_pinyin_flypy"), keypath: "rimelingo_online")?["user_dict"] == "rimelingo_online_flypy")
        #expect(layers.generatedValue(.schema("double_pinyin"), keypath: "rimelingo_online")?["user_dict"] == "rimelingo_online_ziranma")
        #expect(layers.generatedValue(.schema("double_pinyin"), keypath: "engine/translators/+") == ["table_translator@rimelingo_online"])
        #expect(layers.generatedValue(.schema("double_pinyin_custom"), keypath: "rimelingo_online") == nil)
        #expect(layers.generatedValue(.schema("rime_ice"), keypath: "engine/translators/+") == ["table_translator@rimelingo_online"])
    }

    @Test func existingSubscriptionCacheAddsMissingZiranmaTableWithoutDownloading() async throws {
        try "schema_list:\n  - schema: double_pinyin\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("feed.txt")
        try "具身智能\tju shen zhi neng\t80\n".write(to: source, atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        let added = try await manager.add(url: source.absoluteString, name: nil)
        let cached = try Data(contentsOf: manager.cacheURL(added.id))
        #expect(try manager.ensureTables())
        #expect(try manager.ensureTables() == false)

        // An older installation has the cache and signature, but no Ziranma table or mount.
        let table = paths.userDataDir.appendingPathComponent("rimelingo_online_ziranma.txt")
        try FileManager.default.removeItem(at: table)
        try FileManager.default.removeItem(at: paths.rimelingoDir.appendingPathComponent("generated/double_pinyin.yaml"))
        try FileManager.default.removeItem(at: source)

        #expect(try manager.ensureTables())
        #expect(try String(contentsOf: table, encoding: .utf8).contains("具身智能\tjuufving\t80"))
        #expect(ConfigLayers(paths: paths).generatedValue(.schema("double_pinyin"), keypath: "rimelingo_online")?["user_dict"]
                == "rimelingo_online_ziranma")
        #expect(try Data(contentsOf: manager.cacheURL(added.id)) == cached)
        #expect(try manager.ensureTables() == false)
    }

    @Test func ensureTablesDedupesAndRebuildsOnlyWhenInputsChange() async throws {
        try "schema_list:\n  - schema: rime_ice\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        #expect(try manager.ensureTables())
        #expect(try manager.ensureTables() == false)

        let source = root.appendingPathComponent("feed.txt")
        try "智能体\n氛围编程\n".write(to: source, atomically: true, encoding: .utf8)
        try await manager.add(url: source.absoluteString, name: nil)
        #expect(try manager.ensureTables())
        let full = try String(contentsOf: paths.userDataDir.appendingPathComponent("rimelingo_online.txt"), encoding: .utf8)
        #expect(full.components(separatedBy: "智能体\tzhinengti").count == 2) // one row, bundled weight kept
        #expect(full.contains("智能体\tzhinengti\t95"))
        // librime skips a table translator whose user dict is disabled.
        #expect(ConfigLayers(paths: paths).generatedValue(.schema("rime_ice"), keypath: "rimelingo_online")?["enable_user_dict"] == nil)
    }

    @Test func mountsOnlyPinyinSchemasAndRemountsDeletedLayers() throws {
        try "schema_list:\n  - schema: rime_ice\n  - schema: double_pinyin_mspy\n  - schema: t9\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        #expect(try manager.ensureTables())
        let layers = ConfigLayers(paths: paths)
        #expect(layers.generatedValue(.schema("rime_ice"), keypath: "rimelingo_online") != nil)
        #expect(layers.generatedValue(.schema("double_pinyin_mspy"), keypath: "rimelingo_online") == nil)
        #expect(layers.generatedValue(.schema("t9"), keypath: "rimelingo_online") == nil)
        // The user deletes the generated layer: the next deploy mounts again.
        try FileManager.default.removeItem(at: paths.rimelingoDir.appendingPathComponent("generated/rime_ice.yaml"))
        #expect(try manager.ensureTables())
        #expect(ConfigLayers(paths: paths).generatedValue(.schema("rime_ice"), keypath: "rimelingo_online") != nil)
    }

    @Test(arguments: [false, true])
    func tableSignatureDetectsSameSizeAndTimestampChanges(shipped: Bool) async throws {
        try "schema_list:\n  - schema: rime_ice\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        let manager = stubManager()
        let target: URL
        if shipped {
            target = paths.sharedDataDir!.appendingPathComponent("rimelingo/rimelingo_tech.tsv")
        } else {
            let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
            target = manager.cacheURL(added.id)
        }
        let initial = Data("原词\tyuan ci\t50\n".utf8)
        let updated = Data("原词\tyuan ci\t80\n".utf8)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try initial.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: target.path)
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let before = manager.tableSignature(schemas: ["rime_ice"], items: manager.subscriptions())
        #expect(try manager.ensureTables())
        #expect(try manager.ensureTables() == false)

        try updated.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: target.path)
        let afterAttributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(beforeAttributes[.modificationDate] as? Date == afterAttributes[.modificationDate] as? Date)
        #expect(beforeAttributes[.size] as? Int == afterAttributes[.size] as? Int)
        let after = manager.tableSignature(schemas: ["rime_ice"], items: manager.subscriptions())
        #expect(before != after)
        #expect(after.contains(PackageManager.sha256(of: updated)))
        #expect(try manager.ensureTables())
        let table = try String(contentsOf: paths.userDataDir.appendingPathComponent("rimelingo_online.txt"), encoding: .utf8)
        #expect(table.contains("原词\tyuanci\t80"))

        // A timestamp-only change must not invalidate content-addressed tables.
        try FileManager.default.setAttributes([.modificationDate: timestamp.addingTimeInterval(3600)], ofItemAtPath: target.path)
        #expect(manager.tableSignature(schemas: ["rime_ice"], items: manager.subscriptions()) == after)
        #expect(try manager.ensureTables() == false)
    }
}

extension SubscriptionTests {
    @Test(arguments: [false, true])
    func pendingUpdateDoesNotRestoreRemovedSubscription(fails: Bool) async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        let gate = SubscriptionFetchGate()
        let updating = SubscriptionManager(paths: paths, fetch: { _, _ in
            await gate.pause()
            if fails { throw SubscriptionError.http(503) }
            return .init(data: Data("新词\txin ci\t60\n".utf8), etag: "new", lastModified: nil, status: 200)
        })
        let task = Task { try await updating.update(id: added.id, force: true) }
        await gate.waitForEntry()
        try manager.remove(id: added.id)
        await gate.resume()
        #expect(try await task.value == nil)
        #expect(manager.subscriptions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: manager.cacheURL(added.id).path))
    }

    @Test(arguments: [false, true])
    func pendingUpdatePreservesIntervalAndOtherSubscriptions(fails: Bool) async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        let gate = SubscriptionFetchGate()
        let updating = SubscriptionManager(paths: paths, fetch: { _, _ in
            await gate.pause()
            if fails { throw SubscriptionError.http(503) }
            return .init(data: Data("原词\tyuan ci\t50\n新词\txin ci\t60\n".utf8), etag: "new", lastModified: nil, status: 200)
        })
        let task = Task { try await updating.update(id: added.id, force: true) }
        await gate.waitForEntry()
        try manager.setInterval(id: added.id, .weekly)
        let other = try await manager.add(url: "https://example.invalid/other.txt", name: "另一份词库")
        let savedOther = manager.subscriptions().first { $0.id == other.id }
        await gate.resume()
        let result = try await task.value
        #expect(result?.updateInterval == .weekly)
        #expect(result?.entryCount == (fails ? 1 : 2))
        #expect((result?.lastError != nil) == fails)
        #expect(manager.subscriptions().first { $0.id == added.id }?.updateInterval == .weekly)
        #expect(manager.subscriptions().first { $0.id == other.id } == savedOther)
        #expect(manager.subscriptions().count == 2)
    }

    private func stubManager() -> SubscriptionManager {
        SubscriptionManager(paths: paths, fetch: { _, _ in
            .init(data: Data("原词\tyuan ci\t50\n".utf8), etag: "original", lastModified: nil, status: 200)
        })
    }

    @Test func updateDueIgnoresHistoricalNewEntriesWhenNotDue() async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        let due = added.lastChecked!.addingTimeInterval(25 * 3600)
        let updating = SubscriptionManager(paths: paths, fetch: { _, etag in
            #expect(etag == "original")
            return .init(data: Data("原词\tyuan ci\t50\n新词\txin ci\t60\n".utf8), etag: "new", lastModified: nil, status: 200)
        })
        #expect(await updating.updateDue(now: due))
        #expect(manager.subscriptions().first?.newEntries == 1)
        let notDue = SubscriptionManager(paths: paths, fetch: { _, _ in
            Issue.record("未到期或仅手动订阅不应发起下载")
            throw SubscriptionError.http(500)
        })
        #expect(await notDue.updateDue(now: due.addingTimeInterval(3600)) == false)
        #expect(await notDue.updateDue(now: due.addingTimeInterval(7200)) == false)
        #expect(try await notDue.update(id: added.id, now: due.addingTimeInterval(7200))?.contentChanged == false)
        #expect(manager.subscriptions().first?.newEntries == 1)
        try manager.setInterval(id: added.id, .manual)
        #expect(await notDue.updateDue(now: due.addingTimeInterval(30 * 24 * 3600)) == false)
    }

    @Test(arguments: ["新词\txin ci\t50\n", "原词\tyuan ci\t80\n", "原词\tyuan qi\t50\n"])
    func updateDueDetectsEqualCountContentChanges(content: String) async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        let updating = SubscriptionManager(paths: paths, fetch: { _, _ in
            .init(data: Data(content.utf8), etag: nil, lastModified: nil, status: 200)
        })
        #expect(await updating.updateDue(now: added.lastChecked!.addingTimeInterval(25 * 3600)))
        #expect(manager.subscriptions().first?.entryCount == 1)
        #expect(try String(contentsOf: manager.cacheURL(added.id), encoding: .utf8) == content)
        #expect(try await updating.update(id: added.id, force: true)?.contentChanged == false)
    }

    @Test(arguments: [200, 304, 503])
    func updateDueDoesNotReportUnchangedOrFailedDownloads(status: Int) async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        let content = Data("原词\tyuan ci\t50\n新词\txin ci\t60\n".utf8)
        let initialUpdate = SubscriptionManager(paths: paths, fetch: { _, _ in
            .init(data: content, etag: "new", lastModified: nil, status: 200)
        })
        let result = try #require(await initialUpdate.update(id: added.id, force: true))
        #expect(result.contentChanged && result.item.newEntries == 1)
        let checked = SubscriptionManager(paths: paths, fetch: { _, _ in
            .init(data: status == 200 ? content : nil, etag: "new", lastModified: nil, status: status)
        })
        #expect(await checked.updateDue(now: result.item.lastChecked!.addingTimeInterval(25 * 3600)) == false)
        #expect(try Data(contentsOf: manager.cacheURL(added.id)) == content)
        #expect((manager.subscriptions().first?.lastError != nil) == (status == 503))
    }

    @Test func cacheWriteFailureDoesNotReportContentChanged() async throws {
        let manager = stubManager()
        let added = try await manager.add(url: "https://example.invalid/feed.txt", name: nil)
        try FileManager.default.removeItem(at: manager.cacheURL(added.id))
        // A directory at the cache path deterministically prevents atomic file replacement.
        try FileManager.default.createDirectory(at: manager.cacheURL(added.id), withIntermediateDirectories: true)
        let result = try #require(await manager.update(id: added.id, force: true))
        #expect(result.contentChanged == false)
        #expect(result.item.lastError != nil)
    }

    @Test func intervalsDecideAutomaticUpdates() async throws {
        let source = root.appendingPathComponent("feed.txt")
        try "氛围编程\n".write(to: source, atomically: true, encoding: .utf8)
        let manager = SubscriptionManager(paths: paths)
        let added = try await manager.add(url: source.absoluteString, name: nil)
        #expect(added.updateInterval == .daily)
        try "氛围编程\n智能体\n".write(to: source, atomically: true, encoding: .utf8)
        let start = added.lastChecked!
        // Daily: not after 6 hours, yes after 25.
        #expect(try await manager.update(id: added.id, now: start.addingTimeInterval(6 * 3600))?.entryCount == 1)
        #expect(try await manager.update(id: added.id, now: start.addingTimeInterval(25 * 3600))?.entryCount == 2)
        // Weekly and manual.
        try manager.setInterval(id: added.id, .weekly)
        try "氛围编程\n智能体\n具身智能\n".write(to: source, atomically: true, encoding: .utf8)
        #expect(try await manager.update(id: added.id, now: start.addingTimeInterval(3 * 24 * 3600))?.entryCount == 2)
        try manager.setInterval(id: added.id, .manual)
        #expect(try await manager.update(id: added.id, now: start.addingTimeInterval(30 * 24 * 3600))?.entryCount == 2)
        #expect(try await manager.update(id: added.id, force: true)?.entryCount == 3)   // 立即检查 still works
    }
}

private actor SubscriptionFetchFixture {
    var response: SubscriptionManager.Response
    var urls: [URL] = []
    var etags: [String?] = []
    var metadataRequests = 0

    init(_ content: String = "示例词\tshi li ci\t50\n") {
        response = .init(data: Data(content.utf8), etag: "v1", lastModified: nil, status: 200)
    }

    func fetch(_ url: URL, _ etag: String?) -> SubscriptionManager.Response {
        urls.append(url)
        etags.append(etag)
        return response
    }

    func set(_ response: SubscriptionManager.Response) { self.response = response }
    func metadata(_ url: URL) -> Date? { metadataRequests += 1; return nil }
    func counts() -> (feeds: Int, metadata: Int) { (urls.count, metadataRequests) }
    func resetCounts() { urls = []; etags = []; metadataRequests = 0 }
}

extension SubscriptionTests {
    private var refreshDate: Date { Date(timeIntervalSince1970: 2_000_000_000) }

    private func seed(_ manager: SubscriptionManager, count: Int, github: Bool = false) throws -> [VocabularySubscription] {
        let items = (0..<count).map { index -> VocabularySubscription in
            let host = github ? "raw.githubusercontent.com" : "example.com"
            return VocabularySubscription(id: "feed\(index)", name: "Feed \(index)",
                url: URL(string: "https://\(host)/owner/words/main/feed\(index).txt")!,
                addedAt: refreshDate.addingTimeInterval(Double(index - 100)))
        }
        try manager.save(items)
        return items
    }

    @Test func refreshDetectsEqualCountChangesAndSignatureUsesActualBytes() async throws {
        try "schema_list:\n  - schema: rime_ice\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        let fixture = SubscriptionFetchFixture("测试词\tce shi ci\t50\n")
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let added = try await manager.add(url: "https://example.com/feed.txt", name: nil)
        #expect(try manager.ensureTables())
        let cached = manager.cacheURL(added.id)
        let timestamp = try FileManager.default.attributesOfItem(atPath: cached.path)[.modificationDate] as! Date
        let size = try Data(contentsOf: cached).count
        await fixture.set(.init(data: Data("测试词\tce shi ci\t80\n".utf8), etag: "v2", lastModified: nil, status: 200))
        let report = await manager.refresh(mode: .manual, now: refreshDate)
        #expect(report.changedIDs == [added.id] && report.errors.isEmpty)
        #expect(manager.subscriptions().first?.entryCount == 1)
        #expect(try Data(contentsOf: cached).count == size)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: cached.path)
        #expect(try manager.ensureTables())
        #expect(try String(contentsOf: paths.userDataDir.appendingPathComponent("rimelingo_online.txt"), encoding: .utf8)
            .contains("测试词\tceshici\t80"))
        #expect(try manager.ensureTables() == false)

        // An external same-size/same-time edit also bypasses no content metadata.
        try Data("测试词\tce shi ci\t90\n".utf8).write(to: cached)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: cached.path)
        #expect(try manager.ensureTables())
        #expect(try String(contentsOf: paths.userDataDir.appendingPathComponent("rimelingo_online.txt"), encoding: .utf8)
            .contains("测试词\tceshici\t90"))
    }

    @Test func unchangedResponsesAndSkippedChecksIgnoreHistoricalNewWords() async throws {
        let fixture = SubscriptionFetchFixture("词甲\tci jia\t50\n")
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let added = try await manager.add(url: "https://example.com/feed.txt", name: nil)
        let content = Data("词甲\tci jia\t50\n词乙\tci yi\t50\n".utf8)
        await fixture.set(.init(data: content, etag: "v2", lastModified: nil, status: 200))
        #expect(await manager.refresh(mode: .manual, now: refreshDate).changed)
        #expect(manager.subscriptions().first?.newEntries == 1)
        await fixture.resetCounts()
        let skipped = await manager.refresh(mode: .due, now: refreshDate.addingTimeInterval(1))
        #expect(skipped.checkedIDs.isEmpty && !skipped.changed)
        let skippedRequests = await fixture.counts()
        #expect(skippedRequests.feeds == 0)
        let unchanged = await manager.refresh(mode: .manual, now: refreshDate.addingTimeInterval(2))
        #expect(!unchanged.changed && unchanged.errors.isEmpty)
        #expect(manager.subscriptions().first?.newEntries == 1)
        await fixture.set(.init(data: nil, etag: "v2", lastModified: nil, status: 304))
        let notModified = await manager.refresh(mode: .manual, now: refreshDate.addingTimeInterval(3))
        #expect(!notModified.changed && notModified.errors.isEmpty)
        #expect(manager.subscriptions().first?.newEntries == 1 && manager.subscriptions().first?.id == added.id)
        #expect(await manager.updateDue(now: refreshDate.addingTimeInterval(4)) == false)
    }

    @Test func manualRefreshChecksManualIntervals() async throws {
        let fixture = SubscriptionFetchFixture("词甲\tci jia\t50\n")
        let source = URL(string: "https://example.com/resources/terms.txt")!
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let added = try await manager.add(url: source.absoluteString, name: nil)
        try manager.setInterval(id: added.id, .manual)
        await fixture.set(.init(data: Data("词甲\tci jia\t80\n".utf8), etag: "v2", lastModified: nil, status: 200))
        await fixture.resetCounts()
        let due = await manager.refresh(mode: .due, now: refreshDate)
        #expect(due.checkedIDs.isEmpty)
        #expect(await fixture.counts().feeds == 0)
        let report = await manager.refresh(mode: .manual, now: refreshDate)
        #expect(report.changedIDs == [added.id] && report.errors.isEmpty)
        #expect(manager.subscriptions().first?.url == source && manager.subscriptions().first?.updateInterval == .manual)
        let requestedURLs = await fixture.urls
        let requestedETags = await fixture.etags
        #expect(requestedURLs == [source] && requestedETags == ["v1"])
    }

    @Test func failedDownloadsPreserveCache() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let added = try await manager.add(url: "https://example.com/feed.txt", name: nil)
        let before = try Data(contentsOf: manager.cacheURL(added.id))
        await fixture.resetCounts()
        await fixture.set(.init(data: nil, etag: nil, lastModified: nil, status: 503))
        let report = await manager.refresh(mode: .manual, now: refreshDate)
        #expect(report.errors[added.id]?.contains("503") == true && !report.changed)
        #expect(try Data(contentsOf: manager.cacheURL(added.id)) == before)
        #expect(await fixture.counts().feeds == 1)
        #expect(manager.subscriptions().first?.lastError == report.errors[added.id])
        await fixture.set(.init(data: nil, etag: nil, lastModified: nil, status: 200))
        let empty = await manager.refresh(mode: .manual, now: refreshDate.addingTimeInterval(1))
        #expect(empty.errors[added.id] != nil && !empty.changed)
        #expect(try Data(contentsOf: manager.cacheURL(added.id)) == before)
    }

    @Test func emptyAndOversizedDownloadsDoNotReplaceUsableCache() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let data = Data("示例词\tshi li ci\t50\n".utf8)
        let added = try await manager.add(url: "https://example.com/feed.txt", name: nil)
        await fixture.set(.init(data: Data("# no entries\n".utf8), etag: nil, lastModified: nil, status: 200))
        let empty = await manager.refresh(mode: .manual, now: refreshDate)
        #expect(empty.errors[added.id] != nil && !empty.changed)
        await fixture.set(.init(data: Data(repeating: 0, count: SubscriptionManager.maxBytes + 1), etag: nil, lastModified: nil, status: 200))
        let oversized = await manager.refresh(mode: .manual, now: refreshDate.addingTimeInterval(1))
        #expect(oversized.errors[added.id]?.contains("20 MB") == true && !oversized.changed)
        #expect(try Data(contentsOf: manager.cacheURL(added.id)) == data)
        #expect(await fixture.counts().feeds == 3) // add + two checks; no retries
    }

    @Test func twentyMiBLimitIsInclusive() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let added = try await manager.add(url: "https://example.com/feed.txt", name: nil)
        var limit = Data("边界词\tbian jie ci\t50\n#".utf8)
        limit.append(Data(repeating: 0x61, count: SubscriptionManager.maxBytes - limit.count))
        await fixture.set(.init(data: limit, etag: nil, lastModified: nil, status: 200))
        let accepted = await manager.refresh(mode: .manual, now: refreshDate)
        #expect(accepted.changed && accepted.errors.isEmpty)
        #expect(try Data(contentsOf: manager.cacheURL(added.id)).count == SubscriptionManager.maxBytes)
    }

    @Test func missingCacheDropsETagAndRejects304WithoutRetry() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let added = try await manager.add(url: "https://example.com/feed.txt", name: nil)
        try FileManager.default.removeItem(at: manager.cacheURL(added.id))
        await fixture.resetCounts()
        await fixture.set(.init(data: nil, etag: "v1", lastModified: nil, status: 304))
        let report = await manager.refresh(mode: .manual, now: refreshDate)
        #expect(report.errors[added.id] != nil && !report.changed)
        let requestedETags = await fixture.etags
        let requests = await fixture.counts()
        #expect(requestedETags == [nil] && requests.feeds == 1)
        #expect(!FileManager.default.fileExists(atPath: manager.cacheURL(added.id).path))
    }

    @Test func rejectsNewSubscriptionAtLimitButKeepsExistingURLs() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        let original = try seed(manager, count: SubscriptionManager.maxSubscriptions)
        let existing = try await manager.add(url: original[0].url.absoluteString, name: nil)
        #expect(existing.id == original[0].id)
        do {
            _ = try await manager.add(url: "https://example.com/new.txt", name: nil)
            Issue.record("Expected the subscription limit to reject the new URL")
        } catch SubscriptionError.limitReached(let limit) {
            #expect(limit == 32)
        }
        #expect(manager.subscriptions() == original)
        #expect(await fixture.counts().feeds == 0)
    }

    @Test func legacyLongListsRotateInBoundedBatchesAndRemainIntact() async throws {
        let fixture = SubscriptionFetchFixture()
        var manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        manager.fetchCommitDate = { await fixture.metadata($0) }
        let original = try seed(manager, count: 40, github: true)
        let first = await manager.refresh(mode: .due, now: refreshDate)
        #expect(first.checkedIDs == original.prefix(32).map(\.id) && first.deferredCount == 8)
        #expect(first.changedIDs.count == 32 && first.errors.isEmpty)
        let requests = await fixture.counts()
        #expect(requests.feeds == 32 && requests.metadata == 32)
        #expect(requests.feeds + requests.metadata == SubscriptionManager.maxRequestsPerRefresh)
        await fixture.resetCounts()
        let next = await manager.refresh(mode: .due, now: refreshDate.addingTimeInterval(1))
        #expect(next.checkedIDs == original.suffix(8).map(\.id) && next.deferredCount == 0)
        #expect(manager.subscriptions().count == 40)
        #expect(original.allSatisfy { FileManager.default.fileExists(atPath: manager.cacheURL($0.id).path) })
        let nextRequests = await fixture.counts()
        #expect(nextRequests.feeds == 8 && nextRequests.metadata == 8)
    }

    @Test func refreshDoesNotResurrectFeedRemovedWhileFetching() async throws {
        let localPaths = paths
        let initial = SubscriptionManager(paths: paths)
        let original = try seed(initial, count: 1)[0]
        let manager = SubscriptionManager(paths: paths) { _, _ in
            try SubscriptionManager(paths: localPaths).remove(id: original.id)
            return .init(data: Data("旧响应\tjiu xiang ying\t50\n".utf8), etag: nil, lastModified: nil, status: 200)
        }
        let report = await manager.refresh(mode: .manual, now: refreshDate)
        #expect(manager.subscriptions().isEmpty && !report.changed)
        #expect(!FileManager.default.fileExists(atPath: manager.cacheURL(original.id).path))
    }

    @Test func refreshPreservesEditsMadeDuringDownloadAndMetadataRequests() async throws {
        let localPaths = paths
        let initial = SubscriptionManager(paths: paths)
        let original = try seed(initial, count: 1, github: true)[0]
        var manager = SubscriptionManager(paths: paths) { _, _ in
            try SubscriptionManager(paths: localPaths).setInterval(id: original.id, .weekly)
            return .init(data: Data("示例词\tshi li ci\t50\n".utf8), etag: "v1", lastModified: nil, status: 200)
        }
        manager.fetchCommitDate = { _ in
            let peer = SubscriptionManager(paths: localPaths)
            var items = peer.subscriptions()
            items[0].name = "Renamed"
            items[0].interval = .manual
            items.append(.init(id: "new", name: "New", url: URL(string: "https://example.com/new.txt")!, addedAt: original.addedAt))
            try peer.save(items)
            return nil
        }
        let report = await manager.refresh(mode: .manual, now: refreshDate)
        let after = manager.subscriptions()
        #expect(report.changed && report.errors.isEmpty && after.count == 2)
        #expect(after[0].name == "Renamed" && after[0].updateInterval == .manual && after[0].entryCount == 1)
        #expect(after[1].id == "new")
    }

    @Test func obsoleteResponseDoesNotOverwriteNewSource() async throws {
        let localPaths = paths
        let initial = SubscriptionManager(paths: paths)
        let original = try seed(initial, count: 1)[0]
        let newURL = URL(string: "https://example.com/new.txt")!
        let manager = SubscriptionManager(paths: paths) { _, _ in
            let peer = SubscriptionManager(paths: localPaths)
            var items = peer.subscriptions()
            items[0].url = newURL
            try peer.save(items)
            return .init(data: Data("旧响应\tjiu xiang ying\t50\n".utf8), etag: "old", lastModified: nil, status: 200)
        }
        let report = await manager.refresh(mode: .manual, now: refreshDate)
        #expect(!report.changed && manager.subscriptions().first?.url == newURL)
        #expect(manager.subscriptions().first?.lastChecked == nil)
        #expect(!FileManager.default.fileExists(atPath: manager.cacheURL(original.id).path))
    }

    @Test func futureTimestampForceCheckStillDownloads() async throws {
        let fixture = SubscriptionFetchFixture()
        let manager = SubscriptionManager(paths: paths) { await fixture.fetch($0, $1) }
        var original = try seed(manager, count: 1)
        original[0].lastChecked = refreshDate.addingTimeInterval(25 * 3600)
        original[0].interval = .manual
        try manager.save(original)
        let checked = try await manager.update(id: original[0].id, force: true, now: refreshDate)
        #expect(checked?.entryCount == 1 && checked?.lastError == nil)
        #expect(checked?.lastChecked == refreshDate)
        #expect(await fixture.counts().feeds == 1)
        #expect(FileManager.default.fileExists(atPath: manager.cacheURL(original[0].id).path))
    }

    @Test func newerCheckDuringFetchRejectsObsoleteResponse() async throws {
        let localPaths = paths
        let initial = SubscriptionManager(paths: paths)
        let original = try seed(initial, count: 1)[0]
        let newerDate = refreshDate.addingTimeInterval(1)
        let newData = Data("示例词\tshi li ci\t90\n".utf8)
        let manager = SubscriptionManager(paths: paths) { _, _ in
            let peer = SubscriptionManager(paths: localPaths)
            var items = peer.subscriptions()
            items[0].lastChecked = newerDate
            items[0].entryCount = 1
            items[0].etag = "new"
            try FileManager.default.createDirectory(at: peer.cacheURL(original.id).deletingLastPathComponent(), withIntermediateDirectories: true)
            try newData.write(to: peer.cacheURL(original.id))
            try peer.save(items)
            return .init(data: Data("示例词\tshi li ci\t50\n".utf8), etag: "old", lastModified: nil, status: 200)
        }
        let checked = try await manager.update(id: original.id, force: true, now: refreshDate)
        #expect(checked?.lastChecked == newerDate && checked?.etag == "new")
        #expect(try Data(contentsOf: manager.cacheURL(original.id)) == newData)
        #expect(manager.subscriptions().first?.lastChecked == newerDate)
    }

    @Test func refreshReportsManifestSaveFailures() async throws {
        let localPaths = paths
        let initial = SubscriptionManager(paths: paths)
        let original = try seed(initial, count: 1, github: true)[0]
        var manager = SubscriptionManager(paths: paths) { _, _ in
            .init(data: Data("示例词\tshi li ci\t50\n".utf8), etag: nil, lastModified: nil, status: 200)
        }
        // Pre-create the lock and writable cache directory so only the manifest's
        // parent becomes read-only during metadata await, before the commit lock.
        try manager.setInterval(id: original.id, .daily)
        try FileManager.default.createDirectory(at: manager.cacheURL(original.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        manager.fetchCommitDate = { _ in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: localPaths.rimelingoDir.path)
            return nil
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.rimelingoDir.path) }
        let report = await manager.refresh(mode: .manual, now: refreshDate)
        #expect(report.errors[original.id] != nil)
        #expect(report.changedIDs == [original.id]) // downloaded bytes are still usable
        #expect(manager.subscriptions().first?.lastChecked == nil)
    }

    @Test func mixedBatchReportsFailedFeedWhileKeepingSuccessfulChange() async throws {
        let manager = SubscriptionManager(paths: paths) { url, _ in
            url.lastPathComponent == "feed0.txt"
                ? .init(data: Data("示例词\tshi li ci\t80\n".utf8), etag: nil, lastModified: nil, status: 200)
                : .init(data: nil, etag: nil, lastModified: nil, status: 503)
        }
        let original = try seed(manager, count: 2)
        try FileManager.default.createDirectory(at: manager.cacheURL(original[0].id).deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = Data("示例词\tshi li ci\t50\n".utf8)
        for item in original { try before.write(to: manager.cacheURL(item.id)) }
        let report = await manager.refresh(mode: .due, now: refreshDate)
        #expect(report.checkedIDs == original.map(\.id) && report.changedIDs == [original[0].id])
        #expect(report.errors.count == 1 && report.errors[original[1].id]?.contains("503") == true)
        #expect(try Data(contentsOf: manager.cacheURL(original[1].id)) == before)
        #expect(manager.subscriptions()[1].lastError == report.errors[original[1].id])
    }
}

private actor SubscriptionFetchGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }

    func resume() {
        release?.resume()
        release = nil
    }
}

extension SubscriptionTests {
    /// Lists written by older builds carry fields this build no longer reads.
    @Test func olderListsWithExtraFieldsStillLoadAndUpdate() async throws {
        let manager = SubscriptionManager(paths: paths) { _, _ in
            .init(data: Data("氛围编程\n具身智能\n".utf8), etag: nil, lastModified: nil, status: 200)
        }
        try FileManager.default.createDirectory(at: paths.rimelingoDir, withIntermediateDirectories: true)
        try Data("""
        [{"id": "terms", "name": "Terms", "url": "https://example.com/words/terms.txt", "addedAt": "2026-01-01T00:00:00Z",
          "entryCount": 0, "newEntries": 0, "recentWords": [],
          "feedID": "terms", "expectedSHA256": "\(String(repeating: "0", count: 64))"}]
        """.utf8).write(to: manager.listURL)
        #expect(manager.subscriptions().map(\.id) == ["terms"])
        let updated = try await manager.update(id: "terms", force: true)
        #expect(updated?.entryCount == 2 && updated?.lastError == nil && updated?.contentChanged == true)
    }
}
