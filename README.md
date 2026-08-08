# nvim-pi

This is my personal Neovim config, centered on running [Pi](https://github.com/earendil-works/pi) inside the editor.
I keep it public in case anyone is curious about what that integration can look like in daily use.

Pi lives in an embedded terminal managed by Snacks and Edgy.
The editor and agent share enough context to work together without pretending they are one application.

## What the integration does

- Pi can display edit and write proposals as read-only Neovim diffs while approval stays in the terminal. Every mutation names the proposed-file ranges to leave unfolded, and Neovim rejects previews that hide a change or do not fit.
- Pi can focus a specific file range in the editor and dim everything outside it.
- Each Git worktree gets its own Neovim tab, file browser, and Pi terminal context, and Pi can fork the current conversation into a new managed worktree.
- Small local extensions handle things such as prompt autocomplete, syntax highlighting, sounds, and request-scoped Vibing Mode.

## The rest of the setup

The surrounding config is just as personal.
It uses LazyVim, Snacks, Edgy, and Neo-tree on macOS.
The keymaps follow Colemak-DH, and a few shortcuts are built around Wispr Flow for voice input.

There is no installation guide because this is not meant to be a reusable Neovim distribution.
It is the config I actively use, and I change it whenever I want a new behavior or find a better way to do something.

A lot of the code is vibe-coded slop.
Some of it is carefully worked through; some of it exists because I wanted a feature that afternoon.
Browse it for ideas, steal whatever is useful, and expect the details to keep changing.

## Repository layout

- `lua/config/pi/` contains the Neovim side of the Pi integration.
- `pi-extensions/` contains the Pi extensions used by this setup.
- `lua/plugins/` and the rest of `lua/config/` contain the surrounding editor configuration.
- `vendor/pi-packages/` points to the Pi packages fork used by this config.

## License

MIT
