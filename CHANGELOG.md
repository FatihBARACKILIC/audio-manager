# Changelog

All notable changes to Audio Manager are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-16

First release. A menu bar app that gives every running app its own volume.

### Added

- **Per-app volume, mute and boost.** A slider and a mute button for every running app,
  with up to +12 dB of amplification for apps that are too quiet to hear.
- **Two modes per app.** *Mute only* silences an app at the source with no processing and
  no added delay, and is the default. *Full control* routes the app's audio through Audio
  Manager so volume, boost and the equalizer work, at the cost of a few milliseconds.
- **A 10-band equalizer per app**, on ISO octave centre frequencies from 32 Hz to 16 kHz.
- **Focus mode.** Only the apps you allow can make sound; everything else goes quiet.
  Assignable to a keyboard shortcut.
- **Profiles.** Save a whole setup under a name and switch between them from the panel.
  Editing one means activating it, changing what you want, and folding the result back in.
- **Schedules.** Rules that mute apps, turn on focus mode or activate a profile inside a
  time window on chosen weekdays. Windows that cross midnight and days that change length
  are handled correctly.
- **A hearing-safety ceiling** applied after every other gain stage, so no amount of boost
  or equalizer gain can get past it.
- **Export and import.** Your profiles, schedule rules and preferences as a plain,
  versioned JSON file you keep — for reinstalling, or for moving to another Mac.
- **Remove Audio Manager**, which deletes everything the app created, unmutes every app
  and turns off the login item before showing itself in Finder.
- **Turkish and English**, throughout.
- **Configurable global shortcuts** for the panel (⌘⇧V by default) and for focus mode.
- **Launch at login**, opt-in, registered through `SMAppService`.
- **Notifications** when something other than you changes an app's audio — a schedule
  rule firing, focus mode taking effect — and when an app is boosted to a loud level.
- **Diagnostic flags** (`--dump-state`, `--simulate-control`, `--simulate-mute`,
  `--watch`, `--reset-settings`, `--show-panel`) that report what the app sees and
  decides without changing any stored setting.

### Notes

- Requires macOS 15 (Sequoia) or later, on Apple Silicon or Intel.
- Released ad-hoc signed but **not notarised**: notarising needs a paid Apple Developer
  membership this project does not have. macOS blocks the app until you allow it once —
  the README explains both ways to do that.
- Built on Core Audio process taps. The first time you mute or adjust an app, macOS asks
  for permission to record system audio: that is the only supported way to control
  another app's volume, and there is no narrower permission to ask for. Audio is
  processed in memory and discarded, nothing is ever written to disk, and the app
  contains no networking code at all.
- Apple frameworks only — no third-party dependencies, no audio driver, no private APIs.
- Idle in the menu bar with nothing controlled, the app holds no audio resources
  whatsoever: no device, no processing, no timers. Measured at 0.0% CPU and 13 MB.

[Unreleased]: https://github.com/FatihBARACKILIC/audio-manager/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/FatihBARACKILIC/audio-manager/releases/tag/v1.0.0
