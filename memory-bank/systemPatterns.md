# System Patterns

## Terminal Architecture
- SSH transport via Citadel and `withPTY` interactive sessions.
- Terminal rendering via SwiftTerm host view.
- Resize loop: UI geometry -> PTY rows/cols -> remote window change.

## UI Structure
- Multi-window app model with terminal-focused windows.
- Ornaments for host, tools rail, and status details.

## Repo Layout Pattern
- Runtime app code in `/Users/michael/Developer/glas.sh/glas.sh`.
- Reusable/shared package code in `/Users/michael/Developer/glas.sh/Packages`.
