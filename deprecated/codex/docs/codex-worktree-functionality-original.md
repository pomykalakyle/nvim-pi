# Codex Worktree Workflow

## Purpose

This workflow lets the user run Codex conversations in multiple Git worktrees while keeping one primary checkout and one Neovim instance.
Each Codex tab is associated with one checkout.
Neo-tree, repository buffers, and file pickers follow the checkout associated with the active Codex tab.

The primary checkout remains in its normal location under `~/Documents/projects`.
Additional worktrees created through this workflow are stored under `~/.codex/worktrees`.

## Checkout Browsing Context

A browsing context belongs to a checkout rather than to an individual Codex tab.
The primary checkout and every worktree have separate browsing contexts.

Each browsing context includes:

- The Neovim working directory.
- The Neo-tree root and location.
- The repository buffers used while browsing that checkout.
- The root used by file and text pickers.

When the user switches to a Codex tab associated with a different checkout, Neovim switches to that checkout's browsing context.
Neovim restores the checkout's most recently used repository buffer when one is available.
Neo-tree displays the checkout's files.
New file and text searches are scoped to the checkout.

When the user switches between Codex tabs associated with the same checkout, the browsing context stays where it is.
Those tabs share the same buffers, Neo-tree state, and picker root.

## Opening an Existing Worktree

The user can open a worktree picker for the repository containing the current checkout.
The exact command and shortcut for opening the picker will be chosen during implementation.

The picker lists:

- The primary checkout.
- Every existing Git worktree for the same repository.

Each entry clearly identifies its path and checked-out branch or detached state.

When the user selects a checkout that already has a running Codex tab, Neovim focuses that tab.
When the user selects a checkout without a running Codex tab, Neovim opens a new Codex tab rooted in that checkout and starts a new conversation there.
Neovim then activates the selected checkout's browsing context.

The picker is based on Git worktrees rather than saved Codex conversations.

## Handing Off the Current Conversation

The user can request a worktree handoff from the active Codex conversation.
This is the flow used when the current conversation began in the primary checkout but should continue in isolated work.

During a successful handoff:

1. Codex creates a new Git worktree under `~/.codex/worktrees`.
2. The active Codex tab becomes associated with the new worktree.
3. The same Codex conversation resumes in the new worktree with its existing history.
4. Subsequent Codex file operations, edits, tests, and Git commands use the new worktree as their default working root.
5. Neovim activates the new worktree's browsing context.

The Codex terminal may briefly reload as part of changing its working root.
The user does not need to locate or resume the conversation manually.
The handoff must not create a second conversation.

If the handoff cannot complete, the current conversation remains associated with its original checkout.
Neovim also remains in the original browsing context.
The workflow reports the failure without leaving the conversation or editor split between two checkouts.

## Creating Ordinary Codex Tabs

The existing add-tab action continues to create a Codex tab in the currently active checkout.
Creating an ordinary tab does not automatically create a worktree.

The worktree picker and handoff flow are explicit actions.
This keeps the fast path for multiple conversations in one checkout while making worktree isolation available when needed.

## Worktree Storage and Lifetime

Managed worktrees live under:

```text
~/.codex/worktrees/<repository>/<worktree>
```

This keeps additional checkouts out of `~/Documents/projects`.
The primary checkout is never moved into the managed worktree directory.

Worktrees persist until the user removes them through Git or a future cleanup workflow.
The first version does not delete worktrees automatically.

## Out of Scope

The first version does not provide:

- A repository-wide picker for saved Codex conversations.
- Changes to Codex's built-in resume picker or its working-directory filtering.
- Automatic discovery or opening of projects.
- A new worktree for every newly created Codex tab.
- Automatic worktree deletion or retention policies.
- Branch publishing, pull-request creation, merging, or handoff back into the primary checkout.
- Separate browsing contexts for Codex tabs that use the same checkout.

## Expected User Flows

### Continue Parallel Work in an Existing Worktree

1. The user opens the worktree picker.
2. The user selects an existing worktree.
3. Neovim opens or focuses the Codex tab associated with that worktree.
4. Neo-tree, buffers, and file pickers follow the selected worktree.

### Move the Current Conversation into New Isolated Work

1. The user requests a worktree handoff from the active Codex conversation.
2. Codex creates a managed worktree.
3. The active conversation resumes in that worktree.
4. Neovim follows the conversation into the new browsing context.

### Switch Between Parallel Conversations

1. The user switches Codex tabs with the existing tab controls.
2. Neovim compares the checkout associated with the old and new tabs.
3. Neovim switches browsing contexts only when the checkout changes.
4. Returning to a previous worktree restores that worktree's browsing context.
