**A volume slider for every app, in your menu bar.**

macOS gives you one volume knob for the whole machine. Audio Manager gives you one per
app: mute Slack while a video keeps playing, turn a loud browser tab down without
touching your music, boost a quiet video call, or let only one app make sound while you
work.

It lives in the menu bar, has no Dock icon, and does nothing at all until you ask it to.

## Installing

With [Homebrew](https://brew.sh):

```sh
brew tap fatihbarackilic/audio-manager https://github.com/FatihBARACKILIC/audio-manager
brew install --cask audio-manager
```

Or download `AudioManager-1.0.0.zip` below, unzip it, and drag **AudioManager.app** into
your Applications folder.

### macOS will block it the first time

Audio Manager is ad-hoc signed but **not notarised** — notarising requires a paid Apple
Developer membership, and this is a free open-source project without one. So macOS
refuses to open it until you allow it once:

```sh
xattr -dr com.apple.quarantine /Applications/AudioManager.app
```

Or open it, let macOS block it, then go to **System Settings → Privacy & Security** and
click **Open Anyway**. On macOS 15 the old right-click → Open shortcut no longer works.

You are trusting this project rather than Apple's review here. The whole source is in
this repository, it contains no networking code at all, and you can build it yourself.

Then a speaker icon appears in the menu bar — that is the whole app. Press ⌘⇧V to open
the panel.

**Requires macOS 15 (Sequoia) or later**, on Apple Silicon or Intel.

## What is in it

- **A volume slider and a mute button per app**, plus up to +12 dB of boost for anything
  too quiet to hear.
- **Two modes per app.** *Mute only* silences an app at the source with no processing and
  no added delay, and is the default. *Full control* adds volume, boost and EQ at the cost
  of a few milliseconds — fine for music and video, less ideal for a live call.
- **A 10-band equalizer** per app.
- **Focus mode**: only the apps you allow can make sound.
- **Profiles**: save a whole setup as "Work" or "Music" and switch in one click.
- **Schedules**: mute Slack on weekdays from 09:00, or switch profiles every evening.
  Windows that cross midnight work correctly.
- **A hearing-safety ceiling** applied after every boost, so nothing can surprise you.
- **Export and import** your settings as a plain JSON file you keep.
- **English and Turkish**, throughout.

## About the permission

The first time you mute or adjust an app, macOS asks for permission to **record system
audio**. That prompt looks alarming, so: macOS has no API that says "set that app's
volume to 40%". The only supported way is to capture the app's output, change it, and
play the result back — and macOS classifies that as recording. There is no narrower
permission to ask for.

Audio is processed in memory and thrown away buffer by buffer. **Nothing is ever written
to disk**, and **the app contains no networking code at all** — no analytics, no
telemetry, no update checks. It cannot send anything anywhere. Muting an app does not
even read its audio: the stream is dropped untouched.

## What it costs to run

| What it is doing | CPU | Memory |
|---|---|---|
| Nothing — idle in the menu bar | 0.0% | 13 MB |
| 4 apps muted, panel closed | 0.17% | 15 MB |
| 3 apps in full control with EQ, panel open and metering | ~1.0% | 16 MB |

With nothing controlled, the app holds no audio resources at all — no device, no
processing, no timers. It wakes when you or the system does something, and not otherwise.

## Under the hood

Swift 6 with strict concurrency, Apple frameworks only — no third-party dependencies, no
audio driver, no private APIs. It uses Core Audio process taps, one shared aggregate
device and one render callback for every controlled app.

Full notes in the [changelog](https://github.com/FatihBARACKILIC/audio-manager/blob/main/CHANGELOG.md).
