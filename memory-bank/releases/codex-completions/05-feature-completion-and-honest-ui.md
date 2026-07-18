# Phase 05 — Feature Completion and Honest UI

## Objective

Ensure every release-visible control completes its advertised workflow or is unavailable, while preserving the defining Vision Pro experience: a premium terminal window with full transparency and adjustable opacity and blur.

## Included items

`VIS-001...005` and `FEAT-001...012`.

## Current status — QA

The live terminal retains a clear native backing, genuine 100% window transparency, and independent continuous opacity/blur controls. Selected frost, font, selection, caret, and ANSI colors reach the live view. The full opacity/blur endpoint matrix—including both values at zero—is regression-tested. SharePlay source/entitlement, unused settings, unsupported SSH Agent UI, and unused AI-summary code/claims are removed; HTML Preview is Debug-only; forwarding uses the shared manager. The tools-menu ordering and focused-caret regressions reported on 2026-07-17 are repaired. The 164-test app action passes on both simulator runtimes; physical Vision Pro contrast, accessibility, passthrough, and extreme-value evidence remains required.

## Product constraint

The audit's near-opaque terminal recommendation at `../docs/glas.sh-results.txt:207` is not adopted as a product requirement. Its underlying concerns—contrast, accessibility, and glass layering—remain valid, but they must be solved without removing:

- 100% terminal transparency;
- independent opacity control;
- independent blur control;
- global and per-session overrides.

The current glass implementation at `glas.sh/SettingsManager.swift:1130`, `glas.sh/SettingsView.swift:574`, and `glas.sh/TerminalWindowView.swift:574` is evaluated against this invariant before approval.

## Reuse strategy

- Extend the existing terminal appearance settings and migration path.
- Reuse the real `PortForwardManager` in `glas.sh/PortForwardManager.swift`; do not maintain display-only forwarding state.
- Reuse the current HTML Preview, recorder, AI, and settings implementations only where their data paths can be completed; keep the removed SharePlay surface absent from Release builds.
- Prefer compile-time/release configuration hiding for incomplete surfaces over inert controls.

## Work packages

### 05.1 Transparent terminal and appearance controls

- Specify exact semantics for opacity, blur, background fill, material/frost, tint, and interactive glass.
- Preserve an endpoint that renders the terminal background fully transparent.
- Provide continuous opacity and blur adjustment; do not collapse both into a single ambiguous control.
- Keep controls available when interactive glass is enabled unless a documented platform limitation makes a specific combination impossible.
- Separate terminal canvas appearance from window chrome and ornaments.
- Test text/background/tint composition so transparency does not accidentally become an opaque theme fill.
- Offer readable defaults, contrast guidance, and accessibility presets as recommendations, not forced clamps.

### 05.2 Appearance migration

- Decode legacy global `windowOpacity`, `blurBackground`, `interactiveGlassEffects`, and `glassMaterialStyle` values.
- Decode and translate old `TerminalSessionOverride` payloads instead of dropping unknown fields.
- Preserve Boolean legacy blur behavior as well as newer numeric values.
- Version the appearance schema and make migration idempotent.
- Test old defaults, old per-session overrides, mixed old/new values, invalid values, and round-trip persistence.

### 05.3 Liquid Glass and Vision Pro interaction

- Use glass for controls, navigation, toolbars, and ornaments where it improves spatial hierarchy.
- Avoid stacking custom glass effects unintentionally.
- Keep standard system components where they provide correct hover, focus, contrast, and accessibility behavior.
- Use visionOS 27 improvements for adaptive geometry, toolbars, privacy, and accessibility without adding spectacle that competes with terminal work.
- Validate full transparency and blur on physical Vision Pro across representative lighting and passthrough conditions.

### 05.4 SharePlay removal

Choose and test one release outcome:

- Complete: connect the shared output stream to viewer rendering, define authorization, participant roles, read-only default, lifecycle cleanup, and a separately audited remote-input path; or
- Hidden: remove every release entry point and public claim while retaining only clearly marked development scaffolding.

### 05.5 Port forwarding

- Inject one shared `PortForwardManager` into terminal and standalone surfaces.
- Make add/toggle/delete controls reflect confirmed tunnel state.
- Consolidate or remove the standalone window's separate transient manager.
- Cover local, remote, dynamic, cancellation, reconnect, failure, and cleanup.
- Never display an active state before the tunnel is active.

### 05.6 HTML Preview

Choose and test one release outcome:

- Complete: use an explicit SSH tunnel or deliberate remote URL, validate scheme/host/port, display origin, define TLS and navigation policy, and tie lifetime to the session; or
- Hidden: remove the release entry point and product claim.

### 05.7 Authentication and transport options

- Hide SSH Agent until an app-owned agent design exists.
- Hide or fully integrate `requestPTY`, compression, and agent forwarding.
- Never substitute password authentication while labeling the connection as Agent.
- Add integration tests before exposing any option.

### 05.8 Inert settings and AI summary

- Auto-record must use Phase 03 policy or be removed.
- Save scrollback and maximum scrollback must use Phase 04 runtime behavior or be removed.
- Tailscale auto-discovery, sidebar default visibility, info-panel visibility, and sidebar position must affect the actual UI or be removed.
- AI summary must have a reachable, privacy-scoped, size-bounded recording flow or be removed.

### 05.9 Public claims

- Compare README, website, App Store copy, screenshots, and help text against completed/hidden outcomes.
- Remove claims for hidden or partial SharePlay, HTML Preview, forwarding, recording, AI summaries, SSH Agent, and inert settings.
- Describe hardware signing and transparent-terminal behavior accurately.

## Acceptance criteria

- Full terminal transparency is demonstrably available on Vision Pro.
- Opacity and blur are independently controllable and persist globally and per session.
- Upgrades preserve legacy appearance intent.
- Accessibility guidance does not remove user choice.
- Every visible feature completes entry, runtime behavior, errors, cleanup, and tests.
- Incomplete features have no release UI entry point or public functional claim.
- Terminal-local and standalone forwarding never diverge.

## Automated tests

- Appearance value bounds, endpoints, persistence, and old-schema migration corpus.
- Full-transparency state and independent opacity/blur binding tests.
- Release-surface snapshot/availability tests for completed versus hidden features.
- SharePlay removed-state tests and Release symbol/UI inspection.
- Port-forward lifecycle and shared-state tests.
- HTML origin/tunnel policy or hidden-state tests.
- Runtime-consumer tests for every retained setting.

## Manual/device verification

- Physical Vision Pro transparency/opacity/blur matrix under different passthrough lighting.
- Eye-and-hand usability and text legibility at full transparency and intermediate settings.
- Complete feature workflows and cleanup.
- Public screenshot/copy comparison against the tested build.

## Exit evidence

- User approval that the defining transparent-terminal experience is preserved.
- Feature-by-feature complete/hidden decision record.
- Device evidence and green migration/lifecycle tests.
