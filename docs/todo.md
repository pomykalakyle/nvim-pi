# TODO

## Tie Neovim refreshes to actual file mutations

Status: open
Created: 2026-08-09

The diff-preview extension currently refreshes Neovim from a broad Pi `tool_result` handler after `edit` and `write` calls. The handler has to infer from result metadata whether the tool changed the file on disk.

Manual proposals use the same tools but may leave the file unchanged, accept a change through a separate review path, or reject it. As a result, the refresh handler needs proposal-specific exceptions and can issue duplicate or unnecessary refreshes when those cases are not distinguished.

Revisit which part of the extension owns buffer refreshes. A refresh should happen once after a successful on-disk mutation and should not happen for pending or rejected proposals. Preserve immediate Vibing Mode refreshes, accepted-proposal refreshes, error reporting, and loaded-buffer behavior.

## Keep file focusing available during proposal review

Status: open
Created: 2026-08-09

Calling `focus_file` while the proposal review interface is active fails with `No normal editor window is available beside Pi`. This prevents the user from focusing relevant source while evaluating a pending change.

File focusing should work during proposal review without dismissing or resolving the proposal. Preserve the active review, its pending state, and the user's current editor layout.

## Wrap proposal preview text by default

Status: fixed
Created: 2026-08-09
Resolved: 2026-08-10

Proposal previews do not wrap long lines by default, so reviewing them can require horizontal scrolling.

Enable text wrapping by default within proposal previews. Keep the setting scoped to preview windows and preserve the user's existing window options after the preview closes.

## Preserve the Neo-tree location when focusing files

Status: open
Created: 2026-08-09

Calling `focus_file` can change Neo-tree's displayed location to the focused file's parent directory. This was observed after focusing `pi-extensions/neovim-diff-preview/index.ts`, though it may depend on the current buffer or editor layout.

Focusing a file should preserve Neo-tree's existing location and navigation state.

## Improve autocomplete quality

Status: open
Created: 2026-08-10

The current Pi autocomplete behavior needs further improvement. Revisit its suggestion quality and interaction flow before treating the feature as complete.
