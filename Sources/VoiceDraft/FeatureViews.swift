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
        case .insertLast: return D("Insert last result")
        }
    }
    /// One-line explanation for actions whose title alone is not self-explanatory.
    var detail: String? {
        self == .insertLast ? D("Paste the last result again, wherever the cursor is now.") : nil
    }
}

struct FnShortcutStatus: View {
    @ObservedObject var state: AppState
    var showReady = false
    @State private var systemActionDisabled: Bool?
    private var usesFn: Bool { state.device.features.shortcuts.contains { $0.enabled && $0.isFn } }

    var body: some View {
        // Keep a mounted container while the first preference read is pending.
        // A task on an empty Group has no rendered child on which to start.
        VStack(alignment: .leading, spacing: 0) {
            if usesFn, let systemActionDisabled, showReady || !systemActionDisabled {
                let tint = systemActionDisabled ? VD.Palette.success : VD.Palette.warning
                HStack(alignment: .firstTextBaseline, spacing: VD.Space.m) {
                    Image(systemName: systemActionDisabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: VD.Space.s) {
                        Text(systemActionDisabled
                             ? D("Fn system action is off")
                             : D("Check the macOS Fn action"))
                            .font(VD.Font.body.weight(.semibold))
                        if !systemActionDisabled {
                            Text(D("Fn shortcuts, alone or with modifier keys, need ‘Press Fn (🌐) key to’ set to ‘Do Nothing’ in System Settings → Keyboard. Otherwise recording can also switch input sources, open emoji or start Dictation. This system-wide setting stays in effect after VoiceDraft quits."))
                                .font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Button(D("Open Keyboard Settings")) {
                            guard !state.preview, let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, VD.Space.l).padding(.vertical, VD.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                    .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous))
            }
        }
        .task(id: usesFn) {
            systemActionDisabled = nil
            guard usesFn, !state.preview else { return }
            repeat {
                systemActionDisabled = FnSystemAction.isDisabled()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
            } while !Task.isCancelled
        }
    }
}

/// Settings → Shortcuts. Each row's key caps are one control that starts
/// recording; the overflow menu offers Fn alone and the default binding.
/// Rejected recordings keep the previous binding and explain why inline.
struct ShortcutPreferences: View {
    @ObservedObject var state: AppState
    @State private var capturing: ShortcutAction?
    @State private var liveModifiers: UInt32 = 0
    @State private var problems: [ShortcutAction: String] = [:]
    @State private var monitor: Any?
    var body: some View {
        VStack(alignment: .leading, spacing: VD.Space.s) {
            Text(D("Hold to talk. Release to finish. Tap briefly to lock recording, then tap again to finish."))
                .font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(state.device.features.shortcuts) { binding in
                VStack(alignment: .trailing, spacing: 2) {
                    VDSettingRow(title: binding.action.title, detail: binding.action.detail) {
                        HStack(spacing: VD.Space.s) {
                            keyField(binding)
                            VDOverflowMenu(label: D("Shortcut options")) {
                                Button(D("Use Fn alone")) { apply(binding.action) { $0.keyCode = ShortcutBinding.fnKeyCode; $0.modifiers = 0 } }
                                if let fallback = ShortcutBinding.defaults.first(where: { $0.action == binding.action }) {
                                    Button(String(format: D("Use default shortcut (%@)"), fallback.keyLabel)) {
                                        apply(binding.action) { $0.keyCode = fallback.keyCode; $0.modifiers = fallback.modifiers }
                                    }
                                }
                            }
                            VDSwitch(binding.action.title, isOn: Binding(get: { binding.enabled }, set: { value in apply(binding.action) { $0.enabled = value } }))
                        }
                    }
                    if let problem = problems[binding.action] {
                        Text(problem).font(VD.Font.footnote).foregroundStyle(VD.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing)
                    }
                    if capturing == binding.action {
                        Text(D("Press keys · Esc cancels")).font(VD.Font.footnote).foregroundStyle(VD.Palette.accent)
                    }
                }
            }
            Text(D("Fn works alone or with Shift, Control, Option or Command: hold the modifier, then press Fn. Fn with letter keys is not available because macOS reserves those 🌐 shortcuts."))
                .font(VD.Font.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(D("Restore default shortcuts")) {
                    end(); problems.removeAll()
                    var options = state.device.features; options.shortcuts = ShortcutBinding.defaults; state.saveFeatures(options)
                }
            }
            FnShortcutStatus(state: state, showReady: true)
        }.disabled(state.busy).onDisappear { end() }
    }

    /// The key caps as one button: click to record, click again to cancel.
    private func keyField(_ binding: ShortcutBinding) -> some View {
        let recording = capturing == binding.action
        let shape = RoundedRectangle(cornerRadius: VD.Radius.control, style: .continuous)
        return Button { recording ? end() : begin(binding.action) } label: {
            Group {
                if recording {
                    HStack(spacing: 5) {
                        let held = ShortcutBinding.modifierSymbols(liveModifiers)
                        if !held.isEmpty { VDKeyCaps(label: held, size: 12) }
                        Text("…").font(.system(size: 13, weight: .semibold)).foregroundStyle(VD.Palette.accent)
                    }.padding(.horizontal, VD.Space.s)
                } else {
                    VDKeyCaps(label: binding.keyLabel, size: 12).opacity(binding.enabled ? 1 : 0.4)
                }
            }
            .frame(minWidth: 56, minHeight: 32)
            .padding(2)
            .background(recording ? VD.Palette.accentSoft : .clear, in: shape)
            .overlay(shape.strokeBorder(recording ? VD.Palette.accent : .clear, lineWidth: 1.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(recording ? D("Press keys · Esc cancels") : D("Record a new shortcut"))
        .accessibilityLabel("\(binding.action.title), \(binding.keyLabel)")
        .accessibilityHint(D("Record a new shortcut"))
    }

    private func message(for problem: ShortcutBinding.Problem) -> String {
        switch problem {
        case .notAllowed: return D("Add Control, Option or Command, or use Fn")
        case .conflict(let other): return String(format: D("Already used by %@"), other.title)
        }
    }

    /// Validates the edited binding against the other actions without saving.
    /// On success returns the options to save; otherwise shows the reason under
    /// the row and returns nil, leaving the saved binding unchanged.
    private func candidate(_ action: ShortcutAction, update: (inout ShortcutBinding) -> Void) -> DesktopOptions? {
        var options = state.device.features
        guard let i = options.shortcuts.firstIndex(where: { $0.action == action }) else { return nil }
        update(&options.shortcuts[i])
        if let problem = ShortcutBinding.problem(with: options.shortcuts[i], in: options.shortcuts) {
            problems[action] = message(for: problem); return nil
        }
        problems[action] = nil
        return options
    }

    private func apply(_ action: ShortcutAction, update: (inout ShortcutBinding) -> Void) {
        end()
        if let options = candidate(action, update: update) { save(options, for: action) }
    }

    /// Saves and reinstalls the global shortcuts. The settings overlay hides
    /// `state.error`, so a failed save (for example no event tap for Fn
    /// without Accessibility) is shown under the row instead.
    private func save(_ options: DesktopOptions, for action: ShortcutAction) {
        state.error = ""
        state.saveFeatures(options)
        if !state.error.isEmpty && state.device.features.shortcuts != options.shortcuts {
            problems[action] = L(state.error); state.error = ""
        }
    }

    private static func modifierBits(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        for (flag, bit) in [(NSEvent.ModifierFlags.shift, UInt32(1)), (.control, 2), (.option, 4), (.command, 8)] where flags.contains(flag) { modifiers |= bit }
        return modifiers
    }

    private func begin(_ action: ShortcutAction) {
        end()
        do { try state.configureShortcuts?([]) }
        catch { state.error = .init(error: error); return }
        capturing = action; problems[action] = nil
        liveModifiers = Self.modifierBits(NSEvent.modifierFlags)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let keyDown = event.type == .keyDown
            // isARepeat raises an AppKit exception on flagsChanged (Fn and other
            // modifiers), so read it from key-downs only.
            switch ShortcutRecorder.decide(eventType: keyDown ? .keyDown : .flagsChanged, keyCode: UInt32(event.keyCode),
                                           modifiers: Self.modifierBits(event.modifierFlags),
                                           fnHeld: event.modifierFlags.contains(.function), isRepeat: keyDown && event.isARepeat) {
            case .cancel: end(); return nil
            case .updateLiveModifiers(let held): liveModifiers = held; return event
            case .ignore: return nil
            case .record(let keyCode, let modifiers):
                // A rejected combination keeps recording so the user can try another.
                guard let options = candidate(action, update: { $0.keyCode = keyCode; $0.modifiers = modifiers; $0.enabled = true }) else { return nil }
                end(); save(options, for: action)
                return nil
            }
        }
    }
    /// Stops recording and reinstalls the saved bindings as global shortcuts.
    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if capturing != nil { try? state.configureShortcuts?(state.device.features.shortcuts) }; capturing = nil
        liveModifiers = 0
    }
}

/// The Recording section of the General settings tab.
struct RecordingPreferences: View {
    @ObservedObject var state: AppState
    @State private var confirmRetention = false
    @State private var proposedDays = 0
    private func option(_ key: WritableKeyPath<DesktopOptions, Bool>) -> Binding<Bool> {
        Binding(get: { state.device.features[keyPath: key] }, set: { value in
            var options = state.device.features; options[keyPath: key] = value; state.saveFeatures(options)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: VD.Space.s) {
            VDSectionHeader(icon: "record.circle", title: F("Recording · up to 10 minutes", "录音 · 最长 10 分钟"))
            VDSwitchRow(title: F("Play recording sounds", "播放录音提示音"), isOn: option(\.sounds))
            VDSwitchRow(title: F("Mute system output while recording", "录音时静音系统声音"), isOn: option(\.muteOutput))
            VDSwitchRow(title: F("Keep recordings with history", "在历史中保留录音"), detail: F("Audio stays on this Mac and is excluded from configuration sync. Turning this off affects future recordings; deleting history also deletes its audio.", "录音只保存在本机，不参与配置同步。关闭只影响之后的录音；删除历史时也会删除相应音频。"), isOn: option(\.retainAudio)).disabled(!state.device.keepHistory)
            VDSettingRow(title: F("History retention", "历史保留期限")) {
                Picker(F("History retention", "历史保留期限"), selection: Binding(get: { state.device.features.retentionDays }, set: { days in
                    proposedDays = days
                    if days == 0 { setRetention(days) } else { confirmRetention = true }
                })) {
                    Text(F("Forever", "永久")).tag(0)
                    ForEach([1,7,30,90], id: \.self) { days in Text("\(days) " + F("days", "天")).tag(days) }
                }.labelsHidden().fixedSize()
            }
            VDSwitchRow(title: F("Use recent inputs as writing context", "用近期输入辅助写作"), detail: F("Uses up to three recent VoiceDraft outputs from the same app, for 30 minutes. This context is sent to your writing model and cleared when VoiceDraft quits.", "使用同一应用最近 30 分钟的最多三条 VoiceDraft 输出作为上下文，发送给写作模型。退出后清空，不读取周围文档。"), isOn: option(\.recentContext))
            VDSettingRow(title: F("Clear recent context", "清空近期上下文")) {
                Button(D("Clear")) { state.clearRecentContext() }
            }
        }.disabled(state.busy)
        .confirmationDialog(F("Delete history and audio older than this period?", "删除超过此期限的历史和录音？"), isPresented: $confirmRetention) {
            Button(F("Apply retention period", "应用保留期限"), role: .destructive) { setRetention(proposedDays) }
        }
    }
    private func setRetention(_ days: Int) { var options = state.device.features; options.retentionDays = days; state.saveFeatures(options) }
}

/// The On-screen context section of the General settings tab. Everything is
/// device-local and off by default; the consumers and OCR need the master switch.
struct ScreenContextPreferences: View {
    @ObservedObject var state: AppState
    /// Refreshed by the settings overlay's polling task; nil until the first read.
    var screenRecordingAllowed: Bool?
    @State private var appID = ""
    private var options: DesktopOptions { state.device.features }
    private func option(_ key: WritableKeyPath<DesktopOptions, Bool>, after: ((Bool) -> Void)? = nil) -> Binding<Bool> {
        Binding(get: { state.device.features[keyPath: key] }, set: { value in
            var options = state.device.features; options[keyPath: key] = value; state.saveFeatures(options)
            after?(value)
        })
    }
    private var pendingID: String? {
        let id = ScreenContextPolicy.sanitizedExclusions([appID]).first
        guard let id, !(ScreenContextPolicy.builtInExcludedBundleIDs + options.screenContextExcludedApps).contains(where: { $0.lowercased() == id.lowercased() }) else { return nil }
        return id
    }
    var body: some View {
        let master = options.screenContext
        VStack(alignment: .leading, spacing: VD.Space.s) {
            VDSectionHeader(icon: "text.viewfinder", title: D("On-screen context"))
            VDSwitchRow(title: D("Use on-screen text as context"),
                        detail: D("When you dictate into another app, VoiceDraft reads the text visible in that app's front window. Names and terms help recognition, and a short excerpt near your cursor helps the writing model. Nothing is saved or synced."),
                        isOn: option(\.screenContext))
            VDSwitchRow(title: D("Recognition hints"),
                        detail: D("Sends up to 300 names and terms from the screen to your speech model. The full text is never sent to speech recognition."),
                        isOn: option(\.screenContextASR)).disabled(!master)
            VDSwitchRow(title: D("Writing reference"),
                        detail: D("Sends up to 1,500 characters near your cursor to your writing model so it can match names, terms and tone. It never adds this text to your result."),
                        isOn: option(\.screenContextWriting)).disabled(!master)
            // Turning OCR on is an explicit request point for Screen Recording; takes only preflight.
            VDSwitchRow(title: D("Read the window with OCR when an app exposes no text"),
                        detail: D("Some apps hide their text from Accessibility. VoiceDraft can capture only that window and recognize its text on this Mac. Requires Screen Recording. The image is never saved, and macOS may ask you to confirm this permission again from time to time."),
                        isOn: option(\.screenContextOCR) { on in if on && !state.preview { ScreenRecordingPermission.request() } }).disabled(!master)
            if master && options.screenContextOCR {
                let allowed = screenRecordingAllowed ?? state.preview
                VDSettingRow(title: D("Screen Recording"),
                             detail: allowed ? D("Only the front window is captured, and only when an app exposes no text.")
                                             : D("OCR is skipped until you allow it. Text from Accessibility still works. If you just allowed it, quit and reopen VoiceDraft.")) {
                    if allowed {
                        VDBadge(text: D("Allowed"), tint: VD.Palette.success)
                    } else {
                        Button(D("Allow")) { if !state.preview { ScreenRecordingPermission.request() } }
                            .accessibilityLabel(D("Allow Screen Recording"))
                    }
                }
            }
            VDLabeledField(title: D("Never read these apps"), detail: D("Password managers and VoiceDraft are always skipped.")) {
                VDSurface(padding: 0, spacing: 0) {
                    let rows = ScreenContextPolicy.builtInExcludedBundleIDs.map { ($0, true) } + options.screenContextExcludedApps.map { ($0, false) }
                    ForEach(Array(rows.enumerated()), id: \.element.0) { index, row in
                        if index > 0 { Divider().padding(.horizontal, VD.Space.l) }
                        HStack(spacing: VD.Space.s) {
                            Text(row.0).font(VD.Font.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            if row.1 {
                                VDBadge(text: D("Built in"), tint: .secondary)
                            } else {
                                VDIconButton(systemName: "trash", label: L("Delete")) {
                                    var updated = options; updated.screenContextExcludedApps.removeAll { $0 == row.0 }; state.saveFeatures(updated)
                                }
                            }
                        }.frame(minHeight: 28).padding(.horizontal, VD.Space.l).padding(.vertical, VD.Space.s)
                    }
                }
                HStack(spacing: VD.Space.s) {
                    SingleLineField(D("App bundle ID, e.g. com.apple.mail"), text: $appID).frame(minWidth: 200)
                    Menu(D("Running apps")) {
                        ForEach(NSWorkspace.shared.runningApplications.filter {
                            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                        }, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier!) { appID = app.bundleIdentifier! }
                        }
                    }.fixedSize()
                    Button(D("Exclude")) {
                        guard let id = pendingID else { return }
                        var updated = options
                        updated.screenContextExcludedApps = ScreenContextPolicy.sanitizedExclusions(updated.screenContextExcludedApps + [id])
                        state.saveFeatures(updated); appID = ""
                    }.disabled(pendingID == nil)
                }
            }.padding(.top, VD.Space.xs)
            Text(D("On-screen text stays in memory for at most 60 seconds. It is never written to history, saved to disk or synced. Visible text can include other people's messages, so exclude apps you do not want read."))
                .font(VD.Font.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(state.busy)
    }
}

/// Launch-at-login and first-use guide rows for the General section of the settings tab.
struct LaunchPreferences: View {
    @ObservedObject var state: AppState
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    var body: some View {
        VDSwitchRow(title: F("Launch at login", "登录 Mac 后启动"), isOn: Binding(get: { loginEnabled }, set: { enabled in
            guard !state.preview else { return }
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginEnabled = SMAppService.mainApp.status == .enabled
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch { state.error = .init(error: error) }
        })).disabled(state.busy)
        VDSettingRow(title: F("Open first-use guide", "打开首次使用引导")) {
            Button(D("Open")) { state.showingOnboarding = true }
        }.disabled(state.busy)
    }
}

struct StyleLibraryView: View {
    @ObservedObject var state: AppState
    @State private var editing: WritingStyle?
    @State private var appID = ""
    @State private var assignedStyle = ""
    var body: some View {
        VStack(alignment: .leading, spacing: VD.Space.xxl) {
            VStack(alignment: .leading, spacing: VD.Space.m) {
                VDSectionHeader(icon: "paintbrush", title: F("Writing styles", "写作风格库"))
                let defaultStyleTitle = F("Default style", "默认使用风格")
                VDSettingRow(title: defaultStyleTitle) {
                    Picker(defaultStyleTitle, selection: Binding(get: { state.settings.selectedStyleID?.uuidString ?? "" }, set: { id in
                        var copy = state.settings; copy.selectedStyleID = UUID(uuidString: id); state.save(copy)
                    })) {
                        Text(F("General writing preferences", "下方通用写作偏好")).tag("")
                        ForEach(state.settings.styles) { style in Text(style.name).tag(style.id.uuidString) }
                    }.labelsHidden().fixedSize()
                }
                if state.settings.styles.isEmpty {
                    VDEmptyState(icon: "paintbrush", title: D("No writing styles yet"), detail: D("Create a style or start from a preset."), verticalPadding: VD.Space.xl)
                        .background(VD.Palette.surface, in: RoundedRectangle(cornerRadius: VD.Radius.card, style: .continuous))
                } else {
                    VDSurface(padding: 0, spacing: 0) {
                        ForEach(Array(state.settings.styles.enumerated()), id: \.element.id) { index, style in
                            if index > 0 { Divider().padding(.horizontal, VD.Space.l) }
                            HStack(spacing: VD.Space.s) {
                                Text(style.name).font(VD.Font.body).lineLimit(1)
                                if state.settings.selectedStyleID == style.id { VDBadge(text: D("Default")) }
                                Spacer()
                                VDIconButton(systemName: "pencil", label: L("Edit")) { editing = style }
                                VDIconButton(systemName: "trash", label: L("Delete")) {
                                    var copy = state.settings; copy.styles.removeAll { $0.id == style.id }
                                    copy.applicationStyles = copy.applicationStyles.filter { $0.value != style.id }
                                    if copy.selectedStyleID == style.id { copy.selectedStyleID = nil }; state.save(copy)
                                }
                            }.padding(.horizontal, VD.Space.l).padding(.vertical, VD.Space.s)
                        }
                    }
                }
                HStack(spacing: VD.Space.s) {
                    Button(F("New style", "新建风格")) { editing = WritingStyle(name: F("New style", "新风格"), prompt: "") }
                    Menu(F("Add a preset", "添加预设")) {
                        Button(F("Casual", "日常自然")) { editing = WritingStyle(name: F("Casual", "日常自然"), prompt: "Use natural, conversational language. Preserve my voice and avoid formal phrasing.") }
                        Button(F("Professional", "工作沟通")) { editing = WritingStyle(name: F("Professional", "工作沟通"), prompt: "Use clear professional language. Keep sentences concise, polite and actionable. Preserve all facts.") }
                        Button(F("Bullet notes", "条目笔记")) { editing = WritingStyle(name: F("Bullet notes", "条目笔记"), prompt: "Organize the text into short bullet points. Preserve facts, conditions and action items without adding any information.") }
                    }.fixedSize()
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline, spacing: VD.Space.s) {
                    Text(F("Select text in another app and press the style shortcut to choose a style and replace the selection.", "在其他应用中选中文字，按风格快捷键，选择风格后直接替换选区。"))
                        .font(VD.Font.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let binding = state.device.features.shortcuts.first(where: { $0.action == .styleSelection && $0.enabled }) {
                        VDKeyCaps(label: binding.label, size: 11)
                    }
                }
            }
            VStack(alignment: .leading, spacing: VD.Space.m) {
                VDSectionHeader(icon: "app.badge", title: F("Choose a style automatically by app", "按应用自动切换风格"))
                if state.settings.applicationStyles.isEmpty {
                    VDEmptyState(icon: "square.stack", title: D("No app rules yet"), detail: D("Pick an app and a style below to switch styles automatically."), verticalPadding: VD.Space.xl)
                        .background(VD.Palette.surface, in: RoundedRectangle(cornerRadius: VD.Radius.card, style: .continuous))
                } else {
                    VDSurface(padding: 0, spacing: 0) {
                        ForEach(Array(state.settings.applicationStyles.keys.sorted().enumerated()), id: \.element) { index, bundle in
                            if index > 0 { Divider().padding(.horizontal, VD.Space.l) }
                            HStack(spacing: VD.Space.s) {
                                Text(bundle).font(VD.Font.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                Spacer()
                                Text(state.settings.styles.first { $0.id == state.settings.applicationStyles[bundle] }?.name ?? "").font(VD.Font.body).foregroundStyle(.secondary)
                                VDIconButton(systemName: "trash", label: L("Delete")) { var copy = state.settings; copy.applicationStyles.removeValue(forKey: bundle); state.save(copy) }
                            }.padding(.horizontal, VD.Space.l).padding(.vertical, VD.Space.s)
                        }
                    }
                }
                VDLabeledField(title: D("Add a rule")) {
                    HStack(spacing: VD.Space.s) {
                        SingleLineField(F("App bundle ID", "应用标识，例如 com.apple.mail"), text: $appID).frame(minWidth: 200)
                        Menu(F("Running apps", "正在运行的应用")) {
                            ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                                Button(app.localizedName ?? app.bundleIdentifier!) { appID = app.bundleIdentifier! }
                            }
                        }.fixedSize()
                        Picker(F("Style", "风格"), selection: $assignedStyle) {
                            Text(F("Select style", "选择风格")).tag("")
                            ForEach(state.settings.styles) { style in Text(style.name).tag(style.id.uuidString) }
                        }.labelsHidden().fixedSize()
                        Button(F("Assign", "绑定")) {
                            guard let id = UUID(uuidString: assignedStyle) else { return }
                            var copy = state.settings; copy.applicationStyles[appID.trimmingCharacters(in: .whitespaces)] = id; state.save(copy)
                        }.disabled(appID.trimmingCharacters(in: .whitespaces).isEmpty || assignedStyle.isEmpty)
                    }
                }
            }
        }.sheet(item: $editing) { value in StyleEditor(style: value) { style in
            var copy = state.settings
            if let i = copy.styles.firstIndex(where: { $0.id == style.id }) { copy.styles[i] = style } else { copy.styles.append(style) }
            state.save(copy)
            return state.error.isEmpty
        } }.disabled(state.busy)
    }
}

struct StyleEditor: View {
    @State var style: WritingStyle
    let save: (WritingStyle) -> Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: VD.Space.l) {
            Text(D("Writing style")).font(VD.Font.sheetTitle)
            VStack(alignment: .leading, spacing: 6) {
                Text(D("Style name")).font(.system(size: 13, weight: .medium))
                SingleLineField(D("Style name"), text: $style.name)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(D("Style instructions")).font(.system(size: 13, weight: .medium))
                TextEditor(text: $style.prompt).font(VD.Font.body).vdEditorBox(minHeight: 220)
                    .accessibilityLabel(D("Style instructions"))
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save")) { if save(style) { dismiss() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(style.name.trimmingCharacters(in: .whitespaces).isEmpty || style.prompt.utf8.count > 20_000)
            }
        }.vdSheet(width: 560)
    }
}

struct VocabularyFileControls: View {
    /// What the review sheet extracts from; nil is a file import.
    enum ContextKind { case agent, screen }
    @ObservedObject var state: AppState
    @State private var candidates: [VocabularyEntry] = []
    @State private var selected: Set<UUID> = []
    @State private var showPreview = false
    @State private var context: ContextKind?
    @State private var screenApp: ScreenContextApplication?
    @State private var screenScan: ScreenContextScan?
    /// The screen target is excluded: nothing was read and there is nothing to retry.
    @State private var blocked = false
    @State private var scanning = false
    @State private var scan: AgentContextScan?
    @State private var sources: [String: String] = [:]
    @State private var scanError = ""
    @State private var filtering = false
    @State private var filterSummary = ""
    @State private var rawCandidates: [AgentContextCandidate] = []
    @State private var scanAttempt = UUID()
    private let fixture: ReviewFixture?

    /// Synthetic review state for `VOICEDRAFT_CAPTURE_SHEETS`: the view renders only the review
    /// sheet's content and never scans, filters or reads the screen.
    struct ReviewFixture {
        var context: ContextKind?
        var app: ScreenContextApplication?
        var scan: AgentContextScan?
        var screenScan: ScreenContextScan?
        var scanning = false
        var candidates: [AgentContextCandidate] = []
        /// Kept, found and model name of a finished model filter.
        var filtered: (kept: Int, found: Int, model: String)?
    }

    init(state: AppState, fixture: ReviewFixture? = nil) {
        self.state = state
        self.fixture = fixture
        guard let fixture else { return }
        _context = State(initialValue: fixture.context); _screenApp = State(initialValue: fixture.app)
        _scan = State(initialValue: fixture.scan); _screenScan = State(initialValue: fixture.screenScan)
        _scanning = State(initialValue: fixture.scanning); _filterSummary = State(initialValue: fixture.filtered.map { Self.filterSummaryText(kept: $0.kept, found: $0.found, model: $0.model) } ?? "")
        let entries = fixture.candidates.map { VocabularyEntry(text: $0.text) }
        _candidates = State(initialValue: entries)
        _selected = State(initialValue: Set(entries.prefix(3).map(\.id)))
        _sources = State(initialValue: Self.sourceLabels(fixture.candidates, context: fixture.context, screenSource: fixture.screenScan?.source))
    }

    var body: some View {
        if fixture != nil { reviewSheet } else { controls }
    }

    private var controls: some View {
        HStack {
            Button(F("Import vocabulary", "导入词库")) { importFile() }
            Button(F("Export vocabulary", "导出词库")) { exportFile() }
            Button(F("Extract from Codex / Claude context", "从 Codex / Claude 上下文提取")) { start(.agent) }
            screenButton
        }
        .onAppear { consume(state.screenExtractionRequest) }
        .onChange(of: state.screenExtractionRequest) { consume($0) }
        .sheet(isPresented: $showPreview) {
            reviewSheet.task(id: scanAttempt) { await findAndFilter() }
        }
    }

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: VD.Space.l) {
            VStack(alignment: .leading, spacing: VD.Space.s) {
                Text(F("Review words to import", "选择要导入的词条")).font(VD.Font.sheetTitle)
                Text(context == .agent
                     ? F("Finds local Codex and Claude context automatically, then sends only candidate words to your writing model to filter out common terms. Review the shortlist before importing.", "自动查找本机 Codex 和 Claude 上下文，再将候选词交给你的写作模型筛除通用词。只发送候选词列表，最后由你勾选导入。")
                     : context == .screen
                     ? String(format: D("Reads the text visible in %@ on this Mac, then sends only candidate words to your writing model to filter out common terms. Review the shortlist before importing."), screenApp?.name ?? "")
                     : F("Review the vocabulary before importing. Only selected terms are added.", "检查词库内容，只添加勾选的词条。"))
                    .font(VD.Font.detail).foregroundStyle(.secondary).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            if scanning {
                HStack(spacing: VD.Space.s) {
                    ProgressView().controlSize(.small)
                    Text(filtering ? F("Filtering with your writing model…", "正在用写作模型筛选…")
                         : context == .screen ? D("Reading the screen…") : F("Finding local context…", "正在查找本机上下文…")).font(VD.Font.detail)
                }
            } else if context == .agent, let scan {
                VStack(alignment: .leading, spacing: VD.Space.xs) {
                    Text(F("Context files read", "已读取上下文文件") + ": \(scan.filesRead) · " + (scan.sources.isEmpty ? "Codex / Claude" : scan.sources.map(\.rawValue).joined(separator: " / ")))
                    if scan.limited { Text(F("Recent context was prioritized to keep the scan quick.", "已优先提取近期上下文，避免扫描时间过长。")) }
                    if scan.unreadableFiles > 0 { Text(F("Some context files could not be read", "部分上下文文件无法读取") + ": \(scan.unreadableFiles)") }
                }.font(VD.Font.detail).foregroundStyle(.secondary)
            }
            if !filterSummary.isEmpty { Text(filterSummary).font(VD.Font.detail).foregroundStyle(.secondary) }
            if !scanError.isEmpty, !blocked {
                VDInlineNotice(kind: .error, text: scanError)
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
            HStack(spacing: VD.Space.s) {
                Button(F("Select all", "全选")) { selected = Set(candidates.map(\.id)) }
                Button(F("Clear selection", "清空选择")) { selected.removeAll() }
                Spacer()
                Text("\(selected.count) / \(candidates.count)").font(VD.Font.detail).foregroundStyle(.secondary).monospacedDigit()
            }.buttonStyle(.bordered).disabled(scanning || candidates.isEmpty)
            if candidates.isEmpty {
                VDEmptyState(icon: scanning ? "hourglass" : blocked ? "hand.raised" : !scanError.isEmpty ? "exclamationmark.triangle" : "text.magnifyingglass",
                             title: scanning ? (filtering ? F("Selecting useful names and specialist terms…", "正在保留有价值的名称和专门术语…")
                                               // The progress row above already names the source ("Reading the screen…").
                                               : F("Extracting candidate terms locally…", "正在本机提取候选词…"))
                     : blocked ? scanError
                     : !scanError.isEmpty ? F("Filtering did not finish. Retry or review the unfiltered list.", "筛选未完成，可以重试或查看未筛选的词条。")
                     : !filterSummary.isEmpty ? F("The model found no terms worth adding this time.", "这次没有筛选出值得加入词库的词条。")
                     : context == .screen
                     ? (screenScan?.charactersRead ?? 0) == 0 ? D("No readable text was found in this window.")
                       : D("No new candidate terms were found on this screen. Existing vocabulary words are excluded.")
                     : scan?.filesRead == 0
                     ? F("No readable Codex or Claude context was found in this account's home folder.", "在当前账户的用户目录中，没有找到可读取的 Codex 或 Claude 上下文。")
                     : F("No new candidate terms were found. Existing vocabulary words are excluded.", "没有找到新的候选词，词库中已有的词条已排除。"))
                    .multilineTextAlignment(.center).padding(.horizontal, VD.Space.xl)
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .background(VD.Palette.surface, in: RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous))
            } else {
                List(candidates) { entry in
                    HStack {
                        Toggle(entry.text, isOn: Binding(get: { selected.contains(entry.id) }, set: { value in if value { selected.insert(entry.id) } else { selected.remove(entry.id) } }))
                        Spacer()
                        if let source = sources[entry.text] { Text(source).font(VD.Font.footnote).foregroundStyle(.secondary) }
                    }
                }.scrollContentBackground(.hidden).frame(height: 260)
                    .background(VD.Palette.field, in: RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: VD.Radius.chip, style: .continuous).strokeBorder(VD.Palette.line))
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { showPreview = false }.keyboardShortcut(.cancelAction)
                Button(F("Import selected words", "导入所选词条")) {
                    do {
                        var copy = state.settings
                        try VocabularyFile.merge(candidates.filter { selected.contains($0.id) }, into: &copy.vocabulary)
                        state.save(copy); if state.error.isEmpty { showPreview = false }
                    } catch { state.error = .init(error: error) }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(scanning || selected.isEmpty)
            }
        }.vdSheet(width: 600)
    }
    /// Vocabulary's screen button reads the last external app; disabled with a reason when none or excluded.
    private var screenButton: some View {
        let app = state.screenContextApplication
        let excluded = app.map { !ScreenContextPolicy.allows(bundleID: $0.bundleID, options: state.device.features, ownBundleID: Bundle.main.bundleIdentifier) } ?? false
        return Button(app.map { String(format: D("Extract from %@"), $0.name) } ?? D("Extract from screen")) {
            if let app { start(.screen, app: app) }
        }
        .disabled(app == nil || excluded)
        .help(app == nil ? D("Switch to the app you want to read, then choose Extract words from this screen in the menu bar.")
              : excluded ? String(format: D("%@ is excluded from on-screen context."), app?.name ?? "") : "")
    }
    private func start(_ kind: ContextKind, app: ScreenContextApplication? = nil) {
        context = kind; screenApp = app; screenScan = nil; blocked = false
        scanning = true; scan = nil; scanError = ""
        filtering = false; filterSummary = ""; rawCandidates = []; scanAttempt = UUID()
        candidates = []; selected = []; sources = [:]; showPreview = true
    }
    /// A status-menu request opens the sheet in screen mode for the app it captured.
    private func consume(_ request: ScreenExtractionRequest?) {
        guard let request else { return }
        state.screenExtractionRequest = nil
        start(.screen, app: request.app)
    }
    private func findAndFilter() async {
        guard let context else { return }
        do {
            let found: [AgentContextCandidate]
            switch context {
            case .agent:
                let result = try await state.scanAgentContext()
                try Task.checkCancellation()
                scan = result; found = result.candidates
            case .screen:
                guard let app = screenApp else { return }
                let result = try await state.scanScreenContext(app: app)
                try Task.checkCancellation()
                screenScan = result
                if result.excluded {
                    scanError = String(format: D("%@ is excluded from on-screen context."), app.name)
                    blocked = true; scanning = false; return
                }
                found = result.candidates
            }
            let known = Set(state.settings.vocabulary.entries.flatMap { [$0.text, $0.displayAs] + $0.aliases }.map(AppVocabulary.automaticTermKey))
            let fresh = found.filter { !known.contains(AppVocabulary.automaticTermKey($0.text)) }
            rawCandidates = fresh
            if !fresh.isEmpty {
                filtering = true
                let filtered = try await state.filterAgentContext(fresh, source: context == .screen ? .vocabularyScreenContextFilter : .vocabularyAgentContextFilter)
                try Task.checkCancellation()
                let byText = Dictionary(uniqueKeysWithValues: fresh.map { ($0.text, $0) })
                present(filtered.terms.compactMap { byText[$0] })
                filterSummary = Self.filterSummaryText(kept: candidates.count, found: fresh.count, model: filtered.model)
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
        sources = Self.sourceLabels(fresh, context: context, screenSource: screenScan?.source)
    }
    private static func filterSummaryText(kept: Int, found: Int, model: String) -> String {
        F("Model selection", "模型筛选") + ": \(kept) / \(found) · \(model)"
    }
    private static func sourceLabels(_ items: [AgentContextCandidate], context: ContextKind?, screenSource: ScreenContextSource?) -> [String: String] {
        let screenLabel = screenSource == .ocr ? D("Screen · OCR") : D("Screen · Accessibility")
        return Dictionary(uniqueKeysWithValues: items.map {
            ($0.text, context == .screen ? screenLabel
                : ($0.isProject ? F("Project", "项目") + " · " : "") + $0.sources.map(\.rawValue).joined(separator: " / "))
        })
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20_000_000 else { throw FeatureError("The selected file is too large.") }
            candidates = try VocabularyFile.entries(Data(contentsOf: url))
            context = nil; screenApp = nil; screenScan = nil; blocked = false
            scanning = false; filtering = false; filterSummary = ""; scan = nil; scanError = ""; sources = [:]
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
    @State private var vocabulary: DomainVocabularySelection
    @State private var saveFailed = false
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityAllowed = false
    @State private var screenRecordingAllowed = false

    init(state: AppState, initialStep: Int = 0, initialDomains: Set<VocabularyDomain> = []) {
        self.state = state
        _step = State(initialValue: initialStep)
        _vocabulary = State(initialValue: DomainVocabularySelection(domains: initialDomains))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VD.Space.l) {
            VStack(alignment: .leading, spacing: VD.Space.s) {
                Text(F("Welcome to VoiceDraft", "欢迎使用 VoiceDraft")).font(VD.Font.pageTitle).tracking(-0.8)
                HStack(spacing: VD.Space.s) {
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { index in
                            Circle().fill(index <= step ? VD.Palette.accent : VD.Palette.line).frame(width: 8, height: 8)
                        }
                    }.accessibilityHidden(true)
                    Text("\(step + 1) / 4").font(VD.Font.detail).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, VD.Space.s)
                    .padding(.vertical, VD.Space.xs)
            }
            if saveFailed { VDInlineNotice(kind: .error, text: L(state.error)) }
            Divider()
            HStack {
                Button(F("Set up later", "稍后设置")) { state.completeOnboarding() }
                Spacer()
                if step > 0 { Button(F("Back", "上一步")) { step -= 1 } }
                Button(nextTitle) {
                    if step == 0 && !vocabulary.additions(to: state.settings.vocabulary).isEmpty {
                        do {
                            var copy = state.settings
                            try vocabulary.merge(into: &copy.vocabulary)
                            state.save(copy)
                            saveFailed = !state.error.isEmpty
                        } catch { state.error = .init(error: error); saveFailed = true }
                        guard !saveFailed else { return }
                    }
                    saveFailed = false
                    if step == 3 { state.completeOnboarding(); state.page = "Studio" } else { step += 1 }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(VD.Space.xxl).frame(width: 740, height: 620).background(VD.Palette.canvas).tint(VD.Palette.accent)
        .task {
            // macOS has no Accessibility authorization-change notification. Keep
            // this sheet current even while System Settings is still frontmost.
            repeat {
                mic = state.preview || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                accessibilityAllowed = state.insertionAuthorized
                screenRecordingAllowed = state.preview || ScreenRecordingPermission.granted
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { return }
            } while !Task.isCancelled
        }
    }

    private var nextTitle: String {
        if step == 3 { return F("Start using VoiceDraft", "开始使用") }
        let count = vocabulary.additions(to: state.settings.vocabulary).count
        return step == 0 && count > 0 ? F("Add \(count) words and continue", "添加 \(count) 个词并继续") : F("Next", "下一步")
    }

    private func domainTitle(_ domain: VocabularyDomain) -> String {
        switch domain {
        case .artificialIntelligence: return F("AI & machine learning", "AI 与机器学习")
        case .software: return F("Software development", "软件开发")
        case .design: return F("Product & design", "产品与设计")
        case .data: return F("Data & analytics", "数据与分析")
        case .hardware: return F("Hardware & engineering", "硬件与工程")
        case .research: return F("Education & research", "教育与科研")
        }
    }

    private var domainContent: some View {
        let known = DomainVocabularySelection.knownTerms(in: state.settings.vocabulary)
        return VStack(alignment: .leading, spacing: VD.Space.l) {
            stepHeading(F("What fields do you work in?", "你从事哪些领域？"),
                        detail: F("Choose any that fit, or continue without choosing. Review a few specialist names to help recognize your first dictations.", "可以多选，也可以直接跳过。先选一些常用的专业名称，帮助识别最初几次输入。"))
            VDSurface {
                VDSectionHeader(icon: "square.grid.2x2", title: D("Your fields"))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: VD.Space.m) {
                    ForEach(VocabularyDomain.allCases) { domain in
                        Toggle(domainTitle(domain), isOn: Binding(get: { vocabulary.domains.contains(domain) }, set: {
                            if $0 { vocabulary.domains.insert(domain) } else { vocabulary.domains.remove(domain) }
                        })).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if !vocabulary.terms.isEmpty {
                VDSurface {
                    VDSectionHeader(icon: "text.book.closed", title: F("Your starter vocabulary", "你的初始词库"))
                    Text(F("Uncheck words you do not need. Existing words keep their settings. You can edit these later in Vocabulary.", "取消不需要的词。已有词条会保留原来的设置，之后也可以在词库中修改。"))
                        .font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: VD.Space.m) {
                        ForEach(vocabulary.terms, id: \.self) { term in
                            let existing = known.contains(AppVocabulary.automaticTermKey(term))
                            VStack(alignment: .leading, spacing: 2) {
                                Toggle(term, isOn: Binding(get: { existing || vocabulary.isSelected(term) }, set: { vocabulary.select(term, enabled: $0) }))
                                    .disabled(existing)
                                if existing { Text(F("Already in vocabulary", "词库中已有")).font(VD.Font.footnote).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private func stepHeading(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: VD.Space.s) {
            Text(title).font(VD.Font.sectionTitle)
            if let detail {
                Text(detail).font(VD.Font.body).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionRow(icon: String, title: String, detail: String, granted: Bool, allowLabel: String, allow: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: VD.Space.m) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium)).foregroundStyle(VD.Palette.accent)
                .frame(width: 36, height: 36)
                .background(VD.Palette.accentSoft, in: RoundedRectangle(cornerRadius: VD.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(VD.Font.body.weight(.medium))
                Text(detail).font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: VD.Space.l)
            if granted {
                VDBadge(text: D("Allowed"), tint: VD.Palette.success)
            } else {
                VDBadge(text: D("Not allowed"), tint: VD.Palette.warning)
                Button(D("Allow"), action: allow).buttonStyle(.bordered).accessibilityLabel(allowLabel)
            }
        }
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: VD.Space.l) {
            if step == 0 {
                domainContent
            } else if step == 1 {
                stepHeading(F("Connect your speech and writing models", "连接你的语音与写作模型"),
                            detail: F("Model calls go directly to your chosen provider. Keys are saved in Keychain. You can add Qwen, Doubao, Whisper-compatible or Google speech, and choose a writing protocol in Models.", "模型调用直接发送给你选择的服务商，密钥保存在钥匙串中。你可以在模型设置中添加 Qwen、豆包、Whisper 兼容服务或 Google Speech，并选择写作接口。"))
                ModelsView(state: state, showsHeading: false)
            } else if step == 2 {
                stepHeading(F("Microphone and text insertion", "麦克风与文字插入"))
                VDSurface(spacing: VD.Space.m) {
                    permissionRow(icon: "mic", title: D("Microphone"), detail: D("Records your voice only while you dictate."),
                                  granted: mic, allowLabel: F("Allow microphone", "允许麦克风")) {
                        guard !state.preview else { return }
                        AVCaptureDevice.requestAccess(for: .audio) { allowed in Task { @MainActor in mic = allowed } }
                    }
                    Divider()
                    permissionRow(icon: "accessibility", title: D("Accessibility"), detail: D("Runs shortcuts in any app and inserts text where you type."),
                                  granted: accessibilityAllowed, allowLabel: L("Allow Accessibility")) {
                        if !state.preview { TextInsertion.requestAccess() }
                        accessibilityAllowed = state.insertionAuthorized
                    }
                    Divider()
                    // Optional; this step never turns on any on-screen context option.
                    permissionRow(icon: "rectangle.dashed.badge.record", title: D("Screen Recording (optional)"),
                                  detail: D("Only needed if you turn on reading windows with OCR in Settings."),
                                  granted: screenRecordingAllowed, allowLabel: D("Allow Screen Recording")) {
                        guard !state.preview else { return }
                        ScreenRecordingPermission.request()
                        screenRecordingAllowed = ScreenRecordingPermission.granted
                    }
                }
                Text(F("Accessibility enables shortcuts and insertion into other apps. You can also use VoiceDraft's editor without insertion permission.", "辅助功能权限用于全局快捷键和向其他应用插入文字。也可以先在 VoiceDraft 编辑器中使用。"))
                    .font(VD.Font.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                stepHeading(F("Ready to try", "开始试用"))
                VDSurface(style: .shaded, spacing: VD.Space.m) {
                    Text(ShortcutAction.dictate.title).font(VD.Font.body.weight(.medium)).foregroundStyle(.secondary)
                    VDKeyCaps(label: state.shortcutLabel(.dictate), size: 22)
                    Text(F("Hold to speak, release to finish. Tap to lock recording and tap again to finish. Recordings can last up to 10 minutes. Try a short sentence in the home editor first.", "按住说话，松开结束；轻按锁定录音，再按一次结束。最长支持 10 分钟。先回到首页试说一句短句吧。"))
                        .font(VD.Font.body).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                FnShortcutStatus(state: state, showReady: true)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}
