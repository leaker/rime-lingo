// Signs (or verifies) the release manifest with Ed25519 (CryptoKit), writing <file>.sig as
// base64. The private key lives in the login Keychain and is never printed; the apps embed
// the public key (UpdateConfiguration.manifestPublicKey).
//
//   swift scripts/sign-manifest.swift keygen               # once: creates the key, prints the PUBLIC key
//   swift scripts/sign-manifest.swift pubkey               # prints the public key of the stored key
//   swift scripts/sign-manifest.swift sign latest.json     # writes latest.json.sig
//   swift scripts/sign-manifest.swift verify latest.json <public-key-base64>
//   swift scripts/sign-manifest.swift check-key <public-key-base64>   # is it a usable public key?
//   swift scripts/sign-manifest.swift prove                # prints a signature that shows the key is held
//   swift scripts/sign-manifest.swift check-proof <public-key-base64> <proof>
//   swift scripts/sign-manifest.swift import <public-key-base64>      # restores a backed-up private key
//
// `--backup` after keygen, pubkey, sign, prove or import uses the backup key instead of the everyday one
// (Keychain account "ed25519-backup" instead of "ed25519"). The apps trust a manifest
// signed by either (UpdateConfiguration.manifestBackupPublicKey), so the backup key is what
// still reaches installed copies when the everyday key is lost or has leaked. See below.
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
// and this puts them back on another Mac:
//   swift scripts/sign-manifest.swift import <manifestPublicKey from the source>
// It asks for the hex with echo off and stores it only if it is the private half of that
// public key, and only if no key is there yet. Do not paste the hex anywhere that is logged
// or synced, and never put it on a command line (`security add-generic-password -X …`
// would): it stays in the shell history and is visible to other processes while it runs.
//
// The backup key is generated once, before the first release, and does not stay on this Mac:
//   swift scripts/sign-manifest.swift keygen --backup
// prints its PUBLIC key; paste that into `manifestBackupPublicKey`. While the key is still
// here, also run
//   swift scripts/sign-manifest.swift prove --backup
// and paste what it prints into `manifestBackupKeyProof`, then commit both. The proof is a
// signature over a fixed sentence naming the public key: scripts/release.sh checks it at
// every release, so a mistyped or foreign backup constant is caught while it can still be
// fixed, without the private key. It does not show that the offline copy is readable. Then move
// the private half to offline storage. This prints its 32 bytes as hex, to be written down
// or stored where no network reaches:
//   security find-generic-password -s com.leelib.rimelingo.manifest-key -a ed25519-backup -w
// and this DELETES it from the Keychain once the offline copy is checked:
//   security delete-generic-password -s com.leelib.rimelingo.manifest-key -a ed25519-backup
// From then on releases are signed with the everyday key only, as before. When the backup
// key is needed, put it back, typing or pasting the hex at the prompt (never as an argument):
//   swift scripts/sign-manifest.swift import --backup <manifestBackupPublicKey from the source>
// and sign the release with
// `sign --backup` (RIMELINGO_SIGN_WITH_BACKUP_KEY=1 makes scripts/release.sh do that). That
// release should carry a new everyday key in `manifestPublicKey`; delete the backup key
// from the Keychain again afterwards.
// Tests only: `--ephemeral-key-file <path>` after keygen, pubkey, sign, prove or import
// keeps the key in that file instead of the Keychain, with or without `--backup`; import
// then also takes the hex from a pipe (scripts/test-release-manifests.sh).
import CryptoKit
import Foundation
import Security

let service = "com.leelib.rimelingo.manifest-key"

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
var backup = false
if let index = arguments.firstIndex(of: "--backup") {
    guard ["keygen", "pubkey", "sign", "prove", "import"].contains(arguments.first ?? "") else {
        fail("--backup goes with keygen, pubkey, sign, prove or import")
    }
    backup = true
    arguments.remove(at: index)
}
let account = backup ? "ed25519-backup" : "ed25519"
let label = backup ? "RimeLingo release manifest backup signing key" : "RimeLingo release manifest signing key"
let keyName = backup ? "backup manifest signing key" : "manifest signing key"
let flags = backup ? " --backup" : ""

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
            ?? (backup
                ? "no backup manifest signing key in the login Keychain (service \(service), account \(account)); "
                    + "it is kept offline: restore it as described at the top of scripts/sign-manifest.swift"
                : "no manifest signing key in the login Keychain (service \(service)); run: swift scripts/sign-manifest.swift keygen"))
    }
    return key
}

/// A public key as the apps take it: base64 of 32 bytes that are not a point of small
/// order. CryptoKit accepts those eight points, and under them a signature anyone can
/// write down verifies. Keep identical to UpdateConfiguration.isSmallOrderPoint.
func publicKey(_ text: String) -> Curve25519.Signing.PublicKey? {
    func spanning(_ first: UInt8, _ middle: UInt8, _ last: UInt8) -> [UInt8] {
        [first] + Array(repeating: middle, count: 30) + [last]
    }
    let smallOrderPoints: Set<[UInt8]> = [
        spanning(0x00, 0x00, 0x00), spanning(0x01, 0x00, 0x00),
        [0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0, 0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98, 0xf0,
         0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39, 0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x05],
        [0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f, 0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f,
         0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6, 0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0x7a],
        spanning(0xec, 0xff, 0x7f), spanning(0xed, 0xff, 0x7f), spanning(0xee, 0xff, 0x7f)
    ]
    guard let data = Data(base64Encoded: text), data.count == 32 else { return nil }
    var y = [UInt8](data)
    y[31] &= 0x7f
    return smallOrderPoints.contains(y) ? nil : try? Curve25519.Signing.PublicKey(rawRepresentation: data)
}

/// What a proof of possession signs. Keep identical to UpdateConfiguration.keyProofMessage.
func proofMessage(for key: String) -> Data {
    Data("RimeLingo manifest signing key, proof of possession: \(key)".utf8)
}

/// Anything already there is kept, readable as a key or not.
func refuseToReplaceAKey() {
    if let keyFile {
        guard !FileManager.default.fileExists(atPath: keyFile) else { fail("\(keyFile) already exists; refusing to replace it") }
    } else {
        let status = SecItemCopyMatching(keychainQuery() as CFDictionary, nil)
        guard status == errSecItemNotFound else {
            fail(status == errSecSuccess ? "a \(keyName) already exists; refusing to replace it"
                : "cannot tell whether a \(keyName) already exists (status \(status))")
        }
    }
}

func store(_ key: Curve25519.Signing.PrivateKey) {
    if let keyFile {
        guard FileManager.default.createFile(atPath: keyFile, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                             attributes: [.posixPermissions: 0o600]) else { fail("cannot write \(keyFile)") }
    } else {
        var item = keychainQuery()
        item[kSecValueData as String] = key.rawRepresentation
        item[kSecAttrLabel as String] = label
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { fail("could not store the key in the Keychain (status \(status))") }
    }
}

/// The hex of a private key, read from the terminal with echo off: as an argument it would
/// stay in the shell history and show in `ps`. Only the tests' key file takes it from a pipe.
func readPrivateKeyHex() -> String {
    if keyFile != nil, isatty(STDIN_FILENO) == 0 { return readLine() ?? "" }
    var buffer = [CChar](repeating: 0, count: 256)
    defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    guard readpassphrase("Private half of the \(keyName) (64 hex digits, not shown): ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
        fail("import asks for the private key on the terminal, with echo off; run it in a terminal")
    }
    return String(cString: buffer)
}

switch arguments.first {
case "keygen":
    guard arguments.count == 1 else { fail("usage: keygen\(flags)") }
    refuseToReplaceAKey()
    let key = Curve25519.Signing.PrivateKey()
    store(key)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "import":
    guard arguments.count == 2 else {
        fail("usage: import\(flags) <public-key>   (the private key is asked for; it is never an argument)")
    }
    guard let expected = publicKey(arguments[1]) else { fail("not a usable Ed25519 public key: \(arguments[1])") }
    refuseToReplaceAKey()
    let hex = Array(readPrivateKeyHex().trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    let digits = hex.compactMap { UInt8(String(UnicodeScalar($0)), radix: 16) }
    guard hex.count == 64, digits.count == 64 else { fail("that is not 64 hex digits; nothing was stored") }
    let raw = Data(stride(from: 0, to: 64, by: 2).map { digits[$0] << 4 | digits[$0 + 1] })
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
          key.publicKey.rawRepresentation == expected.rawRepresentation else {
        fail("that is not the private key of \(arguments[1]); nothing was stored")
    }
    store(key)
    print("stored the \(keyName) of \(key.publicKey.rawRepresentation.base64EncodedString())")
case "pubkey":
    guard arguments.count == 1 else { fail("usage: pubkey\(flags)") }
    print(requireKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard arguments.count == 2 else { fail("usage: sign\(flags) <file>") }
    let key = requireKey()
    let path = arguments[1]
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let signature = try key.signature(for: data)
    try (signature.base64EncodedString() + "\n").write(toFile: path + ".sig", atomically: true, encoding: .utf8)
    print("signed \(path) with \(key.publicKey.rawRepresentation.base64EncodedString())")
case "verify":
    guard arguments.count == 3 else { fail("usage: verify <file> <public-key>") }
    guard let key = publicKey(arguments[2]) else { fail("not a usable Ed25519 public key: \(arguments[2])") }
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let text = try String(contentsOfFile: arguments[1] + ".sig", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let signature = Data(base64Encoded: text), key.isValidSignature(signature, for: data) else { fail("signature invalid") }
    print("signature valid")
case "check-key":
    // Exactly what `keygen` prints: a constant with a stray character is not close enough.
    guard arguments.count == 2 else { fail("usage: check-key <public-key>") }
    guard let key = publicKey(arguments[1]), key.rawRepresentation.base64EncodedString() == arguments[1] else {
        fail("not a usable Ed25519 public key: \(arguments[1])")
    }
    print("public key usable")
case "prove":
    guard arguments.count == 1 else { fail("usage: prove\(flags)") }
    let key = requireKey()
    print(try key.signature(for: proofMessage(for: key.publicKey.rawRepresentation.base64EncodedString())).base64EncodedString())
case "check-proof":
    guard arguments.count == 3 else { fail("usage: check-proof <public-key> <proof>") }
    guard let key = publicKey(arguments[1]) else { fail("not a usable Ed25519 public key: \(arguments[1])") }
    guard let proof = Data(base64Encoded: arguments[2]), key.isValidSignature(proof, for: proofMessage(for: arguments[1])) else {
        fail("this is not a proof made with the private key of \(arguments[1])")
    }
    print("proof valid")
default:
    fail("usage: sign-manifest.swift keygen [--backup] | pubkey [--backup] | sign [--backup] <file> | verify <file> <public-key>"
        + " | check-key <public-key> | prove [--backup] | check-proof <public-key> <proof> | import [--backup] <public-key>")
}
