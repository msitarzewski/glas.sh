# 260208_ssh-key-management-config-import-and-trust-scoping

## Objective
Implement SSH key management and pasted SSH config import in the app sandbox model, while scoping known-host trust to each server configuration.

## Outcome
- Added settings-level SSH key CRUD backed by Keychain storage.
- Added pasted OpenSSH config parsing/import for a safe directive subset.
- Switched server auth config from key-path-first to key-selection by stored key ID.
- Scoped host-key trust persistence to server configs and wired trust-accept flow to update those configs.
- Added explicit RSA message: key auth support is coming soon, ED25519 is supported now.
- Build: successful (`xcodebuild ... build`).
- Tests: parser tests added; simulator-backed `xcodebuild test` unavailable in this environment due to CoreSimulator service errors.

## Files Modified
- `/Users/michael/Developer/glas.sh/glas.sh/Managers.swift`
- `/Users/michael/Developer/glas.sh/glas.sh/Models.swift`
- `/Users/michael/Developer/glas.sh/glas.sh/ConnectionManagerView.swift`
- `/Users/michael/Developer/glas.sh/glas.sh/ServerFormViews.swift`
- `/Users/michael/Developer/glas.sh/glas.sh/SettingsView.swift`
- `/Users/michael/Developer/glas.sh/glas.shTests/glas_shTests.swift`

## Integration Notes
- Runtime SSH auth path updated in `SSHConnection.connect(...)` to resolve key material via key ID from Keychain.
- Trust prompt acceptance now persists host key entries via `ServerManager` onto the matching server config.
- Config import maps parsed host blocks into `ServerConfiguration` records without filesystem `~/.ssh/config` dependency.

