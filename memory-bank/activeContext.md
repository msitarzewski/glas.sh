# Active Context

## Current Focus
- visionOS 26 Liquid Glass compliance shipped — all views updated.
- Focus latency fix shipped — `@FocusState` added to all form views, terminal focus streamlined.
- Stabilize and polish the visionOS SSH terminal UX.
- Ship secure SSH key handling improvements without breaking legacy users.
- Maintain clean repo structure for public open-source collaboration.

## Immediate Priorities
- Continue PR-based workflow on protected `main`.
- Verify end-to-end auth behavior for RSA SHA-2 and ED25519 across existing server fleet.
- Keep high-frequency terminal stream rendering stable under carriage-return update workloads (`apt`, `wget`, `curl -#`) and avoid UI-side chunk loss.
- Validate Secure Enclave key generation/export/copy UX and connection preflight auth prompt.
- Follow-up stream:
  - True Secure Enclave signing integration (no exportable app-level private key material for generated P-256 keys).
  - SSH agent authentication/forwarding implementation and session wiring.
