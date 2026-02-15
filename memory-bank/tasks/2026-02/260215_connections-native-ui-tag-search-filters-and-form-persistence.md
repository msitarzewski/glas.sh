# 260215_connections-native-ui-tag-search-filters-and-form-persistence

## Objective
Complete the Connections UX reset to visionOS-native patterns, then close data-entry persistence gaps found during QA (tag save behavior and SSH key selection in edit/add forms).

## Outcome
- ✅ Replaced ornament-heavy/custom table composition with a native `NavigationSplitView` + `List` + `searchable` + toolbar flow.
- ✅ Added left-nav `Tags` mode and moved tag filtering into search-submit behavior.
- ✅ Implemented active tag filter chips under the title area (promoted from search when a tag match is submitted).
- ✅ Removed bottom tag pill strip in favor of contextual active-filter chips.
- ✅ Ensured tag text is committed when pressing `Save` (without requiring Return) in both Add and Edit server forms.
- ✅ Fixed SSH key picker selection persistence reliability with explicit optional UUID tags and key-selection normalization.
- ✅ Cleaned async misuse warnings in SSH connection progress updates.
- ✅ Increased default Connections window size for wider table readability.

## Files Modified
- `/Users/michael/Developer/glas.sh/glas.sh/ConnectionManagerView.swift`
  - Shifted to native split-view/list structure.
  - Added alphabetical left-nav section ordering.
  - Added search-submit tag filter promotion and active filter chips.
  - Added row-tap connect behavior in list row mode.
  - Added server info view sheet action.
- `/Users/michael/Developer/glas.sh/glas.sh/ServerFormViews.swift`
  - Added `commitPendingTag()` on Save for Add/Edit forms.
  - Trim/dedupe behavior for tag entry.
  - Hardened SSH key picker optional tagging and selection normalization.
- `/Users/michael/Developer/glas.sh/glas.sh/Models.swift`
  - Removed unnecessary `await` on synchronous `setConnectionProgress` calls.
- `/Users/michael/Developer/glas.sh/glas.sh/glas_shApp.swift`
  - Increased default Connections window size.
  - Simplified main bootstrap behavior and added HTML preview not-found fallback view.

## Validation
- `xcodebuild -project glas.sh.xcodeproj -scheme glas.sh -configuration Debug -destination "platform=visionOS Simulator,id=AA41662F-0BE4-4689-8FBB-18864AB16F37" build`
- Result observed during this session: `** BUILD SUCCEEDED **` on multiple runs.
- Note: later in-session retries intermittently hit local simulator/DerivedData lock instability (`build.db` locked / CoreSimulator unavailable), unrelated to compile correctness of these code-path changes.

## Notes
- Tag filter promotion currently requires exact case-insensitive match on Return; partial-match promotion can be added in a follow-up.
- SSH key selection now defaults to the first available key only when current selection is invalid in SSH-key auth mode.
