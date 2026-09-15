import AudioDomain
import AudioPersistence
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }

            ProfileSettingsView(model: model)
                .tabItem { Label("Profiles", systemImage: "square.stack.3d.up") }

            ScheduleSettingsView(model: model)
                .tabItem { Label("Schedule", systemImage: "clock") }

            ShortcutSettingsView(model: model)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(minWidth: 620, minHeight: 440)
    }
}

struct GeneralSettingsView: View {
    @Bindable var model: AppModel
    @State private var limitEnabled = true
    @State private var maximumGain = 1.0

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
        }
        .formStyle(.grouped)
        .onAppear {
            limitEnabled = model.outputLimit.isEnabled
            maximumGain = model.outputLimit.maximumGain
        }
        .onChange(of: limitEnabled) { _, _ in commitLimit() }
        .onChange(of: maximumGain) { _, _ in commitLimit() }
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
