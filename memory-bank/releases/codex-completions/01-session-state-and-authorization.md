# Phase 01 — Session State and Authorization

## Objective

Finish the shared session-opening policy without allowing server configuration, credentials, host trust, or authorization behavior to diverge between entry paths.

## Included items

`SES-001...005` from the canonical ledger.

## Current status — QA

The shared session-opening policy, authoritative live server store, explicit external-request confirmation, credential preparation, reconnect cancellation, layout partial-failure handling, and transient-session cleanup are implemented and covered by the 164-test app suite on visionOS 26.4 and 27.0 simulators. Physical Vision Pro hardware-key, widget/deep-link, and network-interruption workflows remain part of Phase 10 device acceptance.

## Existing implementation to extend

- `glas.sh/SessionManager.swift:34` centralizes credential preparation.
- `glas.sh/SessionManager.swift:58` creates authorized sessions.
- `glas.sh/SessionManager.swift:81` centralizes manual reconnect.
- `glas.sh/Models.swift:430` performs auto-reconnect.
- `glas.sh/glas_shApp.swift:145` receives external URLs and `glas.sh/glas_shApp.swift:148` presents confirmation.
- `glas.sh/ConnectionManagerView.swift:550` opens normal connections and `glas.sh/ConnectionManagerView.swift:679` restores layouts.
- `glas.sh/TerminalWindowView.swift:370` duplicates sessions and `glas.sh/TerminalWindowView.swift:400` reconnects them.

Preserve this work and refine it; do not replace it with parallel flow-specific connection implementations.

## Reuse strategy

- Extend `SessionManager` as the single orchestration boundary.
- Reuse `ServerManager` persistence methods after changing ownership/injection so there is one authoritative live instance.
- Reuse `SessionOpenError` for typed, user-facing policy failures.
- Reuse existing trust challenges and terminal session objects; do not introduce mock production sessions.
- Reuse widget `glassh://connect?serverID=` URLs and route them through the same external-request policy.

## Work packages

### 01.1 One authoritative server store

`ConnectionManagerView` currently creates its own `ServerManager` at `glas.sh/ConnectionManagerView.swift:15`, while `SessionManager` owns another at `glas.sh/SessionManager.swift:20`. Consolidate ownership and inject the same observable store into both.

Required behavior:

- Editing, adding, deleting, favoriting, trusting, or updating last-connected state changes one live source.
- Deep links cannot resolve a deleted server or stale pre-edit configuration.
- Jump-host chains use the same current configurations shown in Connections.
- Updating `lastConnected` cannot serialize a stale array over newer edits.
- Tests exercise edits and deletions followed immediately by deep-link and layout requests.

### 01.2 Complete credential policy

- Password: retrieve namespaced Keychain material unless a transient quick-connect password is explicitly supplied.
- Imported key: resolve metadata and secret material consistently.
- Hardware signing key: defer final authorization mechanics to Phase 02 but route every use through the same policy.
- Agent: return a typed unsupported result while its release UI is hidden in Phase 05.
- Jump hosts: resolve credentials and authorization for every hop, not just the final server.
- Missing or inaccessible credentials: distinguish not-found, locked/unavailable, canceled authorization, unsupported method, and corrupt material.

### 01.3 Entry-path parity

Cover:

- normal saved connection;
- quick connect and Tailscale transient connection;
- manual reconnect;
- automatic reconnect;
- duplicate session;
- layout preset with partial success;
- widget and deep-link launch;
- host-key trust retry;
- future workspace restore through the same boundary.

### 01.4 External-request lifecycle

- Load persistent server/settings state before resolving a cold-launch URL.
- Reject malformed schemes, hosts, parameters, and UUIDs.
- Reject unavailable, deleted, or unauthorized server IDs.
- Present server identity before connecting.
- Require a fresh decision for external requests; do not treat prior app activity as consent.
- After confirmation, apply the same credential, trust, compatibility, and hardware-key policy as a normal connection.
- Surface host-key challenges without bypassing trust review.

### 01.5 Error, cancellation, and cleanup policy

- Remove failed transient sessions from `SessionManager.sessions`.
- Preserve useful session context on manual reconnect failure.
- Report layout failures per server while retaining successful sessions.
- Cancel reconnect tasks before a competing manual action.
- Avoid multiple concurrent system-auth prompts for the same session.

## Acceptance criteria

- One live `ServerManager` instance serves Connections, sessions, deep links, layouts, jump hosts, widgets, and last-connected writes.
- Every listed entry path invokes the shared preparation policy.
- Password, imported-key, and hardware-key configurations behave consistently across entry paths.
- External requests always require confirmation and cannot use stale/deleted configurations.
- Layout partial failures are visible per server without discarding successful sessions.
- No failed transient session remains open or registered.

## Automated tests

- Server edit/delete followed by immediate lookup from session and external-request paths.
- Password resolution for create, reconnect, duplicate, layout, and auto-reconnect.
- Unsupported agent behavior never falls back to password.
- Cold-launch deep-link state loading and confirmation.
- Invalid/missing/deleted deep-link IDs.
- Layout mixed success/failure cleanup.
- Jump-chain resolution and cycle/missing-hop failure.
- Cancellation and competing reconnect behavior.

## Manual/device verification

- Widget tap and pasted `glassh://` URL on cold and warm launch.
- Password reconnect after network interruption.
- Hardware-key normal/reconnect/duplicate/layout/widget flows on Vision Pro.
- Edit or delete a server, then exercise a previously generated widget URL.

## Risks and mitigations

- State consolidation can affect many views: migrate ownership incrementally and keep persistence format stable.
- External URL ordering is platform-dependent: test cold launch on simulator and hardware.
- Authentication UI cannot be fully validated in simulator: do not close the gate without physical-device evidence.

## Exit evidence

- Reviewed state-ownership diagram and diff.
- Green entry-path unit/integration suite.
- Device evidence for external confirmation and hardware-key parity.
