# Audio Manager

**A volume slider for every app, in your menu bar.**

macOS gives you one volume knob for the whole machine. Audio Manager gives you one per
app: mute Slack while a video keeps playing, turn a loud browser tab down without
touching your music, boost a quiet video call, or let only one app make sound while you
work.

It lives in the menu bar, has no Dock icon, and does nothing at all until you ask it to.

---

## What you can do with it

| | |
|---|---|
| **Mute one app** | Silence Slack, Discord or a browser without silencing anything else. |
| **Set a volume per app** | Music at 100%, the browser at 30%, all at the same time. |
| **Make something louder** | Boost up to +12 dB when a video or call is too quiet to hear. |
| **Shape the sound** | A 10-band equalizer per app — more bass for music, more clarity for speech. |
| **Focus mode** | Only the apps you allow can make sound. Everything else goes quiet. |
| **Profiles** | Save a whole setup as "Work" or "Music" and switch between them in one click. |
| **Schedules** | Mute Slack automatically on weekdays from 09:00, or switch profiles every evening. |
| **Hearing safety** | A volume ceiling that applies after every boost, so nothing can surprise you. |

Everything is in English and Turkish.

---

## Install

With [Homebrew](https://brew.sh):

```sh
brew tap fatihbarackilic/audio-manager https://github.com/FatihBARACKILIC/audio-manager
brew install --cask audio-manager
```

Or download `AudioManager-<version>.zip` from the
[latest release](https://github.com/FatihBARACKILIC/audio-manager/releases/latest),
unzip it, and drag **AudioManager.app** into your Applications folder.

Either way, open it once from Applications. A speaker icon appears in the menu bar —
that is the whole app. There is no Dock icon and no window until you open one.

**Requires macOS 15 (Sequoia) or later**, on Apple Silicon or Intel.

---

## The permission it asks for

The first time you mute or adjust an app, macOS asks for permission to **record system
audio**. That prompt looks alarming, so here is exactly why it appears.

macOS has no API that simply says "set that app's volume to 40%". The only supported way
to control another app's audio is to *capture* its output, change it, and play the result
back. macOS classifies that as recording — so that is the permission it asks for. There
is no narrower one to ask for.

What Audio Manager actually does with it:

- Audio is processed in memory and thrown away, buffer by buffer.
- **Nothing is ever written to disk.** No recordings, no logs of what you played.
- **There is no network code in the app at all** — no analytics, no telemetry, no crash
  reporting, no update checks. It cannot send anything anywhere.
- Muting an app does not even read its audio: the stream is dropped untouched.

If you say no, the app keeps running and tells you how to grant the permission later
(System Settings → Privacy & Security → Microphone).

---

## Using it

Click the menu bar icon, or press **⌘⇧V**, and the panel opens with every running app.
Apps that are making sound right now are listed first.

**Each row** has a volume slider and a mute button. Click the chevron on the right for
that app's advanced controls.

**Two modes per app**, chosen in the advanced controls:

- **Mute only** *(the default)* — the app can be silenced, and nothing else. Its audio is
  never processed, so there is no delay of any kind.
- **Full control** — volume, boost and the equalizer all work, because the app's audio
  now travels through Audio Manager. This adds a few milliseconds of delay. That is
  invisible for music and video; for a live call you may prefer mute only.

Moving an app's volume slider switches it to full control for you, since a volume that
does nothing would be worse than a mode change.

**Focus mode** silences everything except the apps you tick as allowed. Give it a
keyboard shortcut in Settings and you can quiet the machine in one keystroke.

**Profiles** capture the current setup under a name. Switch to "Work" and Slack and Mail
mute themselves while your editor stays audible; switch to "Music" and it all comes back.

**Schedules** apply a rule inside a time window — mute a set of apps, turn on focus mode,
or activate a profile — on the weekdays you choose. Rules that cross midnight and days
that change length work correctly.

Settings (from the panel's gear) also cover launching at login, notifications, the
volume ceiling, and both keyboard shortcuts.

---

## If something is not working

**A muted app is still making sound.** Check the permission first — open the panel and
look for a banner at the top. Without permission to capture audio, macOS lets the app
keep playing rather than telling us anything is wrong.

**One app cannot be controlled at all.** Some audio cannot legally be captured — DRM
protected content is the usual case. Audio Manager will say so for that app rather than
pretending to work.

**An app you expected is missing from the list.** The panel shows apps that appear in
the Dock, plus anything currently making sound. Background helpers only appear while they
are playing, and Chrome, Brave, VS Code and other Electron apps are shown as one row
rather than one per helper process.

**The menu bar icon is gone.** macOS hides menu bar items when the bar runs out of room,
usually on a laptop with lots of icons and a notch. Try quitting another menu bar app.

**You want to start over.** Run this once, and every setting goes back to its default:

```sh
/Applications/AudioManager.app/Contents/MacOS/AudioManager --reset-settings
```

---

## What it costs to run

Audio Manager is meant to be invisible in Activity Monitor. Measured on Apple Silicon
with a Release build:

| What it is doing | CPU | Memory |
|---|---|---|
| Nothing — idle in the menu bar | 0.0% | 13 MB |
| 4 apps muted, panel closed | 0.17% | 15 MB |
| 3 apps in full control with EQ, panel open and metering | ~1.0% | 16 MB |

When you are not controlling any app, the app holds no audio resources whatsoever — no
device, no processing, no timers. It wakes up when you or the system does something, and
not otherwise.

---

## Privacy

No audio is recorded, stored or transmitted. No file is ever written except your own
settings, in `~/Library/Application Support/com.barackilic.AudioManager/`. The app
contains no networking code, so it cannot phone home even by accident.

---

## For developers

Built with Swift 6 and Apple frameworks only — no third-party dependencies, no audio
driver, no private APIs. It uses **Core Audio process taps**, the supported API for
capturing another process's output, introduced in macOS 14.2.

```sh
git clone https://github.com/FatihBARACKILIC/audio-manager.git
cd audio-manager
xcodebuild -project AudioManager.xcodeproj -scheme AudioManager -configuration Release build

cd Packages/AudioManagerKit && swift test
```

### Architecture

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

The rules the code is held to are in [AGENTS.md](AGENTS.md).

### Notes on how it works

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

### Diagnostics

These flags report what the app sees and decides. None of them change stored settings:

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
permission problem apart from a bug.

Run the app with `open -a` rather than launching the binary directly: macOS attributes
the audio permission to whichever process started it, so running it straight from a
terminal asks Terminal's permission instead of the app's.

### Releasing

Pushing a `v*` tag runs [`.github/workflows/release.yml`](.github/workflows/release.yml),
which tests, builds, signs, notarises and publishes the zip, then points
[`Casks/audio-manager.rb`](Casks/audio-manager.rb) at it. It needs five repository
secrets: `DEVELOPER_ID_CERTIFICATE_P12` (base64 of a Developer ID Application `.p12`),
`DEVELOPER_ID_CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_ID_APP_PASSWORD` (an
app-specific password) and `APPLE_TEAM_ID`.

## License

[MIT](LICENSE).
