# Build & Deployment

## Local Build
- Open `glas.sh.xcodeproj` from the repository root.
- Shared iOS/visionOS scheme: `glas.sh`.
- Native Apple Silicon macOS scheme: `glas.sh Mac`.
- Release-build examples:
  - `xcodebuild -project glas.sh.xcodeproj -scheme glas.sh -configuration Release -destination 'generic/platform=visionOS' build`
  - `xcodebuild -project glas.sh.xcodeproj -scheme glas.sh -configuration Release -destination 'generic/platform=iOS' build`
  - `xcodebuild -project glas.sh.xcodeproj -scheme 'glas.sh Mac' -configuration Release -destination 'platform=macOS,arch=arm64' build`
- Use an explicit simulator/device destination and retain `.xcresult` output for release evidence.

## Packaging Notes
- Bundle identifier currently uses `sh.glas.app` namespace.
- App Store metadata and distribution details should be maintained outside source code secrets.
