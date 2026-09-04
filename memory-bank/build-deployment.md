# Build & Deployment

## Local Build
- Open `glas.sh.xcodeproj` from the repository root.
- Shared application scheme: `glas.sh`.
- The single native application target supports Apple Silicon macOS, iPhone/iPad, and Vision Pro. Catalyst is disabled. The former `glas.sh Mac` target and scheme were retired by One Base.
- Release-build examples:
  - `xcodebuild -project glas.sh.xcodeproj -scheme glas.sh -configuration Release -destination 'generic/platform=visionOS' build`
  - `xcodebuild -project glas.sh.xcodeproj -scheme glas.sh -configuration Release -destination 'generic/platform=iOS' build`
  - `xcodebuild -project glas.sh.xcodeproj -scheme glas.sh -configuration Release -destination 'platform=macOS,arch=arm64' build`
- Use an explicit simulator/device destination and retain `.xcresult` output for release evidence.
- Builds with `CODE_SIGNING_ALLOWED=NO` are valid for noninteractive compilation
  and test isolation only. Keychain, app-group, entitlement, and credential-flow
  acceptance must use a normally signed build with bundle identifier `sh.glas.app`.
- Code-signing identity and trust checks are Keychain-backed and must run outside
  the workspace sandbox. A restricted lookup failure is not evidence that an
  identity is missing or invalid. Never replace a normally signed credential-flow
  review build with an ad-hoc signature that removes its Keychain or app-group
  entitlements; create a fresh derived-data build with normal signing instead.

## Supported Build Matrix
- Deployment floor: macOS 26.0, iOS/iPadOS 26.0, and visionOS 26.0.
- Application architectures: arm64 only. Intel and Mac Catalyst are outside scope.
- Current project settings: Swift 6.0, marketing version 1.0, build 2, application bundle identifier `sh.glas.app`.
- Shared schemes: `glas.sh` for the app and `glasWidgets` for the platform-filtered widget extension.
- Installed-SDK compilation is not runtime proof. Record the Xcode build, SDK, destination runtime, test count, and physical-device evidence separately.

## Packaging Notes
- Bundle identifier currently uses `sh.glas.app` namespace.
- The widget remains a separate extension and is embedded only on supported platforms.
- App Store metadata and distribution details should be maintained outside source code secrets.
