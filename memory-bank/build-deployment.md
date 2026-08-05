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
