import Foundation
import AppKit
import SwiftUI
import VoiceDraftCore

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var release: UpdateRelease?
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var installing = false
    private var options = DesktopOptions()
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()
    func configure(_ options: DesktopOptions, preview: Bool) {
        guard !preview else { return }
        guard self.options.updateFeed != options.updateFeed || self.options.updatePublicKey != options.updatePublicKey || self.options.automaticUpdates != options.automaticUpdates else { return }
        self.options = options; generation = UUID(); task?.cancel(); release = nil
        timer?.invalidate(); timer = nil
        if options.automaticUpdates && !options.updateFeed.isEmpty && !options.updatePublicKey.isEmpty {
            let id = generation
            Task { [weak self] in
                while self?.busy == true { try? await Task.sleep(nanoseconds: 100_000_000); if self?.generation != id { return } }
                guard self?.generation == id else { return }; self?.check()
            }
            timer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in Task { @MainActor in self?.check() } }
        }
    }
    func check() {
        guard !busy else { return }
        let options = options, id = generation
        busy = true; status = F("Checking for updates…", "正在检查更新…")
        task = Task {
            defer { busy = false }
            do {
                let url = try Endpoint.validate(options.updateFeed)
                guard url.scheme == "https" else { throw FeatureError("Updates require HTTPS.") }
                let request = URLRequest(url: url, timeoutInterval: 30)
                let (data, response) = try await HTTPTransport().send(request, maxBytes: 100_000)
                guard response.statusCode == 200 else { throw FeatureError("Update server returned HTTP \(response.statusCode).") }
                #if arch(arm64)
                let arch = "arm64"
                #else
                let arch = "x86_64"
                #endif
                let os = ProcessInfo.processInfo.operatingSystemVersion
                let candidate = try UpdateVerifier.verify(data, publicKey: options.updatePublicKey, architecture: arch, systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
                try Task.checkCancellation(); guard generation == id else { return }
                let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
                release = candidate.build > build ? candidate : nil
                status = release == nil ? F("You're up to date.", "当前已是最新版本。") : F("Update available: ", "发现新版本：") + candidate.version
            } catch { if generation == id { status = error.localizedDescription } }
        }
    }
    func install() {
        guard !busy, let release else { return }
        let id = generation
        installing = true
        busy = true; status = F("Downloading and verifying…", "正在下载并校验…")
        task = Task {
            defer { busy = false; installing = false }
            var staging: URL?
            do {
                let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
                guard app.pathExtension == "app", app.lastPathComponent == "VoiceDraft.app", app.path != "/VoiceDraft.app" else { throw FeatureError("Run the packaged VoiceDraft.app to install updates.") }
                let parent = app.deletingLastPathComponent()
                guard FileManager.default.isWritableFile(atPath: parent.path) else { throw FeatureError("Move VoiceDraft to an Applications folder you can write to before updating.") }
                let directory = parent.appendingPathComponent(".VoiceDraft-update-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); staging = directory
                let archive = directory.appendingPathComponent("update.zip")
                try await download(release, to: archive)
                let data = try Data(contentsOf: archive, options: .mappedIfSafe)
                try UpdateVerifier.verifyPackage(data, release: release)
                try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
                let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
                try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false)
                try await run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
                let next = unpacked.appendingPathComponent("VoiceDraft.app")
                guard let bundle = Bundle(url: next), bundle.bundleIdentifier == "com.voicedraft.mac",
                      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
                      Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") == release.build else { throw FeatureError("The downloaded app does not match the signed release.") }
                try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", next.path])
                try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
                let helper = directory.appendingPathComponent("install.sh")
                let script = """
                #!/bin/sh
                set -eu
                pid="$1"; current="$2"; next="$3"; work="$4"
                count=0
                while kill -0 "$pid" 2>/dev/null; do
                    count=$((count + 1)); [ "$count" -lt 120 ] || exit 1
                    sleep 1
                done
                backup="$work/Previous.app"
                /bin/mv "$current" "$backup"
                if /bin/mv "$next" "$current"; then
                    if /usr/bin/open "$current"; then
                        /bin/rm -rf "$work"
                    else
                        /bin/mv "$current" "$work/Failed.app"
                        /bin/mv "$backup" "$current"
                        /usr/bin/open "$current"
                    fi
                else
                    /bin/mv "$backup" "$current"
                    /usr/bin/open "$current"
                fi
                """
                try Data(script.utf8).write(to: helper, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), app.path, next.path, directory.path]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); staging = nil
                NSApp.terminate(nil)
            } catch { if let staging { try? FileManager.default.removeItem(at: staging) }; status = error.localizedDescription }
        }
    }
    private func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: FeatureError("Update verification failed: \(URL(fileURLWithPath: executable).lastPathComponent).")) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
    private func download(_ release: UpdateRelease, to url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: HTTPTransport(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try Endpoint.validate(release.url), timeoutInterval: 120)
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw FeatureError("Could not download the update package.") }
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        var buffer = Data(), count = 0
        for try await byte in bytes {
            try Task.checkCancellation(); count += 1
            guard count <= release.size else { throw FeatureError("Update download exceeds its signed size.") }
            buffer.append(byte)
            if buffer.count >= 65536 { try file.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        try file.write(contentsOf: buffer)
        guard count == release.size else { throw FeatureError("The update download is incomplete.") }
    }
}

struct UpdatePreferences: View {
    @ObservedObject var state: AppState
    @State private var feed = ""
    @State private var publicKey = ""
    @State private var automatic = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(F("Software updates", "软件更新")).font(.headline)
            TextField(F("HTTPS update manifest URL", "HTTPS 更新清单地址"), text: $feed)
            TextField(F("Ed25519 public key (Base64)", "Ed25519 公钥（Base64）"), text: $publicKey)
            Toggle(F("Check automatically every day", "每天自动检查更新"), isOn: $automatic)
            HStack {
                Button(F("Save update source", "保存更新源")) {
                    var options = state.device.features; options.updateFeed = feed.trimmingCharacters(in: .whitespacesAndNewlines)
                    options.updatePublicKey = publicKey.trimmingCharacters(in: .whitespacesAndNewlines); options.automaticUpdates = automatic
                    state.saveFeatures(options)
                }
                UpdateActions(updater: state.updater, canInstall: !state.busy && !state.preview)
            }
            Text(F("Updates are verified with your release public key. After downloading, choose Install and restart. Release notes come from the signed manifest.", "使用发布公钥校验更新。点击“安装并重启”会下载、验证并安装；版本说明也经过签名验证。"))
                .font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder).onAppear {
            feed = state.device.features.updateFeed; publicKey = state.device.features.updatePublicKey; automatic = state.device.features.automaticUpdates
        }
    }
}
private struct UpdateActions: View {
    @ObservedObject var updater: UpdateController
    let canInstall: Bool
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button(F("Check now", "检查更新")) { updater.check() }.disabled(updater.busy || !canInstall)
                if updater.release != nil { Button(F("Install and restart", "安装并重启")) { updater.install() }.disabled(updater.busy || !canInstall) }
            }
            Text(updater.status).font(.caption).textSelection(.enabled)
            if let release = updater.release { Text(release.notes).font(.caption).textSelection(.enabled) }
        }
    }
}
