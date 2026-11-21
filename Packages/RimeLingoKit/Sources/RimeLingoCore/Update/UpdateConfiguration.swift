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
    public static let manifestPublicKey = "REPLACE_BEFORE_FIRST_RELEASE"

    public static var isConfigured: Bool { isConfigured(manifestPublicKey) }
    public static func isConfigured(_ key: String) -> Bool {
        key != placeholderPublicKey && Data(base64Encoded: key)?.count == 32
    }

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

/// Turns the bytes of latest.json and latest.json.sig into a trusted `AppRelease`.
public enum ManifestVerifier {
    /// `signature` is the base64 text of latest.json.sig.
    public static func verify(manifest: Data, signature: Data, publicKey: String) -> Bool {
        guard UpdateConfiguration.isConfigured(publicKey),
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let text = String(data: signature, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let raw = Data(base64Encoded: text) else { return false }
        return key.isValidSignature(raw, for: manifest)
    }

    /// The signature is checked before a single byte of the manifest is interpreted.
    public static func release(manifest: Data, signature: Data, publicKey: String) throws -> AppRelease {
        guard UpdateConfiguration.isConfigured(publicKey) else { throw UpdateFailure.notConfigured }
        guard verify(manifest: manifest, signature: signature, publicKey: publicKey) else { throw UpdateFailure.untrustedManifest }
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
    public static let check = "io.github.leaker.rimelingo.update.check"
    /// Settings → input method: install the staged update as soon as nothing is interrupted.
    public static let install = "io.github.leaker.rimelingo.update.install"
    /// The persisted update state changed.
    public static let changed = "io.github.leaker.rimelingo.update.changed"
    /// A new version is in place on disk (`userInfo["version"]`).
    public static let installed = "io.github.leaker.rimelingo.update.installed"
}
