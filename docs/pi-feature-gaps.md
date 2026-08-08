# Pi Integration Feature Gaps

The active Neovim configuration has replaced the former Codex and OpenCode integrations with Pi. Historical implementations and design documents live under `deprecated/` rather than as commented-out code in active modules.

## Not Yet Replaced

### Multiple conversations

The current integration owns one Pi terminal per project directory. It does not provide numbered conversation slots, next/previous slot navigation, or direct slot shortcuts.

### Editor context actions

There are no Neovim mappings dedicated to sending a visual selection or a selected tree file to Pi.

### Hands-Free Mode

The former speech workflow has not been ported to Pi. Dictation and spoken submit, interrupt, approve, and reject controls are unavailable.

### Numbered-pane UI

The Pi pane does not provide the former numbered pane title, slot-aware context, or explicit modal/maximized pane mode.
