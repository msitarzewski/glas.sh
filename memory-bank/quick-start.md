# Quick Start

## Session Startup Notes
- Repository root: `/Users/michael/Software/glass/glas.sh`.
- Review `README.md` for public scope, then `memory-bank/activeContext.md` and `memory-bank/progress.md` for current engineering status.
- Review `memory-bank/releases/codex-completions/README.md` for the active release ledger. Connection Library and One Base are completed historical release programs with post-release regression notes.
- Open `glas.sh.xcodeproj` and use the shared `glas.sh` scheme for Mac, iPhone, iPad, and Vision Pro. `glas.sh Mac` was retired by One Base.
- For historical implementation evidence, inspect monthly task docs under `memory-bank/tasks`; do not rewrite their contemporaneous results.
- GitHub CLI auth is Keychain-backed. Any authenticated `gh` status, push-adjacent,
  or pull-request operation must run outside the workspace sandbox. A sandbox auth
  failure is not evidence that the user's GitHub session is invalid.
- Use a normally signed app for manual Keychain acceptance. An app built with
  `CODE_SIGNING_ALLOWED=NO` is compile/test evidence only and must not be launched
  to diagnose credential persistence.
