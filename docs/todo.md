# TODO

## Avoid repeated approval prompts for subagent writes

Status: open
Created: 2026-08-11

Subagents frequently attempt to use `write`, and each attempt requires manual approval. This creates repeated interruptions whenever subagents run.

Investigate why subagent writes do not use the expected approval or authorization flow, and fix the repeated approval requirement without assuming that subagents should be read-only.

## Give subagents access to Neovim-backed file tools

Status: open
Created: 2026-08-11

Forked subagents can read the repository but cannot use the native `edit` and `write` tools because those tools resolve the requesting Pi workspace through the originating Neovim session. The fork has conversation context and the same working directory, but no matching Neovim workspace registration.

Allow an authorized subagent to route file operations through the originating workspace without creating a worktree or losing proposal and Vibing Mode behavior. Keep workspace ownership explicit so edits cannot be delivered to an unrelated tab or Pi process.

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

## Keep tool commands available during proposal review

Status: open
Created: 2026-08-10

While an edit or write proposal is pending, the extension blocks Bash and instructs the agent not to run tests, commands, or unrelated tools. This prevents investigation and other non-edit work needed to evaluate the proposal.

Proposal review should restrict additional file mutations without blocking unrelated tool calls.

## Improve fenced code block readability in Pi messages

Status: open
Created: 2026-08-10

Pi intentionally displays literal fence delimiters around code blocks and does not give them a distinct background or frame. With the current theme and sparse syntax highlighting, code blocks are difficult to distinguish from surrounding text.

Revisit this when Pi exposes a stable rendering hook or a sufficiently mature package becomes available.

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

## Reveal diff files in Neo-tree reliably

Status: open
Created: 2026-08-10

Opening a diff does not always reveal its file in Neo-tree. This leaves Neo-tree showing a different location or selection from the file being reviewed.

## Improve autocomplete quality

Status: open
Created: 2026-08-10

The current Pi autocomplete behavior needs further improvement. Revisit its suggestion quality and interaction flow before treating the feature as complete.

## Improve workspace presentation

Status: open
Created: 2026-08-10

Pi workspaces span editor buffers, layouts, Pi sessions, and worktrees, but their identity is currently shown inside the Pi pane. Revisit how all workspaces and the active worktree should be represented without losing per-workspace buffer navigation.

## Avoid entering insert mode when opening a worktree

Status: open
Created: 2026-08-10

Opening a new worktree leaves Neovim in insert mode with focus in the Pi text input. This is unexpected and makes the new worktree immediately capture keyboard input.

A newly opened worktree should start in normal mode rather than entering the Pi text input.

## Open Pi links without using the mouse

Status: open
Created: 2026-08-10

Following a link shown in Pi currently requires clicking it. Moving from the keyboard to the mouse interrupts the workflow.

Links shown in Pi should be accessible through a keyboard-driven interaction.

## Keep focused files in the tab list

Status: open
Created: 2026-08-14

Calling `focus_file` displays the requested file and range, but the buffer does not remain in the tab list at the top of Neovim. After focus changes, the file is harder to return to through normal buffer navigation.
