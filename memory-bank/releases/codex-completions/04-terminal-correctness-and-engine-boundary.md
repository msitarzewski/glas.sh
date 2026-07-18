# Phase 04 — Terminal Correctness and Engine Boundary

## Objective

Turn the existing SwiftTerm integration into a testable, replaceable terminal-engine implementation while raising input, protocol, rendering, accessibility, and search behavior to a premium-terminal standard.

## Included items

`TERM-001...012`.

## Current status — In progress

Live-buffer search, explicit focus ownership with bounded retry/resign, multiline and large-paste review, OSC working-directory propagation, validated HTTP(S) links, deny-by-default OSC 52/1337 behavior, hardware-key mappings, cursor/blink/scrollback runtime settings, and font/selection/caret/ANSI theme wiring are implemented and in QA. The tools menu uses fixed declaration order so its top action is not clipped by automatic reversal, and the caret theme is replayed after SwiftTerm creates its first-responder caret. A narrow UIKit-private `TerminalEngine` boundary and SwiftTerm adapter are implemented. Physical IME/dictation, international keyboard/accessibility, representative TUI, full conformance, and performance evidence remain open.

## Existing implementation to extend

- SSH/PTTY transport and terminal session state remain in `glas.sh/Models.swift`.
- The SwiftTerm bridge lives in `Packages/RealityKitContent/Sources/RealityKitContent/SwiftTermHostView.swift`.
- `glas.sh/TerminalWindowView.swift` owns the terminal-facing SwiftUI experience.
- Output delivery already follows queued/drained semantics documented in `memory-bank/systemPatterns.md#Terminal Architecture`.
- PTY resize already flows from UI geometry to the remote shell.

Do not rewrite transport or replace SwiftTerm in this phase. First introduce a boundary around the implementation that already works.

## Reuse strategy

- Extract protocols around current bridge capabilities, not an abstract emulator wish list.
- Keep session transport independent from engine rendering details.
- Adapt the existing `SwiftTermHostModel` and host view behind the boundary.
- Extend current settings and terminal callbacks rather than duplicating state in a second model.
- Use existing SwiftTerm buffer APIs where available; isolate upstream gaps behind the adapter.

## Work packages

### 04.1 TerminalEngine contract

Define the smallest useful contract for:

- feeding ordered output bytes;
- emitting exact input bytes;
- resize and current geometry;
- live buffer search and navigation;
- selection and copy;
- cursor and scrollback configuration;
- link/clipboard/working-directory/semantic events;
- focus ownership and composition state;
- engine diagnostics and performance counters.

The contract must not include RealityKit or visionOS-only UI types. Spatial presentation belongs above the engine boundary.

### 04.2 SwiftTerm adapter

- Move current bridge behavior behind the engine contract incrementally.
- Preserve Metal rendering, queued byte delivery, PTY resize, bell callbacks, and context-menu workaround.
- Avoid extra copying on the output hot path.
- Document upstream SwiftTerm patches or limitations separately from app policy.

### 04.3 Real terminal search

- Search the live SwiftTerm buffer, including wrapped and scrolled content.
- Define case sensitivity, regex/plain text, next/previous, result count, active match, and alternate-screen behavior.
- Keep informational `TerminalSession.output` for diagnostics only; do not present it as terminal search.
- Preserve selection and scroll position when dismissing search.

### 04.4 Focus, composition, and input ownership

- Replace unconditional focus reclamation with an explicit ownership model.
- Do not call `becomeFirstResponder()` while search, sheets, editable command composer, alerts, file pickers, or IME composition own focus.
- Resume terminal focus only after the competing control releases it and the terminal window remains active.
- Validate IME marked text, composition commit/cancel, dictation, hardware keyboard, modifier keys, dead keys, and international layouts.

### 04.5 Paste and clipboard policy

- Detect multiline and bracketed-paste state.
- Present review for risky multiline paste without corrupting legitimate TUI input.
- Define size limits and cancellation.
- Gate OSC 52 reads/writes through explicit policy and user-visible controls.
- Never log pasted or copied terminal data.

### 04.6 Links and semantic delegates

- Validate OSC 8 and detected URLs by scheme and user intent.
- Implement working-directory callbacks and semantic content hooks.
- Define file-reference handling without assuming remote paths are local.
- Expose command boundary/exit status signals needed by Phase 07 without coupling the engine to workspace UI.

### 04.7 Runtime settings

- Apply cursor style and blinking to the active emulator.
- Apply bounded maximum scrollback to the actual engine buffer.
- Define save-scrollback persistence, privacy, storage, and cleanup—or remove the control in Phase 05.
- Make global and per-session changes observable without reconnecting unless the engine requires it.

### 04.8 Conformance and performance corpus

Cover:

- vttest;
- tmux and Zellij;
- ncurses applications;
- Vim/Neovim;
- alternate-screen entry/exit;
- resize and reflow;
- fragmented and malformed UTF-8;
- combining marks, emoji, wide graphemes, ligatures, and RTL text;
- OSC 8, OSC 52, and OSC 133;
- mouse reporting modes;
- bracketed paste and modern keyboard protocol behavior;
- Kitty keyboard/graphics behavior where the engine supports it;
- large scrollback, sustained output, synchronized output, latency, and memory.

## Acceptance criteria

- App/session code depends on the terminal contract rather than SwiftTerm view internals.
- SwiftTerm remains the production engine with no regression in byte ordering, PTY resize, Metal rendering, or bell behavior.
- Search operates on the live terminal buffer.
- Focus maintenance never steals input from an active control or composition session.
- Clipboard, links, paste, working-directory, and semantic events follow explicit policies.
- Cursor and scrollback settings affect runtime behavior.
- The conformance corpus has recorded results and known limitations.

## Automated tests

- Contract tests with deterministic byte and resize fixtures.
- Fragmented output and input ordering.
- Buffer search across wrapping, Unicode, alternate screen, and large scrollback.
- Focus state-machine tests for sheets/search/composer/IME.
- Paste and OSC policy tests.
- Link scheme/host validation.
- Settings propagation and bounds.
- Performance regression thresholds defined from baseline measurements, not invented targets.

## Manual/device verification

- Hardware keyboard and international input on Vision Pro.
- Eye-and-hand transitions between terminal, search, sheets, and composer.
- Transparency/blur combinations under sustained output to confirm readability remains user-controlled and rendering remains stable.
- vttest and representative TUIs on real SSH sessions.

## Exit evidence

- Reviewed engine-contract and dependency diagram.
- Green conformance/behavior suite with documented unsupported protocols.
- Performance baseline for use in Phase 09.
