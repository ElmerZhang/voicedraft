import SwiftUI
import AppKit
import VoiceDraftCore

private let ink = Color(red: 0.14, green: 0.20, blue: 0.18)
private let accent = Color(red: 0.20, green: 0.39, blue: 0.30)
private let paper = Color(red: 0.97, green: 0.97, blue: 0.94)

struct RootView: View {
    @ObservedObject var state: AppState
    private let pages = [("Studio", "waveform"), ("Models", "cpu"), ("Vocabulary", "text.book.closed"),
                         ("Sync", "arrow.triangle.2.circlepath"), ("History", "clock.arrow.circlepath")]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2.bold()).foregroundStyle(accent)
                    Text("VoiceDraft").font(.title3.weight(.semibold))
                }.padding(.top, 24)
                Text("THINK OUT LOUD").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                VStack(spacing: 7) {
                    ForEach(pages, id: \.0) { title, icon in
                        Button { state.page = title } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon).frame(width: 20)
                                Text(title).font(.system(size: 14, weight: state.page == title ? .semibold : .regular))
                                Spacer()
                            }.padding(12).foregroundStyle(state.page == title ? .white : ink)
                                .background(state.page == title ? accent : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    Label("Your models. Your words.", systemImage: "lock.shield").font(.system(size: 11, weight: .medium))
                    Text("Qwen on Alibaba Cloud\nEncrypted configuration sync")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                }
                Divider()
                Text("MAC PREVIEW  ·  0.1.0").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(22).frame(width: 220).background(Color(red: 0.93, green: 0.94, blue: 0.90))
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(state.page.uppercased()).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(2)
                    Spacer()
                    Circle().fill(state.busy ? Color.orange : accent).frame(width: 7, height: 7)
                    Text(state.busy ? "In progress" : "On your terms").font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 20)
                if !state.error.isEmpty {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text(state.error).textSelection(.enabled)
                        Spacer()
                        Button { state.error = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.font(.callout).padding(14).foregroundStyle(Color(red: 0.55, green: 0.20, blue: 0.12))
                        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 32).padding(.bottom, 12)
                }
                ScrollView {
                    Group {
                        switch state.page {
                        case "Models": ModelsView(state: state)
                        case "Vocabulary": VocabularyView(state: state)
                        case "Sync": SyncView(state: state)
                        case "History": HistoryView(state: state)
                        default: StudioView(state: state)
                        }
                    }.padding(.horizontal, 32).padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !state.notice.isEmpty {
                    Text(state.notice).font(.caption).foregroundStyle(accent).padding(.horizontal, 32).padding(.bottom, 10)
                }
            }.background(paper)
        }.frame(minWidth: 940, minHeight: 700).foregroundStyle(ink).tint(accent).preferredColorScheme(.light)
    }
}

private struct PageHeading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 34, weight: .medium, design: .serif))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
        }.padding(.bottom, 24)
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ink.opacity(0.08)))
    }
}

struct StudioView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "A little less typing.", detail: "Speak naturally. Turn your thoughts into words, wherever you work.")
            HStack(spacing: 8) {
                ForEach(WritingMode.allCases) { mode in
                    Button { state.mode = mode } label: {
                        Label(mode.title, systemImage: mode.icon).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 10)
                            .background(state.mode == mode ? accent.opacity(0.12) : Color.white.opacity(0.65), in: Capsule())
                    }.buttonStyle(.plain).disabled(state.busy)
                }
            }
            Card {
                HStack(alignment: .center, spacing: 24) {
                    Button { state.toggle() } label: {
                        Image(systemName: state.recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 27)).foregroundStyle(.white).frame(width: 76, height: 76)
                            .background(state.recording ? Color(red: 0.72, green: 0.26, blue: 0.20) : accent, in: Circle())
                    }.buttonStyle(.plain).disabled(state.busy && !state.recording)
                        .accessibilityLabel(state.recording ? "Stop recording" : "Start recording")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.status).font(.system(size: 18, weight: .medium))
                        Text(state.recording ? String(format: "%02d:%02d · tap to finish", Int(state.elapsed) / 60, Int(state.elapsed) % 60) : "⌃ ⌥ Space  to start or finish in any app")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        if state.recording { ProgressView(value: state.level).frame(width: 190) }
                    }
                    Spacer()
                    if state.busy { Button("Cancel") { state.cancel() }.buttonStyle(.bordered) }
                }
                Divider()
                HStack {
                    Label(state.settings.speech?.model ?? "Choose ASR", systemImage: "waveform")
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Label(state.settings.writing?.model ?? "Choose LLM", systemImage: "sparkles")
                    Spacer()
                    Button("Configure") { state.page = "Models" }.buttonStyle(.plain).foregroundStyle(accent)
                }.font(.system(size: 11))
            }
            if state.mode == .edit || state.mode == .ask {
                Card {
                    Text("Selection").font(.headline)
                    Text("Global shortcuts read selected text from the active app. For a test here, paste text below.").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $state.selection).font(.body).frame(minHeight: 70).scrollContentBackground(.hidden)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                Card {
                    HStack {
                        Text("Transcript").font(.headline)
                        Spacer()
                        Button("Process text") { state.processText() }.disabled(state.busy || state.transcript.isEmpty)
                    }
                    TextEditor(text: $state.transcript).font(.system(size: 14)).frame(minHeight: 150).scrollContentBackground(.hidden)
                    Text("Or type here to test your writing model.").font(.caption).foregroundStyle(.secondary)
                }
                Card {
                    HStack {
                        Text("Ready to use").font(.headline)
                        Spacer()
                        Button { state.copyResult() } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(state.result.isEmpty)
                    }
                    TextEditor(text: $state.result).font(.system(size: 14)).frame(minHeight: 150).scrollContentBackground(.hidden)
                    Text(state.mode == .translate ? "Translation target: \(state.settings.targetLanguage)" : "Your wording, with a little more clarity.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Make room for your voice").font(.headline)
                        Text("Allow Accessibility for insertion. Microphone permission is requested when you record.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Allow Accessibility") { TextInsertion.requestAccess() }
                }
                Toggle("Insert into the original app after recording", isOn: Binding(get: { state.device.autoPaste }, set: { state.saveDevice(autoPaste: $0, history: state.device.keepHistory) }))
                Text("⌃ ⌥ T  Translate      ⌃ ⌥ E  Edit selection      ⌃ ⌥ A  Ask").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ModelsView: View {
    @ObservedObject var state: AppState
    @State private var editing: ModelProfile?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "Choose how you think.", detail: "Independent Qwen models for listening and writing. Connect with your own Alibaba Cloud Model Studio API keys.")
            ForEach(ModelRole.allCases) { role in
                HStack {
                    Text(role.title.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1)
                    Spacer()
                    Button { editing = ModelProfile.qwen(role) } label: { Label("Add profile", systemImage: "plus") }
                }
                ForEach(state.settings.profiles.filter { $0.role == role }) { profile in
                    Card {
                        HStack {
                            Image(systemName: role == .speech ? "waveform" : "sparkles").font(.title2).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(profile.name).font(.headline)
                                Text(profile.model).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile.id == state.settings.speechID || profile.id == state.settings.writingID {
                                Text("ACTIVE").font(.system(size: 10, weight: .bold)).foregroundStyle(accent).padding(7).background(accent.opacity(0.1), in: Capsule())
                            } else {
                                Button("Use") {
                                    var copy = state.settings
                                    if role == .speech { copy.speechID = profile.id } else { copy.writingID = profile.id }
                                    state.save(copy)
                                }
                            }
                            Button("Edit") { editing = profile }
                        }
                        Text(profile.endpoint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
            Text("Use the complete /chat/completions URL for your Bailian region or workspace. ASR profiles currently use the Qwen3-ASR-Flash HTTP protocol. Other providers will be added later.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
        }.sheet(item: $editing) { profile in ProfileEditor(state: state, profile: profile) }
    }
}

struct ProfileEditor: View {
    @ObservedObject var state: AppState
    @State var profile: ModelProfile
    @State private var keyDraft = APIKeyDraft(hasSavedKey: false)
    @State private var problem = ""
    @State private var testing = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile.role.title).font(.title2.weight(.semibold))
            Form {
                LabeledContent("Profile name") { SingleLineField("Profile name", text: $profile.name) }
                LabeledContent("Full endpoint URL") { SingleLineField("Full endpoint URL", text: $profile.endpoint) }
                LabeledContent("Model ID") { SingleLineField("Model ID", text: $profile.model) }
                LabeledContent("Bailian API key") {
                    SingleLineField("Bailian API key", text: $keyDraft.replacement, secure: true,
                                    placeholder: keyDraft.showsSavedKey ? "••••••••••••" : nil)
                }
            }.textFieldStyle(.roundedBorder)
            if keyDraft.hasSavedKey {
                HStack {
                    Text(keyDraft.removeSavedKey && keyDraft.credentialUpdate == ""
                         ? "The saved API key will be removed when you save."
                         : (keyDraft.credentialUpdate == nil
                            ? "API key saved on this Mac. Enter a new key to replace it."
                            : "The new API key will replace the saved key when you save."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(keyDraft.removeSavedKey ? "Keep saved key" : "Remove saved key") {
                        keyDraft.removeSavedKey.toggle()
                        keyDraft.replacement = ""
                    }.disabled(testing)
                }
            }
            Text("Advanced request parameters (JSON)").font(.headline)
            TextEditor(text: $profile.extraJSON).font(.system(size: 12, design: .monospaced)).frame(height: 85).border(.gray.opacity(0.2))
            Text("API keys are stored in this Mac's Keychain and encrypted before sync. The endpoint must match the API key's region.").font(.caption).foregroundStyle(.secondary)
            if !problem.isEmpty { Text(problem).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if state.settings.profiles.contains(where: { $0.id == profile.id }),
                   state.settings.speechID != profile.id && state.settings.writingID != profile.id {
                    Button("Delete profile", role: .destructive) {
                        var copy = state.settings; copy.profiles.removeAll { $0.id == profile.id }; state.save(copy); dismiss()
                    }
                }
                Spacer()
                if profile.role == .writing {
                    Button(testing ? "Testing…" : "Test connection") {
                        testing = true; problem = ""
                        Task {
                            defer { testing = false }
                            do {
                                let key = try keyDraft.keyForRequest { try state.key(for: profile) }
                                let request = try QwenRequests.writing(profile: profile, key: key, text: "Reply with OK.", mode: .ask, settings: SharedSettings())
                                _ = try await HTTPTransport().complete(request); problem = "Connection successful."
                            } catch { problem = error.localizedDescription }
                        }
                    }.disabled(testing)
                }
                Button("Cancel") { dismiss() }
                Button("Save profile") {
                    var copy = state.settings
                    if let i = copy.profiles.firstIndex(where: { $0.id == profile.id }) { copy.profiles[i] = profile }
                    else { copy.profiles.append(profile) }
                    do {
                        try copy.validate(); state.error = ""
                        state.save(copy, credential: keyDraft.credentialUpdate.map { (profile.id, $0) })
                        if state.error.isEmpty { dismiss() } else { problem = state.error }
                    } catch { problem = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(testing)
            }
        }.padding(28).frame(width: 600).onAppear {
            profile = profile.normalizedInput
            do { keyDraft = APIKeyDraft(hasSavedKey: try state.hasKey(for: profile)) }
            catch { problem = "\(error.localizedDescription) The existing key will be kept unless you enter a replacement." }
        }
    }
}

struct VocabularyView: View {
    @ObservedObject var state: AppState
    @State private var words = ""
    @State private var style = ""
    @State private var language = ""
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "Sounds like you.", detail: "Names, products, and phrases that matter. Shared securely across your devices.")
            Card {
                Text("Personal vocabulary").font(.headline)
                Text("One word or phrase per line. Used as recognition context and spelling guidance, without forcing substitutions.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $words).font(.system(size: 14)).frame(height: 170).scrollContentBackground(.hidden)
            }
            Card {
                Text("Your writing style").font(.headline)
                TextEditor(text: $style).font(.body).frame(height: 85).scrollContentBackground(.hidden)
                SingleLineField("Translation target language", text: $language)
            }
            HStack {
                Text("Vocabulary and preferences are included in encrypted sync.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save preferences") {
                    var copy = state.settings; copy.hotwords = words; copy.stylePrompt = style; copy.targetLanguage = language
                    state.save(copy)
                }.buttonStyle(.borderedProminent)
            }
        }.onAppear { if !loaded { load(); loaded = true } }
            .onChange(of: state.settings) { _ in load() }
    }
    private func load() { words = state.settings.hotwords; style = state.settings.stylePrompt; language = state.settings.targetLanguage }
}

struct SyncView: View {
    @ObservedObject var state: AppState
    @State private var url = ""
    @State private var token = ""
    @State private var passphrase = ""
    @State private var automatic = false
    @State private var confirmDownload = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "One setup. Every device.", detail: "Your models, API keys, vocabulary, and writing preferences travel together. Only you hold the decryption passphrase.")
            Card {
                Label("End-to-end encrypted", systemImage: "lock.shield").font(.headline).foregroundStyle(accent)
                Text("The server stores an encrypted configuration vault. Recordings and dictation history stay on this Mac. Model calls go directly to your configured Bailian endpoint.")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(5)
            }
            Card {
                SingleLineField("Sync server URL", text: $url)
                SingleLineField("Server access token", text: $token, secure: true)
                SingleLineField("Sync passphrase · at least 12 characters", text: $passphrase, secure: true)
                Text("Use the same three values on each device. The passphrase is never sent to the server; losing it means the server copy cannot be recovered.").font(.caption).foregroundStyle(.secondary)
                Toggle("Sync automatically every 30 seconds and after saving", isOn: $automatic)
                HStack {
                    Button("Save connection") { state.configureSync(url: url, token: token, passphrase: passphrase, automatic: automatic) }
                    Spacer()
                    Button("Download server copy…") { confirmDownload = true }.disabled(state.syncing || state.busy)
                    Button(state.syncing ? "Syncing…" : "Sync now") { Task { await state.sync() } }
                        .buttonStyle(.borderedProminent).disabled(state.syncing || state.busy)
                }
            }.textFieldStyle(.roundedBorder)
            Card {
                Text(state.syncStatus).font(.callout).textSelection(.enabled)
                Text("First Mac: save the connection, then Sync now.\nNew device: save the connection, then Download server copy.\nIf both devices have changes, sync pauses instead of overwriting either copy.")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(5)
            }
        }.onAppear {
            url = state.device.serverURL; automatic = state.device.autoSync
            do { token = try state.syncToken(); passphrase = try state.syncPassphrase() } catch { state.error = error.localizedDescription }
        }.confirmationDialog("Replace this Mac's model settings and vocabulary with the server copy?", isPresented: $confirmDownload, titleVisibility: .visible) {
            Button("Download and replace") { Task { await state.sync(download: true) } }
        } message: { Text("Local history is kept. Current model settings are backed up on this Mac before replacement.") }
    }
}

struct HistoryView: View {
    @ObservedObject var state: AppState
    @State private var query = ""
    @State private var confirmClear = false
    private var entries: [HistoryEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.history.filter { term.isEmpty || $0.result.localizedCaseInsensitiveContains(term) || $0.original.localizedCaseInsensitiveContains(term) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "A thought worth keeping.", detail: "Your last 500 entries, saved only on this Mac. Audio is deleted after each recording is read.")
            HStack {
                SingleLineField("Search your words", text: $query)
                Button("Clear history…", role: .destructive) { confirmClear = true }.disabled(state.history.isEmpty)
            }
            Toggle("Save future transcripts on this Mac", isOn: Binding(get: { state.device.keepHistory }, set: { state.saveDevice(autoPaste: state.device.autoPaste, history: $0) }))
            if entries.isEmpty {
                Card {
                    Image(systemName: "text.alignleft").font(.largeTitle).foregroundStyle(accent.opacity(0.5))
                    Text("Your words will find a home here.").font(.headline)
                    Text("Record your first thought in Studio, or use the shortcut in any app.").font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 20)
            }
            ForEach(entries) { entry in
                Card {
                    HStack {
                        Label(entry.mode.title, systemImage: entry.mode.icon).font(.caption.weight(.semibold)).foregroundStyle(accent)
                        Text("· \(entry.application)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        Button { state.copyResult(entry.result) } label: { Image(systemName: "doc.on.doc") }
                        Button(role: .destructive) { state.deleteHistory(entry.id) } label: { Image(systemName: "trash") }
                    }
                    Text(entry.result).font(.body).textSelection(.enabled).lineSpacing(4)
                    if entry.original != entry.result {
                        DisclosureGroup("Original transcript") { Text(entry.original).font(.caption).textSelection(.enabled) }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.confirmationDialog("Delete all local history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete history", role: .destructive) { state.deleteHistory() }
        }
    }
}

struct RecordingHUD: View {
    @ObservedObject var state: AppState
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.recording ? "waveform" : "sparkles").foregroundStyle(state.recording ? .orange : .green)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.status).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if state.recording { ProgressView(value: state.level).frame(width: 180).tint(.orange) }
            }
            Spacer()
            if state.recording {
                Text(String(format: "%02d:%02d", Int(state.elapsed) / 60, Int(state.elapsed) % 60)).font(.system(size: 11, design: .monospaced))
                Button { state.finish() } label: { Image(systemName: "stop.fill") }.buttonStyle(.plain)
            }
            if state.busy { Button { state.cancel() } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
        }.padding(18).frame(width: 410).foregroundStyle(.white)
            .background(Color(red: 0.12, green: 0.16, blue: 0.14), in: RoundedRectangle(cornerRadius: 18))
            .preferredColorScheme(.dark)
    }
}
