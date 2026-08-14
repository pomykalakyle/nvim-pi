-- Registers editor lifecycle autocmds loaded by LazyVim.

-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

--- Reviewed: false.
local function configure_lua_end_concealment()
  local match_id = vim.w.lua_end_conceal_match

  if vim.bo.filetype ~= "lua" then
    if match_id then
      pcall(vim.fn.matchdelete, match_id)
      vim.w.lua_end_conceal_match = nil
      vim.wo.conceallevel = vim.w.lua_end_previous_conceallevel
      vim.wo.concealcursor = vim.w.lua_end_previous_concealcursor
      vim.w.lua_end_previous_conceallevel = nil
      vim.w.lua_end_previous_concealcursor = nil
    end
    return
  end

  if match_id then
    return
  end

  vim.w.lua_end_previous_conceallevel = vim.wo.conceallevel
  vim.w.lua_end_previous_concealcursor = vim.wo.concealcursor
  vim.wo.conceallevel = 2
  vim.wo.concealcursor = ""
  vim.w.lua_end_conceal_match =
    vim.fn.matchadd("Conceal", [[^\s*\zs\<end\>\ze\s*\%(\-\-.*\)\?$]], 10, -1, { conceal = "┘" })
end

vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "WinEnter" }, {
  desc = "Display standalone Lua end statements as a corner until focused",
  callback = configure_lua_end_concealment,
})
