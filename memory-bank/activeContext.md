# Active Context

## Current Focus
- Comprehensive audit fix shipped — 7 package wiring fixes, 6 app feature wiring, 7 dead code removals.
- SSH channel writability fix shipped — terminal input no longer freezes under backpressure.
- Shared App Group defaults migration shipped — servers/keys/trustedHostKeys shared between glas.sh and glassdb.
- visionOS 26 Liquid Glass compliance shipped — all views updated.
- Stabilize and polish the visionOS SSH terminal UX.

## Immediate Priorities
- Continue PR-based workflow on protected `main`.
- Verify end-to-end auth behavior for RSA SHA-2 and ED25519 across existing server fleet.
- Test newly wired features: terminal bell, snippet execution, confirm-before-close, background session cleanup.
- Validate shared defaults migration path (upgrade from old builds, fresh install, cross-app read from glassdb).
- Follow-up stream:
  - True Secure Enclave signing integration (no exportable app-level private key material for generated P-256 keys).
  - SSH agent authentication/forwarding implementation (forwardAgent now marked "Coming Soon").
  - Port forwarding implementation (UI exists, SSH tunnel wiring needed via DirectTCPIP).
  - Auto-reconnect implementation (SessionState.reconnecting exists, needs behavioral wiring).
  - glassdb follow-up PR to read from shared App Group suite.
