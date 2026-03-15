# 260315_shared-defaults-migration

## Objective
Migrate server configurations, SSH key metadata, and trusted host keys from `UserDefaults.standard` (per-app sandboxed) to shared App Group storage (`group.sh.glas.shared`) so data is accessible to both glas.sh and glassdb.

## Outcome
- Added App Group entitlement to glas.sh (matching glassdb)
- Added `SharedDefaults` enum in `Constants.swift` with suite name, shared defaults instance, and `migrateIfNeeded()` migration logic
- Switched `servers`, `sshKeys`, and `trustedHostKeys` reads/writes to shared suite across ServerManager, SettingsManager, and Models.swift
- Migration runs at bootstrap before settings load, with per-app sentinel to prevent re-migration
- All 20+ UI/terminal settings remain on `UserDefaults.standard`

## Files Modified
- `glas.sh/glas.sh.entitlements` — Added `com.apple.security.application-groups`
- `glas.sh/Constants.swift` — Added `SharedDefaults` enum
- `glas.sh/ServerManager.swift` — Switched to `SharedDefaults.defaults` (2 lines)
- `glas.sh/SettingsManager.swift` — Switched to `SharedDefaults.defaults` (4 lines)
- `glas.sh/Models.swift` — Switched fallback trusted host key read
- `glas.sh/glas_shApp.swift` — Added `SharedDefaults.migrateIfNeeded()` at bootstrap

## Patterns Applied
- `systemPatterns.md#File Organization` — SharedDefaults added to Constants.swift
- Migration sentinel stored in `.standard` (per-app) so each app migrates independently

## Architectural Decisions
- Simple copy (not merge) — shared suite is empty for all existing users
- Old `.standard` data not deleted — serves as inert backup for downgrade safety
- glassdb not modified in this change (follow-up PR will read from shared suite)
