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

Pre-seed the simulator with:
- 2–3 dummy servers with friendly names (e.g., `homelab.local`, `prod-web-01.example.com`, `pi5-living-room`)
- A canned terminal output history (run `ls -la /etc && uname -a && htop` against any local sshd before capture)
- One SSH key showing migration badge state
- One favorited server

## The 8 shots (priority order — first shot is the App Store thumbnail)

### Shot 1 — HERO: Multi-window terminal scene
- **Source**: Vision Pro on-device
- **Frame**: Two terminal windows side-by-side at slight angles, one with a colorful TUI (htop, k9s, or `lsd` output), one with a build log streaming
- **Ornament visible**: bottom ornament with connection label, status indicator, AI/SFTP icons
- **Caption text overlay**: "Terminals that float where you want them"
- **Why this shot**: Sells the headline value — visionOS-native multi-window SSH in a single image

### Shot 2 — On-device AI assistant
- **Source**: Simulator
- **Frame**: Terminal window showing a recently-failed command (e.g., `tar` with unclear error). AI Assistant sheet open over it with the suggestion rendered. Sparkles icon highlighted.
- **Caption text overlay**: "Private AI. On your device. Not in someone's cloud."
- **Why**: Differentiator vs every competitor — none has on-device AI

### Shot 3 — Tailscale device list
- **Source**: Simulator
- **Frame**: Tailscale tab in Connections view, showing 6–10 devices from a simulated tailnet (hostnames, OS icons, online dots). One device highlighted on hover.
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

- [ ] Boot Simulator: Vision Pro 26 Simulator on macOS host with Retina display
- [ ] Seed the app: dummy servers, sample SSH keys, one favorited server, one tag (`production`)
- [ ] Run a long-running ssh session to a real or local server to get realistic terminal content
- [ ] For each shot: navigate → adjust window scale to fill canvas → `xcrun simctl io booted screenshot ~/Desktop/glas-sh-shot-N.png`
- [ ] On Vision Pro: AirPlay to Mac → use native screen recorder → extract frames OR use device spatial screenshot
- [ ] Open each PNG in any image editor → overlay caption text (Sora 700) → export at 3840×2160 PNG → name `01_hero.png` through `08_transparency.png`
- [ ] Verify dimensions: `sips -g pixelWidth -g pixelHeight ~/Desktop/01_hero.png`
- [ ] Verify color space is RGB (not CMYK or P3-only): `sips -g space ~/Desktop/01_hero.png`

## After upload

- Order in App Store Connect: 01_hero first (it's the listing thumbnail)
- A/B test post-launch: swap shot 1 with shot 8 after 30 days, watch conversion rate in App Store Connect Analytics
