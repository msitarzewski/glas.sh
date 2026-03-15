# 260315 visionOS 26 UX Compliance & Focus Latency Fix

## Objective
Bring all views into compliance with visionOS 26 Liquid Glass design language, accessibility requirements, and scene management APIs. Fix 4-5 second input focus latency in form text fields and terminal windows.

## Outcome
- ✅ Tests: 25 passing (no regressions)
- ✅ Build: Clean on visionOS 26 SDK
- ✅ Review: Approved

## Files Modified
- `TerminalWindowView.swift` — Ornament-based status bar, `.sheet()` modal, 60pt button targets, accessibility labels, search field auto-focus, removed redundant delayed focus call
- `glas_shApp.swift` — `.defaultLaunchBehavior(.presented)`, `.restorationBehavior(.disabled)` on terminal/html-preview windows, openWindow passthrough to WindowRecoveryManager
- `ConnectionManagerView.swift` — Removed ~130 lines dead code (ServerCard + ConnectionTicker), tag filter chip sizing + accessibility
- `ServerFormViews.swift` — Color tag selectors to 44pt visual/60pt hit, tag chip delete to 44pt min, `@FocusState` on AddServerView + EditServerView
- `SettingsView.swift` — SSH key actions into context Menu, theme preview circles to 32pt, `@FocusState` on AddSSHKeyView/GenerateSecureEnclaveSSHKeyView/RenameSSHKeyView
- `HTMLPreviewWindow.swift` — `.glassBackgroundEffect()`, removed stub back/forward/tools buttons, removed `print()` statements
- `WindowRecoveryManager.swift` — Replaced UIKit `requestSceneSessionActivation` with SwiftUI `OpenWindowAction`
- `PortForwardingManagerView.swift` — `.regularMaterial`, accessibility labels on forward rows
- `SwiftTermHostView.swift` — Focus retry reduced from 4×120ms to 3×50ms

## Issues Resolved (21 + focus fix)

### P0 Critical (5)
1. FooterGlassIconButton 24pt → 60pt hit area
2. Tag chip delete buttons → 44pt min frame + contentShape
3. Color tag selectors → 44pt visual + 60pt hit area
4. VoiceOver labels added to all interactive elements
5. `.restorationBehavior(.disabled)` on terminal/html-preview WindowGroups

### P1 Important (8)
1. Custom ZStack modal → `.sheet()`
2. `.ultraThinMaterial` → `.glassBackgroundEffect()` / `.regularMaterial`
3. Status bar → `.ornament(attachmentAnchor: .scene(.bottom))`
4. `.defaultLaunchBehavior(.presented)` on Connections window
5. Active tag filter chips sizing increased
6. SSH key Rename/Delete → context Menu
7. White border overlays removed (system handles via Liquid Glass)
8. `.hoverEffect(.lift)` removed from large views, `.highlight` for small controls

### P2 Polish (8)
1. ServerCard + ConnectionTicker dead code removed
2. Unified Liquid Glass strategy
3. Theme color previews 24pt → 32pt
4. WindowRecoveryManager simplified to SwiftUI-native
5. Status circle accessibility via `.accessibilityElement(children: .combine)`
6. HTMLPreviewWindow stub buttons removed
7. Search overlay close button → 44pt min
8. `print()` statements removed

### Focus Latency Fix
- Added `@FocusState` to 7 form views with auto-focus on first field
- Reduced terminal focus retry from 4×120ms to 3×50ms (480ms → 150ms worst case)
- Removed redundant 150ms-delayed second focus() call in terminal .onAppear

## Patterns Applied
- `systemPatterns.md#visionOS Form Pattern` — extended with @FocusState guidance
- `systemPatterns.md#UI Structure` — updated for Liquid Glass / ornament patterns

## Architectural Decisions
- Decision: Use `.ornament()` for terminal status bar instead of inline VStack
- Rationale: Reclaims terminal viewport space; follows visionOS convention
- Decision: Use system `.sheet()` instead of custom modal overlay
- Rationale: Gets Liquid Glass styling, gesture dismissal, accessibility for free
- Decision: Reduce focus retry aggressiveness (3×50ms vs 4×120ms)
- Rationale: becomeFirstResponder() either works in one layout cycle or needs minimal retry; 120ms was unnecessarily conservative
