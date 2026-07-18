# 2026-07 Tasks

## Tasks Completed

### 2026-07-17: codex-completions implementation and automated-QA checkpoint
- Completed and user-approved the current code/automated-QA checkpoint for the `codex-completions` visionOS release candidate.
- Preserved true full terminal transparency and independent opacity/blur controls while hardening menu order, focus ownership, caret theme, ANSI colors, security, session lifecycle, recording, SFTP, forwarding, and generated-command policy.
- Verified 164/164 app tests on both visionOS 26.4 and visionOS 27.0 arm64 simulators, plus 75/75 GlasSecretStore tests across 13 suites.
- Built an arm64-only generic Release app with minimum visionOS 26.0 and SDK 27.0; installed and smoke-launched on both simulator runtimes.
- Completed independent security/static reviews and an isolated Gitleaks adjudication with zero actionable production credentials.
- Retained physical-device, matching-Xcode-26, external-service, conformance, cross-repository, Phases 06–09, and App Store distribution work as explicit open gates.
- See: [170726_codex-completions-release.md](./170726_codex-completions-release.md)
