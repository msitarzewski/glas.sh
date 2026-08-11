# Project Rules

## Code and Structure
- Prefer incremental edits over large rewrites.
- Keep implementation docs in root README and memory bank, not mixed into runtime source folders.
- Keep local machine artifacts out of commits (`xcuserdata`, build state, etc.).
- One manager/service per file — no monolithic files combining unrelated concerns.
- All UserDefaults keys and Keychain service names go through typed enums in `Constants.swift`. No bare string literals for storage keys.
- Use `os.Logger` with subsystem `sh.glas` and appropriate category (`Logger.ssh`, `.servers`, `.settings`, `.keychain`, `.app`). No `print()` in production code.
- Concurrency safety: use `OSAllocatedUnfairLock` for thread-safe caches accessed from non-actor contexts. Use `nonisolated(unsafe)` only for `deinit` access to actor-isolated task properties.

## Keychain Handling
- Use protocol/purpose/terminal-namespaced, profile-stable accounts from `KeychainAccountNamespace`; do not compose bare credential account strings at call sites.
- Shared legacy migrations are forward-only and non-destructive: atomic add-if-absent, verified readback, conflict preservation, and no source deletion.
- User-authorized app-owned credential replacement may remove an exact old account only after the new secret and metadata commit and only when concurrent replacement is not overwritten.
- Destructive secret operations require durable secret-free recovery state, artifact-level verification, and fail-closed behavior when exact restoration cannot be proven.
- Never use `try?` for keychain saves — use `do/catch` with `Logger.keychain.error()` + user-facing alert.
- Pre-load existing passwords in edit flows.
- Clean up orphaned keychain entries when auth method switches away from password.
- Suppress visionOS AutoFill on app-managed SecureFields via `.textContentType(.init(rawValue: ""))`.

## Terminal Focus and Appearance
- Terminal focus must respect aggregate ownership by search, sheets, editors, alerts, file pickers, and IME composition. Use explicit resign plus bounded key-window-aware retry; never use an unconditional periodic focus timer.
- Reapply configured caret color after first-responder acquisition because SwiftTerm creates its UIKit caret during focus.
- Preserve independent opacity and blur controls. Both zero is a supported fully transparent terminal and must not be clamped away by defaults, accessibility guidance, or Liquid Glass composition.

## Collaboration
- Use PR-first workflow for all non-trivial changes.
- Keep branch naming with `agent/` prefix for feature branches.
- GitHub CLI authentication is stored in macOS Keychain. Run authenticated `gh`
  operations outside the workspace sandbox so the Keychain-backed session is
  visible. Never ask the user to reauthenticate based only on a sandboxed `gh`
  failure; retry the same operation outside the sandbox first.
- Local foreground GUI automation is opt-in. Do not run macOS XCUITests or other
  automation that opens, focuses, or drives application windows on the user's
  active desktop without explicit approval for that test session. Non-interactive
  builds/unit tests and simulator work remain permitted.

## Documentation Tone and Status Labeling
- Use neutral, operational language in memory-bank files.
- Avoid alarm-style emoji markers and high-intensity wording in persistent docs.
- Label archived notes as historical records and keep current status in `README.md`, `activeContext.md`, and `progress.md`.
- Preserve contemporaneous task and release evidence. Add a dated post-release checkpoint instead of rewriting old test totals or claiming that later evidence existed at the original gate.
- Label evidence precisely: a build is not a test pass, simulator evidence is not physical-device evidence, and a partial device smoke is not a completed release matrix.
- Treat `Package.resolved`, the Xcode target graph, current source, retained `.xcresult` records, and GitHub merge metadata as authorities for version, target, test, and publication claims.
