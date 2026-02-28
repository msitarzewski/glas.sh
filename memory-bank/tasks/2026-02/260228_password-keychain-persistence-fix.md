# 260228_password-keychain-persistence-fix

## Objective
Fix password keychain persistence so that passwords are reliably saved, loaded, and cleaned up across Add/Edit server flows — and suppress the visionOS system "save password" dialog that fires on credential-style forms.

## Outcome
- SecureField no longer triggers visionOS AutoFill credential detection
- Keychain save errors are logged via `Logger.keychain` and surfaced to the user via alert
- EditServerView pre-loads existing password from keychain on appear
- Changing host/port/username in Edit cleans up the orphaned keychain entry
- Switching auth method away from password cleans up the old keychain entry
- Build: successful
- Tests: 25/25 passing

## Files Modified
- `glas.sh/ServerFormViews.swift` — all changes in this single file:
  - Added `import os` for Logger access
  - Added `@State private var keychainSaveError: String?` to both AddServerView and EditServerView
  - Added `.textContentType(.init(rawValue: ""))` to both SecureFields (suppresses visionOS AutoFill)
  - Replaced `try?` with `do/catch` + `Logger.keychain.error()` in both `saveServer()` and `saveChanges()`
  - Added `.alert("Keychain Error", ...)` to both views — shown on save failure, dismisses form on OK
  - Added password pre-load in EditServerView `.onAppear` via `KeychainManager.retrievePassword(for:)`
  - Added keychain key migration in `saveChanges()`: deletes old entry when connection details change, deletes entry when auth method switches away from password

## Patterns Applied
- `systemPatterns.md#SSH Secret Handling Pattern` — keychain CRUD via `KeychainManager`
- `systemPatterns.md#Structured Logging` — `Logger.keychain` for error reporting
- Existing `KeychainManager.savePassword/retrievePassword/deletePassword` API — no new keychain code needed

## Integration Points
- `ServerFormViews.swift:222` — `KeychainManager.savePassword` in AddServerView
- `ServerFormViews.swift:465` — `KeychainManager.savePassword` in EditServerView
- `ServerFormViews.swift:431` — `KeychainManager.retrievePassword` on EditServerView appear
- `ServerFormViews.swift:477` — `KeychainManager.deletePassword` for orphaned key cleanup
- `ServerFormViews.swift:481` — `KeychainManager.deletePassword` on auth method change

## Architectural Decisions
- **AutoFill suppression via empty rawValue**: `.textContentType(.init(rawValue: ""))` is preferred over `.textContentType(nil)` because `nil` can still allow system inference, while an empty raw value explicitly opts out.
- **Server still created on keychain failure**: In AddServerView, `serverManager.addServer()` runs before the keychain save attempt. If save fails, the server exists but the user sees an alert explaining the password wasn't saved. This avoids a half-failed state where the user thinks nothing happened.
- **Pre-load uses `try?`**: Password retrieval in `.onAppear` silently falls back to empty — no alert needed since an empty field is the natural default.
- **Old key cleanup uses `try?`**: Deleting orphaned keychain entries is best-effort — failure to clean up an old entry is non-critical.
