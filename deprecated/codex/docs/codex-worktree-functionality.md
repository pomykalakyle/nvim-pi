# Codex Worktree Functionality

## Purpose

These features allow the user to run Codex conversations in multiple Git worktrees while keeping one main worktree and one Neovim instance.
Each Codex tab is associated with one worktree.
Neo-tree, the visible repository buffer, and file pickers follow the worktree associated with the active Codex tab.

These features never move the main worktree from its existing location.
Repositories stored under `~/Documents/projects` remain there.
Additional linked worktrees created through these features are stored under `~/.codex/worktrees`.

## Following the Active Worktree

Neovim keeps separate browsing state for each worktree: its working directory, Neo-tree state, picker root, and most recently viewed repository buffer (the worktree's browsing context).

When the user switches Codex tabs with the existing tab controls, Neovim compares the worktrees associated with the previously and newly active tabs.
When the worktree changes, Neovim switches to the new worktree's browsing context.
Neovim restores the worktree's most recently viewed repository buffer when one is available.
When the worktree has no remembered repository buffer, Neovim shows an empty editing buffer.
Buffers from other worktrees remain loaded and unchanged.
After the switch, Neovim changes Neo-tree's root to the selected worktree, and Neo-tree displays that worktree's files.
New file and text searches are scoped to the worktree.

When the worktree does not change, the browsing context stays where it is.
Those tabs share the same most recently viewed repository buffer, Neo-tree state, and picker root.

## Opening an Existing Worktree

The user opens a worktree picker for the repository containing the current worktree with `<leader>fw`.
The worktree picker uses Snacks Picker and opens in the same left-side location and layout as the existing file picker.

The picker lists:

- The main worktree.
- Every existing linked worktree for the same repository.

Each entry is labeled with the worktree's directory name, such as `manual-retry`.
Names that exceed the available width use the picker's normal truncation behavior.

When the user selects a worktree with one or more running Codex tabs, Neovim focuses the most recently active tab associated with that worktree.
When the user selects a worktree without a running Codex tab, Neovim opens a new Codex tab rooted in that worktree and starts a new conversation there.
Neovim then switches to the selected worktree's browsing context.

The picker is based on Git worktrees rather than saved Codex conversations.

## Handing Off the Current Conversation

The user can request a worktree handoff from the active Codex conversation.
The request can be expressed naturally, such as "Create a worktree for this."
This is the flow used when the current conversation began in the main worktree but should continue in isolated work.

During a successful handoff:

1. Codex fetches `origin/main`.
2. Codex chooses a concise, unique, task-relevant name and creates a new branch and managed worktree from the fetched `origin/main`.
3. The active Codex tab becomes associated with the new worktree.
4. The same Codex conversation resumes in the new worktree with its existing history.
5. Subsequent Codex file operations, edits, tests, and Git commands use the new worktree as their default working root.
6. Neovim switches to the new worktree's browsing context.

Changes written to disk before the handoff remain in the original worktree.
Modified Neovim buffers remain loaded and unchanged.
When the conversation resumes, Codex knows the new worktree path, branch name, base reference, and exact base commit.
The user does not need to locate or resume the conversation manually.
The handoff must not create a second conversation.

If Codex cannot fetch `origin/main`, the handoff fails.
If the handoff cannot complete, the current conversation remains associated with its original worktree.
Neovim also remains in the original browsing context.
The handoff reports the failure without leaving the conversation or editor split between two worktrees.

## Creating Ordinary Codex Tabs

The existing add-tab action continues to create a Codex tab in the currently active worktree.
Creating an ordinary tab does not automatically create a worktree.

## Worktree Storage and Lifetime

Managed worktrees live under:

```text
~/.codex/worktrees/<repository>/<worktree>
```

This keeps additional working directories out of `~/Documents/projects`.
The main worktree is never moved into the managed worktree directory.

Worktrees persist until the user removes them through Git or a future cleanup workflow.
The first version does not delete worktrees automatically.
