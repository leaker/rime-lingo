// Signs (or verifies) the release manifest with Ed25519 (CryptoKit), writing <file>.sig as
// base64. The private key lives in the login Keychain and is never printed; the apps embed
// the public key (UpdateConfiguration.manifestPublicKey).
//
//   swift scripts/sign-manifest.swift keygen               # once: creates the key, prints the PUBLIC key
//   swift scripts/sign-manifest.swift pubkey               # prints the public key of the stored key
//   swift scripts/sign-manifest.swift sign latest.json     # writes latest.json.sig
//   swift scripts/sign-manifest.swift verify latest.json <public-key-base64>
//
// What protects the key, and what does not. The Keychain item is created by the `swift`
// interpreter running this file, so its access list trusts that interpreter: this script
// reads the key without a prompt, and so can any other Swift script run by this user on
// this Mac. Treat it like a file only you can read, not like a key that asks before use.
// To make every use ask: open Keychain Access, find "RimeLingo release manifest signing
// key" in the login keychain, and under Access Control remove every listed application
// (then answer "Allow", not "Always Allow", when release.sh signs). A stolen key alone
// installs nothing: an update must also be signed with the team's Developer ID
// certificate and be newer than what is installed.
//
// Back the key up offline once, right after keygen; it exists nowhere else, and without
// it no installed copy can be updated again. This prints the 32 private bytes as hex:
//   security find-generic-password -s com.leelib.rimelingo.manifest-key -a ed25519 -w
// and this puts them back on another Mac (then `pubkey` must print the key in the source):
//   security add-generic-password -s com.leelib.rimelingo.manifest-key -a ed25519 \
//     -l "RimeLingo release manifest signing key" -X <the hex>
// Do not paste the hex anywhere that is logged or synced.
// Tests only: `--ephemeral-key-file <path>` after keygen, pubkey or sign keeps the key in
// that file instead of the Keychain (scripts/test-release-manifests.sh).
import CryptoKit
import Foundation
import Security

let service = "com.leelib.rimelingo.manifest-key"
let account = "ed25519"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var keyFile: String?
if let index = arguments.firstIndex(of: "--ephemeral-key-file") {
    guard index + 1 < arguments.count else { fail("--ephemeral-key-file needs a path") }
    keyFile = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
}

func keychainQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
}

func storedKey() -> Curve25519.Signing.PrivateKey? {
    let raw: Data?
    if let keyFile {
        raw = (try? String(contentsOfFile: keyFile, encoding: .utf8))
            .flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    } else {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        raw = SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }
    return raw.flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
}

func requireKey() -> Curve25519.Signing.PrivateKey {
    guard let key = storedKey() else {
        fail(keyFile.map { "no valid key in \($0)" }
            ?? "no manifest signing key in the login Keychain (service \(service)); run: swift scripts/sign-manifest.swift keygen")
    }
    return key
}

switch arguments.first {
case "keygen":
    guard arguments.count == 1 else { fail("usage: keygen") }
    guard storedKey() == nil else { fail("a manifest signing key already exists; refusing to replace it") }
    let key = Curve25519.Signing.PrivateKey()
    if let keyFile {
        guard FileManager.default.createFile(atPath: keyFile, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                             attributes: [.posixPermissions: 0o600]) else { fail("cannot write \(keyFile)") }
    } else {
        var item = keychainQuery()
        item[kSecValueData as String] = key.rawRepresentation
        item[kSecAttrLabel as String] = "RimeLingo release manifest signing key"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { fail("could not store the key in the Keychain (status \(status))") }
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "pubkey":
    guard arguments.count == 1 else { fail("usage: pubkey") }
    print(requireKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard arguments.count == 2 else { fail("usage: sign <file>") }
    let key = requireKey()
    let path = arguments[1]
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let signature = try key.signature(for: data)
    try (signature.base64EncodedString() + "\n").write(toFile: path + ".sig", atomically: true, encoding: .utf8)
    print("signed \(path) with \(key.publicKey.rawRepresentation.base64EncodedString())")
case "verify":
    guard arguments.count == 3, let keyData = Data(base64Encoded: arguments[2]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { fail("usage: verify <file> <public-key>") }
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let text = try String(contentsOfFile: arguments[1] + ".sig", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let signature = Data(base64Encoded: text), key.isValidSignature(signature, for: data) else { fail("signature invalid") }
    print("signature valid")
default:
    fail("usage: sign-manifest.swift keygen | pubkey | sign <file> | verify <file> <public-key>")
}
