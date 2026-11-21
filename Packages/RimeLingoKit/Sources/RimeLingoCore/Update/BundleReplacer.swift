public import Foundation

/// Replaces the contents of an installed bundle with those of another copy, without ever
/// removing the bundle directory and without writing into an existing file.
///
/// Overwriting a Mach-O that is executing or mapped invalidates its code-signature page
/// hashes and the kernel kills the process. Every changed item is therefore first copied
/// beside its destination under a temporary name (`prepare`), and only then moved into
/// place with rename(2) (`commit`), which leaves the old inode to whoever still has it open.
public struct BundleReplacer: Sendable {
    public struct Plan: Sendable, Equatable {
        public struct Place: Sendable, Equatable {
            /// Path relative to the bundle.
            public var path: String
            /// The item in the way has another type (file against directory) and is moved aside first.
            public var displaces: Bool
        }

        public var id: String
        public var source: URL
        public var target: URL
        /// In the order `commit` renames them.
        public var places: [Place]
        /// Items of the target that the source does not have.
        public var stale: [String]
        public var unchanged: Int
    }

    public var fs: any UpdateFileSystem

    public init(fs: any UpdateFileSystem = LocalUpdateFileSystem()) { self.fs = fs }

    /// Compares the two trees. Identical files (type, mode, size, SHA-256) are left alone.
    /// A directory that is new, or replaces a file, is placed as one unit.
    public func plan(from source: URL, into target: URL) throws -> Plan {
        guard BundleTree.entry(at: source)?.kind == .directory, BundleTree.entry(at: target)?.kind == .directory else {
            throw CocoaError(.fileNoSuchFile)
        }
        var plan = Plan(id: UUID().uuidString, source: source, target: target, places: [], stale: [], unchanged: 0)
        try walk("", &plan)
        plan.places = plan.places.enumerated()
            .sorted { (Self.rank($0.element.path), $0.offset) < (Self.rank($1.element.path), $1.offset) }
            .map(\.element)
        return plan
    }

    private func walk(_ directory: String, _ plan: inout Plan) throws {
        let sourceNames = try BundleTree.children(of: plan.source.appendingPathComponent(directory))
        let targetNames = try BundleTree.children(of: plan.target.appendingPathComponent(directory))
            .filter { !$0.hasPrefix(BundleTree.temporaryPrefix) }
        for name in sourceNames {
            let path = directory.isEmpty ? name : directory + "/" + name
            let from = plan.source.appendingPathComponent(path), to = plan.target.appendingPathComponent(path)
            guard !name.hasPrefix(BundleTree.temporaryPrefix), let new = BundleTree.entry(at: from), new.kind != .other else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            guard let old = BundleTree.entry(at: to) else {
                plan.places.append(.init(path: path, displaces: false))
                continue
            }
            switch (new.kind, old.kind) {
            case (.directory, .directory): try walk(path, &plan)
            case (.directory, _), (_, .directory), (_, .other): plan.places.append(.init(path: path, displaces: true))
            case (.file, .file) where Self.sameFile(from, new, to, old): plan.unchanged += 1
            case (.symlink, .symlink) where BundleTree.linkTarget(from) == BundleTree.linkTarget(to): plan.unchanged += 1
            default: plan.places.append(.init(path: path, displaces: false))
            }
        }
        let kept = Set(sourceNames)
        for name in targetNames where !kept.contains(name) {
            plan.stale.append(directory.isEmpty ? name : directory + "/" + name)
        }
    }

    private static func sameFile(_ from: URL, _ new: TreeEntry, _ to: URL, _ old: TreeEntry) -> Bool {
        guard new.mode == old.mode, new.size == old.size, let left = try? BundleTree.sha256(of: from),
              let right = try? BundleTree.sha256(of: to) else { return false }
        return left == right
    }

    /// Data first, code after it, the main executable last: the later a crash, the more
    /// of the new bundle is already consistent.
    static func rank(_ path: String) -> Int {
        if path == "Contents/MacOS" || path.hasPrefix("Contents/MacOS/") { return 6 }
        if path == "Contents/_CodeSignature" || path.hasPrefix("Contents/_CodeSignature/") { return 5 }
        if path == "Contents/Info.plist" { return 4 }
        if path == "Contents/Applications" || path.hasPrefix("Contents/Applications/") { return 3 }
        if path == "Contents/Helpers" || path.hasPrefix("Contents/Helpers/") { return 2 }
        if path == "Contents/Frameworks" || path.hasPrefix("Contents/Frameworks/") { return 1 }
        return 0
    }

    private func temporary(_ plan: Plan, _ path: String, displaced: Bool = false) -> URL {
        let url = plan.target.appendingPathComponent(path)
        let name = BundleTree.temporaryPrefix + plan.id + (displaced ? "-old-" : "-") + url.lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Copies every item to place beside its destination. Nothing the bundle is made of
    /// changes; a failure removes the copies and leaves the bundle as it was.
    public func prepare(_ plan: Plan) throws {
        do {
            for place in plan.places {
                let from = plan.source.appendingPathComponent(place.path)
                if BundleTree.entry(at: from)?.kind == .symlink, let target = BundleTree.linkTarget(from) {
                    try fs.createSymbolicLink(at: temporary(plan, place.path), destination: target)
                } else {
                    try fs.copyItem(at: from, to: temporary(plan, place.path))
                }
            }
        } catch {
            cleanTemporaries(in: plan.target)
            throw error
        }
    }

    /// Renames only. A failure part-way leaves a mixed bundle: the caller rolls back.
    public func commit(_ plan: Plan) throws {
        for place in plan.places {
            let destination = plan.target.appendingPathComponent(place.path)
            if place.displaces { try fs.rename(destination, to: temporary(plan, place.path, displaced: true)) }
            try fs.rename(temporary(plan, place.path), to: destination)
        }
    }

    /// Removes what the new version no longer has, and what `commit` moved aside. The
    /// bundle directory and `Contents` themselves are never removed.
    public func removeStale(_ plan: Plan) throws {
        for path in plan.stale where !path.isEmpty && path != "Contents" {
            try fs.removeItem(at: plan.target.appendingPathComponent(path))
        }
        for place in plan.places where place.displaces {
            try fs.removeItem(at: temporary(plan, place.path, displaced: true))
        }
    }

    /// Removes every leftover of an interrupted `prepare` or `commit`.
    public func cleanTemporaries(in bundle: URL) {
        for name in (try? BundleTree.children(of: bundle)) ?? [] {
            let child = bundle.appendingPathComponent(name)
            if name.hasPrefix(BundleTree.temporaryPrefix) {
                try? fs.removeItem(at: child)
            } else if BundleTree.entry(at: child)?.kind == .directory {
                cleanTemporaries(in: child)
            }
        }
    }

    /// The whole replacement: plan, prepare, commit, clean up.
    public func replace(from source: URL, into target: URL, beforeCommit: () throws -> Void = {},
                        afterCommit: () throws -> Void = {}) throws {
        cleanTemporaries(in: target)
        let plan = try plan(from: source, into: target)
        try prepare(plan)
        try beforeCommit()
        try commit(plan)
        try afterCommit()
        try removeStale(plan)
    }
}
