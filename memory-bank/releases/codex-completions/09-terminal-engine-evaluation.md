# Phase 09: Terminal Engine Evaluation

## Objective

Run a bounded, evidence-based `libghostty` integration spike after the existing SwiftTerm path is hardened. This phase informs an engine decision; it does not authorize a terminal rewrite.

## Included Items

- `ENG-001`: bounded `libghostty` integration spike.
- `ENG-002`: evidence-based engine decision.
- Audit-requested comparison with Ghostty, iTerm2, WezTerm, and Kitty behavior where the platforms and protocols overlap.

## Current status — Not started

SwiftTerm remains the production engine behind the hardened adapter. No `libghostty` spike, comparative benchmark, or engine migration is represented as complete. The current candidate proves that the SwiftTerm path builds, passes its automated behavior suite, preserves ANSI color/caret behavior, and supports full transparency; the broader conformance/performance baseline and physical-device comparison remain prerequisites for this phase.

## Preconditions

- Phase 04's conformance corpus and `TerminalEngine` boundary are complete enough to run unchanged against another engine.
- Critical host-key, credential, recording, paste, OSC, and focus risks are closed or explicitly waived.
- The current SwiftTerm implementation has a measured baseline; the spike is not judged against an unmeasured target.

## Product Invariant

Any candidate engine must support the reason glas.sh exists: a premium Vision Pro terminal with a terminal canvas that can be 100% transparent and with user-adjustable opacity and blur. An engine that forces an opaque surface, clamps transparency, or couples opacity and blur without a viable adapter is not acceptable.

## Work Packages

### 09.1 Evaluation harness (`ENG-001`)

- Run the Phase 04 conformance corpus through the existing `TerminalEngine` boundary.
- Capture fidelity, input behavior, accessibility, latency, throughput, memory use, and crash data.
- Record the exact engine revision, build settings, platform SDK, simulator/runtime, and device used.

### 09.2 Bounded `libghostty` spike (`ENG-001`)

- Integrate only behind the engine boundary and a development-only selection mechanism.
- Keep the production default unchanged during evaluation.
- Implement only the minimum adapters needed to run the shared corpus and representative interactive sessions.
- Do not fork application state, settings, or security policy by engine.

### 09.3 Comparative benchmarks (`ENG-002`)

- Compare rendering and protocol behavior against documented or reproducible behavior in Ghostty, iTerm2, WezTerm, and Kitty.
- Measure cold start, first-prompt time, sustained output, resize, scrollback, search, Unicode, mouse reporting, and paste.
- Test transparent backgrounds and every opacity/blur extreme on Vision Pro hardware.
- Include accessibility and input-method behavior, not just frames per second.

### 09.4 Platform and maintenance assessment (`ENG-002`)

- Evaluate visionOS, macOS, and iPadOS integration cost.
- Assess Metal/toolchain requirements, binary size, licensing, update cadence, Swift interoperability, debugging, and App Store constraints.
- Identify ownership and upgrade costs for each native adapter.

### 09.5 Decision record (`ENG-002`)

- Choose one outcome: retain SwiftTerm, adopt `libghostty` incrementally, or defer pending specified blockers.
- Base the recommendation on published measurements and compatibility results.
- If adoption is recommended, create a separately approved migration program with rollback and coexistence stages.
- Do not replace the production engine under this phase alone.

## Acceptance Criteria

- The same conformance corpus runs against the baseline and the candidate.
- Results cover correctness, security integration, accessibility, performance, platform fit, and maintenance cost.
- Vision Pro transparency, opacity, and blur are tested explicitly and remain uncompromised.
- The decision explains trade-offs and has reproducible evidence.
- No production engine replacement occurs without a new approval gate.

## Verification

- Automated corpus pass/fail comparison.
- Instrumented performance runs on representative hardware.
- Manual keyboard, IME, dictation, mouse, accessibility, and window-appearance checks.
- App Store build/link verification for every candidate artifact.
- Regression run with the candidate disabled to prove the spike does not disturb the default engine.

## Evidence Required to Close

- Versioned benchmark report and raw result locations.
- Compatibility and conformance matrix.
- Maintenance/licensing assessment.
- Approved engine decision record.
- If applicable, a separately approved migration proposal.
