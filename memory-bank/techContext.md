# Tech Context

## Stack
- Swift + SwiftUI (visionOS)
- Xcode project: `/Users/michael/Developer/glas.sh/glas.sh.xcodeproj`
- SSH layer: Citadel + vendored swift-nio-ssh
- Terminal layer: SwiftTerm
- Security/runtime frameworks in active use:
  - `Security` (Keychain, Secure Enclave key APIs)
  - `LocalAuthentication` (connection-time user presence prompt for secure enclave-backed key use)

## Build Target
- Main scheme: `glas.sh`
- visionOS simulator builds used for iterative validation.
