# AGENTS.md

Operating rules for any AI agent or contributor working in this repository.
Read this file **before** writing code. If a rule here blocks the task, stop and
report it — do not work around it silently.

Written in English on purpose: this is a public open-source repo and the agent
instructions should match the codebase language.

---

## 1. What this project is

**Audio Manager** is a macOS menu bar app that controls the audio of each running
application independently: per-app volume, per-app mute, amplification, a 10-band
EQ, saved profiles, scheduled muting, and a focus mode.

The whole product rests on **Core Audio Process Taps**
(`AudioHardwareCreateProcessTap` / `CATapDescription`, macOS 14.2+). A tap captures
one process's output and mutes its original stream; we re-render the captured audio
through our own DSP graph into an aggregate device.

### Fixed product decisions (do not renegotiate)

| Topic | Decision |
|---|---|
| Minimum OS | macOS 15.0 |
| Language | Swift 6, strict concurrency = `complete` |
| App type | `LSUIElement` — menu bar panel + Settings window, no Dock icon |
| Per-app default mode | **Mute-only** (app is silenced, its audio is never processed) |
| Per-app opt-in mode | **Full control** (volume / gain / EQ via re-render), explained in the UI |
| App list | All running apps; apps currently producing audio sorted first |
| Process grouping | Group by bundle ID; Chrome/Electron/VS Code helper processes are hidden behind their parent app row |
| EQ | 10-band graphic EQ |
| Localization | String Catalog, EN default + TR |
| Launch at login | Opt-in in Settings, via `SMAppService` only |
| Shortcuts | User-configurable. Panel default `⌘⇧V`; focus mode has its own (unassigned by default) |
| Persistence | Versioned JSON in Application Support, exportable to a user-chosen file |
| Branch | Work directly on `main` |

---

## 2. Hard boundaries — never cross these

- **No third-party dependencies.** Apple SDKs only. Adding any SPM/CocoaPods/Carthage
  dependency requires explicit human approval, asked for in advance.
- **No audio driver, HAL plugin, kernel extension, DriverKit, or System Extension.**
  Process taps only. If taps cannot do something, say so — do not reach for a driver.
- **No private/undocumented APIs**, no unpublished CoreAudio selectors, no SPI,
  no method swizzling, no `dlsym` tricks.
- **No AppleScript / ScriptingBridge** per-app volume hacks. They only work for a
  handful of apps and produce an inconsistent product.
- **No network access of any kind.** No analytics, telemetry, crash reporting,
  update checks, or remote config. The app is fully offline.
- **No microphone/input capture features.** Output audio only.
- **Never change these without asking:** App Sandbox on/off, entitlements,
  `MACOSX_DEPLOYMENT_TARGET`, `PRODUCT_BUNDLE_IDENTIFIER`, `DEVELOPMENT_TEAM`,
  code signing style.
- **Never record, persist, or transmit captured audio.** Tapped audio exists only in
  memory, only for the duration of rendering. No file writes, ever.
- **No `fatalError`, `try!`, `as!`, force unwrap, or unchecked array indexing** in
  shipping code. Test code may use them where it makes a failure clearer.

---

## 3. Module architecture

Local Swift packages, with a strict one-way dependency rule:

```
AudioManager (app target, SwiftUI)
        │
        ▼
AudioDomain  ◄──── AudioPersistence
        ▲
        │ (implements protocols defined in AudioDomain)
        │
   AudioCore  (CoreAudio + AVFAudio)
```

- **`AudioDomain`** — pure Swift. App/session models, profiles, scheduler, focus
  mode, volume mapping, EQ presets, policy rules. **May not import** CoreAudio,
  AVFAudio, AppKit, or SwiftUI. Everything here is `Sendable` and unit-testable
  with no hardware.
- **`AudioCore`** — the only place CoreAudio lives. Process discovery, tap
  lifecycle, aggregate device, IOProc, DSP graph (gain, 10-band EQ, safety limiter).
  Exposed to the rest of the app **only** through protocols declared in
  `AudioDomain` (e.g. `AudioEngineControlling`, `AudioProcessObserving`).
- **`AudioPersistence`** — Codable JSON store, schema versioning, migrations.
- **App target** — SwiftUI views, `MenuBarExtra`, Settings, onboarding, hotkeys,
  notifications. Contains no audio logic and no persistence logic.

Rules:
- UI never talks to `AudioCore` types directly; it talks to domain protocols.
- No cross-module singletons. Inject dependencies through initializers.
- `public` only what another module genuinely needs; default to `internal`.

---

## 4. Concurrency rules (Swift 6)

- Strict concurrency is `complete`. Warnings are errors. Do not silence a
  concurrency diagnostic with `@unchecked Sendable`, `nonisolated(unsafe)`, or
  `@preconcurrency` unless there is a lock or RT-thread justification written in a
  comment right above it.
- UI and app state are `@MainActor`. Domain value types are `Sendable` structs.
- Use structured concurrency (`Task`, `async let`, `AsyncStream`) for everything
  that is **not** real-time audio. Do not scatter `DispatchQueue.async`.
- Use `Synchronization`'s `Atomic` / `Mutex` (macOS 15+) rather than
  `os_unfair_lock` wrappers or `DispatchQueue` as a lock.

### Real-time audio thread — absolute rules

Inside an `AudioDeviceIOProc`, render block, or anything called on the HAL's
real-time thread:

- **No allocation.** No `Array`/`Data`/`String` creation, no `append`, no boxing.
- **No locks that can block**, no `DispatchQueue`, no `Task`, no `await`.
- **No ARC traffic** where avoidable — prefer `UnsafeMutableBufferPointer` over
  Swift collections, capture nothing retain/release-heavy in the callback.
- **No logging**, no `print`, no `os_log` on the hot path.
- **No Obj-C / CoreAudio property calls** from the callback.
- Buffers, ring buffers, and DSP state are **preallocated** at graph setup.
- UI → audio parameter changes go through lock-free atomics or a single-producer
  ring/command queue, and are **ramped** across the buffer. Never apply a gain jump
  directly — that is audible zipper noise.
- Audio → UI (levels, state) goes through an atomic snapshot polled by the UI at a
  low rate, never by pushing from the RT thread.

---

## 5. Core Audio rules

- Every `OSStatus` is checked. Wrap the C API in small throwing Swift helpers
  (e.g. `try CoreAudioError.check(status, "create tap")`); never discard a status.
- No raw four-char-code literals scattered in call sites — put selectors and
  addresses in one typed place.
- Subscribe to property listeners for: default output device change, device list
  change, device disconnect, sample rate / stream format change, process list
  change, process exit. **Rebuild the graph gracefully** — never crash, never leak
  a tap or aggregate device.
- Every created tap / aggregate device / IOProc has an explicit teardown path,
  including on quit, crash-adjacent error paths, and permission revocation.
- If a tap cannot be created (DRM-protected content, permission denied, process
  vanished), **degrade to mute-only** for that app and surface a clear UI state.
  Never leave an app silently broken.
- A process tap silences its process only while something is actually **reading** the
  tap. A tap created with `CATapMuted` and then left alone changes nothing — measured
  on macOS 15, with the tap correctly registered (`muteBehavior` reads back as 1) and
  audio still audible. Muting therefore means *render this app as silence*: its tap
  joins the shared aggregate device like any other and its stream is dropped before a
  single sample is touched. Use `.mutedWhenTapped` for every tap, so that if our IOProc
  ever stops the user's audio returns by itself.
- The hearing-safety limiter is the **last** stage of the chain and cannot be
  bypassed by amplification or EQ gain.

### Stability

Stability is a product requirement. The app must never crash and must never leave the
user without sound. Any error path degrades gracefully: worst case our processing
stops, taps are released, and audio plays through the system exactly as it would if
this app were not installed.

---

## 6. Performance is a feature, not a tuning pass

The user requirement is explicit: this app sits in the menu bar all day and must be
close to invisible in Activity Monitor. Every design choice is made with that first.
A feature that cannot be built inside these budgets is redesigned, not shipped slow.

### Budgets (Apple Silicon, Release build, 48 kHz stereo)

Two numbers per row: **target** is what the design must aim for, **ceiling** is a
hard fail — exceeding it means the change is not done.

| State | CPU (target / ceiling) | Memory footprint (target / ceiling) |
|---|---|---|
| Idle — panel closed, nothing controlled | **0.0% / 0.2%** | **22 MB / 30 MB** |
| Apps muted (mute-only, stream dropped) | **0.2% / 0.5%** | **24 MB / 32 MB** |
| Full control — 4 apps, 10-band EQ active | **0.4% / 1.0%** | **32 MB / 45 MB** |
| Panel open, meters animating | **1.0% / 2.0%** | **36 MB / 50 MB** |

Additional hard limits:

- **Idle wake-ups: < 1 per second** with the panel closed. This matters more than
  CPU% — a truly event-driven app wakes only when the user or the system does
  something. Any repeating timer that survives an idle app is a bug.
- Cold launch to menu bar icon visible: **< 250 ms**.
- Panel open: **< 80 ms**.
- Audio thread: **< 5%** of the buffer deadline consumed per IOProc call
  (at 512 frames / 48 kHz that is ~10.6 ms — we must finish in well under 0.5 ms).
  No dropouts, ever, under any UI activity.
- Energy Impact in Activity Monitor while idle: **0.0**.

### How these are measured (use the same method every time)

- **Memory** = *Memory* column in Activity Monitor / `footprint <pid>` (phys
  footprint), not virtual size. Measured 60 s after launch, panel closed.
- **CPU** = averaged over 60 s, not peak.
- **Wake-ups** = *Idle Wake Ups* column, or `powermetrics --samplers tasks`.
- Always Release build. Debug builds are not evidence.

### What is and isn't ours

The DSP itself is cheap: ten stereo biquads at 48 kHz is a few million
multiply-adds per second per app — a rounding error on Apple Silicon. The cost in
this app comes from **overhead**, not math: buffer copies, thread wake-ups, SwiftUI
re-renders, object churn, timers. Optimize those first; the filters are not the
problem.

Note also that `coreaudiod` does work on our behalf when a tap is active, and that
CPU appears under **its** process, not ours. Our budget is about our own process,
but the right way to keep `coreaudiod` cheap is the same: fewer taps, one aggregate
device, no tap at all when nothing needs rendering.

### Framework cost and the SwiftUI decision

A SwiftUI menu bar app carries a higher baseline footprint than a plain AppKit one.
The plan is: build the panel in SwiftUI, keep observation scopes narrow, and
**measure against the ceilings above**. If the idle footprint cannot be brought
under 30 MB, the panel is rewritten in AppKit (`NSPopover` + `NSView`) rather than
accepting the regression — report it before doing that.

Practical consequences of the memory ceiling:

- No preloaded views. Settings, onboarding, and profile editors are built on first
  open and released when closed.
- Icon cache is bounded (LRU, small) and rasterized at display size; it is dropped
  when the panel closes.
- No history buffers, no accumulating logs, no retained audio beyond the live ring
  buffers.
- Assets stay minimal: SF Symbols and the app icon, nothing else.

### Zero-cost idle (the most important rule)

When the user is controlling nothing at all, **nothing must be running**:
no aggregate device, no IOProc, no tap, no timers, no observers doing work, no
background `Task` loops. The engine is created lazily when the first app is muted or
put into full control, and **torn down completely** when the last one leaves.

Muting is not free, and cannot be: the tap has to be read for the mute to hold, so one
IOProc runs while anything is muted (~94 wake-ups a second at 512 frames / 48 kHz).
What muting does avoid is all of the work: a silenced stream is skipped in the render
callback before any filtering, mixing or metering, which is why the muted state costs
about a fifth of a percent rather than the same as full control.

### Audio path

- **One** aggregate device and **one** IOProc for all tapped apps. Never one engine,
  device, or thread per app.
- Prefer Accelerate (`vDSP` biquad cascade for the 10-band EQ, `vDSP_vsmul`/ramped
  multiply for gain) over spinning up an `AVAudioEngine` graph per app. If
  `AVAudioEngine` is ever used, justify it with a measurement.
- **Skip work that does nothing**, decided once per buffer, never per sample:
  flat EQ → bypass the filter stage entirely; gain == 1.0 and no ramp pending →
  no multiply; silent input buffer → skip the chain.
- Ring buffers are preallocated, bounded (≤ 100 ms of audio per app), and reused.
  No allocation, no growth, no copies beyond the one the HAL requires.
- Use the device's native sample rate and format. No resampling or format
  conversion unless a process genuinely differs — and then convert once, not twice.

### Event-driven everywhere — no polling

- Process/app discovery uses CoreAudio property listeners and `NSWorkspace`
  notifications. There is **no refresh timer** anywhere.
- The scheduler uses a **single** coalesced sleep until the next rule boundary
  (one `Task` awaiting the next event), not a ticking timer and not one timer
  per rule. Rescheduled only when rules change or the clock jumps.
- No `Combine` publisher firing at audio rate. No `DispatchSourceTimer` polling the
  HAL.

### UI cost

- When the panel is closed, the UI does **zero** work: no metering, no state
  updates, no animations, no observation of audio state. Level metering starts when
  the panel appears and stops when it disappears.
- Meters are computed with `vDSP` on the buffer we already have, published as a
  coalesced atomic snapshot polled at **≤ 20 Hz** — never pushed per render cycle.
- SwiftUI: `@Observable`, stable identities, and narrow observation scopes so a
  single slider drag never re-renders the whole app list. Slider changes are
  throttled before they reach persistence (audio gets them immediately via atomics;
  disk does not).
- App icons are fetched once, rasterized at display size, and held in a small
  bounded cache. Never hold full-resolution `NSImage`s for every running app.
- The Settings window is lazy: not built, not loaded, and not observing anything
  until the user opens it.

### Footprint

- Link only the frameworks actually used. No framework pulled in "just in case".
- Nothing runs at login beyond registering the menu bar item and restoring state —
  defer everything else until first use.
- No background work while the user is away: respect system sleep/wake, and tear
  the engine down rather than keeping it warm.

### Measured baseline (Release, Apple Silicon, recorded 2026-09-16)

The numbers the app actually hits today, for comparison when something regresses:

| State | CPU | Memory (phys footprint) |
|---|---|---|
| Idle, panel closed, nothing controlled | 0.0% over 30 s | 13 MB |
| 4 apps muted, panel closed | 0.17% over 60 s | 15 MB |
| 3 apps in full control, EQ on, meters running | ~1.0% over 30 s | 16 MB |

Profiling the rendering case shows the render callback taking about 0.5% of the audio
IO thread's samples: the process cost is dominated by the audio thread waking up ~94
times a second, not by the DSP. `coreaudiod` costs about 8.5% of a core with audio
merely playing and about 11% with three apps tapped.

### Verification

- Every audio- or UI-touching change is checked against the table above before it is
  considered done — `sample`/`Instruments` (Time Profiler + Allocations) for CPU and
  memory, and a check that idle really is idle.
- Report measured numbers when finishing such a change. If a budget is exceeded, say
  so and propose a redesign; do not quietly accept a regression.

---

## 7. UI rules

- SwiftUI for every view. The app *shell* is AppKit — an `NSStatusItem` with an
  `NSPopover` and a plain `NSWindow` for settings — because a global shortcut has to
  be able to open the panel and `MenuBarExtra` exposes no way to do that. That shell
  is confined to `AppDelegate`; nothing else in the app touches AppKit except the
  small wrappers for hotkeys, login item and app icons.
- **No hardcoded user-facing strings.** Everything goes through
  `Localizable.xcstrings` with EN as source and TR provided.
- SF Symbols only for iconography. No bundled icon fonts or bitmap icon sets.
- Respect light/dark mode, Dynamic Type, Reduce Motion, and increased contrast.
- Accessibility is mandatory: every slider, toggle, and row has a label and value;
  the panel is fully keyboard-navigable.
- Explain, don't surprise: the full-control toggle carries a short explanation of
  the latency trade-off, as decided.
- Permission states (undetermined / denied / granted) each have a real UI. A denied
  app shows how to fix it, never an empty window or a spinner.

---

## 8. Persistence

- Codable JSON under `~/Library/Application Support/com.barackilic.AudioManager/`.
- Every stored file carries a `schemaVersion`. Adding a field means a default value
  and a migration test. Never break an existing user's profiles.
- `UserDefaults` only for small, losable preferences (window position, last tab).
- Atomic writes; a corrupt or unreadable store falls back to defaults and logs a
  user-visible, recoverable state — never a crash.
- Store no PII and no audio.

---

## 9. Testing

Every feature ships with tests. "Write the tests later" is not an option here.

- Use **Swift Testing** (`import Testing`, `@Test`, `#expect`) for new tests.
  XCTest only where Swift Testing cannot (some performance/UI cases).
- `AudioDomain` is tested exhaustively: volume curve mapping, profile apply/switch,
  scheduler boundaries (DST, midnight wrap, overlapping windows), focus mode,
  EQ band math, limiter behavior, process→app grouping (including Chrome helpers).
- `AudioCore` is tested through fakes of its protocols. **The default test plan must
  not touch real audio hardware, create taps, or require TCC permission.**
  Hardware integration tests live in a separate, opt-in test plan / tag and are
  excluded from CI.
- Tests are deterministic: inject a clock abstraction, never call `Date()` or sleep
  in domain code. No test depends on execution order or wall-clock timing.
- `xcodebuild test` must pass before every commit. CI runs it on GitHub Actions.

---

## 10. Code style

- Follow the Swift API Design Guidelines. Clear names over short names; no
  abbreviations (`processIdentifier`, not `pid`, except where the C API uses it).
- Prefer structs and value semantics. Classes are `final` unless subclassed.
- One primary type per file; keep files under ~400 lines.
- Comments explain **why**, not what. Match the comment density of surrounding code.
  No commented-out code, no `// TODO` without an accompanying issue or note to the
  user.
- Errors are typed Swift `Error` enums with a `LocalizedError` conformance where the
  user will see them.
- Keep new code consistent with what is already in the file — naming, idiom, layout.

---

## 11. Git

- Work directly on `main`. Small, focused commits.
- Commit subjects in English, imperative mood, ≤ 72 characters, prefixed
  `feat:` / `fix:` / `refactor:` / `test:` / `chore:` / `docs:`.
- Never commit: secrets, `xcuserdata/`, build products, `.DS_Store`, captured audio,
  or anything under `DerivedData`.
- Do not push, tag, or release unless explicitly asked.

---

## 12. Diagnostics hooks

The app accepts a few command line flags, and they are part of the contract:

- `--dump-state` prints the grouped app list and the effective decision per app.
- `--simulate-control` (with `--dump-state`) routes every app through the processing
  path for one run, to prove the capture path end to end on a real machine.
- `--simulate-mute` (with `--dump-state`) mutes every app for one run, to check the
  silencing path on a machine where muting is misbehaving.
- `--watch <seconds>` keeps the engine running before reporting, and reports peak levels.
- `--reset-settings` clears stored settings and writes defaults back.
- `--show-panel` opens the panel at launch.

**A diagnostics run must never write to the user's settings.** `--simulate-control`
suspends persistence for the life of the process; keep that true for anything added
here. Diagnostics read state and report it — they never become a second way to
configure the app.

## 13. When to stop and ask

Stop and report to the user instead of improvising when:

- A rule in this file blocks the implementation (most likely: App Sandbox vs.
  aggregate device creation — report it, do not turn the sandbox off).
- A feature would need a dependency, a driver, a private API, or network access.
- An Apple API behaves differently from what this document assumes.
- A product decision in §1 turns out to be technically impossible.

Report what you found, what the options are, and what you recommend — then wait.
