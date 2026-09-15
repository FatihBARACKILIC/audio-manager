import AudioDomain
import SwiftUI

/// The menu bar panel: the whole app in one place for the common case.
struct PanelView: View {
    @Bindable var model: AppModel
    @State private var expandedApp: AppKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if model.permission != .granted {
                PermissionBanner(model: model)
            }

            if let warning = model.loadWarning {
                banner(warning, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }

            if case .degraded(let failure) = model.engineStatus {
                banner(message(for: failure), symbol: "exclamationmark.triangle", tint: .orange)
            }

            Divider()

            if model.apps.isEmpty {
                emptyState
            } else {
                appList
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear { model.isPanelVisible = true }
        .onDisappear { model.isPanelVisible = false }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Text("Audio Manager")
                .font(.headline)

            Spacer()

            Button {
                model.toggleFocusMode()
            } label: {
                Label("Focus", systemImage: model.focus.isActive ? "moon.fill" : "moon")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.focus.isActive ? Color.accentColor : Color.secondary)
            .help(model.focus.isActive
                ? Text("Focus mode is on. Only allowed apps can make sound.")
                : Text("Turn on focus mode"))

            Button {
                AppCommands.openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("Open settings"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.apps) { app in
                    AppRowView(
                        model: model,
                        app: app,
                        isExpanded: expandedApp == app.key,
                        onToggleExpanded: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expandedApp = expandedApp == app.key ? nil : app.key
                            }
                        }
                    )
                    if app.key != model.apps.last?.key {
                        Divider().padding(.leading, 46)
                    }
                }
            }
        }
        .frame(maxHeight: 420)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.slash")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No apps with audio yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Apps appear here as soon as they are running.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    model.activateProfile(nil)
                } label: {
                    Text("No profile")
                }
                if !model.profiles.isEmpty {
                    Divider()
                    ForEach(model.profiles) { profile in
                        Button {
                            model.activateProfile(profile)
                        } label: {
                            Text(profile.name)
                        }
                    }
                }
            } label: {
                Label(
                    model.activeProfile?.name ?? String(localized: "No profile"),
                    systemImage: "square.stack.3d.up"
                )
                .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func banner(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func message(for failure: EngineFailure) -> String {
        switch failure {
        case .permissionDenied:
            String(localized: "Audio Manager needs permission to capture system audio.")
        case .tapCreationFailed:
            String(localized: "One app could not be controlled and was left untouched.")
        case .deviceUnavailable:
            String(localized: "The output device changed. Audio is playing normally.")
        case .protectedContent:
            String(localized: "This app plays protected content that cannot be controlled.")
        case .formatUnsupported:
            String(localized: "This app's audio format is not supported.")
        }
    }
}

/// Shown at the top of the panel until the user grants audio capture access.
struct PermissionBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Permission needed")
                    .font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: "waveform.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }

            Text("macOS treats controlling another app's volume as capturing its audio. Audio Manager never records or stores anything.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if model.permission == .notDetermined {
                    Button {
                        Task { await model.requestPermission() }
                    } label: {
                        Text("Grant access")
                    }
                    .controlSize(.small)
                } else {
                    Button {
                        openPrivacySettings()
                    } label: {
                        Text("Open System Settings")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    private func openPrivacySettings() {
        guard
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
