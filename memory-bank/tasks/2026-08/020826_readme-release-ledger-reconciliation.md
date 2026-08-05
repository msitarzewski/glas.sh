# 020826_readme-release-ledger-reconciliation

## Objective

Bring the public README architecture and build narrative in line with the unified One Base application while preserving the approved post-release evidence already recorded in the release ledgers.

## Outcome

- ✅ Updated the public architecture narrative from a visionOS-only description to one native Swift 6 application target, one `@main`, one `sh.glas.app` identity, and one shared scheme across Mac, iPhone, iPad, and Vision Pro.
- ✅ Documented `Platforms/macOS` as the native AppKit/local-PTY implementation boundary rather than a separate product.
- ✅ Corrected the SwiftTerm host description and documented the current GlasSecretStore package boundary.
- ✅ Updated requirements and GUI/CLI build instructions for every supported destination while retaining the Vision Pro-first product positioning.
- ✅ Preserved the Codex Completions, Connection Library, and One Base post-release adaptive-workspace and physical-device checkpoints without rewriting their historical acceptance evidence.
- ✅ QA: documented paths exist, project settings and shared schemes match the README, Markdown fences are balanced, obsolete public architecture phrases are absent, and `git diff --check` passes.
- ✅ User approved the implementation and documentation result on 2026-08-02.

## Files Modified

- `README.md` — current architecture, repository layout, terminal host boundary, requirements, supported destinations, and shared-scheme build instructions.
- `memory-bank/releases/codex-completions/*` — retained the existing post-release adaptive-workspace and Vision Pro evidence reconciliation.
- `memory-bank/releases/connection-library/*` — retained the existing post-release physical-device routing evidence.
- `memory-bank/releases/one-base/*` — retained the existing post-release merge and physical-device verification notes.
- `memory-bank/tasks/2026-08/README.md` and `memory-bank/toc.md` — index this approved task record.

## Patterns Applied

- `memory-bank/systemPatterns.md#One-Native-Multiplatform-Application-Target`
- `memory-bank/systemPatterns.md#Terminal-Architecture`
- Release evidence remains checkpoint-specific: later verification augments rather than rewrites historical approval records.

## Integration Points

- `glas.sh/glas_shApp.swift` remains the sole application entry point.
- `glas.sh.xcodeproj/project.pbxproj` remains the authority for supported platforms, bundle identity, deployment floors, Swift version, and Catalyst policy.
- `glas.sh.xcodeproj/xcshareddata/xcschemes/glas.sh.xcscheme` remains the shared application scheme.
- `Platforms/macOS` remains a platform implementation boundary inside the unified application target.

## Architectural Decisions

No new architectural decision was introduced. The README now reflects the approved One Base and adaptive-workspace architecture already recorded in the Memory Bank.

## QA Results

- Documentation paths: pass.
- Project/scheme fact check: pass.
- Markdown fence check: pass.
- Obsolete public-architecture phrase scan: pass.
- Release-ledger checkpoint retention scan: pass.
- `git diff --check`: pass.
- Application build/tests: not run; documentation-only change.
