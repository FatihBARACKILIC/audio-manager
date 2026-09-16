import AudioDomain
import SwiftUI

/// Profiles: save the current per-app setup under a name and switch back to it later.
struct ProfileSettingsView: View {
    @Bindable var model: AppModel
    @State private var newProfileName = ""
    @State private var selection: AudioProfile.ID?

    var body: some View {
        HSplitView {
            profileList
                .frame(minWidth: 200)

            detail
                .frame(minWidth: 320)
        }
        .padding(.bottom, 1)
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(model.profiles) { profile in
                    HStack {
                        Text(profile.name)
                        Spacer()
                        if profile.id == model.activeProfileID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel(Text("Active profile"))
                        }
                    }
                    .tag(profile.id)
                }
            }

            Divider()

            HStack(spacing: 6) {
                TextField(text: $newProfileName) {
                    Text("New profile name")
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(addProfile)

                ListActionButton(
                    symbol: "plus",
                    label: Text("Save the current setup as a profile"),
                    isEnabled: !newProfileName.trimmingCharacters(in: .whitespaces).isEmpty,
                    action: addProfile
                )

                ListActionButton(
                    symbol: "minus",
                    label: Text("Delete the selected profile"),
                    isEnabled: selection != nil,
                    action: deleteSelected
                )
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = model.profiles.first(where: { $0.id == selection }) {
            ProfileEditor(model: model, profile: profile) {
                selection = nil
            }
            .id(profile.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Select a profile")
                    .foregroundStyle(.secondary)
                Text("Set up your apps the way you want them, then save that as a profile.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.saveCurrentAsProfile(named: name)
        newProfileName = ""
        selection = model.profiles.last?.id
    }

    private func deleteSelected() {
        guard let profile = model.profiles.first(where: { $0.id == selection }) else { return }
        selection = nil
        model.deleteProfile(profile)
    }
}

/// One profile: what it does, and the two things you can do to it.
///
/// A profile is edited by activating it, changing apps in the panel and folding those
/// changes back in — there is no separate editor for every setting, because the panel
/// already is one and duplicating it would mean two places to get wrong.
private struct ProfileEditor: View {
    @Bindable var model: AppModel
    let profile: AudioProfile
    let onDelete: () -> Void

    @State private var name: String = ""

    private var isActive: Bool { profile.id == model.activeProfileID }

    var body: some View {
        Form {
            Section {
                TextField(text: $name) {
                    Text("Name")
                }
                .onAppear { name = profile.name }
                .onSubmit { model.renameProfile(profile, to: name) }

                LabeledContent {
                    (isActive ? Text("Active") : Text("Not active"))
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                } label: {
                    Text("Status")
                }
            } header: {
                Text("Profile")
            }

            Section {
                if profile.settings.isEmpty {
                    Text("This profile changes nothing yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.key) { entry in
                        LabeledContent {
                            Text(describe(entry.settings))
                                .foregroundStyle(.secondary)
                        } label: {
                            Text(displayName(for: entry.key))
                        }
                    }
                }

                if let unlisted = profile.unlistedApps {
                    LabeledContent {
                        Text(describe(unlisted))
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("Every other app")
                    }
                }

                if let focus = profile.focus, focus.isActive {
                    LabeledContent {
                        Text(verbatim: "\(focus.allowedApps.count)")
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("Apps allowed in focus mode")
                    }
                }
            } header: {
                Text("What it does")
            }

            Section {
                Button {
                    model.activateProfile(profile)
                } label: {
                    Text("Activate this profile")
                }
                .disabled(isActive)

                Button {
                    model.updateProfile(profile)
                } label: {
                    Text("Update from current setup")
                }
                .disabled(!isActive)

                Button(role: .destructive) {
                    onDelete()
                    model.deleteProfile(profile)
                } label: {
                    Text("Delete profile")
                }
            } footer: {
                Text(isActive
                    ? "Change any app in the panel, then press Update to fold those changes into this profile."
                    : "Activate this profile first to change what it contains.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var entries: [(key: AppKey, settings: AppAudioSettings)] {
        profile.settings
            .map { (key: $0.key, settings: $0.value) }
            .sorted { displayName(for: $0.key).localizedCaseInsensitiveCompare(displayName(for: $1.key)) == .orderedAscending }
    }

    /// The app's real name when it is running, and its stored key when it is not — a
    /// profile keeps settings for apps that are closed, and hiding them would make the
    /// list look wrong.
    private func displayName(for key: AppKey) -> String {
        model.apps.first { $0.key == key }?.name ?? key.rawValue
    }

    private func describe(_ settings: AppAudioSettings) -> String {
        if settings.isMuted {
            return String(localized: "Muted")
        }
        var parts = [String(localized: "\(Int(settings.volume * 100))% volume")]
        if settings.boostDecibels > 0 {
            parts.append(String(localized: "+\(Int(settings.boostDecibels)) dB"))
        }
        if !settings.equalizer.isFlat {
            parts.append(String(localized: "EQ on"))
        }
        return parts.joined(separator: ", ")
    }
}
