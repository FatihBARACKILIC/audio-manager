import AudioDomain
import SwiftUI

/// One app in the panel: icon, name, mute, volume, and the advanced controls behind a
/// disclosure so the common case stays a single glance.
struct AppRowView: View {
    @Bindable var model: AppModel
    let app: AudioApp
    let isExpanded: Bool
    let onToggleExpanded: () -> Void

    private var state: EffectiveAppState { model.state(for: app.key) }
    private var settings: AppAudioSettings { model.settings(for: app.key) }

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if let override {
                overrideNotice(override)
                    .padding(.leading, 50)
                    .padding(.trailing, 14)
                    .padding(.top, 4)
            }
            if isExpanded {
                advancedControls
                    .padding(.leading, 46)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
            }
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
    }

    private var mainRow: some View {
        HStack(spacing: 10) {
            AppIconView(bundlePath: app.bundlePath, isPlaying: app.isPlaying)
                .frame(width: 26, height: 26)
                .padding(.leading, 14)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.callout)
                        .lineLimit(1)

                    if app.isPlaying {
                        LevelIndicator(level: model.levels[app.key] ?? 0)
                            .accessibilityHidden(true)
                    }

                    // The override notice below already says this in words, so the
                    // badge is only worth the space when there is no notice.
                    if state.reason != .manual, override == nil {
                        Image(systemName: reasonSymbol)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(reasonDescription)
                    }
                }

                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { settings.volume },
                            set: { model.setVolume($0, for: app.key) }
                        ),
                        in: 0...1
                    )
                    .controlSize(.mini)
                    .disabled(state.isMuted)
                    .accessibilityLabel(Text("Volume for \(app.name)"))
                    .accessibilityHint(override.map(\.explanation) ?? Text(""))
                    .accessibilityValue(Text("\(Int(settings.volume * 100)) percent"))

                    Text("\(Int(settings.volume * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Button {
                model.toggleMute(for: app.key)
            } label: {
                Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .disabled(override != nil)
            .foregroundStyle(muteButtonTint)
            .help(muteButtonHelp)
            .accessibilityLabel(state.isMuted ? Text("Unmute \(app.name)") : Text("Mute \(app.name)"))

            Button(action: onToggleExpanded) {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .padding(.trailing, 14)
            .accessibilityLabel(Text("More options for \(app.name)"))
        }
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(selection: Binding(
                get: { settings.mode },
                set: { model.setMode($0, for: app.key) }
            )) {
                Text("Mute only").tag(ControlMode.muteOnly)
                Text("Full control").tag(ControlMode.fullControl)
            } label: {
                Text("Mode")
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            Text(settings.mode == .muteOnly
                ? "Mute only silences this app at the source. No processing, no added delay."
                : "Full control routes this app through Audio Manager so volume, boost and EQ work. Adds a few milliseconds of delay — fine for music and video, less ideal for calls.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.mode == .fullControl {
                HStack(spacing: 8) {
                    Text("Boost")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { settings.boostDecibels },
                            set: { model.setBoost(decibels: $0, for: app.key) }
                        ),
                        in: AppAudioSettings.boostRange
                    )
                    .controlSize(.mini)
                    .accessibilityLabel(Text("Boost for \(app.name)"))
                    Text("+\(Int(settings.boostDecibels)) dB")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }

                EqualizerView(
                    settings: Binding(
                        get: { settings.equalizer },
                        set: { model.setEqualizer($0, for: app.key) }
                    )
                )
            }

            HStack {
                Toggle(isOn: Binding(
                    get: { model.focus.allowedApps.contains(app.key) },
                    set: { _ in model.toggleFocusMembership(for: app.key) }
                )) {
                    Text("Allow in focus mode")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Spacer()

                Button {
                    model.resetSettings(for: app.key)
                } label: {
                    Text("Reset")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Something the user cannot change from this row is deciding this app's state.
    ///
    /// Only schedule rules and focus mode qualify: a profile's settings are overridden
    /// the moment the user touches the row, so a profile never leaves a control dead.
    private struct Override {
        var explanation: Text
        var actionLabel: Text
        var action: () -> Void
    }

    private var override: Override? {
        guard state.isMuted else { return nil }
        switch state.reason {
        case .schedule:
            return Override(
                explanation: Text("Muted by a schedule rule"),
                actionLabel: Text("Change\u{2026}"),
                action: { AppCommands.openSettings(tab: .schedule) }
            )
        case .focusMode:
            return Override(
                explanation: Text("Muted by focus mode"),
                actionLabel: Text("Allow"),
                action: { model.toggleFocusMembership(for: app.key) }
            )
        case .manual, .profile:
            return nil
        }
    }

    private func overrideNotice(_ override: Override) -> some View {
        HStack(spacing: 6) {
            Image(systemName: state.reason == .schedule ? "clock.fill" : "moon.fill")
                .font(.caption2)
            override.explanation
                .font(.caption2)
            Button(action: override.action) {
                override.actionLabel
                    .font(.caption2)
            }
            .buttonStyle(.link)
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    private var muteButtonTint: Color {
        if override != nil { return .secondary }
        return state.isMuted ? Color.accentColor : Color.secondary
    }

    private var muteButtonHelp: Text {
        if let override {
            return override.explanation
        }
        return state.isMuted ? Text("Unmute \(app.name)") : Text("Mute \(app.name)")
    }

    private var reasonSymbol: String {
        switch state.reason {
        case .focusMode: "moon.fill"
        case .schedule: "clock.fill"
        case .profile: "square.stack.3d.up.fill"
        case .manual: "hand.point.up.left"
        }
    }

    private var reasonDescription: Text {
        switch state.reason {
        case .focusMode: Text("Set by focus mode")
        case .schedule: Text("Set by a schedule rule")
        case .profile: Text("Set by the active profile")
        case .manual: Text("Set by you")
        }
    }
}

/// App icon with a subtle "currently playing" ring.
struct AppIconView: View {
    let bundlePath: String?
    let isPlaying: Bool

    var body: some View {
        ZStack {
            if let image = AppIconCache.shared.icon(forBundlePath: bundlePath) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.tertiary)
            }
        }
        .overlay {
            if isPlaying {
                Circle()
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Three bars that rise with the app's level. Only ever animated while the panel is
/// open, because that is the only time the model publishes levels.
struct LevelIndicator: View {
    let level: Float

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor.opacity(opacity(for: index)))
                    .frame(width: 2, height: height(for: index))
            }
        }
        .frame(height: 9, alignment: .bottom)
    }

    private func height(for index: Int) -> CGFloat {
        let scaled = CGFloat(min(max(level, 0), 1))
        let base: CGFloat = [4, 9, 6][index]
        return max(2, base * (0.35 + scaled * 0.65))
    }

    private func opacity(for index: Int) -> Double {
        level > Float(index) * 0.25 ? 0.9 : 0.25
    }
}
