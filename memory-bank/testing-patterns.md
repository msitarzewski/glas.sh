# Testing Patterns

## Test Suite
- **Exact-current native Mac connection-experience checkpoint (2026-08-11):**
  macOS 27 ran 276/276 tests with zero failures or skips after the stale-pane crash
  repair. iOS 27 and visionOS 27 simulator builds pass. A signed thin-arm64 Mac
  Release with hardened runtime satisfies its designated requirement. Manual review
  accepted Add/Edit layout and password save/connect; the first clean-exit smoke
  found a precondition crash and the rebuilt retest passed without error.
- **Exact-current adaptive-workspace checkpoint (2026-07-30):** macOS 27 ran 274/274 tests with zero build warnings; visionOS 27, iPadOS 27, and iOS 27 simulator builds passed.
- **Most recent full One Base runtime matrix:** iPhone and iPad 232/232; visionOS 26.4 and 27 229/229; macOS 251/251 before the final render-only delta. The iPad UI harness passed 2/2, the compact-iPhone smoke passed 1/1, and visionOS 27 produced one UI pass plus one explicit simulator-input skip.
- **Historical Connection Library release matrix:** iOS 211, visionOS 208, and native Mac workspace 32. These counts describe that release checkpoint and must not be presented as exact-current totals.
- 69 GlasSecretStore tests pass from the shared sibling repository at revision `1ffaa96312b8e4b4d6b82eb82cc40c8f6df6317f`; run with `swift test --package-path ../GlasSecretStore` and an isolated scratch path.
- Run the app suite via Xcode scheme `glas.sh` or `xcodebuild test`; retain `.xcresult` bundles for release evidence.
- The shared `glas.shUITests` source is attached to iOS/visionOS and Mac UI-test targets. A buildable harness is not a passing runtime result: Xcode 27 beta may lose the UI worker and block during test-session finalization, which must be reported separately from direct application smoke evidence.

## Interactive Test Execution Boundary

- Simulator builds, simulator tests, simulator launches, and non-interactive
  command-line builds/unit tests are normal QA.
- Local foreground macOS GUI automation can take focus and drive the user's active
  desktop. Run it only after explicit approval for that specific test session.
- Prefer signed builds plus user-driven manual visual/interaction review for local
  Mac UI changes. Hosted CI UI execution remains valid when its runner is reliable.
- Stopping a disruptive UI runner is not a waiver or a pass; record its last
  completed assertion and continue with non-foreground evidence.

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
- Build the shared `glas.sh` scheme for every affected destination after functional changes. A build proves compilation only; do not report it as a test pass.
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
- Physical-device truth (2026-08-01): a signed Vision Pro build successfully established SSH to the development Mac over Tailscale. This is partial device evidence, not the completed interaction, accessibility, performance, security, and distribution matrix.

## Regression Focus
- Input/focus behavior when switching windows.
- Ornament interactions and viewport clipping/padding behavior.
- Native adaptive presentation: compact sidebars overlay rather than clip; full-height sidebar material reaches behind traffic lights on Mac; terminal toolbar groups preserve order and spacing as the window compresses.
- Vision Pro terminal presentation: the initial terminal scene must open at usable scale, and the native session sidebar must have a discoverable dismissal path. These remain open as of 2026-08-01.
- Keychain persistence: verify saved passwords survive edit/reconnect cycles.
- Stream rendering: carriage-return updates render in-place, not stacked.
