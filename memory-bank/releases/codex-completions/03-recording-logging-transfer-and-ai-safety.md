# Phase 03 — Recording, Logging, Transfer, and AI Safety

## Objective

Protect terminal data and user-controlled files by default, remove sensitive diagnostics, and ensure generated commands cannot bypass deterministic application policy.

## Included items

`REC-001...006`, `LOG-001`, `SFTP-001...002`, and `AI-001`.

## Current status — In progress

Recording is output-only by default with per-recording input consent and persistent disclosure; files/indexes are protected and bounded; finalization follows session/window lifecycle; deletion is confirmed and fail-closed. Tailscale diagnostics are redacted/bounded. SFTP validates names and containment, uses identity-bound resumable protected partials, uploads with exclusive no-clobber creation, verifies exact sizes, and removes unsafe v3 rename. Generated commands remain editable and always require explicit confirmation. This automated checkpoint passes within the 164-test app action on both simulator runtimes. Export and physical-device file-protection/transfer behavior remain open.

## Existing implementation to extend

- Terminal input/output hooks live in `glas.sh/Models.swift:490` and currently feed recording before transmission.
- `glas.sh/SessionRecorder.swift:99` and `glas.sh/SessionRecorder.swift:191` own asciicast state and files.
- `glas.sh/TailscaleClient.swift:90` handles credentials and diagnostics.
- `glas.sh/SFTPBrowserView.swift:617` owns downloads.
- `glas.sh/AIAssistant.swift:329` renders generated command actions.

Reuse these integration points and the existing `SessionRecorder`, `SFTPBrowserView`, and AI suggestion models. Do not add parallel production paths.

## Work packages

### 03.1 Recording policy model

- Default every recording to output-only.
- Treat input capture as a separate, explicit option with disclosure that remote password prompts cannot be reliably inferred.
- Store consent with the individual recording or session, not as an ambiguous global toggle.
- Display persistent indicators for recording and the stronger input-capture state.
- Ensure auto-record uses the same policy rather than silently enabling input capture.

### 03.2 Recording lifecycle and metadata

- Start only after policy resolution.
- Capture live columns/rows and update resize metadata as supported by asciicast.
- Finalize on disconnect, session close, clean remote exit, connection failure, app termination path, and recording stop.
- Recover or clearly mark incomplete recordings after interruption.
- Keep timestamps monotonic and preserve output order.

### 03.3 Protected storage and user controls

- Select `FileProtectionType.complete` or document why `completeUnlessOpen` is required for active recording.
- Define the storage location and exclude unintended cloud backup if appropriate.
- Add retention policy, listing, export, delete, and delete-all controls.
- Use safe filenames and atomic finalization.
- Never place unredacted recording contents in diagnostics or AI prompts without explicit user action.

### 03.4 Tailscale request and log hardening

- Remove API-key prefixes and raw OAuth/API response bodies from logs.
- Form-encode OAuth values using correct URL encoding.
- Log bounded status, byte count, request category, and redacted structured errors.
- Cap decode previews and include only data proven non-sensitive; default to no body.
- Audit production logging across terminal commands, credentials, URLs, and service responses.

### 03.5 SFTP destination safety and streaming

- Reject empty, dot, dot-dot, absolute, separator-containing, or containment-escaping remote names.
- Resolve and verify standardized destination containment.
- Require an explicit collision policy: cancel, rename, or confirmed overwrite.
- Stream chunks into a protected temporary file rather than buffering the whole file.
- Support cancellation and define resumability based on remote capability.
- Verify expected size and an available hash when practical.
- Atomically rename only after successful completion.
- Clean partial files predictably and keep security-scoped resource access balanced.

### 03.6 Deterministic generated-command gate

- Always place generated commands in an editable composer.
- Parse/flag shell control operators, pipelines, redirection, substitution, destructive utilities, privilege escalation, credential operations, network exfiltration patterns, and unclassified syntax.
- Treat the model's risk label as explanatory metadata only.
- Require deterministic confirmation for destructive and unclassified commands.
- Preserve exact command visibility; never execute hidden suffixes or transformed text.
- Provide copy/edit/cancel paths and record no terminal command content in production logs.

## Acceptance criteria

- New recordings contain output only unless input consent was explicitly granted.
- Recording/input-capture state is continuously visible.
- All terminal/session exit paths finalize recording safely.
- Files have verified protection attributes and intentional retention/export/delete behavior.
- Tailscale production logs contain no credential fragments or unbounded response bodies.
- SFTP cannot escape the chosen folder, silently overwrite, or expose a partial final file.
- Generated commands cannot execute directly from an untrusted model risk label.

## Automated tests

- Output-only versus input-enabled asciicast event streams.
- Consent persistence and auto-record policy.
- Disconnect/failure/finalization matrix and live dimension events.
- File-protection and retention/delete behavior.
- Log-capture tests proving secret/body redaction and bounded diagnostics.
- SFTP filename corpus including traversal, separators, Unicode normalization, collisions, cancellation, partial failure, size mismatch, and atomic completion.
- Command-classifier corpus covering operators, substitutions, destructive utilities, sudo, credential commands, and unknown syntax.

## Manual/device verification

- Enter a password at a remote prompt and confirm output-only recording excludes it.
- Inspect recording protection attributes on device.
- Cancel large SFTP downloads and verify cleanup.
- Review AI command flows with VoiceOver/eye-and-hand interaction and hardware keyboard.

## Exit evidence

- Recording privacy design approved.
- Security review of logs, files, and generated commands.
- Green regression corpus and device evidence.
