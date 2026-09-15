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

                Button(action: addProfile) {
                    Image(systemName: "plus")
                }
                .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(Text("Save the current setup as a profile"))

                Button(action: deleteSelected) {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help(Text("Delete the selected profile"))
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = model.profiles.first(where: { $0.id == selection }) {
            Form {
                Section {
                    LabeledContent {
                        Text("\(profile.settings.count)")
                    } label: {
                        Text("Apps with explicit settings")
                    }

                    LabeledContent {
                        Text(profile.unlistedApps == nil
                            ? String(localized: "Left as they are")
                            : String(localized: "Set to a shared fallback"))
                    } label: {
                        Text("Other apps")
                    }

                    if let focus = profile.focus, focus.isActive {
                        LabeledContent {
                            Text("\(focus.allowedApps.count)")
                        } label: {
                            Text("Apps allowed in focus mode")
                        }
                    }
                } header: {
                    Text(profile.name)
                }

                Section {
                    Button {
                        model.activateProfile(profile)
                    } label: {
                        Text("Activate this profile")
                    }
                    .disabled(profile.id == model.activeProfileID)

                    Button(role: .destructive) {
                        model.deleteProfile(profile)
                        selection = nil
                    } label: {
                        Text("Delete profile")
                    }
                }

                Section {
                    Text("Activating a profile clears per-app overrides so the profile is exactly what you hear. Change anything afterwards and save it as a new profile to keep it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
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
        model.deleteProfile(profile)
        selection = nil
    }
}
