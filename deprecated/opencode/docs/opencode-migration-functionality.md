# OpenCode Neovim Custom Behavior

## Phase 1: Basic OpenCode Pane

- [x] **Phase implemented**

The active OpenCode conversation appears in a left-side pane at approximately forty percent of the editor width.

## Phase 2: Terminal Output and Window Navigation

- [x] **Phase implemented**

### Scrolling and Output Following

`Caps Lock-d` scrolls down by half of the visible pane height, and `Caps Lock-u` scrolls up by the same amount.

An unfocused visible OpenCode pane automatically follows new output.
A focused OpenCode pane preserves the user's chosen scroll position.
Reopening the hidden OpenCode pane returns the terminal to a usable input state.

### Neovim Window Navigation

The Command-key window-navigation shortcuts continue to work while the OpenCode terminal is focused without sending those keys to the composer.

| Shortcut | Destination |
| --- | --- |
| `Command-m` | Left window |
| `Command-n` | Window below |
| `Command-e` | Window above |
| `Command-i` | Right window |

## Phase 3: Project Startup

- [x] **Phase implemented**

### Opening the OpenCode Setup with Option-T

During the migration, Option-T opens a new Neovim instance using the OpenCode setup without requiring the user to choose a project first.
Option-N continues to open the current Codex setup until the OpenCode setup is ready to replace it.
When no other Neovim project window is open, the new instance restores the most recent project.
When a project is already open in another Neovim window, the new instance opens the project picker instead and excludes projects that are already open elsewhere.

### Switching Projects from Neovim

`<leader>fp` opens the project picker from an existing Neovim instance.
The picker excludes projects that are already open in another Neovim window.
Selecting a project switches the current Neovim instance to that project.

### Opening OpenCode for the Selected Project

After either workflow restores or selects a project, the OpenCode pane opens automatically.
The most recent agent conversation for that project resumes automatically.

## Phase 4: Review Workflow and Vibing Mode

- [ ] **Phase implemented**

The editing workflow has two modes: Manual Review Mode and Vibing Mode.
Manual Review Mode is active by default.

### Manual Review Mode

Before each file edit, OpenCode explains in the terminal which file will change, what the file controls, why the change is necessary, and exactly what will change.
Each explanation covers one file, and only that file is edited afterward.
The proposed edit waits for the user to approve or reject it in the OpenCode terminal.

#### Diff Viewer

In Manual Review Mode, a proposed patch opens a diff viewer in the main Neovim editing area.
The viewer initially opens in whichever layout the user selected most recently: unified inline or side by side.
The diff is read-only, syntax-highlighted, unwrapped, and displays line numbers with additions and removals clearly distinguished.
Opening the diff leaves keyboard focus in the OpenCode terminal, but the user can move focus normally while the review remains visible.
Neo-tree reveals the file affected by the proposed edit.

The user can toggle the review between side-by-side and unified inline layouts with `t` or a Neovim command.
Toggling layouts preserves scroll positions.

#### Review Lifecycle

Approving, rejecting, completing, or interrupting the turn removes the temporary review interface.
Closing the review returns the main editing area to the editor buffer, cursor position, and scroll position that were visible beforehand.
Review cleanup preserves unrelated loaded buffers and unsaved editor work.
A failure in the approval bridge defaults to rejection rather than silently approving an action.

#### Review Request Sound

A file-edit review request plays the macOS `Tink` sound only while Neovim is unfocused.

### Vibing Mode

Vibing Mode lets the user intentionally skip the Manual Review Mode workflow for a task.
The user can activate it directly by clearly asking in natural language to skip individual edit review, or grant standing authorization for a defined longer-running scope.
For each matching request, OpenCode states that it is enabling Vibing Mode and activates it without requiring separate confirmation.
Standing authorization allows reactivation for later matching requests but does not keep the runtime capability active between requests or conversations.
A current user instruction can narrow or revoke standing authorization.
Unreviewed editing begins only after activation succeeds.
A failed activation leaves Manual Review Mode enabled.

Vibing Mode allows direct patch edits to skip the Manual Review Mode diff and approval flow.
A single patch may edit multiple files while Vibing Mode is active.
Per-file edit explanations are not required while Vibing Mode is active.
Vibing Mode applies only to direct patch edits for the active task.

Vibing Mode runtime state applies only to the request for which it was activated.
Every later request starts with the runtime capability inactive. OpenCode may reactivate it when the prompt requests Vibing Mode directly or an applicable standing user authorization covers the requested edits.
When the user says to stop or narrows the standing scope, that instruction takes precedence before any further edit.

### Completion Notifications

Finishing an agent turn plays the macOS `Tink` sound and produces the configured completion notification.

## Phase 5: Multiple Conversations

- [ ] **Phase implemented**

### Numbered Conversation Slots

One Neovim instance can keep up to nine independent agent conversations available.
Each conversation occupies one stable numbered slot.
Creating a slot starts a fresh conversation.
Creating or selecting a slot hides the previously active slot without ending it.
Hidden slots continue running and retain their conversation state.

The user can select the next or previous occupied slot with wraparound or jump directly to any occupied slot by number.
Closing the active slot ends only that conversation and selects the nearest remaining slot.
Attempting to create a tenth slot produces a warning and leaves the existing slots unchanged.

An asynchronous operation remains bound to the stable slot that started it even if another slot becomes visible later.
Changing project roots closes all slots from the previous project rather than carrying them into the new project.

### Slot-Aware Agent Pane

The selected ordinary or modal pane mode remains consistent while the user switches slots.
Selecting a slot leaves its composer ready for typing.
Layout updates involving Neo-tree or the agent pane return focus to the intended agent slot.
The pane title displays every occupied slot and visibly distinguishes the active slot.

### Slot-Aware Editor Context

Editor-context actions always target the active numbered slot.
When no slot exists, an editor-context action creates one automatically.
Creating or revealing a slot for an editor-context action does not steal focus from the editor unnecessarily.
The locally replaced context commands retain the stock command names so existing mappings and workflows continue to work.

### Conversation Keyboard Workflow

| Shortcut | Action |
| --- | --- |
| `<leader>ca` | Create a new conversation slot |
| `<leader>cx` | Close the active conversation slot |
| `<leader>cn` | Select the next occupied slot |
| `<leader>ce` | Select the previous occupied slot |
| `<leader>c1` through `<leader>c9` | Select a numbered slot directly |
| `[` and `]` | Select the previous or next slot from inside the agent terminal |
| `\1` through `\9` | Select a numbered slot from inside the agent terminal |
| `\n` | Create a slot from inside the agent terminal |
| `\x` | Close the active slot from inside the agent terminal |

## Phase 6: Worktree Integration

- [ ] **Phase implemented**

### Browsing Context

Every numbered agent slot is associated with one Git worktree.
Each worktree is represented by one native Neovim tabpage.
Selecting a slot in another worktree selects that worktree's tabpage and browsing context.
Each worktree tabpage retains its working directory, editor windows, Neo-tree location, picker root, active repository buffer, and complete buffer list.
Returning to a worktree restores the tabpage as the user left it.

Buffers from other worktrees remain loaded and unchanged.
Buffer navigation and buffer pickers show the buffers belonging to the active worktree tabpage.
Neo-tree changes its root to the active worktree.
New file and text searches use the active worktree.
Slots associated with the same worktree share its tabpage and browsing context.

### Worktree Picker

A custom worktree picker lists the main worktree and every linked worktree for the active repository.
Selecting a worktree with running agent slots focuses the most recently active matching slot.
Selecting a worktree without a running slot creates a fresh slot rooted there.
Creating an ordinary conversation slot never creates a worktree automatically.
`<leader>fw` opens the custom worktree picker.

### Managed Conversation Handoff

The user can request a managed worktree handoff in natural language from the active conversation.
A successful handoff fetches the latest `origin/main` before creating isolated work.
The handoff creates a concise, unique, task-relevant branch and linked worktree.
The same conversation resumes in the new worktree with its existing history.
The active numbered slot retains its position during the handoff.

Subsequent agent edits, commands, tests, and Git operations use the new worktree as their default root.
Neovim switches to the new worktree's browsing context after the handoff.
Changes already written in the original worktree remain there.
Modified Neovim buffers remain loaded and are not silently moved or rewritten.

A failed fetch or handoff leaves the conversation and Neovim browsing context in the original worktree.
The main worktree is never moved from its existing project location.
Managed worktrees live under the dedicated user-level worktree directory and persist until deliberately removed.

## Phase 7: Hands-Free Mode

- [ ] **Phase implemented**

### Activation and Lifetime

The user can explicitly start voice control for the selected live agent slot.
Voice control is never enabled automatically.
Voice control binds to one stable slot for its entire lifetime and never follows slot changes silently.
The speech companion is built automatically the first time it is needed and reused afterward.
Microphone capture starts automatically after Hands-Free Mode begins.

### Dictation

Ordinary dictation accumulates into one message while the bound agent is ready.
Saying "Submit that message" submits the current dictated message immediately.
Ten seconds of continuous silence submits a non-empty dictated message.
Silence before dictation begins does not submit anything.
Ordinary dictation is ignored while the agent is working and is not queued as a future message.

### Spoken Controls

Saying "stop" while the agent is working interrupts that turn without ending Hands-Free Mode.
Saying "approve" or "reject" resolves one pending approval when an approval is active.
Spoken control phrases take effect only as standalone commands in states where they are valid.
Spoken control phrases are not included in the message sent to the agent.
Saying "Exit hands-free mode" ends voice control from any state.

### Ending, Status, and Failures

Ending Hands-Free Mode discards an unsubmitted dictated message without interrupting an already running turn.
Hands-Free Mode remains active through ordinary silence until the user ends it or the bound slot is lost.
Closing, exiting, or losing the bound slot ends Hands-Free Mode instead of transferring it.
The pane title shows whether Hands-Free Mode is starting, listening, observing agent work, or awaiting approval.
Agent responses remain visual and are not read aloud.
Voice failures produce a visible error instead of leaving the interface pretending to listen.
A failed voice approval bridge denies the pending action rather than approving it silently.
