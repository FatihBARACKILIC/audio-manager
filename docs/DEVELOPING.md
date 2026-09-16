# Developing Audio Manager

Everything a contributor needs that a user does not. For what the app is and how to use
it, see the [README](../README.md); for the rules the code is held to, [AGENTS.md](../AGENTS.md).

## Building

```sh
git clone https://github.com/FatihBARACKILIC/audio-manager.git
cd audio-manager
xcodebuild -project AudioManager.xcodeproj -scheme AudioManager -configuration Release build

cd Packages/AudioManagerKit && swift test
```

Swift 6 with strict concurrency set to `complete`, deployment target macOS 15.0, no
third-party dependencies of any kind.

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
  policy resolution. No Core Audio, no SwiftUI, fully unit tested with no hardware.
- **`AudioCore`** — the only place Core Audio lives: tap lifecycle, one shared aggregate
  device, the real-time render graph and the equalizer. Reached from the rest of the app
  only through protocols declared in `AudioDomain`.
- **`AudioPersistence`** — versioned JSON in Application Support, written atomically.
- **App target** — menu bar item, panel and settings. The shell is AppKit so a global
  shortcut can open the panel, which `MenuBarExtra` cannot do; every view is SwiftUI.

## Notes on how it works

- Chromium and Electron apps play audio from short-lived helper processes. Every process
  is attributed to the outermost `.app` bundle containing it, so a browser is one row.
- A process tap silences its process only while something is actively **reading** the
  tap. Muting is therefore "render this app as silence": its tap joins the same shared
  aggregate device as everything else, and the render callback drops the stream before
  touching a sample. A tap that nobody reads mutes nothing.
- Every tap is created with `CATapMutedWhenTapped`, so if the render graph ever stops the
  user's audio comes back by itself rather than going missing.
- One aggregate device and one IOProc serve every controlled app, and both are destroyed
  the moment the last app is released.

### The render callback

`RenderGraph.swift` holds the whole per-buffer computation. It is real-time safe: no
allocation, no locks, no logging, no Swift runtime calls that can allocate. Mixing, gain
and the safety clip are single `vDSP` passes; the biquad cascade is deliberately scalar,
because vectorising it would cost two de-interleave passes over the audio to speed up the
one part of the callback that was never the bottleneck.

Parameters reach the audio thread two ways. A gain is a lone aligned 32-bit store that
the render thread picks up and ramps across the buffer, so a slider drag publishes
nothing. Equalizer coefficients are computed off the real-time thread and published into
a four-slot ring named by an atomic index — four rather than two, because the audio
thread reads the index once per callback and keeps using it for the rest of that buffer,
so a writer alternating between two slots could land back on the one a callback is still
reading.

Measured on Apple Silicon, Release, four streams at 512 frames / 48 kHz: 0.53 µs per
buffer steady, 0.56 µs while a gain ramps, 35 µs with the 10-band equalizer running on
all four. The buffer deadline is 10.67 ms.

## Diagnostics

These flags report what the app sees and decides. **None of them change stored settings**
— persistence is suspended for the life of any diagnostics run:

```sh
AudioManager.app/Contents/MacOS/AudioManager --dump-state
AudioManager.app/Contents/MacOS/AudioManager --dump-state --simulate-control --watch 10
AudioManager.app/Contents/MacOS/AudioManager --dump-state --simulate-mute --watch 10
AudioManager.app/Contents/MacOS/AudioManager --reset-settings
AudioManager.app/Contents/MacOS/AudioManager --show-panel
```

`--dump-state` prints the grouped app list and why each app ended up in the state it is
in. `--simulate-control` additionally routes every app through the processing path for
the run, and `--simulate-mute` mutes every app for the run — the quickest way to tell a
permission problem apart from a bug. `--watch <seconds>` keeps the engine running before
reporting, and reports peak levels.

Run the app with `open -a` rather than launching the binary directly when you need the
audio permission: macOS attributes it to whichever process started it, so running it
straight from a terminal asks Terminal's permission instead of the app's.

## Entitlements

The app is sandboxed and asks for exactly two things: `device.audio-input`, which is what
process taps require, and `files.user-selected.read-write`, which is what lets the export
and import panels read and write the file the user picks. Nothing else.

## Releasing

Pushing a `v*` tag runs [`.github/workflows/release.yml`](../.github/workflows/release.yml),
which tests, builds, signs, notarises and publishes the zip, then points
[`Casks/audio-manager.rb`](../Casks/audio-manager.rb) at it.

It needs five repository secrets: `DEVELOPER_ID_CERTIFICATE_P12` (base64 of a Developer
ID Application `.p12`), `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `APPLE_ID`,
`APPLE_ID_APP_PASSWORD` (an app-specific password) and `APPLE_TEAM_ID`.

Users install from the cask with:

```sh
brew tap fatihbarackilic/audio-manager https://github.com/FatihBARACKILIC/audio-manager
brew install --cask audio-manager
```
