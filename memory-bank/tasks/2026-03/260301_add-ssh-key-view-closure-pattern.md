# Refactor AddSSHKeyView to onSave Closure Pattern

**Status**: Planned
**Priority**: Low (next time AddSSHKeyView is touched)
**Origin**: glassdb connection form alignment work (2026-03-01)

---

## Problem

glas.sh's `AddSSHKeyView` (`SettingsView.swift:835`) reaches into `@Environment(SettingsManager.self)` directly to call `settingsManager.addSSHKey()` on save. This couples the view to a specific concrete manager type.

glassdb's `AddSSHKeyView` (`SettingsView.swift:181`) uses an `onSave` closure instead:

```swift
struct AddSSHKeyView: View {
    let onSave: (String, String, String?, SSHKeyAlgorithmKind) throws -> Void
    // ...
}
```

The closure pattern is the standard Apple SwiftUI composition approach — the view doesn't know or care about the data layer, it just reports what happened. This is how `DatePicker`, `PhotosPicker`, and other system views work.

## Why This Matters

1. **Reusability** — The view can be used in any context (Settings, connection form, future onboarding) without needing `SettingsManager` in the environment
2. **Testability** — Previews and tests can pass a closure without wiring up a full manager
3. **Consistency** — glassdb already uses the closure pattern; glas.sh should match so the two codebases stay aligned
4. **Future extraction** — If `AddSSHKeyView` ever moves to a shared package (GlasSecretStore or a new GlasSSHKeyUI package), it can't depend on an app-specific manager type

## What to Change

### `glas.sh/SettingsView.swift` — AddSSHKeyView

**Before** (current):
```swift
struct AddSSHKeyView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.dismiss) private var dismiss

    // ...saves via settingsManager.addSSHKey(name:privateKey:passphrase:)
}
```

**After** (closure pattern):
```swift
struct AddSSHKeyView: View {
    let onSave: (String, String, String?, SSHKeyAlgorithmKind) throws -> Void

    @Environment(\.dismiss) private var dismiss

    // ...calls try onSave(name, privateKey, passphrase, algorithmKind) on save
}
```

### Algorithm detection

glas.sh currently delegates to `SSHKeyDetection.detectPrivateKeyType(from:)` from Citadel, which does proper binary parsing of OpenSSH key format. glassdb uses a naive PEM header sniffer (`detectAlgorithm(from:)` in `SettingsView.swift:243`).

The Citadel detection is more robust, but it lives in the Citadel package which glassdb doesn't use. Two options:

1. **Move PEM detection into GlasSecretStore** as `SSHKeyAlgorithmKind.detect(fromPEM:)` — simple header sniffing, good enough for UI badging, no Citadel dependency
2. **Keep using Citadel in glas.sh, PEM sniffer in glassdb** — both map to `SSHKeyAlgorithmKind` in the end

Option 1 is cleaner long-term. The `onSave` closure approach means the view does the detection and passes the result, regardless of which detection method the host app prefers.

### Call sites to update

1. `SettingsView.swift` — where `.sheet(isPresented: $showingAddSSHKey)` presents AddSSHKeyView
2. `ServerFormViews.swift:175` — where AddServerView presents AddSSHKeyView as nested sheet
3. `ServerFormViews.swift:402` — where EditServerView presents AddSSHKeyView as nested sheet

All three become:
```swift
.sheet(isPresented: $showingAddSSHKey) {
    AddSSHKeyView { name, privateKey, passphrase, algorithmKind in
        try settingsManager.addSSHKey(
            name: name,
            privateKey: privateKey,
            passphrase: passphrase
        )
    }
}
```

## Scope

- ~30 min change
- No functional behavior change — just moves the `settingsManager.addSSHKey()` call from inside the view to the call site's closure
- Build should be clean after; no new tests needed (existing key import tests still pass)
