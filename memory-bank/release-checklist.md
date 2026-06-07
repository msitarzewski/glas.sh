# Release Checklist — v1.0.0 App Store Submission

**Target date for upload**: late May 2026 (≥ 1 week buffer before WWDC26)
**Branch to ship from**: `main` (after `sprint-details` → `main` merge)
**Current bundle ID**: `sh.glas.app`
**Current version**: `1.0` (1)

---

## Pre-flight (code-side — mostly done)

- [x] Build clean on Xcode 26.4 / visionOS 26.4 SDK
- [x] All SPM dependencies at latest
- [x] `PrivacyInfo.xcprivacy` in app + widget bundles
- [x] `CURRENT_PROJECT_VERSION` bumped to 2
- [x] Vendored audit fixes preserved
- [ ] `sprint-details` → `main` merged (PR open, reviewed, squash-merged)
- [ ] `git tag v1.0.0` on main after merge
- [ ] One last clean build from main on a fresh DerivedData

## Apple Developer Program

- [ ] Confirm enrollment is active (Team ID `7JQGQ7CRH8`)
- [ ] Confirm `sh.glas.app` App ID exists in Developer Portal with required capabilities:
  - App Groups (`group.sh.glas.shared`)
  - Keychain Sharing (`sh.glas.shared`)
  - Group Activities (SharePlay)
- [ ] App Store Distribution provisioning profile generated (or auto-managed via App Store Connect API key)

## App Store Connect — create the app record

- [ ] New app: visionOS platform, bundle ID `sh.glas.app`, SKU `glas-sh-v1`
- [ ] Primary language: English (U.S.)
- [ ] Pricing: Free (or chosen tier)
- [ ] Availability: All territories (or chosen subset — be mindful of export-compliance for crypto)

## Listing content

Source of truth lives in `memory-bank/app-store-listing.md` — copy directly from there.

- [ ] App name (30 chars)
- [ ] Subtitle (30 chars)
- [ ] Promotional text (170 chars)
- [ ] Description (≤ 4000 chars)
- [ ] Keywords (≤ 100 chars, comma-separated, no spaces)
- [ ] What's New (≤ 4000 chars; for v1.0.0 keep brief)
- [ ] Support URL: `https://github.com/msitarzewski/glas.sh/issues`
- [ ] Marketing URL: `https://msitarzewski.github.io/glas.sh/`
- [ ] **Privacy policy URL: `https://msitarzewski.github.io/glas.sh/privacy.html`**
- [ ] Category — primary: Developer Tools / Utilities. Secondary: optional.
- [ ] Age rating: complete the questionnaire (likely 4+ — terminal app, no objectionable content)

## App Privacy nutrition label

The privacy manifest declares no data collection. Match that in the App Privacy questionnaire:

- [ ] "Data not collected" for all categories
- [ ] No third-party SDKs disclosed (we have none)
- [ ] Reasoning: app contacts only user-specified SSH servers + (optional, user-initiated) `api.tailscale.com`; no analytics, telemetry, or first-party servers

## Screenshots

Source of truth: `memory-bank/screenshot-shotlist.md`.

- [ ] 6–8 screenshots captured at visionOS spec (3840×2160 landscape or 2160×3840 portrait)
- [ ] App Preview video — optional for v1.0.0, skip if time-constrained
- [ ] All shots uploaded to the App Store Connect listing in priority order (hero first)

## Encryption / Export Compliance

The app uses SSH (encrypted) — Apple asks an encryption question on each submission.

- [ ] Answer Yes to "Does your app use encryption?"
- [ ] Answer Yes to "Does your app qualify for any exemptions provided in Category 5, Part 2 of the U.S. Export Administration Regulations?"
  - Exemption: app uses standard SSH/TLS protocols that are pre-approved; no proprietary crypto.
- [ ] Add `ITSAppUsesNonExemptEncryption = false` to `Info.plist` to bypass the question on future builds (do this AFTER first submission confirms the exemption).

## Archive + upload

- [ ] Switch scheme to release configuration
- [ ] Xcode → Product → Archive (signing must succeed; provisioning profile present)
- [ ] Open Organizer when archive completes
- [ ] Validate App — fixes most issues before upload
- [ ] Distribute App → App Store Connect → Upload
- [ ] Wait for "Ready to Submit" email from Apple (processing + ITC.apps.platform.* checks typically 15–60 min)

## TestFlight smoke test

Before submitting for review, install on real Vision Pro via TestFlight:

- [ ] First-run: app launches, Connections window appears
- [ ] Add a server (use a known-good SSH host)
- [ ] Connect: terminal renders, keyboard input works, characters echo
- [ ] Disconnect cleanly
- [ ] Open SFTP browser on a connected session
- [ ] AI Assistant: open sparkles → enter a command request → response renders
- [ ] Bell: trigger `\a` in remote shell → audio + visual flash
- [ ] Spatial widget: add to home view → tap → app opens to that server
- [ ] Force-quit + relaunch → no ghost windows, no crash on cold start
- [ ] Settings → SSH Keys → confirm key list, migration badge, edit/delete flows

## Submit for review

- [ ] In App Store Connect, attach the uploaded build to the v1.0.0 record
- [ ] Add review notes if anything needs explanation (e.g., demo SSH credentials if reviewer needs to test connections — recommended to provide a throwaway test account)
- [ ] Submit for review
- [ ] Monitor email for "In Review" → "Pending Developer Release" or rejection

## Post-approval

- [ ] Manual release (preferred for v1.0.0) → choose release timing
- [ ] Announce on socials, sponsors page, README badge
- [ ] Tag `v1.0.0` on `main` if not already done
- [ ] Open `v1.1.0` milestone with the deferred features (SSH agent forwarding, SFTP drag-and-drop, terminal themes)

## Known risks for review

- **Foundation Models usage**: Apple sometimes asks about AI capabilities. Our usage is fully on-device via the public Foundation Models framework — no review issue expected.
- **SSH protocol**: legitimate developer-tool category, well-precedented (Termius, Prompt, La Terminal all approved).
- **SharePlay**: read-only screen share through Group Activities — standard.
- **Tailscale OAuth**: user-provided credentials; we don't broker auth. No web view, no embedded browser sign-in flow.
- **Spatial widgets**: standard WidgetKit; no special review path.

If rejected, the most common visionOS reasons would be:
1. Screenshots don't match actual app state — fix by recapturing
2. Privacy questionnaire mismatch with manifest — already aligned
3. Demo account credentials missing — add to review notes proactively
