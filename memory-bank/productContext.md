# Product Context

## Users
- Developers and operators who manage local and remote systems from Vision Pro, Mac, iPad, and iPhone.
- Agentic developers who keep many concurrent projects, windows, tabs, workgroups, and long-running remote sessions spatially organized.

## Value Proposition
- A premium Vision Pro terminal with genuinely transparent terminal canvases and independently adjustable tint, opacity, and blur.
- Real PTY/SSH behavior, ANSI color, interactive TUI support, tabs, workgroups, and multiwindow workflows rather than a command launcher.
- One shared connection library, credential/trust authority, appearance model, and session model across native Apple platform shells.
- Apple-native presentation and controls wherever the platform provides a durable system solution.

## Magic / First Class Experience

- The user-facing mental model is **My Connections**: define a connection once,
  find it in glas.sh and glassdb across supported Apple devices, and use it for
  the product's native job without rebuilding the SSH setup.
- The canonical flow is intentionally simple: create an SSH connection in glas.sh
  on iPhone, open glassdb on Vision Pro, select that same connection as the SSH
  tunnel for a database, satisfy only an honest local security action if one is
  required, and connect.
- Users should not need to understand CloudKit containers, Keychain access
  groups, schema packages, migrations, or secret-store internals. Onboarding and
  Settings explain outcomes in user language: available everywhere, still
  syncing, sign in to iCloud, set up this key, or review a changed fingerprint.
- The experience does not require a proprietary Glass account. Apple iCloud and
  Keychain provide the account and protected platform services, with explicit
  consent for eligible credential mobility.
- Security remains truthful. A device-bound Secure Enclave identity can appear
  everywhere as a known connection, but another device asks the user to enroll a
  local key rather than silently substituting weaker authentication.

## Distribution Direction
- Public open source repository with optional App Store distribution.
- App Store submission remains gated by the release checklist; repository availability does not imply distribution readiness.
