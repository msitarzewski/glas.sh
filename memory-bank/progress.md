# Progress

## Latest Milestones
- Connections window refactored to a native visionOS split-view/list/search/toolbar structure.
- Tag filtering moved to search-submit promotion with active chip filters under title context.
- Server form persistence hardened:
  - pending tag text now commits on Save (Add/Edit)
  - SSH key picker selection persistence stabilized in Add/Edit
- Public repository published.
- `main` branch protection enabled for PR workflow.
- Root README established for GitHub landing view.
- App identity aligned to `glas.sh` domain namespace.
- Legacy task markdown moved out of app source tree into memory bank tasks.
- Memory-bank task records normalized to neutral historical wording.
- Terminal window UX iteration converged on:
  - footer-first action model
  - in-window session settings modal with local tabs
  - terminal-pane-only tint/translucency behavior (avoids text tint washout).

## Open Areas
- Ongoing terminal UX parity polish for edge-case TUIs.
- Final contrast tuning for modal/settings surfaces across varied scene lighting.
- Queued feature request (post-UX): Secure Enclave-backed SSH key generation/storage path comparable to Blink-style hardware-bound key handling.
- Queued feature request (post-UX): SSH agent auth/forwarding end-to-end support (model -> connection settings -> transport behavior).
