# Testing Patterns

## Test Suite
- 25 unit tests in `glas.shTests/glas_shTests.swift`.
- Run via Xcode scheme `glas.sh` or `xcodebuild test`.

## Test Categories
- **ServerManager**: CRUD operations, persistence via UserDefaults, duplicate handling, tag management.
- **SettingsManager**: Settings persistence round-trip, default values, SSH key list operations.
- **Constants**: Compile-time validation of `UserDefaultsKeys` and `KeychainServiceNames` enum values, uniqueness checks.
- **Error Classification**: `isChannelClosedError()` helper coverage across known error string patterns, key exchange failure detection.
- **TerminalSession**: Lifecycle management, task cleanup on deinit.
- **SSHConfigParser**: Edge cases for `~/.ssh/config` parsing (host blocks, key-value formats, whitespace handling).

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
