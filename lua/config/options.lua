-- Overrides LazyVim's global editor defaults.

-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
vim.opt.relativenumber = false
vim.opt.wrap = true

-- Temporary: preview sizing counts the full proposed file instead of compact
-- diff hunks, which rejects tiny edits to long files. Remove this override
-- once the preview uses compact folding and measures only the visible diff.
vim.g.pi_diff_preview_enforce_fit = false
