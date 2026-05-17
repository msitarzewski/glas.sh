# App Store Listing Copy — v1.0.0

All character counts are App Store Connect limits. Trim before paste if a brand decision changes a word.

## App Name (30 chars max)

**Primary choice**: `glas.sh — SSH for Vision Pro` (28)
**Alternates**:
- `glas.sh: Spatial SSH Terminal` (29)
- `glas.sh` (7) — minimalist; relies on subtitle to convey what it is. Risky for ASO but very on-brand.

## Subtitle (30 chars max)

**Primary**: `Native visionOS SSH terminal` (28)
**Alternates**:
- `Spatial SSH for Vision Pro` (26)
- `SSH in your space, on device` (28)
- `Terminal. Spatial. On‑device AI.` (32 — over, trim)

## Promotional text (170 chars max — updateable without resubmission)

**Primary**:
> Float terminals in your space. On‑device AI. Tailscale auto‑discovery. Session recording. SharePlay. SFTP. Multi‑hop jump hosts. No cloud. No subscriptions.

(159 chars)

Use this slot for time-sensitive callouts after launch (release notes hooks, sale announcements, new feature beta).

## Description (≤ 4000 chars)

```
glas.sh is the SSH terminal Apple Vision Pro deserves — built from scratch for spatial computing, not ported from iPad.

Float terminal windows anywhere in your space. Talk to your servers with an AI assistant that runs entirely on your device. Browse files spatially. Watch your session play back. Share a terminal in FaceTime. Connect to your whole Tailscale network with one tap.

— BUILT FOR VISIONOS —

• Multi-window terminals with glass-first chrome and Liquid Glass materials
• Eye-and-hand interaction, 60pt minimum hit targets, full VoiceOver support
• Spatial widgets — pin server status to your home view, tap to connect
• Custom URL scheme (glassh://) for deep links from widgets and shortcuts
• Immersive focus mode for distraction-free work

— ON-DEVICE AI —

• Foundation Models powered command assistant — fully on-device, fully private
• Error explainer — paste a confusing stderr, get a plain-language breakdown
• No prompts, no responses, and no terminal content ever leave your device

— REAL SSH —

• Citadel + swift-nio-ssh under the hood
• Password, public key, and Secure Enclave–protected key authentication
• ED25519, RSA (with SHA-2 signatures), ECDSA P-256
• Multi-hop jump hosts (ProxyJump)
• Local (-L), remote (-R), and dynamic SOCKS (-D) port forwarding
• Full SFTP browser with batch upload/download, file info, hidden files, search

— PRIVACY THAT'S TECHNICAL, NOT MARKETING —

• Credentials stored in Keychain with kSecAttrAccessibleWhenUnlockedThisDeviceOnly
• Optional Secure Enclave–wrapped SSH keys for biometric-gated authentication
• Zero analytics, zero telemetry, zero third-party SDKs
• Open source under the MIT license — audit the claims yourself

— POWER FEATURES —

• Tailscale device discovery — your tailnet shows up as a connection source
• Session recording with on-device AI summary
• SharePlay terminal viewer — let a teammate watch your session read-only
• Layout presets — save and restore multi-window arrangements
• Quick connect — type user@host:port in the search bar, hit enter
• Favorites, tags, and full-text server search
• Auto-reconnect with exponential backoff for flaky links
• True per-window keyboard focus, even after visionOS idle

— DESIGNED IN PUBLIC —

glas.sh is open source, MIT-licensed, and actively developed in the open. Issues, feature requests, and pull requests welcome at github.com/msitarzewski/glas.sh

Made by an indie developer. No VC. No tracking. Just a terminal that respects your spatial computer and your privacy.
```

(~2480 chars — leaves room to grow without rewriting)

## Keywords (≤ 100 chars total, comma-separated, NO spaces after commas)

**Primary set** (96 chars):
```
ssh,terminal,sftp,vision pro,visionos,server,tailscale,sysadmin,devops,linux,unix,shell,console,ai
```

**Notes**:
- Don't repeat words from the app name or subtitle — Apple already indexes those.
- "vision pro" is a single keyword (counts as 10 chars including space — confirm if Apple allows or strips).
- Avoid trademarked competitor names (Termius, Prompt, La Terminal) — Apple may reject.
- Tag editing post-launch requires a new version submission.

## What's New (for v1.0.0)

```
Initial release.

The terminal that Apple Vision Pro deserves — native, spatial, private.

Float terminals in your space, get on-device AI assistance, connect to your full Tailscale network, browse files spatially, record sessions, and share read-only views over SharePlay. All free, all open source, all yours.
```

(~270 chars)

## Support URL

`https://github.com/msitarzewski/glas.sh/issues`

## Marketing URL

`https://msitarzewski.github.io/glas.sh/`

## Privacy Policy URL

`https://msitarzewski.github.io/glas.sh/privacy.html`

## Category

- **Primary**: Developer Tools
- **Secondary** (optional): Productivity

(Apple may surface differently in the visionOS App Store than iOS — confirm at submission time.)

## Age Rating

Likely 4+. The questionnaire will ask about violence, profanity, drug references, gambling, user-generated content, web browsing, etc. — all "None" expected. The only nuance:

- **Unrestricted web access**: No (we don't browse the web)
- **User-generated content visible to others**: No (the SharePlay viewer is private to a FaceTime call, not public)

## Export Compliance

- Uses encryption: **Yes**
- Qualifies for exemption (Category 5, Part 2): **Yes** — uses standard SSH/TLS only
- Recommendation: Add `ITSAppUsesNonExemptEncryption = false` to Info.plist AFTER first submission confirms the exemption, to avoid the question on subsequent builds.

## Review Notes (text given to Apple's reviewer)

```
Thank you for reviewing glas.sh.

This is an SSH client. To exercise it during review, you can connect to any SSH server you have access to. If a demo server would help, please request one — we can provide read-only credentials to a sandbox host on request.

Key features to verify:
1. Add a server (Connections → + → enter host/user/password)
2. Connect — terminal should appear in its own spatial window
3. Type 'ls' or similar; output renders, keyboard input works
4. Open the SFTP browser from the bottom ornament (folder icon)
5. Open the AI Assistant (sparkles icon) — runs fully on-device

Privacy posture: zero data collection, no analytics, no third-party SDKs. Privacy manifest declares only NSPrivacyAccessedAPICategoryUserDefaults.

Repository (open source): https://github.com/msitarzewski/glas.sh
Privacy policy: https://msitarzewski.github.io/glas.sh/privacy.html
```
