#!/usr/bin/env swift
// No network operations. The private signing key is never copied into the app or release directory.
import Foundation
import CryptoKit

func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
let args = Array(CommandLine.arguments.dropFirst())
if args.first == "keygen", args.count == 2 {
    let url = URL(fileURLWithPath: args[1])
    guard !FileManager.default.fileExists(atPath: url.path) else { fail("Refusing to overwrite an existing key.") }
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: url.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600]) else { fail("Could not create signing key.") }
    print("Public key: " + key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}
guard args.count == 6, args[0] == "sign" else {
    fail("Usage:\n  swift scripts/make-update.swift keygen /secure/path/private-key\n  swift scripts/make-update.swift sign /path/VoiceDraft.app https://host/VoiceDraft.zip /secure/path/private-key /path/output arm64|x86_64|universal")
}
do {
    let app = URL(fileURLWithPath: args[1]), directory = URL(fileURLWithPath: args[4], isDirectory: true)
    guard app.lastPathComponent == "VoiceDraft.app", let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.voicedraft.mac",
          let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
          let build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
          let remote = URL(string: args[2]), remote.scheme == "https", remote.host != nil, remote.user == nil, remote.password == nil, remote.query == nil,
          ["arm64", "x86_64", "universal"].contains(args[5]) else { fail("Check the app, HTTPS download URL and architecture.") }
    let raw = try String(contentsOfFile: args[3], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let bytes = Data(base64Encoded: raw) else { fail("Invalid signing key.") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let archive = directory.appendingPathComponent("VoiceDraft.zip")
    guard !FileManager.default.fileExists(atPath: archive.path) else { fail("Choose a fresh output directory; refusing to overwrite an existing package.") }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", app.path, archive.path]
    try process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { fail("Could not package app.") }
    let data = try Data(contentsOf: archive)
    let payload = try JSONSerialization.data(withJSONObject: [
        "version": version, "build": build, "architecture": args[5], "minimumSystemVersion": bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "13.0",
        "url": remote.absoluteString, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "size": data.count,
        "notes": ProcessInfo.processInfo.environment["VOICEDRAFT_RELEASE_NOTES"] ?? "VoiceDraft \(version)"
    ], options: [.sortedKeys])
    let manifest = try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signature": key.signature(for: payload).base64EncodedString()], options: [.prettyPrinted, .sortedKeys])
    try manifest.write(to: directory.appendingPathComponent("update.json"), options: .atomic)
    print("Created VoiceDraft.zip and signed update.json in \(directory.path)")
    print("Public key: " + key.publicKey.rawRepresentation.base64EncodedString())
} catch { fail(error.localizedDescription) }
