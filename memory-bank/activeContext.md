# Active Context

## Current Focus
- Stabilize and polish the visionOS SSH terminal UX.
- Ship secure SSH key handling improvements without breaking legacy users.
- Keep global settings global and move session-specific controls into terminal-local context.
- Keep README/docs aligned with currently shipped capabilities.
- Maintain clean repo structure for public open-source collaboration.

## Immediate Priorities
- Continue PR-based workflow on protected `main`.
- Keep Connections manager aligned to native visionOS conventions (split view/list/search/toolbar), with lightweight filter chips for active tag filters.
- Verify end-to-end auth behavior for RSA SHA-2 and ED25519 across existing server fleet.
- Keep high-frequency terminal stream rendering stable under carriage-return update workloads (`apt`, `wget`, `curl -#`) and avoid UI-side chunk loss.
- Validate Secure Enclave key generation/export/copy UX and connection preflight auth prompt.
- Keep app-source folder free of ad-hoc task markdown docs.
- Follow-up stream:
  - True Secure Enclave signing integration (no exportable app-level private key material for generated P-256 keys).
  - SSH agent authentication/forwarding implementation and session wiring.
