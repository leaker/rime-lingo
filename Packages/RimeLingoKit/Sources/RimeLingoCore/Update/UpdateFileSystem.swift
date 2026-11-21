public import Foundation
import CryptoKit

/// The mutating file operations of an install, behind a seam so tests can make any one
/// of them fail. Reads go straight to the file system.
public protocol UpdateFileSystem: Sendable {
    func createDirectory(at url: URL) throws
    /// Copies a file or a whole directory tree (a clone on APFS), keeping modes and links.
    func copyItem(at source: URL, to destination: URL) throws
    func createSymbolicLink(at url: URL, destination: String) throws
    /// rename(2): atomically replaces a file or link at `destination`.
    func rename(_ source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    /// Owned by the current user and writable.
    func isUserWritable(_ url: URL) -> Bool
}

public struct LocalUpdateFileSystem: UpdateFileSystem {
    public init() {}

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func createSymbolicLink(at url: URL, destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
    }

    public func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func removeItem(at url: URL) throws {
        guard BundleTree.entry(at: url) != nil else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func isUserWritable(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid() else { return false }
        return access(url.path, W_OK) == 0
    }
}

/// One item of a bundle tree, read with lstat (links are never followed).
struct TreeEntry: Equatable, Sendable {
    enum Kind: Sendable { case directory, file, symlink, other }
    var kind: Kind
    /// Permission bits including setuid, setgid and sticky.
    var mode: UInt16
    var size: Int64
}

enum BundleTree {
    static let temporaryPrefix = ".rlu-"

    static func entry(at url: URL) -> TreeEntry? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let kind: TreeEntry.Kind = switch info.st_mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: .file
        case S_IFLNK: .symlink
        default: .other
        }
        return TreeEntry(kind: kind, mode: UInt16(info.st_mode & 0o7777), size: Int64(info.st_size))
    }

    static func children(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    static func linkTarget(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Writes through a temporary file, fsyncs it and renames it into place.
    static func writeDurably(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp")
        let fd = open(temporary.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Where the updater keeps its files: `rimelingo/cache/updates`.
public struct UpdatePaths: Sendable, Equatable {
    public var root: URL

    public init(_ paths: RimeLingoPaths) { root = paths.cacheDir.appendingPathComponent("updates", isDirectory: true) }
    public init(root: URL) { self.root = root }

    public var lock: URL { root.appendingPathComponent("lock") }
    public var stagingTemporary: URL { root.appendingPathComponent("staging.tmp", isDirectory: true) }
    public var staged: URL { root.appendingPathComponent("staged", isDirectory: true) }
    public var stagedApp: URL { staged.appendingPathComponent(UpdateConfiguration.bundleName, isDirectory: true) }
    public var backup: URL { root.appendingPathComponent("backup", isDirectory: true) }
    public var backupApp: URL { backup.appendingPathComponent(UpdateConfiguration.bundleName, isDirectory: true) }
    public var marker: URL { root.appendingPathComponent("install.json") }
    public func archive(_ name: String) -> URL { root.appendingPathComponent(name) }
}

/// Cross-process exclusion for downloading and installing (flock on `updates/lock`).
/// The kernel releases it when the holder dies, which is how an interrupted install is told
/// apart from a running one.
public final class UpdateLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(_ paths: UpdatePaths) -> UpdateLock? {
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let fd = open(paths.lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return UpdateLock(descriptor: fd)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Checks what `ditto -x -k` extracted before any of it is trusted as a bundle.
public enum StagedArchive {
    /// The extracted `RimeLingo.app`, when the archive holds exactly that and nothing in
    /// it is a device, an escaping link or a setuid file.
    public static func locateBundle(in directory: URL) throws -> URL {
        let names = (try? BundleTree.children(of: directory)) ?? []
        guard names == [UpdateConfiguration.bundleName] else { throw UpdateFailure.badArchive("layout") }
        let bundle = directory.appendingPathComponent(UpdateConfiguration.bundleName, isDirectory: true)
        guard BundleTree.entry(at: bundle)?.kind == .directory else { throw UpdateFailure.badArchive("layout") }
        try inspect(bundle, components: [])
        return bundle
    }

    private static func inspect(_ url: URL, components: [String]) throws {
        for name in (try? BundleTree.children(of: url)) ?? [] {
            let child = url.appendingPathComponent(name)
            let path = components + [name]
            guard let entry = BundleTree.entry(at: child) else { throw UpdateFailure.badArchive("unreadable") }
            guard entry.mode & 0o6000 == 0 else { throw UpdateFailure.badArchive("setuid") }
            guard !name.hasPrefix(BundleTree.temporaryPrefix) else { throw UpdateFailure.badArchive("reserved name") }
            switch entry.kind {
            case .directory: try inspect(child, components: path)
            case .file: break
            case .symlink:
                guard let target = BundleTree.linkTarget(child), staysInside(target, from: components) else {
                    throw UpdateFailure.badArchive("link")
                }
            case .other: throw UpdateFailure.badArchive("special file")
            }
        }
    }

    /// A relative link, resolved lexically from its directory, must not leave the bundle.
    static func staysInside(_ target: String, from directory: [String]) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/") else { return false }
        var depth = directory.count
        for component in target.split(separator: "/") {
            switch component {
            case ".": continue
            case "..":
                depth -= 1
                if depth < 0 { return false }
            default: depth += 1
            }
        }
        return true
    }
}
