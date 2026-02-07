# Testing Patterns

## Primary Validation
- Xcode build for visionOS target after functional changes.
- Manual terminal smoke tests:
  - SSH connect/disconnect
  - Inline shell input
  - PTY resize behavior (rows/cols)
  - Common TUIs (`top`, `htop`) and ANSI color rendering

## Regression Focus
- Input/focus behavior when switching windows.
- Ornament interactions and viewport clipping/padding behavior.
