# Code review tracker

This checklist tracks project-owned files that contain at least one
`Reviewed: false.` marker.

Check a file only after every project-owned function in it has been reviewed in
detail and its marker has been updated to `Reviewed: true.` If a later change
adds another `Reviewed: false.` function, uncheck the file.

Tests, vendored code, dependency trees, generated files, and deprecated code are
outside this tracker.

## Root

- [x] `init.lua`

## `lua/`

### `lua/config/`

- [ ] `lua/config/autocmds.lua`
- [ ] `lua/config/colemak.lua`
- [ ] `lua/config/editor.lua`
- [ ] `lua/config/git_worktree.lua`
- [ ] `lua/config/keymaps.lua`
- [x] `lua/config/lazy.lua`
- [ ] `lua/config/project_local_config.lua`
- [ ] `lua/config/startup.lua`

#### `lua/config/pi/`

- [ ] `lua/config/pi/diff_preview.lua`
- [ ] `lua/config/pi/file_focus.lua`
- [ ] `lua/config/pi/terminal.lua`
- [ ] `lua/config/pi/workspace.lua`
- [ ] `lua/config/pi/worktree.lua`

#### `lua/config/project_picker/`

- [ ] `lua/config/project_picker/picker.lua`
- [ ] `lua/config/project_picker/registry.lua`

### `lua/plugins/`

- [ ] `lua/plugins/ai.lua`
- [ ] `lua/plugins/blink-cmp.lua`
- [ ] `lua/plugins/markdown.lua`
- [ ] `lua/plugins/neo-tree.lua`
- [ ] `lua/plugins/sessions.lua`
- [ ] `lua/plugins/snacks.lua`

## `pi-extensions/`

### `pi-extensions/back/`

- [ ] `pi-extensions/back/find-latest-user-message.ts`
- [ ] `pi-extensions/back/index.ts`

### `pi-extensions/bash-syntax-highlighting/`

- [ ] `pi-extensions/bash-syntax-highlighting/highlighter.ts`
- [ ] `pi-extensions/bash-syntax-highlighting/index.ts`

### `pi-extensions/clean-image-paste/`

- [ ] `pi-extensions/clean-image-paste/index.ts`

### `pi-extensions/local-autocomplete/`

- [ ] `pi-extensions/local-autocomplete/index.ts`

### `pi-extensions/mac-sounds/`

- [ ] `pi-extensions/mac-sounds/index.ts`

### `pi-extensions/neovim-diff-preview/`

- [ ] `pi-extensions/neovim-diff-preview/neovim-client.ts`
- [ ] `pi-extensions/neovim-diff-preview/proposal-persistence.ts`
- [ ] `pi-extensions/neovim-diff-preview/proposal-session.ts`
- [ ] `pi-extensions/neovim-diff-preview/proposal.ts`
- [ ] `pi-extensions/neovim-diff-preview/result.ts`
- [ ] `pi-extensions/neovim-diff-preview/review-ui.ts`
- [ ] `pi-extensions/neovim-diff-preview/tools.ts`

### `pi-extensions/neovim-file-focus/`

- [ ] `pi-extensions/neovim-file-focus/index.ts`
- [ ] `pi-extensions/neovim-file-focus/result.ts`

### `pi-extensions/response-timer/`

- [ ] `pi-extensions/response-timer/index.ts`

### `pi-extensions/thinking-hotkeys/`

- [ ] `pi-extensions/thinking-hotkeys/index.ts`
- [ ] `pi-extensions/thinking-hotkeys/levels.ts`

### `pi-extensions/vibing-mode/`

- [ ] `pi-extensions/vibing-mode/index.ts`
- [ ] `pi-extensions/vibing-mode/shared.ts`
- [ ] `pi-extensions/vibing-mode/state.ts`

### `pi-extensions/worktree-handoff/`

- [ ] `pi-extensions/worktree-handoff/extension.ts`
- [ ] `pi-extensions/worktree-handoff/git.ts`
- [ ] `pi-extensions/worktree-handoff/index.ts`
- [ ] `pi-extensions/worktree-handoff/neovim.ts`

## `scripts/`

- [x] `scripts/launch-nvim-pi.sh`
