# Testing Patterns

## Test Suite
- 164 app unit/integration/security/terminal tests in `glas.shTests/glas_shTests.swift`; the approved checkpoint passed all 164 on both visionOS 26.4 and visionOS 27.0 arm64 simulators.
- 75 GlasSecretStore tests across 13 suites under `Packages/GlasSecretStore/Tests`; run with `swift test --package-path Packages/GlasSecretStore` and an isolated scratch path.
- Run the app suite via Xcode scheme `glas.sh` or `xcodebuild test`; retain `.xcresult` bundles for release evidence.

## Test Categories
- **ServerManager**: CRUD operations, persistence via UserDefaults, duplicate handling, tag management.
- **SettingsManager**: Settings persistence round-trip, default values, SSH key list operations.
- **Constants**: Compile-time validation of `UserDefaultsKeys` and `KeychainServiceNames` enum values, uniqueness checks.
- **Error Classification**: `isChannelClosedError()` helper coverage across known error string patterns, key exchange failure detection.
- **TerminalSession**: Lifecycle management, task cleanup on deinit.
- **SSHConfigParser**: Edge cases for `~/.ssh/config` parsing (host blocks, key-value formats, whitespace handling).
- **Credential lifecycle**: forward-only migration, atomic destination creation, conflict/concurrency preservation, transactional artifact deletion, Secure Enclave provenance, and recovery journals.
- **Terminal policy**: live-buffer search, focus ownership, paste size/multiline review, OSC/link policies, hardware mappings, ANSI/SGR styles, caret/theme propagation, scrollback, and PTY resize.
- **Storage and transfer**: recording bounds/protection/deletion, SFTP containment/resume/atomic commit, forwarding/SOCKS bounds and cleanup.
- **Appearance**: global/session migration plus all four opacity/blur endpoint combinations, including fully transparent.

## Primary Validation
- Xcode build for visionOS target after functional changes.
- Manual terminal smoke tests:
  - SSH connect/disconnect
  - Inline shell input
  - PTY resize behavior (rows/cols)
  - Common TUIs (`top`, `htop`) and ANSI color rendering
  - In-place progress rendering (`apt`, `wget`, `curl -#`)

## Regression Focus
- Input/focus behavior when switching windows.
- Ornament interactions and viewport clipping/padding behavior.
- Keychain persistence: verify saved passwords survive edit/reconnect cycles.
- Stream rendering: carriage-return updates render in-place, not stacked.
