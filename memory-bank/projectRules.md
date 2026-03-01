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
- Keychain account key format: `"\(username)@\(host):\(port)"`. Changing any component requires deleting the old entry after saving to the new key.
- Never use `try?` for keychain saves — use `do/catch` with `Logger.keychain.error()` + user-facing alert.
- Pre-load existing passwords in edit flows.
- Clean up orphaned keychain entries when auth method switches away from password.
- Suppress visionOS AutoFill on app-managed SecureFields via `.textContentType(.init(rawValue: ""))`.

## Collaboration
- Use PR-first workflow for all non-trivial changes.
- Keep branch naming with `codex/` prefix for feature branches.

## Documentation Tone and Status Labeling
- Use neutral, operational language in memory-bank files.
- Avoid alarm-style emoji markers and high-intensity wording in persistent docs.
- Label archived notes as historical records and keep current status in `README.md`, `activeContext.md`, and `progress.md`.
