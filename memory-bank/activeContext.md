# Active Context

## Current Focus
- Sprint 2 "Spatial Leap" implemented on `sprint-2` branch — 5 planned features + SFTP enhancements + UX refinements.
- All Sprint 2 code compiles and runs on visionOS 26 simulator. Widget target added to Xcode project via pbxproj.
- Needs testing on device, then PR to main.

## Immediate Priorities
- Test Sprint 2 features end-to-end on visionOS Simulator and real device.
- PR and merge Sprint 2 to main.
- Re-add `WidgetCenter.shared.reloadAllTimelines()` to SessionManager/ServerManager once widget target is fully validated.
- Foundation Models AI features need Xcode 26 beta with FoundationModels framework to compile the `#if canImport(FoundationModels)` code paths.
- Sprint 3 (Tier 3 — Command Center): Tailscale integration, session recording + AI summary, immersive focus environment, notification overlays, SharePlay.
- Follow-up stream:
  - Remote port forwarding (-R) and dynamic/SOCKS (-D)
  - Multi-hop jump host chains
  - True Secure Enclave signing integration
  - visionOS blur: user wants true gaussian blur of passthrough behind terminal, not material frost. No API exists for this currently — revisit if Apple adds one.
