public import Foundation
import CryptoKit

/// Where updates come from and what is trusted. Nothing about the user or their input is
/// sent: only the public release manifest and the release archive are requested.
public enum UpdateConfiguration {
    /// Marks a build with no manifest key. While `manifestPublicKey` equals this value the
    /// updater is inert: it does not contact the network, download or install anything.
    public static let placeholderPublicKey = "REPLACE_BEFORE_FIRST_RELEASE"
    /// Ed25519 public key (base64, 32 raw bytes) that signs latest.json.
    /// TO BE REPLACED BEFORE THE FIRST RELEASE with the output of
    /// `swift scripts/sign-manifest.swift keygen`; scripts/release.sh refuses to publish
    /// while this is the placeholder or differs from the key in the login Keychain.
    public static let manifestPublicKey = "XymJ+jHA7os8dMJ1XTX3UTjvzzczspPao3klaolabNk="
    /// Second Ed25519 public key whose private half is kept offline, so that losing or
    /// leaking the everyday key does not strand installed copies: a manifest signed by
    /// either key is trusted. TO BE REPLACED BEFORE THE FIRST RELEASE with the output of
    /// `swift scripts/sign-manifest.swift keygen --backup`; scripts/release.sh refuses to
    /// publish while this is the placeholder. On its own it does not switch the updater on.
    public static let manifestBackupPublicKey = "E1aXUnUPIq8rXcZh1UrN8pNDMMmfP8EVCpzFqSHYCWY="
    /// Signature (base64) of `keyProofMessage(for: manifestBackupPublicKey)` by the backup
    /// private key. TO BE REPLACED BEFORE THE FIRST RELEASE with the output of
    /// `swift scripts/sign-manifest.swift prove --backup`, run before that key goes offline.
    /// The apps never read it. It is how scripts/release.sh and the tests tell, with the
    /// private half out of reach, that the backup constant is the key that was generated
    /// here and not a mistyped or made-up one, which would otherwise only show on the day
    /// the backup key is needed.
    public static let manifestBackupKeyProof = "Ua3My1k+V5SIsAOStLGea87XmGV0c6dPi/0F19AFnUxd4SEAYmuAGqEvze6KC6iI7K4JBvYfh+qz193fZqSkBQ=="
    /// What a proof signs. Not JSON, so a proof can never pass for the signature of a
    /// manifest. Keep identical to scripts/sign-manifest.swift.
    public static func keyProofMessage(for key: String) -> Data {
        Data("RimeLingo manifest signing key, proof of possession: \(key)".utf8)
    }

    /// Only the everyday key decides this: a build with just a backup key stays inert.
    public static var isConfigured: Bool { isConfigured(manifestPublicKey) }
    public static func isConfigured(_ key: String) -> Bool {
        guard key != placeholderPublicKey, let raw = Data(base64Encoded: key), raw.count == 32 else { return false }
        return !isSmallOrderPoint(raw)
    }

    /// Whether 32 bytes encode one of the eight points of small order. CryptoKit takes
    /// them as public keys, and under such a key a signature needs no private key: the
    /// identity (01 00 … 00) accepts the signature 01 00 … 00 for every message, the
    /// all-zero key its own bytes followed by 32 zero bytes for one message in four. A
    /// constant filled in with such a value must count as no key at all.
    public static func isSmallOrderPoint(_ raw: Data) -> Bool {
        var y = [UInt8](raw)
        guard y.count == 32 else { return false }
        y[31] &= 0x7f
        return smallOrderPoints.contains(y)
    }

    /// Their y coordinates, little-endian with the sign bit cleared: 0, 1, the two of
    /// order eight, p - 1, and the non-canonical spellings p and p + 1 of 0 and 1.
    /// Keep identical to scripts/sign-manifest.swift.
    private static let smallOrderPoints: Set<[UInt8]> = {
        func spanning(_ first: UInt8, _ middle: UInt8, _ last: UInt8) -> [UInt8] {
            [first] + Array(repeating: middle, count: 30) + [last]
        }
        return [
            spanning(0x00, 0x00, 0x00), spanning(0x01, 0x00, 0x00),
            [0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0, 0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98, 0xf0,
             0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39, 0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x05],
            [0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f, 0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f,
             0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6, 0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0x7a],
            spanning(0xec, 0xff, 0x7f), spanning(0xed, 0xff, 0x7f), spanning(0xee, 0xff, 0x7f),
        ]
    }()

    /// Team whose Developer ID Application certificate signs releases.
    public static let teamID = "FKKCZM5CBJ"
    public static let product = "rimelingo"
    public static let repository = "leaker/rime-lingo"
    public static let bundleName = "RimeLingo.app"
    public static let manifestURL = URL(string: "https://github.com/\(repository)/releases/latest/download/latest.json")!
    public static let manifestSignatureURL = URL(string: manifestURL.absoluteString + ".sig")!

    public static func assetURL(version: String, name: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/v\(version)/")!.appendingPathComponent(name)
    }

    /// github.com serves the release URLs and redirects asset downloads to these hosts.
    public static let allowedHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]
    public static let maxManifestBytes = 262_144
    public static let maxSignatureBytes = 4096
    public static let maxArchiveBytes = 1 << 30

    /// Designated requirement of a release: Apple's Developer ID CA, a Developer ID
    /// Application leaf, issued to the team. An "Apple Development" certificate of the
    /// same team (leaf field …6.1.12, WWDR intermediate) and ad-hoc signatures fail it.
    public static let developerIDRequirement =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        + " and certificate leaf[subject.OU] = \"\(teamID)\""
}

/// The signed release manifest (latest.json).
public struct AppRelease: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public var name: String
        public var size: Int
        public var sha256: String

        public init(name: String, size: Int, sha256: String) {
            self.name = name
            self.size = size
            self.sha256 = sha256
        }
    }

    public var product: String
    public var version: String
    public var build: Int
    public var date: String?
    public var notes: String?
    /// Releases needing a newer macOS are not installed ("15.0").
    public var minimumSystemVersion: String?
    public var files: [String: File]

    public init(product: String = UpdateConfiguration.product, version: String, build: Int, date: String? = nil,
                notes: String? = nil, minimumSystemVersion: String? = nil, files: [String: File]) {
        self.product = product
        self.version = version
        self.build = build
        self.date = date
        self.notes = notes
        self.minimumSystemVersion = minimumSystemVersion
        self.files = files
    }

    public var appVersion: AppVersion { AppVersion(version, build: build) }
    /// The zipped RimeLingo.app.
    public var archive: File? { files["zip"] }

    public func supportsThisSystem(_ system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        guard let minimum = minimumSystemVersion else { return true }
        let running = AppVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
        return !(running < AppVersion(minimum))
    }
}

/// The public keys a manifest signature may verify under: the everyday key and the offline
/// backup key. Tests inject their own.
public struct ManifestKeys: Sendable, Equatable {
    public var everyday: String
    public var backup: String

    public init(_ everyday: String, backup: String = UpdateConfiguration.placeholderPublicKey) {
        self.everyday = everyday
        self.backup = backup
    }

    /// The keys compiled into this build.
    public static let shipped = ManifestKeys(UpdateConfiguration.manifestPublicKey,
                                             backup: UpdateConfiguration.manifestBackupPublicKey)

    public var isConfigured: Bool { UpdateConfiguration.isConfigured(everyday) }
    /// Nothing without a real everyday key; the backup key only when it is a real key too,
    /// so a placeholder, a mangled constant or a point of small order is never something a
    /// signature is checked against.
    public var accepted: [String] {
        guard isConfigured else { return [] }
        return UpdateConfiguration.isConfigured(backup) ? [everyday, backup] : [everyday]
    }
}

/// Turns the bytes of latest.json and latest.json.sig into a trusted `AppRelease`.
public enum ManifestVerifier {
    /// Whether the signature verifies under either accepted key.
    public static func verify(manifest: Data, signature: Data, keys: ManifestKeys) -> Bool {
        keys.accepted.contains { verify(manifest: manifest, signature: signature, publicKey: $0) }
    }

    /// One key. `signature` is the base64 text of latest.json.sig.
    public static func verify(manifest: Data, signature: Data, publicKey: String) -> Bool {
        guard UpdateConfiguration.isConfigured(publicKey),
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let text = String(data: signature, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let raw = Data(base64Encoded: text) else { return false }
        return key.isValidSignature(raw, for: manifest)
    }

    /// The signature is checked before a single byte of the manifest is interpreted.
    public static func release(manifest: Data, signature: Data, keys: ManifestKeys = .shipped) throws -> AppRelease {
        guard keys.isConfigured else { throw UpdateFailure.notConfigured }
        guard verify(manifest: manifest, signature: signature, keys: keys) else { throw UpdateFailure.untrustedManifest }
        guard let release = try? JSONDecoder().decode(AppRelease.self, from: manifest) else {
            throw UpdateFailure.malformedManifest("decode")
        }
        guard release.product == UpdateConfiguration.product else { throw UpdateFailure.malformedManifest("product") }
        guard release.version.range(of: #"^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$"#, options: .regularExpression) != nil,
              release.build > 0 else { throw UpdateFailure.malformedManifest("version") }
        guard let file = release.archive, file.name == "RimeLingo-\(release.version).zip" else {
            throw UpdateFailure.malformedManifest("archive")
        }
        guard file.size > 0, file.size <= UpdateConfiguration.maxArchiveBytes,
              file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw UpdateFailure.malformedManifest("checksum")
        }
        return release
    }
}

/// Which URLs the updater may request. HTTPS only; the first request goes to this
/// repository's releases on github.com, redirects only to GitHub's asset hosts.
public enum RedirectPolicy {
    public static func allows(initial url: URL) -> Bool {
        isPlainHTTPS(url) && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix("/\(UpdateConfiguration.repository)/releases/")
    }

    public static func allows(redirectTo url: URL) -> Bool {
        guard isPlainHTTPS(url), let host = url.host?.lowercased() else { return false }
        return UpdateConfiguration.allowedHosts.contains(host)
    }

    private static func isPlainHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
}

/// Distributed notifications between the settings app and the input method, which is the
/// one that installs while it is running. None of them carries anything but a version.
public enum UpdateNotifications {
    /// Settings → input method: check now.
    public static let check = "com.leelib.rimelingo.update.check"
    /// Settings → input method: install the staged update as soon as nothing is interrupted.
    public static let install = "com.leelib.rimelingo.update.install"
    /// The persisted update state changed.
    public static let changed = "com.leelib.rimelingo.update.changed"
    /// A new version is in place on disk (`userInfo["version"]`).
    public static let installed = "com.leelib.rimelingo.update.installed"
}
