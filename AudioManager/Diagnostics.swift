import AudioDomain
import Foundation

/// Prints what the app currently sees and would do, then exits.
///
/// Run with `--dump-state`. Useful when something looks wrong on a user's machine:
/// it shows the grouped app list and the effective decision per app without needing
/// the UI, and it reads state only — it never changes anything.
@MainActor
enum Diagnostics {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--dump-state")
    }

    /// Seconds to keep the engine running before reporting, from `--watch <seconds>`.
    /// Lets a script confirm that audio is really flowing through the render path.
    static var watchSeconds: Double? {
        guard let index = CommandLine.arguments.firstIndex(of: "--watch"),
              index + 1 < CommandLine.arguments.count
        else { return nil }
        return Double(CommandLine.arguments[index + 1])
    }

    static func dump(_ model: AppModel) {
        setvbuf(stdout, nil, _IONBF, 0)

        print("engine: \(model.engineStatus)")
        if !model.levels.isEmpty {
            let levels = model.levels
                .map { "\($0.key.rawValue)=\(String(format: "%.4f", $0.value))" }
                .sorted()
                .joined(separator: " ")
            print("levels: \(levels)")
        }

        print("permission: \(model.permission.rawValue)")
        print("focus: \(model.focus.isActive ? "on" : "off"), profile: \(model.activeProfile?.name ?? "none")")
        let rules = model.activeScheduleRuleNames
        print("schedule: \(model.scheduleRules.count) rule(s), active now: \(rules.isEmpty ? "none" : rules.joined(separator: ", "))")
        if !model.scheduleMutedApps.isEmpty {
            print("muted by schedule: \(model.scheduleMutedApps.map(\.rawValue).sorted().joined(separator: ", "))")
        }
        print("apps: \(model.apps.count)")

        for app in model.apps {
            let state = model.state(for: app.key)
            let settings = model.settings(for: app.key)
            let flags = [
                app.isPlaying ? "playing" : nil,
                state.isMuted ? "muted" : nil,
                state.needsRendering ? "rendering" : nil,
                state.isPassthrough ? "untouched" : nil,
            ].compactMap { $0 }.joined(separator: ",")

            print("""
                  - \(app.name)
                      key: \(app.key.rawValue)
                      processes: \(app.processes.count) \(app.audioObjectIDs)
                      mode: \(settings.mode.rawValue) volume: \(String(format: "%.2f", settings.volume)) gain: \(String(format: "%.3f", state.gain))
                      flags: \(flags) decided by: \(state.reason.rawValue)
                  """)
        }
    }
}
