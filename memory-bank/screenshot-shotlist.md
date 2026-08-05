# App Store Screenshot Shot-List — v1.0.0

## Spec recap (visionOS)

- **Resolution**: 3840 × 2160 (landscape preferred, native visionOS canvas) OR 2160 × 3840 (portrait)
- **Quantity**: minimum 3, maximum 10 per device family. Recommended: **6–8**.
- **Format**: PNG or JPEG, RGB color space, no transparency
- **Optional captions**: overlay text added in image (Apple does not provide caption fields per-screenshot on visionOS)

## Capture strategy

Two-tier capture:

1. **Simulator captures (5 of 8)** — `xcrun simctl io booted screenshot path.png` after navigating to the target UI state. Use for app-content shots where 2D rendering is faithful.
2. **Vision Pro captures (3 of 8)** — for spatial hero shots where window depth, passthrough blend, and ornament floating make the marketing point. Capture via Vision Pro's built-in spatial capture or AirPlay mirroring.

Prepare a capture-only QA profile that is never included in the production bundle:
- 2–3 reviewer-owned or isolated test servers with non-sensitive friendly names
- Real terminal output captured by running commands against a local or dedicated test SSH host
- One SSH key showing migration badge state
- One favorited server

## The 8 shots (priority order — first shot is the App Store thumbnail)

### Shot 1 — HERO: Multi-window terminal scene
- **Source**: Vision Pro on-device
- **Frame**: Two terminal windows side-by-side at slight angles, one with a colorful TUI (htop, k9s, or `lsd` output), one with a build log streaming
- **Ornament visible**: the current system-owned status/tools ornament for that independent terminal window
- **Caption text overlay**: "Terminals that float where you want them"
- **Why this shot**: Sells the headline value — visionOS-native multi-window SSH in a single image

### Shot 2 — On-device AI assistant
- **Source**: Simulator
- **Frame**: Terminal window showing a recently-failed command (e.g., `tar` with unclear error). AI Assistant sheet open over it with the suggestion rendered. Sparkles icon highlighted.
- **Caption text overlay**: "Private AI. On your device. Not in someone's cloud."
- **Why**: Differentiator vs every competitor — none has on-device AI

### Shot 3 — Tailscale device list
- **Source**: Simulator
- **Frame**: configured Network scope in Connections, showing an isolated capture tailnet with non-sensitive hostnames and real online state. Do not fabricate a production tailnet or ship capture fixtures.
- **Caption text overlay**: "Your whole tailnet, one tap away"
- **Why**: Big-name integration, unique feature

### Shot 4 — SFTP browser
- **Source**: Simulator
- **Frame**: SFTP window showing a remote directory (`/var/www/` or `/home/user/Projects/`) with mixed file types, batch-select mode active (3 files highlighted), selection bar at top showing download/delete actions
- **Caption text overlay**: "Browse, transfer, manage — without leaving your space"
- **Why**: Shows non-terminal capability; SFTP is a major use case

### Shot 5 — Spatial widget on home view
- **Source**: Vision Pro on-device
- **Frame**: Home View visible with the glas.sh widget pinned showing 2–3 servers in medium size, glass styling consistent with rest of visionOS
- **Caption text overlay**: "Connect to anything from anywhere in visionOS"
- **Why**: Spatial-computing-native feature; visually distinctive

### Shot 6 — Settings: SSH keys with badges
- **Source**: Simulator
- **Frame**: Settings → SSH Keys panel showing 3–4 keys with their algorithm badges (ED25519, RSA, P-256-SE), storage kind labels (Imported / Secure Enclave), and migration status. One row expanded showing actions menu.
- **Caption text overlay**: "Real Secure Enclave protection. Real key management."
- **Why**: Demonstrates security depth; appeals to the developer/sysadmin audience

### Shot 7 — Privacy-preserving session recording
- **Source**: Simulator
- **Frame**: Terminal with the recording controls visible; show the explicit output-only/input-capture choice and the persistent red input-recording disclosure state
- **Caption text overlay**: "Record the session. Choose exactly what is captured."
- **Why**: Demonstrates a useful workflow without hiding the credential-capture risk

### Shot 8 — Independent transparency and blur (HERO #2)
- **Source**: Vision Pro on-device
- **Frame**: Two terminal windows in passthrough: one completely transparent and one softly blurred, with the independent Opacity and Blur sliders visible
- **Caption text overlay**: "Your terminal. Your space. Your glass."
- **Why**: This is the literal product purpose and the clearest Vision Pro differentiator

## Caption typography

Keep all captions:
- Same typeface as marketing site (Sora, weight 700)
- Same accent colors (cyan `#5ed9d3` or white `#ecf3ff`)
- Bottom 1/4 of the frame, left-aligned, no more than 8 words
- Drop shadow for legibility against varied backgrounds

Do NOT use:
- Promotional badges Apple disallows ("New!", "Award winner", store-rank claims)
- "Apple Vision Pro" in caption text (Apple guidelines restrict device-name use in marketing imagery)
- Pricing claims ("Free!" — pricing is shown on the App Store automatically)

## Capture-day checklist

- [ ] Capture both the OS 26 compatibility runtime and exact-current OS 27 presentation where App Store Connect accepts them
- [ ] Seed only the capture QA environment: isolated servers, non-production SSH keys, one favorite, and clearly non-sensitive tags
- [ ] Run a long-running ssh session to a real or local server to get realistic terminal content
- [ ] For each shot: navigate → adjust window scale to fill canvas → `xcrun simctl io booted screenshot ~/Desktop/glas-sh-shot-N.png`
- [ ] On Vision Pro: AirPlay to Mac → use native screen recorder → extract frames OR use device spatial screenshot
- [ ] Open each PNG in any image editor → overlay caption text (Sora 700) → export at 3840×2160 PNG → name `01_hero.png` through `08_transparency.png`
- [ ] Verify dimensions: `sips -g pixelWidth -g pixelHeight ~/Desktop/01_hero.png`
- [ ] Verify color space is RGB (not CMYK or P3-only): `sips -g space ~/Desktop/01_hero.png`
- [ ] Verify the terminal scene opens at a readable physical size and the native session sidebar can be dismissed before capturing hero images

## After upload

- Order in App Store Connect: 01_hero first (it's the listing thumbnail)
- A/B test post-launch: swap shot 1 with shot 8 after 30 days, watch conversion rate in App Store Connect Analytics
