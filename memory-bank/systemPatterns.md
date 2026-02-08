# System Patterns

## Terminal Architecture
- SSH transport via Citadel and `withPTY` interactive sessions.
- Terminal rendering via SwiftTerm host view.
- Resize loop: UI geometry -> PTY rows/cols -> remote window change.

## UI Structure
- Multi-window app model with terminal-focused windows.
- Footer-first terminal action model (search/clear/preview/tools) instead of persistent side rails.
- Terminal-local settings modal for session-scoped behavior (`Terminal`, `Overrides`, `Port Forwarding`).
- Composition boundary: keep outer frame/chrome stable while applying tint/translucency at terminal display layer.

## Repo Layout Pattern
- Runtime app code in `/Users/michael/Developer/glas.sh/glas.sh`.
- Reusable/shared package code in `/Users/michael/Developer/glas.sh/Packages`.
