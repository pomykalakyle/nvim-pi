-- Verifies that scope.nvim exposes a separate listed-buffer set for each tabpage.

local first_tab = vim.api.nvim_get_current_tabpage()
local first_buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(first_buffer, "scope-worktree-first")
vim.api.nvim_set_current_buf(first_buffer)

require("scope").setup({})

vim.cmd.tabnew()
local second_tab = vim.api.nvim_get_current_tabpage()
local second_buffer = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(second_buffer, "scope-worktree-second")
vim.api.nvim_set_current_buf(second_buffer)

assert(vim.bo[first_buffer].buflisted == false)
assert(vim.bo[second_buffer].buflisted == true)

vim.api.nvim_set_current_tabpage(first_tab)
assert(vim.bo[first_buffer].buflisted == true)
assert(vim.bo[second_buffer].buflisted == false)

vim.api.nvim_set_current_tabpage(second_tab)
assert(vim.bo[first_buffer].buflisted == false)
assert(vim.bo[second_buffer].buflisted == true)

print("scope-worktree-spec-ok")
