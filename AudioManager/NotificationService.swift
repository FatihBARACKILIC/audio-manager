import AudioDomain
import Foundation
import UserNotifications

/// Tells the user when something changed the audio *for* them, and warns about
/// dangerous levels.
///
/// Deliberately quiet: muting an app yourself needs no notification, you just did it.
/// Only automatic changes — a schedule rule firing, focus mode taking effect — and the
/// loudness warning are worth interrupting for.
@MainActor
final class NotificationService {
    private var isAuthorized = false
    private var hasAskedThisLaunch = false
    /// Apps already warned about, so one loud app cannot produce a stream of alerts.
    private var warnedApps: Set<AppKey> = []

    /// Gain above which a boost is worth warning about (about +6 dB).
    static let loudGainThreshold = 1.9

    func prepare(enabled: Bool) async {
        guard enabled, !hasAskedThisLaunch else { return }
        hasAskedThisLaunch = true
        isAuthorized = await requestAuthorization()
    }

    private func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            // Notifications are a nicety; failing to get permission must not affect
            // anything else the app does.
            return false
        }
    }

    /// Announces automatic mute changes. `manual` changes are skipped on purpose.
    func reportAutomaticChanges(
        previous: [AppKey: EffectiveAppState],
        current: [AppKey: EffectiveAppState],
        apps: [AudioApp],
        enabled: Bool
    ) {
        guard enabled, isAuthorized else { return }

        let names = Dictionary(apps.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })

        for (key, state) in current {
            guard state.reason == .schedule || state.reason == .focusMode else { continue }
            let wasMuted = previous[key]?.isMuted ?? false
            guard wasMuted != state.isMuted, let name = names[key] else { continue }

            let title = state.isMuted
                ? String(localized: "\(name) muted")
                : String(localized: "\(name) unmuted")
            let body = state.reason == .schedule
                ? String(localized: "A schedule rule changed this.")
                : String(localized: "Focus mode changed this.")
            post(title: title, body: body, identifier: "mute-\(key.rawValue)")
        }
    }

    /// Warns once per app when its gain crosses the loud threshold.
    func reportLoudApps(states: [AppKey: EffectiveAppState], apps: [AudioApp], enabled: Bool) {
        guard enabled, isAuthorized else { return }

        let names = Dictionary(apps.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })

        for (key, state) in states {
            let isLoud = !state.isMuted && state.gain >= NotificationService.loudGainThreshold
            if isLoud, !warnedApps.contains(key) {
                warnedApps.insert(key)
                guard let name = names[key] else { continue }
                post(
                    title: String(localized: "\(name) is boosted"),
                    body: String(localized: "This app is playing louder than its original level. Long listening at high volume can damage your hearing."),
                    identifier: "loud-\(key.rawValue)"
                )
            } else if !isLoud {
                warnedApps.remove(key)
            }
        }

        // Apps that stopped being controlled are dropped rather than remembered
        // forever, so a long session cannot grow this set without bound.
        warnedApps.formIntersection(states.keys)
    }

    private func post(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
