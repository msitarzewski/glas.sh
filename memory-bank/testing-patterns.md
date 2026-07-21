# Testing Patterns

## Test Suite
- 211 app unit/integration/security/terminal tests pass on iOS 27; 208 pass on each of visionOS 26.4 and visionOS 27; 32 native workspace tests pass on Apple Silicon macOS 27.
- 76 GlasSecretStore tests across 13 suites under `Packages/GlasSecretStore/Tests`; run with `swift test --package-path Packages/GlasSecretStore` and an isolated scratch path.
- Run the app suite via Xcode scheme `glas.sh` or `xcodebuild test`; retain `.xcresult` bundles for release evidence.
- The shared `glas.shUITests` source is attached to iOS/visionOS and Mac UI-test targets. A buildable harness is not a passing runtime result: Xcode 27 beta may lose the UI worker and block during test-session finalization, which must be reported separately from direct application smoke evidence.

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
- **Connection Library**: deduplication, deterministic tie-break ordering, normalized/empty/multi-tag collections, every search field, built-in scopes, optional Network visibility, workgroup recipes, and selection preservation/clearing.

## Primary Validation
- Xcode build for visionOS target after functional changes.
- Manual terminal smoke tests:
  - SSH connect/disconnect
  - Inline shell input
  - PTY resize behavior (rows/cols)
  - Common TUIs (`top`, `htop`) and ANSI color rendering
  - In-place progress rendering (`apt`, `wget`, `curl -#`)
- Direct Connection Library smoke tests:
  - native Mac Library remains open while Local Terminal opens;
  - iPhone compact mode/scope navigation and hidden unconfigured Network;
  - iPad three-column presentation and adaptive row geometry; selection/details UI assertions require a completed runner execution before being claimed;
  - physical Vision Pro signed build/install, with launch/render claimed only after wearer-present confirmation or functioning CoreDevice services.

## Regression Focus
- Input/focus behavior when switching windows.
- Ornament interactions and viewport clipping/padding behavior.
- Keychain persistence: verify saved passwords survive edit/reconnect cycles.
- Stream rendering: carriage-return updates render in-place, not stacked.
