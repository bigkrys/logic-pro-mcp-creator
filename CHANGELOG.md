# Changelog

All notable changes to `logic-pro-mcp-creator` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-04-20

First release of the **Creator Studio Edition** fork. Adapted from
[koltyj/logic-pro-mcp](https://github.com/koltyj/logic-pro-mcp) for Apple's
subscription tier of Logic Pro.

### Added

- **Creator Studio process targeting.** Server now identifies and drives the
  `Logic Pro Creator Studio` process (bundle `com.apple.mobilelogic`) instead
  of the classic `Logic Pro` (`com.apple.logic10`).
- **MIDI sequence playback** (`midi.send_sequence`). Send an array of timed
  note events in a single call — each event fires concurrently via
  structured `TaskGroup` scheduling.
- **AX tree diagnostics** (`logic_system("ax_dump", {depth: N})`). Dumps the
  Logic Pro accessibility tree to help identify element roles/identifiers
  when UI layouts change across Logic versions.
- **Multi-window AX discovery.** Track-header, mixer, and transport lookups
  now enumerate every Logic window, not just the main one.
- **Structural heuristic for track rows.** When AX identifiers are
  NS-generated (`_NS:88`-style), the resolver falls back to a role-shape
  match (`AXScrollArea → AXGroup → AXLayoutItem[AXTextField]`).
- **Screen-space interaction helpers** (`AXHelpers.getPosition/getSize`) and
  PID-targeted CGEvent mouse/key helpers — required for context-menu driven
  workflows in Creator Studio.
- **Keyboard shortcut for New Project** (Cmd+N) added to `CGEventChannel`
  and prioritized over AppleScript in `project.new` routing.
- **Multilingual rename detection.** The rename context-menu lookup now
  matches localized labels in 11 languages (English, Simplified/Traditional
  Chinese, Japanese, Korean, French, German, Spanish, Italian, Portuguese,
  Russian).
- **Clipboard preservation during rename.** The user's pasteboard is
  snapshotted before the rename paste and restored afterwards, so
  previously copied content is not destroyed.

### Changed

- `ServerConfig.serverName` is now `logic-pro-mcp-creator`; version bumped
  to **1.0.0** to mark first stable Creator Studio release.
- `findTrackHeader(at:)` and related track-control lookups now use
  **1-based indexing** (track 1 = first row) to match user-visible numbering.
- Track-row control detection (`mute`, `solo`, `arm`) now uses
  Creator Studio's `AXCheckBox` / `AXRadioButton` roles with fallbacks to
  the original `AXButton` + title/description matching.
- Mixer channel-strip enumeration now filters out non-strip children
  (labels, separators) by requiring at least one `AXSlider` descendant —
  fixes off-by-many indexing in Creator Studio's mixer layout.
- `transport.set_tempo` routing prefers `accessibility` over `osc`
  (no manual Control Surface setup required).
- `MixerDispatcher.set_volume` and `TransportDispatcher.set_tempo` accept
  both integer and floating-point values for `value`/`volume`/`tempo`/`bpm`.
- `AccessibilityChannel.renameTrack` rewritten to use the right-click
  context menu (`重命名` / `Rename`) + clipboard paste + Return — the
  Creator Studio text field does not accept direct `AXValue` assignment.
- All `AppleScriptChannel` scripts retargeted from
  `tell application "Logic Pro"` to `tell application "Logic Pro Creator Studio"`.

### Fixed

- **Default track index is now 1** (was 0) across `logic_tracks` and
  `logic_mixer` commands. Matches the user-visible 1-based numbering used
  by `AXLogicProElements.findTrackHeader(at:)` — prevents silent failures
  when the LLM omits `index` for a command like `logic_tracks("mute", {})`.
- **`renameTrack` no longer blocks the actor.** Switched all
  `Thread.sleep(forTimeInterval:)` calls to `try? await Task.sleep` so
  concurrent AX reads (state cache polling, other tool calls) can proceed
  while the rename flow waits for the context menu to open.
- **`set_tempo` error message** now mentions both `'tempo'` and `'bpm'`
  (both are accepted parameter names).
- **Hardcoded bundle ID removed from rename flow.** `AccessibilityChannel`
  now activates Logic Pro via `ServerConfig.logicProBundleID` instead of
  duplicating the bundle identifier literal.
- **Deprecated macOS 14 API replaced.** `NSRunningApplication.activate(options:)`
  is a no-op on macOS 14+ — use the argument-less `activate()` instead.
- **`send_sequence` now reports skipped events.** Invalid note events in
  the input array are still dropped, but the success message includes the
  skipped count so callers can tell when malformed data was silently
  filtered.
- **Named key codes.** Magic numbers in the rename flow (0=A, 9=V, 36=Return,
  53=Escape) are now behind a `KeyCode` enum.

### Migration Notes

This fork is **not a drop-in replacement** for `koltyj/logic-pro-mcp`:

- Running binary and the classic Logic Pro simultaneously is supported —
  different process names and bundle IDs mean no conflict.
- If you were previously using `koltyj/logic-pro-mcp` to control Logic
  Pro Creator Studio, switch to this fork — the upstream build does not
  match the subscription process and silently fails.
- Track indexing changed from 0-based to 1-based for AX-layer lookups.
  Dispatcher-level callers were already passing `index` as a human-visible
  number, so no user-facing behavior change is expected — but custom
  downstream code that calls `AXLogicProElements` directly needs updating.

### Credits

- Upstream architecture, channel routing, dispatcher tool design, and
  state-cache strategy: **Kolton Jacobs** ([koltyj/logic-pro-mcp](https://github.com/koltyj/logic-pro-mcp)).
- Creator Studio adaptation, diagnostics, and MIDI sequencing: **Krys Liang**.

[1.0.0]: https://github.com/bigkrys/logic-pro-mcp-creator/releases/tag/v1.0.0
