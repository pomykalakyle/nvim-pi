-- Defines global Colemak-DH, window, and buffer navigation mappings.

-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
--
-- Load Colemak-DH mappings after LazyVim defaults so overrides stick.
require("config.colemak").setup()

-- Toggle agent-applied file focus from either the editor or embedded Pi terminal.
local pi_file_focus = require("config.pi.file_focus")
vim.keymap.set({ "n", "i", "v", "t" }, "<F13>", pi_file_focus.toggle_current_tab, {
  silent = true,
  desc = "Pi: Toggle file focus",
})

-- Window focus navigation on the Command key (ergonomic on this keyboard).
-- The Colemak interceptor passes the Cmd modifier through but still remaps the base
-- letter, so Neovim receives the virtual keys m/n/e/i (physical h/j/k/l positions).
-- Map them to wincmd h/j/k/l, mirroring colemak.lua (m->left, n->down, e->up, i->right).
for vkey, dir in pairs({ m = "h", n = "j", e = "k", i = "l" }) do
  vim.keymap.set({ "n", "t" }, "<D-" .. vkey .. ">", --[[ Provenance: vibed=true, reviewed=false. ]] function()
    vim.cmd("wincmd " .. dir)
  end, { silent = true, desc = "Go to " .. dir .. " window" })
end

-- Buffer navigation on the shifted Colemak horizontal-movement keys, mirroring
-- LazyVim's <S-h>/<S-l>. Virtual M (Shift+m, left key) -> previous buffer;
-- Virtual I (Shift+i, right key) -> next buffer. remap = true so these follow
-- whatever <S-h>/<S-l> are bound to rather than hardcoding :bprevious/:bnext.
vim.keymap.set("n", "M", "<S-h>", { remap = true, silent = true, desc = "Virtual M: Previous buffer" })
vim.keymap.set("n", "I", "<S-l>", { remap = true, silent = true, desc = "Virtual I: Next buffer" })
