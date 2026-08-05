# Phase 03 — Product Identity and Platform Configuration

## Objective

Adopt one application identity while selecting the correct Info.plist, entitlements, deployment settings, and data-migration behavior for each SDK.

## Status

`Complete`

## Owner

Codex agent team

## Dependencies

Phase 02.

## Primary files

- `glas.sh.xcodeproj/project.pbxproj`
- `glas.sh/Info.plist`
- `Platforms/macOS/Info.plist`
- `glas.sh/glas.sh.entitlements`
- `Platforms/macOS/macOS.entitlements`
- `glas.sh/Constants.swift`
- Existing defaults/bootstrap migration code

Only one agent may edit `project.pbxproj` during this phase.

## Product-identity decision

Use `sh.glas.app` as the application bundle identifier on every supported platform unless signing/provisioning evidence requires a user decision.

The old development-only Mac identity is `sh.glas.mac`. Because no release has shipped, this is the safest time to converge, but current development preferences must still be audited.

## Work items

1. Set one application bundle identifier across SDKs.
2. Select SDK-specific configuration following the glassdb pattern:
   - default plist: `glas.sh/Info.plist`;
   - macOS plist: `Platforms/macOS/Info.plist`;
   - default entitlements: `glas.sh/glas.sh.entitlements`;
   - macOS entitlements: `Platforms/macOS/macOS.entitlements`.
3. Preserve URL scheme, category, local-network messaging, Face ID text, and multi-scene declarations where applicable.
4. Preserve the shared Keychain access group.
5. Preserve the iCloud KVS identifier.
6. Add the shared application group to the Mac entitlement because Mac managers use `SharedDefaults`.
7. Audit `UserDefaults.standard` keys stored under `sh.glas.mac`.
8. First prove whether the old defaults domain is safely readable. If it is, extend the existing migration path with an idempotent, non-secret, add-if-absent import.
9. Never copy credentials, key material, passphrases, or host-trust secrets through defaults; GlasSecretStore remains authoritative.
10. If the old preference domain is not safely readable, stop and present the exact evidence before accepting a development-settings reset.

## Migration tests

- First launch with only old Mac standard defaults.
- First launch with both old and new values; new values win.
- Repeated migration is idempotent.
- Shared defaults remain available.
- iCloud-synced themes and appearance remain available.
- Saved servers, SSH keys, passphrases, and host trust remain retrievable through their existing stores.
- No source credential is deleted.

## Signing tests

- Build and codesign each platform product.
- Inspect effective entitlements with `codesign`.
- Verify bundle identifier, KVS identifier, application group, and Keychain group.
- Verify Mac remains native and Apple Silicon-only.

## Rollback

Restore the previous build settings and old Mac bundle identity. Migrations must be forward-safe and must not delete the old domain.

## Exit gate

Every platform uses one intended product identity, receives correct SDK-specific metadata and entitlements, and preserves settings and secret-store access without destructive migration.

## Completion evidence

- All application products use bundle identifier `sh.glas.app`; the widget uses `sh.glas.app.glasWidgets`.
- SDK-conditional plist and entitlement selection preserves the shared `group.sh.glas.shared` app group, Keychain access group, and iCloud KVS namespace.
- `glas.sh/Constants.swift` adds an idempotent, add-if-absent migration for readable non-secret values from the old development Mac defaults domain; existing destination values win and sources are retained.
- Credentials, SSH key material, passphrases, and host trust remain in GlassSecretStore/Keychain paths. `glas.sh/KeychainManager.swift` cleans only verified app-owned compatibility aliases.
- GlasSecretStore passed 69/69, including real Keychain round trips, migration, SSH-key, host-trust, fallback, deletion, and account-identity coverage.
