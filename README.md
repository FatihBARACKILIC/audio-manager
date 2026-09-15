# Audio Manager

Per-app volume control for macOS, from the menu bar.

Mute Slack while a video keeps playing. Turn Chrome down without touching Spotify. Give
one app an equalizer. Save it all as a profile and switch between profiles in a click.

macOS has no built-in way to do this, and no public API that simply sets another app's
volume. Audio Manager uses **Core Audio process taps** (macOS 14.2+): it captures an
app's output, silences the original, processes the audio and plays it back — all in
memory, never touching disk or the network.

## Features

- **Per-app volume, mute and boost** — every running app, controlled independently
- **Two modes per app** — *mute only* (no processing, no added latency, the default) or
  *full control* (volume, boost and EQ, a few milliseconds of latency)
- **10-band graphic equalizer** per app
- **Focus mode** — only the apps you allow can make sound
- **Profiles** — "Work", "Music", "Call"; save the current setup and switch back to it
- **Schedule rules** — mute Slack on weekdays from 09:00, run a profile every evening
- **Hearing safety limit** — a ceiling applied after every other gain stage
- **Global shortcuts** — open the panel (⌘⇧V by default) or toggle focus mode
- **English and Turkish**

## Requirements

- macOS 15 or later
- Apple Silicon or Intel
- Xcode 16 or later to build

## Permission

On first use macOS asks for permission to record system audio. This is unavoidable:
the system classifies *controlling* another app's volume as *capturing* it — there is no
separate, narrower permission.

Audio Manager never records, stores or transmits audio. Captured audio exists only in
memory for the milliseconds it takes to process it, and the app makes no network
connections at all. In *mute only* mode no audio is pulled from the app in the first
place.

## Building

```sh
git clone https://github.com/<you>/AudioManager.git
cd AudioManager
xcodebuild -project AudioManager.xcodeproj -scheme AudioManager -configuration Release build
```

Running the tests:

```sh
cd Packages/AudioManagerKit
swift test
```

## Architecture

```
AudioManager (app: AppKit shell + SwiftUI views)
        │
        ▼
AudioDomain  ◄──── AudioPersistence
        ▲
        │  implements the protocols AudioDomain declares
        │
   AudioCore  (Core Audio taps, aggregate device, DSP)
```

- **`AudioDomain`** — pure Swift: app grouping, volume curve, profiles, schedule engine,
  policy resolution. No Core Audio, no SwiftUI, fully unit tested.
- **`AudioCore`** — the only place Core Audio lives: tap lifecycle, one shared aggregate
  device, the real-time render graph and the equalizer.
- **`AudioPersistence`** — versioned JSON in Application Support, written atomically.
- **App target** — menu bar item, panel and settings. The shell is AppKit so a global
  shortcut can open the panel, which `MenuBarExtra` cannot do; every view is SwiftUI.

Design rules the code sticks to are written down in [AGENTS.md](AGENTS.md).

### Notes on how it works

- Chromium and Electron apps play audio from short-lived helper processes. Every process
  is attributed to the outermost `.app` bundle containing it, so a browser is one row.
- An app under *full control* is tapped with `CATapMutedWhenTapped`: if our render graph
  ever stops, the system plays that app normally again instead of leaving it silent.
- When no app needs muting or processing, the engine holds no Core Audio objects at all:
  no aggregate device, no IOProc, no timers.

## Measured cost

Release build, Apple Silicon, measured with `footprint` and 30-second CPU deltas:

| State | CPU | Memory |
|---|---|---|
| Idle, panel closed | 0.0% | 13 MB |
| 3 apps in full control with EQ, meters running | ~1.0% | 16 MB |

Taps also cost time inside `coreaudiod`, which is a separate process: about 8.5% of a
core with audio simply playing, and about 11% with three apps tapped.

## Diagnostics

The app supports a few flags for troubleshooting; none of them change stored settings:

```sh
AudioManager.app/Contents/MacOS/AudioManager --dump-state
AudioManager.app/Contents/MacOS/AudioManager --dump-state --simulate-control --watch 10
AudioManager.app/Contents/MacOS/AudioManager --reset-settings
AudioManager.app/Contents/MacOS/AudioManager --show-panel
```

`--dump-state` prints the grouped app list and the decision made for each app.
`--simulate-control` additionally routes every app through the processing path for the
duration of the run, which is the quickest way to confirm audio really flows through it.
`--reset-settings` throws away stored settings and writes defaults back.

## License

See [LICENSE](LICENSE).
