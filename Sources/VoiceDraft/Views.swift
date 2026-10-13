import SwiftUI
import AppKit
import VoiceDraftCore

private let ink = Color(red: 0.10, green: 0.10, blue: 0.11)
private let accent = Color(red: 0.15, green: 0.34, blue: 0.96)
private let paper = Color.white

struct RootView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var state: AppState
    private let pages = [("Studio", "waveform"), ("Models", "cpu"), ("Vocabulary", "text.book.closed"),
                         ("Sync", "arrow.triangle.2.circlepath"), ("History", "clock.arrow.circlepath")]
    var body: some View {
        let _ = interfaceLocale
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2.bold()).foregroundStyle(accent)
                    Text("VoiceDraft").font(.title3.weight(.semibold))
                }.padding(.top, 24)
                Text(L("THINK OUT LOUD")).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                VStack(spacing: 7) {
                    ForEach(pages, id: \.0) { title, icon in
                        Button { state.page = title } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon).frame(width: 20)
                                Text(L10n.text(title)).font(.system(size: 14, weight: state.page == title ? .semibold : .regular))
                                Spacer()
                            }.padding(12).foregroundStyle(state.page == title ? .white : ink)
                                .background(state.page == title ? accent : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    Label(L("Your models. Your words."), systemImage: "lock.shield").font(.system(size: 11, weight: .medium))
                    Text(L("Qwen on Alibaba Cloud\nEncrypted configuration sync"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Interface language")).font(.caption).foregroundStyle(.secondary)
                    Picker(L("Interface language"), selection: Binding(get: { state.interfaceLanguage }, set: { state.setLanguage($0) })) {
                        ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                    }.labelsHidden().disabled(state.busy)
                }
                Divider()
                Text(L("MAC PREVIEW  ·  0.1.0")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(22).frame(width: 220).background(Color(red: 0.93, green: 0.94, blue: 0.90))
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L10n.text(state.page).uppercased()).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(2)
                    Spacer()
                    Circle().fill(state.busy ? Color.orange : accent).frame(width: 7, height: 7)
                    Text(state.busy ? L("In progress") : L("On your terms")).font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 20)
                if !state.error.isEmpty {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text(L(state.error)).textSelection(.enabled)
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
                    Text(L(state.notice)).font(.caption).foregroundStyle(accent).padding(.horizontal, 32).padding(.bottom, 10)
                }
            }.background(paper)
        }.environment(\.locale, L10n.locale).frame(minWidth: 940, minHeight: 700).foregroundStyle(ink).tint(accent).preferredColorScheme(.light)
    }
}

private struct PageHeading: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    let detail: String
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text(title)).font(.system(size: 34, weight: .bold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
        }.padding(.bottom, 24)
    }
}

private struct Card<Content: View>: View {
    @Environment(\.locale) private var interfaceLocale
    @ViewBuilder var content: Content
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 16) { content }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ink.opacity(0.08)))
    }
}

struct StudioView: View {
    var showsHeading = true
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var state: AppState
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 20) {
            if showsHeading {
                PageHeading(title: L("A little less typing."), detail: L("Speak naturally. Turn your thoughts into words, wherever you work."))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { ForEach(WritingMode.allCases) { mode in modeButton(mode) } }.fixedSize()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading, spacing: 8) {
                    ForEach(WritingMode.allCases) { mode in modeButton(mode) }
                }
            }
            Card {
                HStack(alignment: .center, spacing: 24) {
                    Button { state.toggle() } label: {
                        Image(systemName: state.recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 27)).foregroundStyle(.white).frame(width: 76, height: 76)
                            .background(state.recording ? Color(red: 0.72, green: 0.26, blue: 0.20) : accent, in: Circle())
                    }.buttonStyle(.plain).disabled(state.busy && !state.recording)
                        .accessibilityLabel(state.recording ? L("Stop recording") : L("Start recording"))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L(state.status)).font(.system(size: 18, weight: .medium))
                        Text(state.recording ? String(format: L("%02d:%02d · tap to finish"), Int(state.elapsed) / 60, Int(state.elapsed) % 60) : L("⌃ ⌥ Space  to start or finish in any app"))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        if state.recording { ProgressView(value: state.level).frame(width: 190) }
                    }
                    Spacer()
                    if state.busy { Button(L("Cancel")) { state.cancel() }.buttonStyle(.bordered) }
                }
                Divider()
                HStack {
                    Picker(L("Input device"), selection: Binding(get: { state.device.inputDeviceID ?? "" }, set: { state.selectInputDevice($0) })) {
                        let defaultName = state.inputDevices.first { $0.id == state.defaultInputID }?.name
                        Text(defaultName.map { L("System default — \($0)") } ?? L("System default")).tag("")
                        ForEach(state.inputDevices) { input in Text(input.name).tag(input.id) }
                        if let saved = state.device.inputDeviceID, !state.inputDevices.contains(where: { $0.id == saved }) {
                            Text(L("Unavailable: \(state.device.inputDeviceName ?? saved)")).tag(saved)
                        }
                    }
                    Button { state.refreshInputDevices() } label: { Image(systemName: "arrow.clockwise") }.help(L("Refresh devices"))
                }.disabled(state.busy)
                HStack {
                    Label(state.settings.speech?.model ?? L("Choose ASR"), systemImage: "waveform")
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Label(state.settings.writing?.model ?? L("Choose LLM"), systemImage: "sparkles")
                    Spacer()
                    Button(L("Configure")) { state.page = "Models" }.buttonStyle(.plain).foregroundStyle(accent)
                }.font(.system(size: 11))
            }
            if state.mode == .edit || state.mode == .ask {
                Card {
                    Text(L("Selection")).font(.headline)
                    Text(L("Global shortcuts read selected text from the active app. For a test here, paste text below.")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $state.selection).font(.body).frame(minHeight: 70).scrollContentBackground(.hidden)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                Card {
                    HStack {
                        Text(L("Transcript")).font(.headline)
                        Spacer()
                        Button(L("Process text")) { state.processText() }.disabled(state.busy || state.transcript.isEmpty)
                    }
                    TextEditor(text: $state.transcript).font(.system(size: 14)).frame(minHeight: 150).scrollContentBackground(.hidden)
                    Text(L("Or type here to test your writing model.")).font(.caption).foregroundStyle(.secondary)
                }
                Card {
                    HStack {
                        Text(L("Ready to use")).font(.headline)
                        Spacer()
                        Button { state.copyResult() } label: { Label(L("Copy"), systemImage: "doc.on.doc") }.disabled(state.result.isEmpty)
                    }
                    TextEditor(text: $state.result).font(.system(size: 14)).frame(minHeight: 150).scrollContentBackground(.hidden)
                    Text(state.mode == .translate ? L("Translation target: \(state.settings.targetLanguage)") : L("Your wording, with a little more clarity.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L("Make room for your voice")).font(.headline)
                        Text(L("Allow Accessibility for insertion. Microphone permission is requested when you record."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Allow Accessibility")) { TextInsertion.requestAccess() }
                }
                Toggle(L("Insert into the original app after recording"), isOn: Binding(get: { state.device.autoPaste }, set: { state.saveDevice(autoPaste: $0, history: state.device.keepHistory) }))
                Text(L("⌃ ⌥ T  Translate      ⌃ ⌥ E  Edit selection      ⌃ ⌥ A  Ask")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
    private func modeButton(_ mode: WritingMode) -> some View {
        Button { state.mode = mode } label: {
            Label(mode.title, systemImage: mode.icon).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(state.mode == mode ? accent.opacity(0.12) : Color.white.opacity(0.65), in: Capsule())
        }.buttonStyle(.plain).disabled(state.busy)
    }

}

struct ModelsView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var state: AppState
    @State private var editing: ModelProfile?
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: L("Choose how you think."), detail: L("Independent Qwen models for listening and writing. Connect with your own Alibaba Cloud Model Studio API keys."))
            ForEach(ModelRole.allCases) { role in
                HStack {
                    Text(role.title.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1)
                    Spacer()
                    Button { editing = ModelProfile.qwen(role) } label: { Label(L("Add profile"), systemImage: "plus") }
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
                                Text(L("ACTIVE")).font(.system(size: 10, weight: .bold)).foregroundStyle(accent).padding(7).background(accent.opacity(0.1), in: Capsule())
                            } else {
                                Button(L("Use")) {
                                    var copy = state.settings
                                    if role == .speech { copy.speechID = profile.id } else { copy.writingID = profile.id }
                                    state.save(copy)
                                }
                            }
                            Button(L("Edit")) { editing = profile }
                        }
                        Text("\(profile.adapter.title) · \(profile.endpoint)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
            Text(L("Choose a supported model first. VoiceDraft uses its HTTP or WebSocket protocol and adapts the app vocabulary to its supported format. Recognition starts after you stop recording. Other model families require their own adapters."))
                .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
        }.sheet(item: $editing) { profile in ProfileEditor(state: state, profile: profile) }
    }
}

struct ProfileEditor: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var state: AppState
    @State var profile: ModelProfile
    @State private var keyDraft = APIKeyDraft(hasSavedKey: false)
    @State private var problem = ""
    @State private var testing = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 16) {
            Text(profile.role.title).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Form {
                        Picker(L("Model"), selection: modelChoice) {
                            if profile.role == .speech && profile.catalogModel == nil {
                                Text(L("Unsupported: \(profile.model)")).tag(profile.model)
                            }
                            ForEach(ModelCatalog.models(for: profile.role)) { model in Text(model.id).tag(model.id) }
                            if profile.role == .writing { Text(L("Other Qwen text model…")).tag("__custom") }
                        }
                        if profile.role == .writing && profile.catalogModel == nil {
                            LabeledContent(L("Model ID")) { SingleLineField(L("Model ID"), text: $profile.model) }
                        }
                        LabeledContent(L("Connection")) { Text(profile.adapter.title).foregroundStyle(.secondary) }
                        LabeledContent(L("Profile name")) { SingleLineField(L("Profile name"), text: $profile.name) }
                        LabeledContent(L("Full endpoint URL")) { SingleLineField(L("Full endpoint URL"), text: $profile.endpoint) }
                        if profile.adapter != .unconfigured {
                            HStack {
                                Text(L("Endpoint must match your key's region or workspace.")).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(L("Use model endpoint")) { profile.endpoint = ModelCatalog.endpoint(profile.endpoint, for: profile.adapter) }
                            }
                        }
                        LabeledContent(L("Bailian API key")) {
                            SingleLineField(L("Bailian API key"), text: $keyDraft.replacement, secure: true,
                                            placeholder: keyDraft.showsSavedKey ? "••••••••••••" : nil)
                        }
                    }.textFieldStyle(.roundedBorder)
                    if keyDraft.hasSavedKey {
                        HStack {
                            Text(keyDraft.removeSavedKey && keyDraft.credentialUpdate == ""
                                 ? L("The saved API key will be removed when you save.")
                                 : (keyDraft.credentialUpdate == nil
                                    ? L("API key saved on this Mac. Enter a new key to replace it.")
                                    : L("The new API key will replace the saved key when you save.")))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(keyDraft.removeSavedKey ? L("Keep saved key") : L("Remove saved key")) {
                                keyDraft.removeSavedKey.toggle()
                                keyDraft.replacement = ""
                            }.disabled(testing)
                        }
                    }
                    if profile.role == .speech { VocabularyProjectionView(vocabulary: state.settings.vocabulary, profile: profile) }
                    Text(L("Advanced model parameters (JSON)")).font(.headline)
                    if profile.adapter == .qwenMessageWebSocket || profile.adapter == .qwenAudioHTTP {
                        Text(L("Optional parameters for the selected model, such as language_hints. Selecting a different protocol resets this JSON."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextEditor(text: $profile.extraJSON).font(.system(size: 12, design: .monospaced)).frame(height: 85).border(.gray.opacity(0.2))
                    Text(L("API keys are stored in this Mac's Keychain and encrypted before sync. The endpoint must match the API key's region.")).font(.caption).foregroundStyle(.secondary)
                }.padding(.trailing, 4)
            }.frame(maxHeight: 560).disabled(testing)
            if !problem.isEmpty { Text(problem).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if state.settings.profiles.contains(where: { $0.id == profile.id }),
                   state.settings.speechID != profile.id && state.settings.writingID != profile.id {
                    Button(L("Delete profile"), role: .destructive) {
                        var copy = state.settings; copy.profiles.removeAll { $0.id == profile.id }; state.save(copy); dismiss()
                    }
                }
                Spacer()
                if profile.role == .writing {
                    Button(testing ? L("Testing…") : L("Test connection")) {
                        testing = true; problem = ""
                        Task {
                            defer { testing = false }
                            do {
                                let key = try keyDraft.keyForRequest { try state.key(for: profile) }
                                let request = try QwenRequests.writing(profile: profile, key: key, text: "Reply with OK.", mode: .ask, settings: SharedSettings())
                                _ = try await HTTPTransport().complete(request); problem = L("Connection successful.")
                            } catch { problem = error.localizedDescription }
                        }
                    }.disabled(testing)
                }
                Button(L("Cancel")) { dismiss() }
                Button(L("Save profile")) {
                    var copy = state.settings
                    if let i = copy.profiles.firstIndex(where: { $0.id == profile.id }) { copy.profiles[i] = profile }
                    else { copy.profiles.append(profile) }
                    do {
                        try profile.validateForInference()
                        try copy.validate(); state.error = ""
                        state.save(copy, credential: keyDraft.credentialUpdate.map { (profile.id, $0) })
                        if state.error.isEmpty { dismiss() } else { problem = L(state.error) }
                    } catch { problem = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(testing)
            }
        }.padding(28).frame(width: 680).onAppear {
            profile = profile.normalizedInput
            do { keyDraft = APIKeyDraft(hasSavedKey: try state.hasKey(for: profile)) }
            catch { problem = L("\(error.localizedDescription) The existing key will be kept unless you enter a replacement.") }
        }
    }

    private var modelChoice: Binding<String> {
        Binding(get: { profile.role == .writing && profile.catalogModel == nil ? "__custom" : profile.model },
                set: { profile.selectModel($0 == "__custom" ? "" : $0) })
    }

}

struct VocabularyProjectionView: View {
    @Environment(\.locale) private var interfaceLocale
    let vocabulary: AppVocabulary
    let profile: ModelProfile
    var body: some View {
        let _ = interfaceLocale
        let projection = VocabularyProjection.make(vocabulary, for: profile.vocabularyCapability)
        VStack(alignment: .leading, spacing: 8) {
            Text(L("App vocabulary → \(profile.model)")).font(.headline)
            Text(L("Manage all terms in Vocabulary. Changing the model only changes the format sent to it.")).font(.caption)
            if !vocabulary.enabled {
                Text(L("App vocabulary is turned off."))
            } else {
                switch profile.vocabularyCapability {
                case .weighted:
                    Text(L("\(projection.terms.count) terms ready. Strength 0–100 maps to weights 1–5; the first 50 priority terms use weight 50."))
                case .context:
                    Text(L("\(projection.terms.count) terms ready as context. This model does not support numeric weights or priority boosts."))
                case .none:
                    Text(L("This model has no supported vocabulary adapter."))
                }
                if projection.omitted > 0 {
                    Text(L("\(projection.omitted) terms exceed this adapter's length or count limits and will be omitted. The app vocabulary is unchanged.")).foregroundStyle(.orange)
                }
                if projection.downgradedPriority > 0 {
                    Text(L("\(projection.downgradedPriority) priority terms will use regular weight 5 because this model's priority limit is 50.")).foregroundStyle(.orange)
                }
                if projection.hasUnsupportedMetadata {
                    Text(L("Language tags, aliases, preferred spelling, and pronunciation are retained in the app vocabulary. This ASR adapter sends only terms and supported weights."))
                }
            }
            if !vocabulary.legacyReferences.isEmpty {
                Text(L("A previous remote vocabulary reference was preserved. Import its terms into the app vocabulary before using them.")).foregroundStyle(.orange)
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

struct VocabularyView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var state: AppState
    @State private var vocabulary = AppVocabulary()
    @State private var style = ""
    @State private var language = ""
    @State private var words = ""
    @State private var query = ""
    @State private var editing: VocabularyEntry?
    @State private var loaded = false
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: L("Sounds like you."), detail: L("One app vocabulary for every model. Keep rich term data here; each adapter sends the fields it supports."))
            Card {
                Toggle(L("Enable app vocabulary"), isOn: $vocabulary.enabled).font(.headline)
                Text(L("Strength, priority, language, aliases, spelling, and pronunciation belong to the app. Unsupported fields remain saved when you switch models.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    SingleLineField(L("Search vocabulary"), text: $query)
                    Button(L("Add term")) { editing = VocabularyEntry() }
                }
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach($vocabulary.entries) { $entry in
                        if query.isEmpty || entry.text.localizedCaseInsensitiveContains(query) {
                            HStack {
                                Toggle(entry.text, isOn: $entry.enabled)
                                Spacer()
                                if entry.priority { Image(systemName: "star.fill").foregroundStyle(.orange).help(L("Priority term")) }
                                Text(L("Strength \(entry.boost)")).font(.caption).foregroundStyle(.secondary)
                                Button(L("Edit")) { editing = entry }
                                Button(role: .destructive) { vocabulary.entries.removeAll { $0.id == entry.id } } label: {
                                    Image(systemName: "trash")
                                }.help(L("Delete term"))
                            }
                        }
                    }
                }
                if vocabulary.entries.isEmpty { Text(L("Add names, products, or phrases you often say.")).foregroundStyle(.secondary) }
                DisclosureGroup(L("Add several terms")) {
                    VStack(alignment: .leading) {
                        Text(L("One word or phrase per line. Existing terms are kept.")).font(.caption)
                        TextEditor(text: $words).frame(height: 90)
                        Button(L("Add to vocabulary")) { vocabulary.appendLines(words); words = "" }
                    }
                }
                Text(L("Save preferences below to apply your changes.")).font(.caption).foregroundStyle(.secondary)
            }
            if let speech = state.settings.speech { Card { VocabularyProjectionView(vocabulary: vocabulary, profile: speech) } }
            if !vocabulary.legacyReferences.isEmpty {
                Card {
                    Text(L("Previous remote vocabularies")).font(.headline)
                    Text(L("These references are kept for recovery. Their contents are not sent until you import the terms here.")).font(.caption)
                    ForEach(vocabulary.legacyReferences.indices, id: \.self) { index in
                        let reference = vocabulary.legacyReferences[index]
                        Text("\(reference.model) · \(reference.resourceID)").textSelection(.enabled)
                    }
                }
            }
            Card {
                Text(L("Your writing style")).font(.headline)
                TextEditor(text: $style).font(.body).frame(height: 85).scrollContentBackground(.hidden)
                SingleLineField(L("Translation target language"), text: $language)
            }
            HStack {
                Text(L("Vocabulary and preferences are included in encrypted sync.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Save preferences")) {
                    var copy = state.settings; copy.vocabulary = vocabulary; copy.stylePrompt = style; copy.targetLanguage = language
                    state.save(copy)
                }.buttonStyle(.borderedProminent)
            }
        }.onAppear { if !loaded { load(); loaded = true } }
            .onChange(of: state.settings) { _ in load() }
            .sheet(item: $editing) { entry in
                VocabularyEntryEditor(entry: entry) { value in
                    if let index = vocabulary.entries.firstIndex(where: { $0.id == value.id }) { vocabulary.entries[index] = value }
                    else { vocabulary.entries.append(value) }
                }
            }
    }
    private func load() { vocabulary = state.settings.vocabulary; style = state.settings.stylePrompt; language = state.settings.targetLanguage }
}

struct VocabularyEntryEditor: View {
    @Environment(\.locale) private var interfaceLocale
    @State var entry: VocabularyEntry
    var save: (VocabularyEntry) -> Void
    var saveError: () -> String? = { nil }
    @State private var aliases = ""
    @State private var problem = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Vocabulary term")).font(.title2)
            Form {
                LabeledContent(L("Word or phrase")) { SingleLineField(L("Word or phrase"), text: $entry.text) }
                Toggle(L("Enabled"), isOn: $entry.enabled)
                HStack {
                    Text(L("Strength \(entry.boost)"))
                    Slider(value: Binding(get: { Double(entry.boost) }, set: { entry.boost = Int($0) }), in: 0...100, step: 1)
                }
                Toggle(L("Priority term"), isOn: $entry.priority)
                LabeledContent(L("Language code (optional)")) { SingleLineField(L("e.g. zh-CN or en-US"), text: $entry.language) }
                LabeledContent(L("Preferred spelling (optional)")) { SingleLineField(L("Preferred spelling"), text: $entry.displayAs) }
                LabeledContent(L("Pronunciation (IPA, optional)")) { SingleLineField(L("IPA pronunciation"), text: $entry.pronunciation) }
            }
            Text(L("Spoken aliases · one per line")).font(.headline)
            TextEditor(text: $aliases).frame(height: 75)
            Text(L("Current Qwen ASR adapters use the term and supported strength only. Other fields are kept for compatible adapters; spelling and aliases also guide the writing model.")).font(.caption).foregroundStyle(.secondary)
            if !problem.isEmpty { Text(problem).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Done")) {
                    entry.aliases = aliases.split(whereSeparator: \.isNewline).map(String.init)
                    let value = entry.normalized
                    do {
                        try value.validate(); save(value)
                        if let error = saveError() { problem = error } else { dismiss() }
                    }
                    catch { problem = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 620).onAppear { aliases = entry.aliases.joined(separator: "\n") }
    }
}

struct SyncView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var state: AppState
    @State private var url = ""
    @State private var token = ""
    @State private var passphrase = ""
    @State private var automatic = false
    @State private var confirmDownload = false
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: L("One setup. Every device."), detail: L("Your models, API keys, vocabulary, and writing preferences travel together. Only you hold the decryption passphrase."))
            Card {
                Label(L("End-to-end encrypted"), systemImage: "lock.shield").font(.headline).foregroundStyle(accent)
                Text(L("The server stores an encrypted configuration vault. Recordings and dictation history stay on this Mac. Model calls go directly to your configured Bailian endpoint."))
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(5)
            }
            Card {
                SingleLineField(L("Sync server URL"), text: $url)
                SingleLineField(L("Server access token"), text: $token, secure: true)
                SingleLineField(L("Sync passphrase · at least 12 characters"), text: $passphrase, secure: true)
                Text(L("Use the same three values on each device. The passphrase is never sent to the server; losing it means the server copy cannot be recovered.")).font(.caption).foregroundStyle(.secondary)
                Toggle(L("Sync automatically every 30 seconds and after saving"), isOn: $automatic)
                HStack {
                    Button(L("Save connection")) { state.configureSync(url: url, token: token, passphrase: passphrase, automatic: automatic) }
                    Spacer()
                    Button(L("Download server copy…")) { confirmDownload = true }.disabled(state.syncing || state.busy)
                    Button(state.syncing ? L("Syncing…") : L("Sync now")) { Task { await state.sync() } }
                        .buttonStyle(.borderedProminent).disabled(state.syncing || state.busy)
                }
            }.textFieldStyle(.roundedBorder)
            Card {
                Text(L(state.syncStatus)).font(.callout).textSelection(.enabled)
                Text(L("First Mac: save the connection, then Sync now.\nNew device: save the connection, then Download server copy.\nIf both devices have changes, sync pauses instead of overwriting either copy."))
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(5)
            }
        }.onAppear {
            url = state.device.serverURL; automatic = state.device.autoSync
            do { token = try state.syncToken(); passphrase = try state.syncPassphrase() } catch { state.error = .init(error: error) }
        }.confirmationDialog(L("Replace this Mac's model settings and vocabulary with the server copy?"), isPresented: $confirmDownload, titleVisibility: .visible) {
            Button(L("Download and replace")) { Task { await state.sync(download: true) } }
        } message: { Text(L("Local history is kept. Current model settings are backed up on this Mac before replacement.")) }
    }
}

struct HistoryView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var state: AppState
    @State private var query = ""
    @State private var confirmClear = false
    private var entries: [HistoryEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.history.filter { term.isEmpty || $0.result.localizedCaseInsensitiveContains(term) || $0.original.localizedCaseInsensitiveContains(term) }
    }
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: L("A thought worth keeping."), detail: L("Your last 500 entries, saved only on this Mac. Audio is deleted after each recording is read."))
            HStack {
                SingleLineField(L("Search your words"), text: $query)
                Button(L("Clear history…"), role: .destructive) { confirmClear = true }.disabled(state.history.isEmpty)
            }
            Toggle(L("Save future transcripts on this Mac"), isOn: Binding(get: { state.device.keepHistory }, set: { state.saveDevice(autoPaste: state.device.autoPaste, history: $0) }))
            if entries.isEmpty {
                Card {
                    Image(systemName: "text.alignleft").font(.largeTitle).foregroundStyle(accent.opacity(0.5))
                    Text(L("Your words will find a home here.")).font(.headline)
                    Text(L("Record your first thought in Studio, or use the shortcut in any app.")).font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 20)
            }
            ForEach(entries) { entry in
                Card {
                    HStack {
                        Label(entry.mode.title, systemImage: entry.mode.icon).font(.caption.weight(.semibold)).foregroundStyle(accent)
                        Text("· \(entry.application)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(L10n.locale))).font(.caption).foregroundStyle(.secondary)
                        Button { state.copyResult(entry.result) } label: { Image(systemName: "doc.on.doc") }.help(L("Copy"))
                        Button(role: .destructive) { state.deleteHistory(entry.id) } label: { Image(systemName: "trash") }.help(L("Delete history entry"))
                    }
                    Text(entry.result).font(.body).textSelection(.enabled).lineSpacing(4)
                    if entry.original != entry.result {
                        DisclosureGroup(L("Original transcript")) { Text(entry.original).font(.caption).textSelection(.enabled) }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.confirmationDialog(L("Delete all local history?"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("Delete history"), role: .destructive) { state.deleteHistory() }
        }
    }
}

struct RecordingHUD: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var state: AppState
    var body: some View {
        let _ = interfaceLocale
        HStack(spacing: 14) {
            Image(systemName: state.recording ? "waveform" : "sparkles").foregroundStyle(state.recording ? .orange : .green)
            VStack(alignment: .leading, spacing: 3) {
                Text(L(state.status)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if state.busy {
                    Text(state.recordingDeviceName.isEmpty ? L("Preparing audio input…") : L("Input: \(state.recordingDeviceName)"))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.middle)
                        .help(state.recordingDeviceName)
                }
                if state.recording { ProgressView(value: state.level).frame(width: 180).tint(.orange) }
            }
            Spacer()
            if state.recording {
                Text(String(format: "%02d:%02d", Int(state.elapsed) / 60, Int(state.elapsed) % 60)).font(.system(size: 11, design: .monospaced))
                Button { state.finish() } label: { Image(systemName: "stop.fill") }.buttonStyle(.plain).help(L("Stop recording"))
            }
            if state.busy { Button { state.cancel() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L("Cancel")) }
        }.padding(18).frame(width: 480).foregroundStyle(.white)
            .background(Color(red: 0.12, green: 0.16, blue: 0.14), in: RoundedRectangle(cornerRadius: 18))
            .preferredColorScheme(.dark)
    }
}
