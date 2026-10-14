import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers
import VoiceDraftCore

func F(_ english: String, _ chinese: String) -> String {
    let code = L10n.resolved(L10n.language)
    if code == "zh-Hant" { return chinese.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? chinese }
    return code == "zh-Hans" ? chinese : english
}

extension ShortcutAction {
    var title: String {
        switch self {
        case .dictate: return F("Dictate", "听写")
        case .translate: return L("Translate")
        case .edit: return L("Edit selection")
        case .ask: return L("Ask")
        case .styleSelection: return F("Apply style to selection", "为选中文字应用风格")
        }
    }
}

struct ShortcutPreferences: View {
    @ObservedObject var state: AppState
    @State private var capturing: ShortcutAction?
    @State private var monitor: Any?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(F("Hold to talk. Release to finish. Tap briefly to lock recording, then tap again to finish.", "按住说话，松开结束；轻按后锁定录音，再按一次结束。启动麦克风时松开也会保留你的操作。"))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(state.device.features.shortcuts) { binding in
                HStack {
                    Toggle(binding.action.title, isOn: Binding(get: { binding.enabled }, set: { value in change(binding) { $0.enabled = value } }))
                    Spacer()
                    Button(capturing == binding.action ? F("Press shortcut… (Esc cancels)", "按下快捷键…（Esc 取消）") : binding.label) { begin(binding.action) }
                        .frame(minWidth: 180)
                    Button("Fn") { change(binding) { $0.keyCode = 63; $0.modifiers = 0 } }.help(F("Fn requires Accessibility", "单独使用 Fn 需要辅助功能权限"))
                }
            }
            Button(F("Restore default shortcuts", "恢复默认快捷键")) {
                end(); var options = state.device.features; options.shortcuts = ShortcutBinding.defaults; state.saveFeatures(options)
            }
        }.disabled(state.busy).onDisappear { end() }
    }
    private func change(_ binding: ShortcutBinding, update: (inout ShortcutBinding) -> Void) {
        end(); var options = state.device.features
        if let i = options.shortcuts.firstIndex(where: { $0.action == binding.action }) { update(&options.shortcuts[i]) }
        state.saveFeatures(options)
    }
    private func begin(_ action: ShortcutAction) {
        end()
        do { try state.configureShortcuts?([]) }
        catch { state.error = .init(error: error); return }
        capturing = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown && event.keyCode == 53 { end(); return nil }
            if event.type == .flagsChanged && event.keyCode != 63 { return event }
            guard event.type == .keyDown || event.modifierFlags.contains(.function), !event.isARepeat else { return nil }
            var options = state.device.features
            if let i = options.shortcuts.firstIndex(where: { $0.action == action }) {
                var modifiers: UInt32 = 0
                for (flag, bit) in [(NSEvent.ModifierFlags.shift, UInt32(1)), (.control, 2), (.option, 4), (.command, 8)] where event.modifierFlags.contains(flag) { modifiers |= bit }
                options.shortcuts[i].keyCode = UInt32(event.keyCode); options.shortcuts[i].modifiers = modifiers
                options.shortcuts[i].enabled = true
            }
            end(); state.saveFeatures(options); return nil
        }
    }
    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if capturing != nil { try? state.configureShortcuts?(state.device.features.shortcuts) }; capturing = nil
    }
}

struct RecordingPreferences: View {
    @ObservedObject var state: AppState
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var confirmRetention = false
    @State private var proposedDays = 0
    private func option(_ key: WritableKeyPath<DesktopOptions, Bool>) -> Binding<Bool> {
        Binding(get: { state.device.features[keyPath: key] }, set: { value in
            var options = state.device.features; options[keyPath: key] = value; state.saveFeatures(options)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(F("Recording · up to 10 minutes", "录音 · 最长 10 分钟")).font(.headline)
            Toggle(F("Play recording sounds", "播放录音提示音"), isOn: option(\.sounds))
            Toggle(F("Mute system output while recording", "录音时静音系统声音"), isOn: option(\.muteOutput))
            Divider()
            Toggle(F("Keep recordings with history", "在历史中保留录音"), isOn: option(\.retainAudio)).disabled(!state.device.keepHistory)
            Text(F("Audio stays on this Mac and is excluded from configuration sync. Turning this off affects future recordings; deleting history also deletes its audio.", "录音只保存在本机，不参与配置同步。关闭只影响之后的录音；删除历史时也会删除相应音频。"))
                .font(.caption).foregroundStyle(.secondary)
            Picker(F("History retention", "历史保留期限"), selection: Binding(get: { state.device.features.retentionDays }, set: { days in
                proposedDays = days
                if days == 0 { setRetention(days) } else { confirmRetention = true }
            })) {
                Text(F("Forever", "永久")).tag(0)
                ForEach([1,7,30,90], id: \.self) { days in Text("\(days) " + F("days", "天")).tag(days) }
            }
            Divider()
            Toggle(F("Use recent inputs as writing context", "用近期输入辅助写作"), isOn: option(\.recentContext))
            Text(F("Uses up to three recent VoiceDraft outputs from the same app, for 30 minutes. This context is sent to your writing model and cleared when VoiceDraft quits.", "使用同一应用最近 30 分钟的最多三条 VoiceDraft 输出作为上下文，发送给写作模型。退出后清空，不读取周围文档。"))
                .font(.caption).foregroundStyle(.secondary)
            Button(F("Clear recent context", "清空近期上下文")) { state.clearRecentContext() }
            Divider()
            Toggle(F("Launch at login", "登录 Mac 后启动"), isOn: Binding(get: { loginEnabled }, set: { enabled in
                guard !state.preview else { return }
                do {
                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    loginEnabled = SMAppService.mainApp.status == .enabled
                    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                } catch { state.error = .init(error: error) }
            }))
            Button(F("Open first-use guide", "打开首次使用引导")) { state.showingOnboarding = true }
        }.disabled(state.busy)
        .confirmationDialog(F("Delete history and audio older than this period?", "删除超过此期限的历史和录音？"), isPresented: $confirmRetention) {
            Button(F("Apply retention period", "应用保留期限"), role: .destructive) { setRetention(proposedDays) }
        }
    }
    private func setRetention(_ days: Int) { var options = state.device.features; options.retentionDays = days; state.saveFeatures(options) }
}

struct StyleLibraryView: View {
    @ObservedObject var state: AppState
    @State private var editing: WritingStyle?
    @State private var appID = ""
    @State private var assignedStyle = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(F("Writing styles", "写作风格库")).font(.headline)
            Picker(F("Default style", "默认使用风格"), selection: Binding(get: { state.settings.selectedStyleID?.uuidString ?? "" }, set: { id in
                var copy = state.settings; copy.selectedStyleID = UUID(uuidString: id); state.save(copy)
            })) {
                Text(F("General writing preferences", "下方通用写作偏好")).tag("")
                ForEach(state.settings.styles) { style in Text(style.name).tag(style.id.uuidString) }
            }
            ForEach(state.settings.styles) { style in
                HStack {
                    Text(style.name); Spacer()
                    Button(L("Edit")) { editing = style }
                    Button(L("Delete"), role: .destructive) {
                        var copy = state.settings; copy.styles.removeAll { $0.id == style.id }
                        copy.applicationStyles = copy.applicationStyles.filter { $0.value != style.id }
                        if copy.selectedStyleID == style.id { copy.selectedStyleID = nil }; state.save(copy)
                    }
                }
            }
            HStack {
                Button(F("New style", "新建风格")) { editing = WritingStyle(name: F("New style", "新风格"), prompt: "") }
                Menu(F("Add a preset", "添加预设")) {
                    Button(F("Casual", "日常自然")) { editing = WritingStyle(name: F("Casual", "日常自然"), prompt: "Use natural, conversational language. Preserve my voice and avoid formal phrasing.") }
                    Button(F("Professional", "工作沟通")) { editing = WritingStyle(name: F("Professional", "工作沟通"), prompt: "Use clear professional language. Keep sentences concise, polite and actionable. Preserve all facts.") }
                    Button(F("Bullet notes", "条目笔记")) { editing = WritingStyle(name: F("Bullet notes", "条目笔记"), prompt: "Organize the text into short bullet points. Preserve facts, conditions and action items without adding any information.") }
                }
            }
            Divider()
            Text(F("Choose a style automatically by app", "按应用自动切换风格")).font(.headline)
            ForEach(state.settings.applicationStyles.keys.sorted(), id: \.self) { bundle in
                HStack {
                    Text(bundle).font(.caption)
                    Spacer()
                    Text(state.settings.styles.first { $0.id == state.settings.applicationStyles[bundle] }?.name ?? "")
                    Button(L("Delete")) { var copy = state.settings; copy.applicationStyles.removeValue(forKey: bundle); state.save(copy) }
                }
            }
            HStack {
                TextField(F("App bundle ID", "应用标识，例如 com.apple.mail"), text: $appID)
                Menu(F("Running apps", "正在运行的应用")) {
                    ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier!) { appID = app.bundleIdentifier! }
                    }
                }
            }
            HStack {
                Picker(F("Style", "风格"), selection: $assignedStyle) {
                    Text(F("Select style", "选择风格")).tag("")
                    ForEach(state.settings.styles) { style in Text(style.name).tag(style.id.uuidString) }
                }
                Button(F("Assign", "绑定")) {
                    guard let id = UUID(uuidString: assignedStyle) else { return }
                    var copy = state.settings; copy.applicationStyles[appID.trimmingCharacters(in: .whitespaces)] = id; state.save(copy)
                }.disabled(appID.trimmingCharacters(in: .whitespaces).isEmpty || assignedStyle.isEmpty)
            }
            Text(F("Select text in another app and press the style shortcut to choose a style and replace the selection.", "在其他应用中选中文字，按风格快捷键，选择风格后直接替换选区。") + " " + state.shortcutLabel(.styleSelection))
                .font(.caption).foregroundStyle(.secondary)
        }.sheet(item: $editing) { value in StyleEditor(style: value) { style in
            var copy = state.settings
            if let i = copy.styles.firstIndex(where: { $0.id == style.id }) { copy.styles[i] = style } else { copy.styles.append(style) }
            state.save(copy)
            return state.error.isEmpty
        } }.disabled(state.busy)
    }
}

private struct StyleEditor: View {
    @State var style: WritingStyle
    let save: (WritingStyle) -> Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField(F("Style name", "风格名称"), text: $style.name)
            TextEditor(text: $style.prompt).frame(height: 220).border(.gray.opacity(0.3))
            HStack { Button(L("Cancel")) { dismiss() }; Spacer(); Button(L("Save")) { if save(style) { dismiss() } }.disabled(style.name.trimmingCharacters(in: .whitespaces).isEmpty || style.prompt.utf8.count > 20_000) }
        }.padding(24).frame(width: 560)
    }
}

struct VocabularyFileControls: View {
    @ObservedObject var state: AppState
    @State private var candidates: [VocabularyEntry] = []
    @State private var selected: Set<UUID> = []
    @State private var showPreview = false
    @State private var contextMode = false
    @State private var scanning = false
    @State private var scan: AgentContextScan?
    @State private var sources: [String: String] = [:]
    @State private var scanError = ""
    @State private var filtering = false
    @State private var filterSummary = ""
    @State private var rawCandidates: [AgentContextCandidate] = []
    @State private var scanAttempt = UUID()

    var body: some View {
        HStack {
            Button(F("Import vocabulary", "导入词库")) { importFile() }
            Button(F("Export vocabulary", "导出词库")) { exportFile() }
            Button(F("Extract from Codex / Claude context", "从 Codex / Claude 上下文提取")) {
                contextMode = true; scanning = true; scan = nil; scanError = ""
                filtering = false; filterSummary = ""; rawCandidates = []; scanAttempt = UUID()
                candidates = []; selected = []; sources = [:]; showPreview = true
            }
        }.sheet(isPresented: $showPreview) {
            VStack(alignment: .leading, spacing: 16) {
                Text(F("Review words to import", "选择要导入的词条")).font(.title2)
                Text(contextMode
                     ? F("Finds local Codex and Claude context automatically, then sends only candidate words to your writing model to filter out common terms. Review the shortlist before importing.", "自动查找本机 Codex 和 Claude 上下文，再将候选词交给你的写作模型筛除通用词。只发送候选词列表，最后由你勾选导入。")
                     : F("Review the vocabulary before importing. Only selected terms are added.", "检查词库内容，只添加勾选的词条。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if scanning {
                    HStack { ProgressView().controlSize(.small); Text(filtering ? F("Filtering with your writing model…", "正在用写作模型筛选…") : F("Finding local context…", "正在查找本机上下文…")) }
                } else if let scan {
                    Text(F("Context files read", "已读取上下文文件") + ": \(scan.filesRead) · " + (scan.sources.isEmpty ? "Codex / Claude" : scan.sources.map(\.rawValue).joined(separator: " / ")))
                        .font(.caption).foregroundStyle(.secondary)
                    if scan.limited { Text(F("Recent context was prioritized to keep the scan quick.", "已优先提取近期上下文，避免扫描时间过长。")).font(.caption).foregroundStyle(.secondary) }
                    if scan.unreadableFiles > 0 { Text(F("Some context files could not be read", "部分上下文文件无法读取") + ": \(scan.unreadableFiles)").font(.caption).foregroundStyle(.secondary) }
                }
                if !filterSummary.isEmpty { Text(filterSummary).font(.caption).foregroundStyle(.secondary) }
                if !scanError.isEmpty {
                    Text(scanError).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(F("Retry filtering", "重新筛选")) { scanning = true; scanError = ""; filterSummary = ""; candidates = []; selected = []; scanAttempt = UUID() }
                        if !rawCandidates.isEmpty {
                            Button(F("Review unfiltered words", "查看未筛选的词条")) {
                                present(rawCandidates)
                                scanError = ""; filterSummary = F("Unfiltered candidates — review carefully", "未经过模型筛选，请逐项检查")
                            }
                        }
                    }
                }
                HStack {
                    Button(F("Select all", "全选")) { selected = Set(candidates.map(\.id)) }
                    Button(F("Clear selection", "清空选择")) { selected.removeAll() }
                    Text("\(selected.count) / \(candidates.count)")
                }.disabled(scanning || candidates.isEmpty)
                if candidates.isEmpty {
                    Text(scanning ? (filtering ? F("Selecting useful names and specialist terms…", "正在保留有价值的名称和专门术语…") : F("Extracting candidate terms locally…", "正在本机提取候选词…"))
                         : !scanError.isEmpty ? F("Filtering did not finish. Retry or review the unfiltered list.", "筛选未完成，可以重试或查看未筛选的词条。")
                         : !filterSummary.isEmpty ? F("The model found no terms worth adding this time.", "这次没有筛选出值得加入词库的词条。")
                         : scan?.filesRead == 0
                         ? F("No readable Codex or Claude context was found in this account's home folder.", "在当前账户的用户目录中，没有找到可读取的 Codex 或 Claude 上下文。")
                         : F("No new candidate terms were found. Existing vocabulary words are excluded.", "没有找到新的候选词，词库中已有的词条已排除。"))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    List(candidates) { entry in
                        HStack {
                            Toggle(entry.text, isOn: Binding(get: { selected.contains(entry.id) }, set: { value in if value { selected.insert(entry.id) } else { selected.remove(entry.id) } }))
                            Spacer()
                            if let source = sources[entry.text] { Text(source).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.frame(height: 260)
                }
                HStack {
                    Button(L("Cancel")) { showPreview = false }; Spacer()
                    Button(F("Import selected words", "导入所选词条")) {
                        do {
                            var copy = state.settings
                            try VocabularyFile.merge(candidates.filter { selected.contains($0.id) }, into: &copy.vocabulary)
                            state.save(copy); if state.error.isEmpty { showPreview = false }
                        } catch { state.error = .init(error: error) }
                    }.disabled(scanning || selected.isEmpty)
                }
            }.padding(24).frame(width: 600)
                .task(id: scanAttempt) { await findAndFilter() }
        }
    }
    private func findAndFilter() async {
        guard contextMode else { return }
        do {
            let result = try await state.scanAgentContext()
            try Task.checkCancellation()
            scan = result
            let known = Set(state.settings.vocabulary.entries.flatMap { [$0.text, $0.displayAs] + $0.aliases }.map(AppVocabulary.automaticTermKey))
            let fresh = result.candidates.filter { !known.contains(AppVocabulary.automaticTermKey($0.text)) }
            rawCandidates = fresh
            if !fresh.isEmpty {
                filtering = true
                let filtered = try await state.filterAgentContext(fresh.map(\.text))
                try Task.checkCancellation()
                let byText = Dictionary(uniqueKeysWithValues: fresh.map { ($0.text, $0) })
                present(filtered.terms.compactMap { byText[$0] })
                filterSummary = F("Model selection", "模型筛选") + ": \(candidates.count) / \(fresh.count) · \(filtered.model)"
            }
            scanning = false; filtering = false
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            scanError = error.localizedDescription; scanning = false; filtering = false
        }
    }
    private func present(_ items: [AgentContextCandidate]) {
        let known = Set(state.settings.vocabulary.entries.flatMap { [$0.text, $0.displayAs] + $0.aliases }.map(AppVocabulary.automaticTermKey))
        let fresh = items.filter { !known.contains(AppVocabulary.automaticTermKey($0.text)) }
        candidates = fresh.map { VocabularyEntry(text: $0.text) }; selected = []
        sources = Dictionary(uniqueKeysWithValues: fresh.map { ($0.text, $0.sources.map(\.rawValue).joined(separator: " / ")) })
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20_000_000 else { throw FeatureError("The selected file is too large.") }
            candidates = try VocabularyFile.entries(Data(contentsOf: url))
            contextMode = false; scanning = false; filtering = false; filterSummary = ""; scan = nil; scanError = ""; sources = [:]
            selected = Set(candidates.map(\.id)); showPreview = true
        } catch { state.error = .init(error: error) }
    }
    private func exportFile() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "VoiceDraft-vocabulary.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try VocabularyFile.export(state.settings.vocabulary).write(to: url, options: .atomic) }
        catch { state.error = .init(error: error) }
    }
}

struct OnboardingView: View {
    @ObservedObject var state: AppState
    @State private var step = 0
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityAllowed = false

    init(state: AppState, initialStep: Int = 0) {
        self.state = state
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(F("Welcome to VoiceDraft", "欢迎使用 VoiceDraft")).font(.largeTitle.bold())
            Text("\(step + 1) / 3").foregroundStyle(.secondary)
            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
                    .padding(.vertical, 4)
            }
            Divider()
            HStack {
                Button(F("Set up later", "稍后设置")) { state.completeOnboarding() }
                Spacer()
                if step > 0 { Button(F("Back", "上一步")) { step -= 1 } }
                Button(step == 2 ? F("Start using VoiceDraft", "开始使用") : F("Next", "下一步")) {
                    if step == 2 { state.completeOnboarding(); state.page = "Studio" } else { step += 1 }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(30).frame(width: 740, height: 620)
        .task {
            // macOS has no Accessibility authorization-change notification. Keep
            // this sheet current even while System Settings is still frontmost.
            repeat {
                mic = state.preview || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                accessibilityAllowed = state.insertionAuthorized
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { return }
            } while !Task.isCancelled
        }
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            if step == 0 {
                Text(F("Connect your speech and writing models", "连接你的语音与写作模型")).font(.title2)
                Text(F("Model calls go directly to your chosen provider. Keys are saved in Keychain. You can add Qwen, Doubao, Whisper-compatible or Google speech, and choose a writing protocol in Models.", "模型调用直接发送给你选择的服务商，密钥保存在钥匙串中。你可以在模型设置中添加 Qwen、豆包、Whisper 兼容服务或 Google Speech，并选择写作接口。"))
                ModelsView(state: state, showsHeading: false)
            } else if step == 1 {
                Text(F("Microphone and text insertion", "麦克风与文字插入")).font(.title2)
                Button(mic ? F("Microphone allowed", "已允许麦克风") : F("Allow microphone", "允许麦克风")) {
                    guard !state.preview else { return }
                    AVCaptureDevice.requestAccess(for: .audio) { allowed in Task { @MainActor in mic = allowed } }
                }.disabled(mic)
                Button(accessibilityAllowed ? F("Accessibility allowed", "已允许辅助功能") : L("Allow Accessibility")) {
                    if !state.preview { TextInsertion.requestAccess() }
                    accessibilityAllowed = state.insertionAuthorized
                }.disabled(accessibilityAllowed)
                Text(F("Accessibility enables shortcuts and insertion into other apps. You can also use VoiceDraft's editor without insertion permission.", "辅助功能权限用于全局快捷键和向其他应用插入文字。也可以先在 VoiceDraft 编辑器中使用。"))
            } else {
                Text(F("Ready to try", "开始试用")).font(.title2)
                Text(state.shortcutLabel(.dictate)).font(.title.monospaced())
                Text(F("Hold to speak, release to finish. Tap to lock recording and tap again to finish. Recordings can last up to 10 minutes. Try a short sentence in the home editor first.", "按住说话，松开结束；轻按锁定录音，再按一次结束。最长支持 10 分钟。先回到首页试说一句短句吧。"))
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}
