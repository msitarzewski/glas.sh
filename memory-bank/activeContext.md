# Active Context

## Current Focus
- Stabilize and polish the visionOS SSH terminal UX.
- Finalize terminal window composition boundaries:
  - frame chrome stays system-like/stable
  - display/translucency controls apply to terminal pane only
- Keep global settings global and move session-specific controls into terminal-local context.
- Keep README/docs aligned with currently shipped capabilities.
- Maintain clean repo structure for public open-source collaboration.

## Immediate Priorities
- Continue PR-based workflow on protected `main`.
- Keep Connections manager aligned to native visionOS conventions (split view/list/search/toolbar), with lightweight filter chips for active tag filters.
- Verify end-to-end edit/add form data persistence for tag and SSH-key fields after current UX refactor.
- Validate final tuning of terminal-local settings modal contrast/legibility under different room backgrounds.
- Keep app-source folder free of ad-hoc task markdown docs.
- Keep UX/table polish as current stream, then execute queued SSH security features:
  - Secure Enclave-backed SSH key generation/storage flow (non-exportable keys, device-bound).
  - SSH agent authentication/forwarding implementation and session wiring.
