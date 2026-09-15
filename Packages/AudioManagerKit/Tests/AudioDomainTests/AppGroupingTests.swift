import Testing

@testable import AudioDomain

@Suite("App grouping")
struct AppGroupingTests {

    private func process(
        id: UInt32,
        pid: Int32,
        bundle: String? = nil,
        containerBundle: String? = nil,
        containerPath: String? = nil,
        name: String? = nil,
        playing: Bool = false,
        regular: Bool? = nil
    ) -> AudioProcessSnapshot {
        AudioProcessSnapshot(
            audioObjectID: id,
            processID: pid,
            bundleIdentifier: bundle,
            containerBundlePath: containerPath,
            containerBundleIdentifier: containerBundle,
            displayName: name,
            isRunningOutput: playing,
            // Belonging to an app bundle stands in for "the user can see this app",
            // which is what the real resolver reports from the workspace.
            isRegularApp: regular ?? (containerPath != nil)
        )
    }

    @Test("Chrome helper processes collapse into a single Chrome row")
    func chromeHelpersGroup() {
        let processes = [
            process(
                id: 1, pid: 100,
                bundle: "com.google.Chrome.helper.renderer",
                containerBundle: "com.google.Chrome",
                containerPath: "/Applications/Google Chrome.app",
                name: "Google Chrome",
                playing: true
            ),
            process(
                id: 2, pid: 101,
                bundle: "com.google.Chrome.helper.renderer",
                containerBundle: "com.google.Chrome",
                containerPath: "/Applications/Google Chrome.app",
                name: "Google Chrome"
            ),
            process(
                id: 3, pid: 102,
                bundle: "com.google.Chrome",
                containerBundle: "com.google.Chrome",
                containerPath: "/Applications/Google Chrome.app",
                name: "Google Chrome"
            ),
        ]

        let apps = AppGrouping.group(processes)

        #expect(apps.count == 1)
        #expect(apps[0].key == .bundle("com.google.Chrome"))
        #expect(apps[0].name == "Google Chrome")
        #expect(apps[0].processes.count == 3)
        #expect(apps[0].isPlaying)
        #expect(apps[0].audioObjectIDs == [1, 2, 3])
    }

    @Test(
        "Helper suffixes are stripped",
        arguments: [
            ("com.google.Chrome.helper", "com.google.Chrome"),
            ("com.google.Chrome.helper.renderer", "com.google.Chrome"),
            ("com.google.Chrome.helper.gpu", "com.google.Chrome"),
            ("com.microsoft.VSCode.helper.plugin", "com.microsoft.VSCode"),
            ("com.spotify.client", "com.spotify.client"),
            ("com.apple.Music", "com.apple.Music"),
        ]
    )
    func stripsHelperSuffix(input: String, expected: String) {
        #expect(AppGrouping.normalizedBundleIdentifier(input) == expected)
    }

    @Test("Playing apps sort above silent ones, then alphabetically")
    func sortsPlayingFirst() {
        let processes = [
            process(id: 1, pid: 1, containerBundle: "com.zebra.App", containerPath: "/Applications/Zebra.app", name: "Zebra"),
            process(id: 2, pid: 2, containerBundle: "com.alpha.App", containerPath: "/Applications/Alpha.app", name: "Alpha"),
            process(id: 3, pid: 3, containerBundle: "com.middle.App", containerPath: "/Applications/Middle.app", name: "Middle", playing: true),
        ]

        let apps = AppGrouping.group(processes)

        #expect(apps.map(\.name) == ["Middle", "Alpha", "Zebra"])
    }

    @Test("System audio daemons are never listed")
    func hidesSystemProcesses() {
        let processes = [
            process(id: 1, pid: 500, bundle: "com.apple.audiomxd", playing: true),
            process(id: 2, pid: 501, bundle: "com.apple.controlcenter"),
            process(id: 3, pid: 502, containerBundle: "com.apple.Music", containerPath: "/Applications/Music.app", name: "Music"),
        ]

        let apps = AppGrouping.group(processes)

        #expect(apps.map(\.name) == ["Music"])
    }

    @Test("A bundle-less process is listed only while it is playing")
    func commandLineToolOnlyWhilePlaying() {
        let silent = process(id: 1, pid: 900)
        let playing = process(id: 2, pid: 901, playing: true)

        #expect(AppGrouping.group([silent]).isEmpty)
        #expect(AppGrouping.group([playing]).count == 1)
        #expect(AppGrouping.group([playing])[0].key == .process(901))
    }

    @Test("Grouping is stable when the same input is regrouped")
    func stableOrdering() {
        let processes = [
            process(id: 1, pid: 1, containerBundle: "com.b.App", containerPath: "/Applications/B.app", name: "Same"),
            process(id: 2, pid: 2, containerBundle: "com.a.App", containerPath: "/Applications/A.app", name: "Same"),
        ]

        let first = AppGrouping.group(processes).map(\.key)
        let second = AppGrouping.group(processes.reversed()).map(\.key)

        #expect(first == second)
        #expect(first == [.bundle("com.a.App"), .bundle("com.b.App")])
    }

    @Test("A background agent is hidden unless it is actually playing")
    func hidesBackgroundAgents() {
        let silentAgent = process(
            id: 1, pid: 700,
            containerBundle: "com.example.agent",
            containerPath: "/Applications/Agent.app",
            name: "Agent",
            regular: false
        )
        let playingAgent = process(
            id: 2, pid: 701,
            containerBundle: "com.example.agent",
            containerPath: "/Applications/Agent.app",
            name: "Agent",
            playing: true,
            regular: false
        )

        #expect(AppGrouping.group([silentAgent]).isEmpty)
        #expect(AppGrouping.group([playingAgent]).count == 1)
    }

    @Test("Explicitly excluded bundle identifiers never appear")
    func honoursExclusions() {
        let processes = [
            process(id: 1, pid: 1, containerBundle: "com.barackilic.AudioManager", containerPath: "/Applications/Audio Manager.app", name: "Audio Manager"),
            process(id: 2, pid: 2, containerBundle: "com.apple.Music", containerPath: "/Applications/Music.app", name: "Music"),
        ]

        let apps = AppGrouping.group(processes, excluding: ["com.barackilic.AudioManager"])

        #expect(apps.map(\.name) == ["Music"])
    }

    @Test("An excluded app's helper processes are hidden too")
    func exclusionCoversHelpers() {
        let helper = process(
            id: 1, pid: 1,
            bundle: "com.barackilic.AudioManager.helper",
            containerBundle: "com.barackilic.AudioManager",
            containerPath: "/Applications/Audio Manager.app",
            name: "Audio Manager",
            playing: true
        )

        #expect(AppGrouping.group([helper], excluding: ["com.barackilic.AudioManager"]).isEmpty)
    }
}
