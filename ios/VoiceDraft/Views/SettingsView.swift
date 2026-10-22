import SwiftUI
import UIKit
import VoiceDraftCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { SyncSettingsView() } label: {
                        Label(AppText.t("Sync"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    NavigationLink { ModelsSettingsView() } label: {
                        Label(AppText.t("Models"), systemImage: "cpu")
                    }
                    NavigationLink { WritingSettingsView() } label: {
                        Label(AppText.t("Writing"), systemImage: "text.badge.star")
                    }
                    NavigationLink { VocabularySettingsView() } label: {
                        Label(AppText.t("Vocabulary"), systemImage: "character.book.closed")
                    }
                }
                Section {
                    Toggle(AppText.t("Keep history"), isOn: Binding(get: { model.device.keepHistory },
                                                                    set: { model.setKeepHistory($0) }))
                    Stepper(value: Binding(get: { model.device.listeningTimeoutMinutes },
                                           set: { model.setListeningTimeout(minutes: $0) }),
                            in: IOSDeviceSettings.listeningTimeoutRange) {
                        Text(verbatim: AppText.t("Listening turns off after {0} min idle", String(model.device.listeningTimeoutMinutes)))
                    }
                } header: {
                    Text(verbatim: AppText.t("This iPhone"))
                }
                Section {
                    NavigationLink { LanguageSettingsView() } label: {
                        Label(AppText.t("Language"), systemImage: "globe")
                    }
                    NavigationLink { KeyboardSetupView() } label: {
                        Label(AppText.t("Keyboard setup"), systemImage: "keyboard")
                    }
                    NavigationLink { AboutView() } label: {
                        Label(AppText.t("About"), systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle(Text(verbatim: AppText.t("Settings")))
        }
    }
}

// MARK: Sync

struct SyncSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var url = ""
    @State private var token = ""
    @State private var passphrase = ""

    var body: some View {
        Form {
            Section {
                MessageBanner()
                TextField(AppText.t("Server URL"), text: $url, prompt: Text(verbatim: "https://sync.example.com"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(AppText.t("Access token"), text: $token)
                SecureField(AppText.t("Sync passphrase"), text: $passphrase)
                Button(AppText.t("Save connection")) {
                    model.configureSync(url: url, token: token, passphrase: passphrase)
                }
                .disabled(model.syncing)
            } header: {
                Text(verbatim: AppText.t("Connection"))
            } footer: {
                Text(verbatim: AppText.t("Use HTTPS, or HTTP on localhost for development. The token and passphrase stay in this iPhone's Keychain. Settings and keys are encrypted with the passphrase before upload; history and audio are never synced."))
            }
            Section {
                Button {
                    Task { await model.downloadSync() }
                } label: {
                    Label(AppText.t("Download from server"), systemImage: "icloud.and.arrow.down")
                }
                Button {
                    Task { await model.uploadSync() }
                } label: {
                    Label(AppText.t("Upload this iPhone's settings"), systemImage: "icloud.and.arrow.up")
                }
            } header: {
                Text(verbatim: AppText.t("Sync"))
            } footer: {
                Text(verbatim: AppText.t("Download replaces this iPhone's models, keys, styles and vocabulary with the server copy."))
            }
            .disabled(model.syncing || model.device.serverURL.isEmpty || model.busy)
            Section {
                HStack {
                    Text(verbatim: AppText.render(model.syncStatus))
                    Spacer()
                    if model.syncing { ProgressView() }
                }
                LabeledContent(AppText.t("Revision"), value: String(model.device.syncRevision))
                LabeledContent(AppText.t("Local changes"), value: model.device.dirty ? AppText.t("Yes") : AppText.t("No"))
            } header: {
                Text(verbatim: AppText.t("Status"))
            }
        }
        .navigationTitle(Text(verbatim: AppText.t("Sync")))
        .onAppear {
            url = model.device.serverURL
            token = model.syncToken
            passphrase = model.syncPassphrase
        }
    }
}

// MARK: Models

struct ModelsSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            MessageBanner()
            ForEach(ModelRole.allCases) { role in
                let profiles = model.settings.profiles.filter { $0.role == role }
                Section {
                    Picker(AppText.t("Active"), selection: Binding(
                        get: { role == .speech ? model.settings.speechID : model.settings.writingID },
                        set: { model.selectProfile($0, role: role) })) {
                        ForEach(profiles) { profile in
                            Text(verbatim: profile.name).tag(profile.id)
                        }
                    }
                    ForEach(profiles) { profile in
                        NavigationLink { APIKeyView(profile: profile) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: profile.name)
                                Text(verbatim: "\(profile.adapter.title) · \(profile.model)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: model.hasKey(for: profile) ? AppText.t("Key saved") : AppText.t("No key"))
                                    .font(.caption)
                                    .foregroundStyle(model.hasKey(for: profile) ? .green : .orange)
                            }
                        }
                    }
                } header: {
                    Text(verbatim: role.title)
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text(verbatim: AppText.t("Add or edit profiles on the Mac and download them here through sync. Keys are stored in this iPhone's Keychain and sent only to the provider's endpoint."))
            }
        }
        .navigationTitle(Text(verbatim: AppText.t("Models")))
    }
}

struct APIKeyView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profile: ModelProfile
    @State private var key = ""

    var body: some View {
        Form {
            Section {
                LabeledContent(AppText.t("Protocol"), value: profile.adapter.title)
                LabeledContent(AppText.t("Model"), value: profile.model)
                Text(verbatim: profile.endpoint).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section {
                SecureField(AppText.t("API key"), text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(AppText.t("Save key")) {
                    model.setKey(key, for: profile)
                    dismiss()
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.hasKey(for: profile) {
                    Button(AppText.t("Remove key"), role: .destructive) {
                        model.setKey("", for: profile)
                        dismiss()
                    }
                }
            } footer: {
                Text(verbatim: model.hasKey(for: profile) ? AppText.t("A key is saved. Enter a new one to replace it.") : "")
            }
        }
        .navigationTitle(Text(verbatim: profile.name))
    }
}

// MARK: Writing

struct WritingSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var targetLanguage = ""

    var body: some View {
        Form {
            MessageBanner()
            Section {
                Picker(AppText.t("Style"), selection: Binding(get: { model.settings.selectedStyleID },
                                                              set: { model.selectStyle($0) })) {
                    Text(verbatim: AppText.t("Default")).tag(UUID?.none)
                    ForEach(model.settings.styles) { style in
                        Text(verbatim: style.name).tag(UUID?.some(style.id))
                    }
                }
            } footer: {
                Text(verbatim: AppText.t("Styles come from sync. Per-app styles apply only on the Mac."))
            }
            Section {
                TextField(AppText.t("Target language"), text: $targetLanguage)
                    .onSubmit { model.setTargetLanguage(targetLanguage) }
                Button(AppText.t("Save")) { model.setTargetLanguage(targetLanguage) }
                    .disabled(targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || targetLanguage == model.settings.targetLanguage)
            } header: {
                Text(verbatim: AppText.t("Translate"))
            }
        }
        .navigationTitle(Text(verbatim: AppText.t("Writing")))
        .onAppear { targetLanguage = model.settings.targetLanguage }
    }
}

// MARK: Vocabulary

struct VocabularySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newTerm = ""

    var body: some View {
        List {
            MessageBanner()
            Section {
                Toggle(AppText.t("Use vocabulary"), isOn: Binding(get: { model.settings.vocabulary.enabled },
                                                                  set: { model.setVocabularyEnabled($0) }))
                HStack {
                    TextField(AppText.t("Add a term"), text: $newTerm)
                        .onSubmit(add)
                    Button(AppText.t("Add"), action: add)
                        .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } footer: {
                Text(verbatim: AppText.t("Names and terms help recognition and writing. Vocabulary syncs with your other devices."))
            }
            Section {
                ForEach(model.settings.vocabulary.entries) { entry in
                    Toggle(isOn: Binding(get: { entry.enabled },
                                         set: { model.setVocabularyEntry(entry.id, enabled: $0) })) {
                        Text(verbatim: entry.displayAs.isEmpty ? entry.text : entry.displayAs)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { model.settings.vocabulary.entries[$0].id }
                    ids.forEach(model.deleteVocabularyEntry)
                }
            } header: {
                Text(verbatim: AppText.t("{0} terms", String(model.settings.vocabulary.entries.count)))
            }
        }
        .navigationTitle(Text(verbatim: AppText.t("Vocabulary")))
    }

    private func add() {
        model.addVocabulary(newTerm)
        newTerm = ""
    }
}

// MARK: Language, keyboard, about

struct LanguageSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Picker(AppText.t("Language"), selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.title).tag(language)
                }
            }
            .pickerStyle(.inline)
        }
        .navigationTitle(Text(verbatim: AppText.t("Language")))
    }
}

struct KeyboardSetupView: View {
    var body: some View {
        Form {
            Section {
                step(1, AppText.t("Open Settings > General > Keyboard > Keyboards."))
                step(2, AppText.t("Tap Add New Keyboard and choose VoiceDraft."))
                step(3, AppText.t("Tap VoiceDraft and turn on Allow Full Access."))
                step(4, AppText.t("In any text field, hold the globe key and pick VoiceDraft."))
                Button(AppText.t("Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } header: {
                Text(verbatim: AppText.t("Enable the keyboard"))
            }
            Section {
                Text(verbatim: AppText.t("Full Access lets the keyboard read the last result and the app's status from the shared app-group container. That is all it is used for."))
                Text(verbatim: AppText.t("The keyboard extension contains no networking code: it cannot send anything anywhere. Its source code is open, so you can verify this."))
                Text(verbatim: AppText.t("To dictate from the keyboard, turn on Listening in VoiceDraft first. Without it the keyboard can still insert the last result."))
            } header: {
                Text(verbatim: AppText.t("Why Full Access"))
            }
        }
        .navigationTitle(Text(verbatim: AppText.t("Keyboard setup")))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)").font(.headline).foregroundStyle(.tint)
            Text(verbatim: text)
        }
    }
}

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(AppText.t("Version"), value: version)
            }
            Section {
                Text(verbatim: AppText.t("VoiceDraft is free software under the GNU Affero General Public License v3.0. You bring your own provider keys; audio and text go directly from this iPhone to the providers you configure. The developer runs no service that receives your data."))
            } header: {
                Text(verbatim: AppText.t("License"))
            }
            Section {
                Link(AppText.t("Source code"), destination: URL(string: "https://github.com/ElmerZhang/voicedraft")!)
                Link(AppText.t("Issues"), destination: URL(string: "https://github.com/ElmerZhang/voicedraft/issues")!)
                Link(AppText.t("License"), destination: URL(string: "https://github.com/ElmerZhang/voicedraft/blob/main/LICENSE")!)
                Link(AppText.t("Security policy"), destination: URL(string: "https://github.com/ElmerZhang/voicedraft/blob/main/SECURITY.md")!)
                Link(AppText.t("GNU AGPL v3.0"), destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!)
            } header: {
                Text(verbatim: AppText.t("Links"))
            }
        }
        .navigationTitle(Text(verbatim: AppText.t("About")))
    }
}
