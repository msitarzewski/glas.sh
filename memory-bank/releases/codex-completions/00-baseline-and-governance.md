# Phase 00 — Baseline and Governance

## Objective

Create a trustworthy execution baseline before implementation begins. This phase owns the release ledger, evidence policy, toolchain/runtime matrix, sequencing rules, and the Vision Pro product invariant.

The supported release baseline is Apple OS 26 or newer on Apple Silicon only.

## Included items

- Program governance for every item in `README.md#Canonical item ledger`.
- Current build/test baseline and the Xcode 26/Xcode 27 runtime distinction (`QA-002`, `QA-003`).
- Product invariant for full terminal transparency and adjustable opacity/blur (`VIS-001...005`). Phase 05 implements it; Phase 00 prevents later phases from redefining it away.

## Current status — Complete

The ledger, evidence rules, supported platform floor, product invariant, and honest open-gate policy are approved. Toolchain/device rows remain execution evidence owned by Phase 10 rather than reopening this governance phase.

## Current evidence

- The working branch contains active user changes and must not be overwritten (`memory-bank/activeContext.md#Current Focus`).
- Xcode 27.0 (27A5209h) builds the final candidate with the installed Metal Toolchain.
- The full app test action passes 164/164 on both visionOS 26.4 and visionOS 27.0 arm64 simulators, with no failures, skips, expected failures, or runtime warnings.
- GlasSecretStore passes 75/75 tests across 13 suites.
- The generic Release app is arm64-only with minimum visionOS 26.0 and SDK 27.0.
- A matching Xcode 26.x current-tree run and physical Vision Pro validation remain required; Xcode 26 is not installed in this environment.

## Work packages

### 00.1 Release-control model

- Use the root release README as the canonical mapping and status dashboard.
- Give each item one owning phase and one evidence trail.
- Require an explicit user decision before moving an item to `Deferred`.
- Require release-build verification for every item marked `Hidden`.
- Keep implementation task records under `memory-bank/tasks/`; do not turn the release plan into retrospective task documentation.

### 00.2 Product-invariant review gate

Every implementation plan affecting appearance, rendering, windows, themes, accessibility, or platform extraction must answer:

1. Can a Vision Pro user still choose a genuinely 100% transparent terminal?
2. Can the user still adjust opacity and blur as distinct concepts?
3. Are global and per-session choices migrated without loss?
4. Do defaults and accessibility guidance preserve user choice?
5. Does the implementation avoid unintentional glass-on-glass while retaining the defining transparent-terminal experience?

### 00.3 Toolchain and runtime matrix

Track at minimum:

| Toolchain | SDK/runtime | Build | Tests | Required conclusion |
|---|---|---|---|---|
| Xcode 26.4 | visionOS 26.x simulator | Pending; Xcode 26 unavailable locally | Pending | Required matching-toolchain baseline |
| Xcode 26.4 | Physical Vision Pro on supported OS | Pending | Manual suite pending | Hardware/security/visual baseline |
| Xcode 27.0 (27A5209h) | visionOS 27.0 simulator | Passed 2026-07-17 | 164/164 passed | Forward compatibility baseline |
| Xcode 27.0 (27A5209h) | visionOS 26.4 simulator | Passed 2026-07-17 | 164/164 passed | Runtime-floor evidence; does not replace Xcode 26 proof |

All rows use arm64 destinations. Intel, Rosetta, Catalyst, and pre-26 runtime results do not qualify this release.

Record exact Xcode build, simulator/runtime, destination, and test result for every release candidate. Never reuse stale simulator UUIDs in persistent documentation.

### 00.4 Dependency and phase gates

- Phases 01–03 close release security boundaries before broad product expansion.
- Phase 04 hardens the terminal before engine comparison.
- Phase 05 makes the visible release honest and preserves the Vision Pro invariant.
- Phase 06 begins multi-platform extraction only after core boundaries are stable.
- Phases 07–09 are product expansion and evidence-based engine work.
- Phase 10 is the only phase that declares a release candidate ready for distribution.

## Acceptance criteria

- Every external audit recommendation and Codex review finding appears in the canonical ledger.
- Each item has a single owner, source, status, and milestone acceptance path.
- The transparency/opacity/blur requirement is explicit in the root README and relevant phases.
- Toolchain evidence distinguishes compilation, simulator execution, and real-device validation.
- Phase dependencies do not permit native-platform or engine work to bypass security and terminal correctness.

## Verification

- Compare ledger sources against all recommendations in `../docs/glas.sh-results.txt:51`, `:120`, `:152`, `:193`, `:222`, and `:249`.
- Compare against `memory-bank/activeContext.md#Functional Hardening Backlog`.
- Compare against the Codex findings recorded in the release README.
- Validate every relative link in the release directory.

## Exit evidence

- User-approved release-program structure.
- Complete ledger audit with no orphaned recommendations.
- Recorded build/test baseline and known runtime mismatch.
