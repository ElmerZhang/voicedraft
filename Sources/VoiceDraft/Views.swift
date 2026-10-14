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
                    Text(F("Your models\nEncrypted configuration sync", "自选模型\n加密配置同步"))
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
                        Text(state.recording ? String(format: L("%02d:%02d · tap to finish"), Int(state.elapsed) / 60, Int(state.elapsed) % 60) : state.shortcutLabel(.dictate) + " · " + F("Hold to talk / tap to lock", "按住说话 / 轻按锁定"))
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
                    TextEditor(text: Binding(get: { state.result }, set: { state.editResult($0) })).font(.system(size: 14)).frame(minHeight: 150).scrollContentBackground(.hidden)
                    if !state.vocabularyLearningStatus.isEmpty {
                        Text(state.vocabularyLearningStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(state.mode == .translate ? L("Translation target: \(state.settings.targetLanguage)") : L("Your wording, with a little more clarity.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L("Make room for your voice")).font(.headline)
                        Text(state.insertionAuthorized
                             ? L("Allow Accessibility for insertion. Microphone permission is requested when you record.")
                             : L("Enable Accessibility to paste into other apps. The result is available here."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Allow Accessibility")) { TextInsertion.requestAccess() }
                }
                Toggle(L("Insert into the original app after recording"), isOn: Binding(get: { state.device.autoPaste }, set: { state.saveDevice(autoPaste: $0, history: state.device.keepHistory) }))
                Text(state.shortcutLabel(.translate) + "  " + L("Translate") + "    " + state.shortcutLabel(.edit) + "  " + L("Edit selection") + "    " + state.shortcutLabel(.ask) + "  " + L("Ask")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
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
    var showsHeading = true
    @State private var editing: ModelProfile?
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: VD.Space.xl) {
            if showsHeading {
                PageHeading(title: L("Choose how you think."), detail: F("Choose speech and writing services using your own credentials.", "使用自己的凭证，独立选择语音识别与写作服务。"))
            }
            ForEach(ModelRole.allCases) { role in
                let profiles = state.settings.profiles.filter { $0.role == role }
                VStack(alignment: .leading, spacing: VD.Space.m) {
                    HStack(alignment: .center) {
                        Label(role.title, systemImage: icon(role)).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { editing = ModelProfile.qwen(role) } label: { Label(L("Add profile"), systemImage: "plus") }
                            .buttonStyle(.vdPillSecondary)
                    }
                    if profiles.isEmpty {
                        VDSurface(style: .shaded, padding: 0) {
                            VDEmptyState(icon: icon(role), title: D("No profiles yet"), detail: D("Add a profile to connect your own provider."))
                        }
                    }
                    ForEach(profiles) { profile in card(profile, role: role) }
                }
            }
            Text(D("Choose a supported model first. Message models show live text while you speak; HTTP models recognize after you finish. Your vocabulary is adapted to the selected model."))
                .font(VD.Font.detail).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.sheet(item: $editing) { profile in ProfileEditor(state: state, profile: profile) }
    }

    private func icon(_ role: ModelRole) -> String { role == .speech ? "waveform" : "sparkles" }

    private func card(_ profile: ModelProfile, role: ModelRole) -> some View {
        VDSurface(padding: VD.Space.l, spacing: VD.Space.m) {
            HStack(alignment: .center, spacing: VD.Space.m) {
                Image(systemName: icon(role)).font(.system(size: 16, weight: .medium)).foregroundStyle(VD.Palette.accent)
                    .frame(width: 36, height: 36)
                    .background(VD.Palette.accentSoft, in: RoundedRectangle(cornerRadius: VD.Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: VD.Space.xs) {
                    Text(profile.name).font(VD.Font.cardTitle).lineLimit(1)
                    Text(profile.model).font(VD.Font.mono).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: VD.Space.m)
                if profile.id == state.settings.speechID || profile.id == state.settings.writingID {
                    VDBadge(text: D("Active"))
                } else {
                    Button(L("Use")) {
                        var copy = state.settings
                        if role == .speech { copy.speechID = profile.id } else { copy.writingID = profile.id }
                        state.save(copy)
                    }.buttonStyle(.bordered)
                }
                Button(L("Edit")) { editing = profile }.buttonStyle(.bordered)
            }
            Text("\(profile.adapter.title) · \(profile.endpoint)").font(VD.Font.footnote).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

struct ProfileEditor: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var state: AppState
    @State var profile: ModelProfile
    @State private var keyDraft = APIKeyDraft(hasSavedKey: false)
    @State private var problem = ""
    @State private var testing = false
    @State private var discoveredModels: [String] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: VD.Space.l) {
            Text(profile.role.title).font(VD.Font.sheetTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Form {
                        Picker(F("Protocol", "服务接口"), selection: Binding(get: { profile.adapter }, set: { adapter in
                            profile.adapter = adapter; discoveredModels = []; profile.extraJSON = "{}"
                            switch adapter {
                            case .whisper: profile.endpoint = "https://api.openai.com/v1/audio/transcriptions"; profile.model = "whisper-1"
                            case .doubao: profile.endpoint = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"; profile.model = "bigmodel"
                            case .googleSpeech: profile.endpoint = "https://speech.googleapis.com/v2/projects/PROJECT/locations/global/recognizers/_:recognize"; profile.model = "chirp_3"
                            case .chatCompletions: profile.endpoint = "https://api.openai.com/v1/chat/completions"; profile.model = ""
                            case .responses: profile.endpoint = "https://api.openai.com/v1/responses"; profile.model = ""
                            case .anthropic: profile.endpoint = "https://api.anthropic.com/v1/messages"; profile.model = ""
                            default:
                                if let model = ModelCatalog.models.first(where: { $0.adapter == adapter }) {
                                    profile.model = model.id; profile.endpoint = "https://dashscope.aliyuncs.com" + adapter.path
                                    if adapter.isWebSocket { profile.endpoint = "wss://dashscope.aliyuncs.com" + adapter.path }
                                }
                            }
                        })) {
                            ForEach(ModelAdapter.allCases.filter { $0 != .unconfigured && $0.isWriting == (profile.role == .writing) }, id: \.self) { adapter in Text(adapter.title).tag(adapter) }
                        }
                        if !profile.adapter.isGeneric {
                            Picker(L("Model"), selection: modelChoice) {
                                ForEach(ModelCatalog.models(for: profile.role)) { model in Text(model.id).tag(model.id) }
                                if profile.role == .writing { Text(L("Other Qwen text model…")).tag("__custom") }
                            }
                        }
                        if profile.adapter.isGeneric || (profile.role == .writing && profile.catalogModel == nil) {
                            LabeledContent(L("Model ID")) { SingleLineField(L("Model ID"), text: $profile.model) }
                        }
                        if !profile.adapter.isWebSocket && profile.adapter != .googleSpeech {
                            HStack {
                                Button(F("Fetch model list", "在线获取模型列表")) {
                                    testing = true; problem = ""
                                    Task {
                                        defer { testing = false }
                                        do { discoveredModels = try await ModelDiscovery.fetch(profile: profile, key: keyDraft.keyForRequest { try state.key(for: profile) }) }
                                        catch { problem = error.localizedDescription }
                                    }
                                }
                                if !discoveredModels.isEmpty {
                                    Menu(F("Choose fetched model", "选择在线模型")) {
                                        ForEach(discoveredModels, id: \.self) { id in Button(id) {
                                            if profile.adapter.isGeneric { profile.model = id } else { profile.selectModel(id) }
                                        } }
                                    }
                                }
                            }
                        }
                        LabeledContent(L("Connection")) { Text(profile.adapter.title).foregroundStyle(.secondary) }
                        LabeledContent(L("Profile name")) { SingleLineField(L("Profile name"), text: $profile.name) }
                        LabeledContent(L("Full endpoint URL")) { SingleLineField(L("Full endpoint URL"), text: $profile.endpoint) }
                        if profile.adapter != .unconfigured {
                            HStack {
                                Text(L("Endpoint must match your key's region or workspace.")).font(VD.Font.detail).foregroundStyle(.secondary)
                                Spacer()
                                Button(L("Use model endpoint")) { profile.endpoint = ModelCatalog.endpoint(profile.endpoint, for: profile.adapter) }
                            }
                        }
                        LabeledContent(F("API key / credential", "API 密钥 / 凭证")) {
                            SingleLineField(F("API key / credential", "API 密钥 / 凭证"), text: $keyDraft.replacement, secure: true,
                                            placeholder: keyDraft.showsSavedKey ? "••••••••••••" : nil)
                        }
                    }.textFieldStyle(.roundedBorder)
                    if profile.adapter == .googleSpeech {
                        Text(F("Replace PROJECT in the endpoint with your Google Cloud project. Paste a service account JSON key or OAuth access token. Set languageCodes in advanced options, for example [\"en-US\"].", "将地址中的 PROJECT 替换为 Google Cloud 项目 ID。凭证可使用服务账号 JSON 密钥或 OAuth access token；在高级参数中设置 languageCodes，例如 [\"cmn-Hans-CN\"]。"))
                            .font(VD.Font.detail).foregroundStyle(.secondary)
                        Button(F("Import service account JSON", "导入服务账号 JSON")) {
                            let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url {
                                do {
                                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64_000 else { throw FeatureError("Credential file too large.") }
                                    keyDraft.replacement = try String(contentsOf: url, encoding: .utf8)
                                } catch { problem = error.localizedDescription }
                            }
                        }
                    }
                    if profile.adapter == .doubao {
                        Text(F("Use the new console API key. Legacy credentials: put app_id in advanced options and the access token in the credential field. Optional resource_id selects your purchased speech resource.", "新版控制台直接填写 API Key。旧版凭证可在高级参数中填写 app_id，密钥栏填写 Access Token；resource_id 可选择已开通的语音资源。"))
                            .font(VD.Font.detail).foregroundStyle(.secondary)
                    }
                    if keyDraft.hasSavedKey {
                        HStack {
                            Text(keyDraft.removeSavedKey && keyDraft.credentialUpdate == ""
                                 ? L("The saved API key will be removed when you save.")
                                 : (keyDraft.credentialUpdate == nil
                                    ? L("API key saved on this Mac. Enter a new key to replace it.")
                                    : L("The new API key will replace the saved key when you save.")))
                                .font(VD.Font.detail).foregroundStyle(.secondary)
                            Spacer()
                            Button(keyDraft.removeSavedKey ? L("Keep saved key") : L("Remove saved key")) {
                                keyDraft.removeSavedKey.toggle()
                                keyDraft.replacement = ""
                            }.disabled(testing)
                        }
                    }
                    if profile.role == .speech { VocabularyProjectionView(vocabulary: state.settings.vocabulary, profile: profile) }
                    Text(L("Advanced model parameters (JSON)")).font(VD.Font.body.weight(.semibold))
                    if profile.adapter == .qwenMessageWebSocket || profile.adapter == .qwenAudioHTTP {
                        Text(L("Optional parameters for the selected model, such as language_hints. Selecting a different protocol resets this JSON."))
                            .font(VD.Font.detail).foregroundStyle(.secondary)
                    }
                    TextEditor(text: $profile.extraJSON).font(VD.Font.mono).vdEditorBox(minHeight: 85)
                    Text(L("API keys are stored in this Mac's Keychain and encrypted before sync. The endpoint must match the API key's region.")).font(VD.Font.detail).foregroundStyle(.secondary)
                }.padding(.trailing, 4)
            }.frame(maxHeight: 560).disabled(testing)
            if !problem.isEmpty { VDInlineNotice(kind: problem == L("Connection successful.") ? .success : .error, text: problem) }
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
                                _ = try await WritingClient.complete(request, profile: profile, key: key); problem = L("Connection successful.")
                            } catch { problem = error.localizedDescription }
                        }
                    }.disabled(testing)
                }
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
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
        }.vdSheet(width: 680).onAppear {
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
                    Text(F("Manual terms take priority. Automatically learned terms are capped at weight 2 and do not use the priority boost.", "手动词条优先。自动学习词条的权重最高为 2，不使用优先词加权。"))
                        .font(.caption).foregroundStyle(.secondary)
                case .context:
                    Text(L("\(projection.terms.count) terms ready as context. This model does not support numeric weights or priority boosts."))
                case .none:
                    Text(L("This model has no supported vocabulary adapter."))
                }
                if projection.omitted > 0 {
                    Text(L("\(projection.omitted) terms exceed this adapter's length or count limits and will be omitted. The app vocabulary is unchanged.")).foregroundStyle(.orange)
                }
                if projection.shadowedAutomatic > 0 {
                    Text(F("\(projection.shadowedAutomatic) automatic terms are superseded by your manual spellings.", "\(projection.shadowedAutomatic) 个自动词条已由你的手动拼写覆盖。"))
                        .font(.caption).foregroundStyle(.secondary)
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
                Toggle(D("Learn from corrections"), isOn: $vocabulary.learnFromCorrections)
                Toggle(D("Discover words from dictation"), isOn: $vocabulary.discoverFromDictation)
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
                                Button(role: .destructive) { vocabulary.removeEntry(entry.id) } label: {
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
        VStack(alignment: .leading, spacing: VD.Space.l) {
            VStack(alignment: .leading, spacing: VD.Space.xs) {
                Text(L("Vocabulary term")).font(VD.Font.sheetTitle)
                Label(entry.origin == .automatic ? D("Auto-added") : D("Manually-added"), systemImage: entry.origin == .automatic ? "sparkle" : "leaf.fill")
                    .font(VD.Font.detail).foregroundStyle(.secondary)
            }
            if entry.origin == .automatic {
                Text(F("Automatic terms have lower priority than manual spellings. Saving here confirms this spelling as a manual term.", "自动词条的优先级低于手动拼写。在此保存后，此拼写将确认为手动词条。"))
                    .font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
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
            VStack(alignment: .leading, spacing: VD.Space.s) {
                Text(L("Spoken aliases · one per line")).font(VD.Font.body.weight(.semibold))
                TextEditor(text: $aliases).font(VD.Font.body).vdEditorBox(minHeight: 75)
            }
            Text(D("Speech models use the word and, where supported, its strength. Other fields are kept for models that support them; spelling and aliases also guide the writing model."))
                .font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !problem.isEmpty { VDInlineNotice(kind: .error, text: problem) }
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Done")) {
                    entry.aliases = aliases.split(whereSeparator: \.isNewline).map(String.init)
                    entry.origin = .manual
                    let value = entry.normalized
                    do {
                        try value.validate(); save(value)
                        if let error = saveError() { problem = error } else { dismiss() }
                    }
                    catch { problem = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.vdSheet(width: 620).onAppear { aliases = entry.aliases.joined(separator: "\n") }
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
    var showsHeading = true
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: VD.Space.l) {
            if showsHeading {
                PageHeading(title: L("One setup. Every device."), detail: L("Your models, API keys, vocabulary, and writing preferences travel together. Only you hold the decryption passphrase."))
            }
            VDSurface {
                field(L("Sync server URL")) { SingleLineField(L("Sync server URL"), text: $url, placeholder: "https://") }
                field(L("Server access token")) { SingleLineField(L("Server access token"), text: $token, secure: true) }
                field(D("Sync passphrase")) {
                    SingleLineField(D("Sync passphrase"), text: $passphrase, secure: true, placeholder: L("Sync passphrase · at least 12 characters"))
                }
                Text(L("Use the same three values on each device. The passphrase is never sent to the server; losing it means the server copy cannot be recovered."))
                    .font(VD.Font.detail).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                Divider()
                VDSettingRow(title: L("Sync automatically every 30 seconds and after saving")) {
                    Toggle(L("Sync automatically every 30 seconds and after saving"), isOn: $automatic).labelsHidden().toggleStyle(.switch)
                }
                HStack {
                    Button(L("Save connection")) { state.configureSync(url: url, token: token, passphrase: passphrase, automatic: automatic) }
                    Spacer()
                    Button(L("Download server copy…")) { confirmDownload = true }.disabled(state.syncing || state.busy)
                    Button(state.syncing ? L("Syncing…") : L("Sync now")) { Task { await state.sync() } }
                        .buttonStyle(.borderedProminent).disabled(state.syncing || state.busy)
                }
            }
            VDSurface(style: .shaded, spacing: VD.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: VD.Space.s) {
                    Circle().fill(statusTint).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(L(state.syncStatus)).font(VD.Font.cardTitle).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if state.syncing { ProgressView().controlSize(.small) }
                }
                Text(L("First Mac: save the connection, then Sync now.\nNew device: save the connection, then Download server copy.\nIf both devices have changes, sync pauses instead of overwriting either copy."))
                    .font(VD.Font.detail).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            VDSurface(style: .shaded, spacing: VD.Space.s) {
                HStack(spacing: VD.Space.s) {
                    Image(systemName: "lock.shield").font(.system(size: 15, weight: .semibold)).foregroundStyle(VD.Palette.accent)
                    Text(L("End-to-end encrypted")).font(VD.Font.cardTitle)
                }
                Text(F("The sync server stores encrypted settings. Model calls go directly to your configured providers; history and retained audio stay on this Mac.", "同步服务器只保存加密配置。模型调用直接发送到你配置的服务商；历史和保留的录音留在本机。"))
                    .font(VD.Font.detail).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }.onAppear {
            url = state.device.serverURL; automatic = state.device.autoSync
            do { token = try state.syncToken(); passphrase = try state.syncPassphrase() } catch { state.error = .init(error: error) }
        }.confirmationDialog(L("Replace this Mac's model settings and vocabulary with the server copy?"), isPresented: $confirmDownload, titleVisibility: .visible) {
            Button(L("Download and replace")) { Task { await state.sync(download: true) } }
        } message: { Text(L("Local history is kept. Current model settings are backed up on this Mac before replacement.")) }
    }

    private func field<Field: View>(_ label: String, @ViewBuilder _ content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .medium))
            content()
        }
    }

    /// Derived from the status message only: connected/synced, not connected, or anything that needs attention.
    private var statusTint: Color {
        let key = state.syncStatus.key
        if state.device.serverURL.isEmpty || key == "Not connected" { return Color.secondary }
        if key.hasPrefix("Synced") || key.hasPrefix("Connection saved") { return VD.Palette.success }
        return VD.Palette.warning
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
            PageHeading(title: L("A thought worth keeping."), detail: F("History and optional recordings, saved only on this Mac.", "历史与可选保留的录音，只存储在本机。"))
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
