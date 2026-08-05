# Project Brief

## Vision
`glas.sh` delivers a premium Apple Vision Pro terminal experience with genuinely transparent terminal canvases, adjustable tint/opacity/blur, and real interactive PTY behavior. The same authoritative application core also provides native Mac, iPad, and iPhone experiences without weakening the Vision Pro product invariant.

Across the Glass family, connections must feel *Magic / First Class*: define an
SSH connection once, find it in every supported Glass app on the user's Apple
devices, and connect with the least intervention compatible with honest security.
The apps may specialize in terminals or databases, but the user experiences one
coherent Apple-device connection library rather than separate product silos.

## Primary Goals
- Reliable local and SSH terminal sessions across Apple platforms, with Vision Pro as the reference experience.
- Correct TTY semantics for interactive shell workflows and TUI tools.
- Native platform composition: spatial windows and ornaments on visionOS, native windows/sidebars/toolbars on macOS, adaptive windowing on iPadOS, and compact navigation on iOS.
- One application target, one application identity, and shared credentials/settings/session authorities across supported platforms.
- Preserve true 100% terminal transparency and independent opacity/blur controls.
- Make reusable SSH identity a Glass-family capability: neutral endpoint metadata,
  app-specific behavior, credential availability, and host trust remain distinct
  even when the experience presents them as one connection.

## Scope
- Repository: `/Users/michael/Software/glass/glas.sh`
- App source: `/Users/michael/Software/glass/glas.sh/glas.sh`
- Platform-specific native boundaries: `/Users/michael/Software/glass/glas.sh/Platforms`
- Shared package code: `/Users/michael/Software/glass/glas.sh/Packages`
- Supported application platforms: Apple Silicon macOS 26+, iOS/iPadOS 26+, and visionOS 26+.
