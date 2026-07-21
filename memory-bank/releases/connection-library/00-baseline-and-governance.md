# Phase 00 — Baseline and Governance

## Objective

Protect the approved terminal/workgroup checkpoint and establish the Connection Library release boundaries before application changes begin.

## Status

`Complete`

## Completed evidence

- Commit `2050a358` preserved the outstanding work on `agent/macos-27-terminal`.
- The commit was replayed without content change as `bba2ba6d` onto the already-merged equivalent base; both commits have tree `d3d92da9cbdccdabc1f17086832f98b3a55a8e54`.
- PR [#28](https://github.com/msitarzewski/glas.sh/pull/28) squash-merged as `f3f00c3b`.
- Fresh branch `agent/connection-library` begins at the merge.
- The existing release format at `memory-bank/releases/codex-completions/README.md` is reused.

## Governance

- Extend existing domain and service types; do not rewrite them.
- Do not add persisted models for concepts already represented by tags, layout presets, workgroups, or saved servers.
- Refactor `glas.sh/ConnectionManagerView.swift` incrementally and delete replaced branches in the same phase.
- Keep the terminal appearance product invariant under regression coverage throughout the release.
- Document any new file with a reuse analysis before creation.

## Exit gate

Historical checkpoint, architecture map, phase plan, cleanup policy, and acceptance criteria are recorded and indexed.
