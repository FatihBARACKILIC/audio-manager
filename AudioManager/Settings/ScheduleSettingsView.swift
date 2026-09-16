import AudioDomain
import SwiftUI

/// Time-based rules: "mute Slack and Mail on weekdays from 09:00 to 12:30".
struct ScheduleSettingsView: View {
    @Bindable var model: AppModel
    @State private var selection: ScheduleRule.ID?

    var body: some View {
        HSplitView {
            ruleList
                .frame(minWidth: 220)

            detail
                .frame(minWidth: 340)
        }
    }

    private var ruleList: some View {
        VStack(spacing: 0) {
            if model.activeScheduleRuleNames.isEmpty {
                Text("No rule is active right now")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else {
                Label(
                    model.activeScheduleRuleNames.joined(separator: ", "),
                    systemImage: "clock.fill"
                )
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            Divider()

            List(selection: $selection) {
                ForEach(model.scheduleRules) { rule in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.name)
                        Text(summary(for: rule))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .opacity(rule.isEnabled ? 1 : 0.5)
                    .tag(rule.id)
                }
            }

            Divider()

            HStack {
                Button(action: addRule) {
                    Image(systemName: "plus")
                }
                .help(Text("Add a rule"))

                Button(action: deleteSelected) {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help(Text("Delete the selected rule"))

                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let index = model.scheduleRules.firstIndex(where: { $0.id == selection }) {
            RuleEditor(
                model: model,
                rule: Binding(
                    get: { model.scheduleRules[index] },
                    set: { model.updateScheduleRule($0) }
                )
            )
        } else {
            VStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Select a rule")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(for rule: ScheduleRule) -> String {
        let days = rule.weekdays.count == 7
            ? String(localized: "Every day")
            : rule.weekdays.sorted { $0.rawValue < $1.rawValue }.map(shortName).joined(separator: " ")
        return "\(days)  \(time(rule.start))–\(time(rule.end))"
    }

    private func time(_ value: TimeOfDay) -> String {
        String(format: "%02d:%02d", value.hour, value.minute)
    }

    private func shortName(_ weekday: Weekday) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let index = weekday.rawValue - 1
        return index < symbols.count ? symbols[index] : "?"
    }

    private func addRule() {
        let rule = ScheduleRule(
            name: String(localized: "New rule"),
            weekdays: Weekday.weekdays,
            start: TimeOfDay(hour: 9, minute: 0),
            end: TimeOfDay(hour: 17, minute: 0),
            action: .muteApps([])
        )
        model.addScheduleRule(rule)
        selection = rule.id
    }

    private func deleteSelected() {
        guard let rule = model.scheduleRules.first(where: { $0.id == selection }) else { return }
        model.deleteScheduleRule(rule)
        selection = nil
    }
}

private struct RuleEditor: View {
    @Bindable var model: AppModel
    @Binding var rule: ScheduleRule

    var body: some View {
        Form {
            Section {
                TextField(text: $rule.name) {
                    Text("Name")
                }
                Toggle(isOn: $rule.isEnabled) {
                    Text("Enabled")
                }
            }

            Section {
                HStack(spacing: 4) {
                    ForEach(Weekday.allCases, id: \.rawValue) { weekday in
                        Toggle(isOn: Binding(
                            get: { rule.weekdays.contains(weekday) },
                            set: { isOn in
                                if isOn {
                                    rule.weekdays.insert(weekday)
                                } else {
                                    rule.weekdays.remove(weekday)
                                }
                            }
                        )) {
                            Text(shortName(weekday))
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                    }
                }

                timePicker(title: String(localized: "From"), time: $rule.start)
                timePicker(title: String(localized: "To"), time: $rule.end)

                if rule.wrapsMidnight, !rule.isEffectivelyEmpty {
                    Text("This window runs past midnight into the next day.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if rule.start == rule.end {
                    Text("A rule that starts and ends at the same time never runs.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("When")
            }

            Section {
                Picker(selection: Binding(
                    get: { actionKind },
                    set: { setActionKind($0) }
                )) {
                    Text("Mute apps").tag(ActionKind.mute)
                    Text("Focus on apps").tag(ActionKind.focus)
                    Text("Activate a profile").tag(ActionKind.profile)
                } label: {
                    Text("Do this")
                }

                switch rule.action {
                case .muteApps(let keys):
                    appPicker(selected: keys) { rule.action = .muteApps($0) }
                case .focusOn(let keys):
                    appPicker(selected: keys) { rule.action = .focusOn($0) }
                case .applyProfile(let id):
                    Picker(selection: Binding(
                        get: { id },
                        set: { rule.action = .applyProfile($0) }
                    )) {
                        ForEach(model.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    } label: {
                        Text("Profile")
                    }
                    .disabled(model.profiles.isEmpty)
                }
            } header: {
                Text("What")
            }
        }
        .formStyle(.grouped)
    }

    private enum ActionKind: Hashable {
        case mute, focus, profile
    }

    private var actionKind: ActionKind {
        switch rule.action {
        case .muteApps: .mute
        case .focusOn: .focus
        case .applyProfile: .profile
        }
    }

    private func setActionKind(_ kind: ActionKind) {
        switch kind {
        case .mute: rule.action = .muteApps([])
        case .focus: rule.action = .focusOn([])
        case .profile:
            if let first = model.profiles.first {
                rule.action = .applyProfile(first.id)
            }
        }
    }

    private func appPicker(selected: Set<AppKey>, update: @escaping (Set<AppKey>) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.apps.isEmpty {
                Text("No apps are running to choose from yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.apps) { app in
                Toggle(isOn: Binding(
                    get: { selected.contains(app.key) },
                    set: { isOn in
                        var keys = selected
                        if isOn {
                            keys.insert(app.key)
                        } else {
                            keys.remove(app.key)
                        }
                        update(keys)
                    }
                )) {
                    Text(app.name)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
        }
    }

    private func timePicker(title: String, time: Binding<TimeOfDay>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: Binding(
                get: { time.wrappedValue.hour },
                set: { time.wrappedValue = TimeOfDay(hour: $0, minute: time.wrappedValue.minute) }
            ), in: 0...23) {
                Text(String(format: "%02d", time.wrappedValue.hour))
                    .monospacedDigit()
            }
            Text(verbatim: ":")
            Stepper(value: Binding(
                get: { time.wrappedValue.minute },
                set: { time.wrappedValue = TimeOfDay(hour: time.wrappedValue.hour, minute: $0) }
            ), in: 0...59, step: 5) {
                Text(String(format: "%02d", time.wrappedValue.minute))
                    .monospacedDigit()
            }
        }
    }

    private func shortName(_ weekday: Weekday) -> String {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let index = weekday.rawValue - 1
        return index < symbols.count ? symbols[index] : "?"
    }
}
