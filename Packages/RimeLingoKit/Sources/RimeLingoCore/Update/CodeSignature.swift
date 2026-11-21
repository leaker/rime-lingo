public import Foundation
import Security

/// What a code signature says about a bundle or the running process.
public struct SignatureInfo: Equatable, Sendable {
    /// The signature, every nested code and all sealed resources are intact.
    public var isValid: Bool
    /// Signed with a Developer ID Application certificate of RimeLingo's team.
    public var satisfiesDeveloperID: Bool
    public var teamID: String?
    public var bundleID: String?
    public var version: String?
    public var build: Int?

    public init(isValid: Bool, satisfiesDeveloperID: Bool, teamID: String? = nil, bundleID: String? = nil,
                version: String? = nil, build: Int? = nil) {
        self.isValid = isValid
        self.satisfiesDeveloperID = satisfiesDeveloperID
        self.teamID = teamID
        self.bundleID = bundleID
        self.version = version
        self.build = build
    }

    public static let unsigned = SignatureInfo(isValid: false, satisfiesDeveloperID: false)
}

public protocol CodeSignatureEvaluating: Sendable {
    /// Full static validation of a bundle on disk, nested code included.
    func evaluate(bundle: URL) -> SignatureInfo
    /// The signature of the process asking.
    func evaluateRunningProcess() -> SignatureInfo
}

/// Security.framework implementation.
public struct SecCodeSignatureEvaluator: CodeSignatureEvaluating {
    /// Code the bundle seal covers only as resources; checked on its own as well.
    static let nestedCode = ["Contents/Applications/RimeLingo Settings.app", "Contents/Helpers/rimelingo"]

    public init() {}

    public func evaluate(bundle: URL) -> SignatureInfo {
        var info = Self.evaluate(path: bundle, strict: true)
        for relative in Self.nestedCode {
            let nested = bundle.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: nested.path) else { continue }
            let inner = Self.evaluate(path: nested, strict: true)
            info.isValid = info.isValid && inner.isValid
            info.satisfiesDeveloperID = info.satisfiesDeveloperID && inner.satisfiesDeveloperID
        }
        return info
    }

    public func evaluateRunningProcess() -> SignatureInfo {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unsigned }
        let valid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        let developerID = Self.requirement.map { SecCodeCheckValidity(code, [], $0) == errSecSuccess } ?? false
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return SignatureInfo(isValid: valid, satisfiesDeveloperID: valid && developerID)
        }
        var info = Self.describe(staticCode)
        info.isValid = valid
        info.satisfiesDeveloperID = valid && developerID
        return info
    }

    /// A quick answer for display: the requirement is checked without hashing resources.
    public static func isDeveloperIDSigned(_ bundle: URL) -> Bool {
        evaluate(path: bundle, strict: false).satisfiesDeveloperID
    }

    private static var requirement: SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(UpdateConfiguration.developerIDRequirement as CFString, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }

    private static func evaluate(path: URL, strict: Bool) -> SignatureInfo {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code else { return .unsigned }
        let raw = strict ? kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
            : kSecCSDoNotValidateResources
        let flags = SecCSFlags(rawValue: raw)
        let valid = SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
        let developerID = requirement.map { SecStaticCodeCheckValidity(code, flags, $0) == errSecSuccess } ?? false
        var info = describe(code)
        info.isValid = valid
        info.satisfiesDeveloperID = valid && developerID
        return info
    }

    /// Identity and version as sealed in the signature (its Info.plist), not as a file
    /// beside it claims.
    private static func describe(_ code: SecStaticCode) -> SignatureInfo {
        var copied: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &copied) == errSecSuccess,
              let dictionary = copied as? [String: Any] else { return .unsigned }
        let plist = dictionary[kSecCodeInfoPList as String] as? [String: Any]
        return SignatureInfo(
            isValid: false, satisfiesDeveloperID: false,
            teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            bundleID: plist?["CFBundleIdentifier"] as? String ?? dictionary[kSecCodeInfoIdentifier as String] as? String,
            version: plist?["CFBundleShortVersionString"] as? String,
            build: (plist?["CFBundleVersion"] as? String).flatMap { Int($0) })
    }
}

/// Whether the running build may update itself at all.
public enum UpdateEligibility: Equatable, Sendable {
    case eligible(bundle: URL)
    /// No manifest key yet: the feature is inert.
    case notConfigured
    /// Not signed with the team's Developer ID Application certificate (Apple Development
    /// and ad-hoc builds): never updated, never offered an update.
    case developmentBuild
    /// The bundle is not where the current user can replace its files.
    case unsupportedLocation(String)

    public static func evaluate(bundle: URL, signature: any CodeSignatureEvaluating, fs: any UpdateFileSystem,
                                publicKey: String = UpdateConfiguration.manifestPublicKey) -> UpdateEligibility {
        guard UpdateConfiguration.isConfigured(publicKey) else { return .notConfigured }
        let running = signature.evaluateRunningProcess()
        guard running.isValid, running.satisfiesDeveloperID, running.teamID == UpdateConfiguration.teamID else {
            return .developmentBuild
        }
        let path = bundle.path
        guard !path.contains("/AppTranslocation/"), fs.isUserWritable(bundle),
              fs.isUserWritable(bundle.appendingPathComponent("Contents")) else { return .unsupportedLocation(path) }
        return .eligible(bundle: bundle)
    }

    public var failure: UpdateFailure? {
        switch self {
        case .eligible: nil
        case .notConfigured: .notConfigured
        case .developmentBuild: .developmentBuild
        case let .unsupportedLocation(path): .unsupportedLocation(path)
        }
    }
}

/// The checks a bundle must pass, in order, before and after it replaces the installed one.
public enum BundleVerification {
    public static func verify(_ info: SignatureInfo, release: AppRelease, bundleID: String, installed: AppVersion?) throws {
        guard info.isValid, info.satisfiesDeveloperID, info.teamID == UpdateConfiguration.teamID else {
            throw UpdateFailure.untrustedBundle
        }
        guard info.bundleID == bundleID else { throw UpdateFailure.wrongBundle }
        guard info.version == release.version, info.build == release.build else { throw UpdateFailure.versionMismatch }
        if let installed, !(installed < release.appVersion) { throw UpdateFailure.notNewer }
    }
}
