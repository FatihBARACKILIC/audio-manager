import AppKit
import AudioDomain
import AudioPersistence
import SwiftUI
import UniformTypeIdentifiers

/// The settings window's tabs, named so the panel can send the user straight to the one
/// that explains what it just told them about.
enum SettingsTab: Hashable {
    case general
    case profiles
    case schedule
    case shortcuts
}

/// Which tab the settings window is showing.
///
/// Held outside the view so that asking for a tab works whether the window is being
/// built for the first time or is already open behind the panel.
@Observable
@MainActor
final class SettingsSelection {
    var tab: SettingsTab = .general
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            ProfileSettingsView(model: model)
                .tabItem { Label("Profiles", systemImage: "square.stack.3d.up") }
                .tag(SettingsTab.profiles)

            ScheduleSettingsView(model: model)
                .tabItem { Label("Schedule", systemImage: "clock") }
                .tag(SettingsTab.schedule)

            ShortcutSettingsView(model: model)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
        }
        .frame(minWidth: 620, minHeight: 440)
    }
}

struct GeneralSettingsView: View {
    @Bindable var model: AppModel
    @State private var limitEnabled = true
    @State private var maximumGain = 1.0
    @State private var isConfirmingRemoval = false
    @State private var removalFailure: String?
    @State private var transferMessage: TransferMessage?
    @State private var pendingImport: PersistedState?

    /// The one-line result shown under the export and import buttons.
    private struct TransferMessage {
        var text: String
        var isFailure: Bool
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.preferences.launchAtLogin },
                    set: { newValue in
                        model.preferences.launchAtLogin = LoginItem.synchronize(enabled: newValue)
                    }
                )) {
                    Text("Open at login")
                }

                Toggle(isOn: $model.preferences.showNotifications) {
                    Text("Show notifications when apps are muted or unmuted")
                }

                Toggle(isOn: $model.preferences.warnOnHighVolume) {
                    Text("Warn me when an app is boosted to a loud level")
                }
            } header: {
                Text("General")
            }

            Section {
                Toggle(isOn: $limitEnabled) {
                    Text("Limit maximum volume")
                }

                HStack {
                    Slider(value: $maximumGain, in: OutputLimit.range)
                        .disabled(!limitEnabled)
                    Text(gainLabel)
                        .font(.body.monospacedDigit())
                        .frame(width: 70, alignment: .trailing)
                        .foregroundStyle(limitEnabled ? .primary : .secondary)
                }

                Text("Applied after volume, boost and EQ, so nothing can get past it. Values above 100% let quiet apps be amplified; keep it at or below 100% to protect your hearing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hearing safety")
            }

            Section {
                LabeledContent {
                    Text(permissionDescription)
                        .foregroundStyle(model.permission == .granted ? .secondary : .primary)
                } label: {
                    Text("Audio capture access")
                }

                if model.permission != .granted {
                    Button {
                        Task { await model.requestPermission() }
                    } label: {
                        Text("Grant access")
                    }
                }

                Text("macOS classifies controlling another app's volume as capturing its audio. Audio Manager processes audio in memory only — it never records, saves or sends anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Permission")
            }

            Section {
                HStack {
                    Button {
                        exportSettings()
                    } label: {
                        Text("Export\u{2026}")
                    }

                    Button {
                        importSettings()
                    } label: {
                        Text("Import\u{2026}")
                    }
                }

                Text("Saves your profiles, schedule rules and preferences to a file you keep. Import it after reinstalling, or on another Mac, to get everything back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let transferMessage {
                    Label(transferMessage.text, systemImage: transferMessage.isFailure
                          ? "exclamationmark.triangle.fill"
                          : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(transferMessage.isFailure ? .orange : .secondary)
                }
            } header: {
                Text("Your settings")
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingRemoval = true
                } label: {
                    Text("Remove Audio Manager\u{2026}")
                }

                Text("Deletes your profiles, schedule rules and preferences, unmutes every app and turns off Open at login. The app itself is then shown in Finder for you to drag to the Trash — macOS does not let a sandboxed app delete itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let removalFailure {
                    Label(removalFailure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Remove")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            limitEnabled = model.outputLimit.isEnabled
            maximumGain = model.outputLimit.maximumGain
        }
        .onChange(of: limitEnabled) { _, _ in commitLimit() }
        .onChange(of: maximumGain) { _, _ in commitLimit() }
        .alert(
            Text("Replace your settings?"),
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            )
        ) {
            Button(role: .cancel) {
                pendingImport = nil
            } label: {
                Text("Cancel")
            }

            Button(role: .destructive) {
                guard let state = pendingImport else { return }
                pendingImport = nil
                Task {
                    await model.replaceSettings(with: state)
                    transferMessage = TransferMessage(
                        text: String(localized: "Settings imported."),
                        isFailure: false
                    )
                }
            } label: {
                Text("Replace")
            }
        } message: {
            Text("Your current profiles, schedule rules and preferences will be replaced by the ones in that file. If that file has Open at login turned on, Audio Manager will register itself to start with your Mac.")
        }
        .alert(Text("Remove Audio Manager from this Mac?"), isPresented: $isConfirmingRemoval) {
            Button(role: .cancel) {
                isConfirmingRemoval = false
            } label: {
                Text("Cancel")
            }

            Button(role: .destructive) {
                Task { await remove() }
            } label: {
                Text("Remove")
            }
        } message: {
            removalMessage
        }
    }

    private var removalMessage: Text {
        if Uninstaller.looksLikeHomebrewInstall {
            return Text("Your profiles, schedule rules and preferences will be deleted and every app will be unmuted. If you want to keep them, cancel and use Export first.\n\nAudio Manager was installed with Homebrew, so finish with: brew uninstall --zap --cask audio-manager")
        }
        return Text("Your profiles, schedule rules and preferences will be deleted and every app will be unmuted. If you want to keep them, cancel and use Export first.\n\nAudio Manager will then quit and show itself in Finder, so you can drag it to the Trash.")
    }

    // MARK: - Export and import

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(SettingsTransfer.suggestedFileName).\(SettingsTransfer.fileExtension)"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try SettingsTransfer.data(for: model.currentPersistedState)
            try data.write(to: url, options: .atomic)
            transferMessage = TransferMessage(
                text: String(localized: "Settings saved to \(url.lastPathComponent)."),
                isFailure: false
            )
        } catch {
            transferMessage = TransferMessage(
                text: String(localized: "Your settings could not be saved to that location."),
                isFailure: true
            )
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            // Decoded before the confirmation, so a file that cannot be used says so
            // instead of asking the user to approve replacing everything with nothing.
            pendingImport = try SettingsTransfer.state(from: data)
            transferMessage = nil
        } catch let error as SettingsTransferError {
            transferMessage = TransferMessage(text: message(for: error), isFailure: true)
        } catch {
            transferMessage = TransferMessage(
                text: String(localized: "That file could not be read."),
                isFailure: true
            )
        }
    }

    private func message(for error: SettingsTransferError) -> String {
        switch error {
        case .unreadable:
            String(localized: "That is not an Audio Manager settings file. Choose the one you exported.")
        case .newerThanThisApp:
            String(localized: "That file was saved by a newer version of Audio Manager. Your settings have not been changed.")
        }
    }

    private func remove() async {
        let erased = await model.removeEverything()
        guard erased else {
            // Everything else is already undone; saying so beats quitting and leaving
            // the user to wonder whether their settings are really gone.
            removalFailure = String(localized: "Your settings could not be deleted. Everything else has been undone.")
            return
        }
        Uninstaller.revealAppInFinder()
        NSApp.terminate(nil)
    }

    private var gainLabel: String {
        String(format: "%.0f%%", maximumGain * 100)
    }

    private var permissionDescription: String {
        switch model.permission {
        case .granted: String(localized: "Granted")
        case .denied: String(localized: "Denied — enable it in System Settings")
        case .notDetermined: String(localized: "Not requested yet")
        }
    }

    private func commitLimit() {
        var limit = OutputLimit(maximumGain: maximumGain, isEnabled: limitEnabled)
        limit.setMaximumGain(maximumGain)
        model.setOutputLimit(limit)
    }
}

struct ShortcutSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                TextField(text: Binding(
                    get: { model.preferences.panelShortcut ?? "" },
                    set: { model.preferences.panelShortcut = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Open panel")
                }
                .onSubmit { AppCommands.shortcutsChanged() }

                TextField(text: Binding(
                    get: { model.preferences.focusShortcut ?? "" },
                    set: { model.preferences.focusShortcut = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Toggle focus mode")
                }
                .onSubmit { AppCommands.shortcutsChanged() }

                Text("Write shortcuts as modifiers plus a key, for example cmd+shift+v. Leave a field empty to remove its shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Keyboard shortcuts")
            }

            Section {
                LabeledContent {
                    Text(preview(model.preferences.panelShortcut))
                } label: {
                    Text("Open panel")
                }
                LabeledContent {
                    Text(preview(model.preferences.focusShortcut))
                } label: {
                    Text("Toggle focus mode")
                }
            } header: {
                Text("Currently registered")
            }
        }
        .formStyle(.grouped)
    }

    private func preview(_ text: String?) -> String {
        KeyboardShortcut.parse(text)?.displayString ?? String(localized: "None")
    }
}
