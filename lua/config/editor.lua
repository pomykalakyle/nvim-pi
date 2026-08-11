-- Shared helpers for file-backed editor windows and focus restoration.

local M = {}

---Resolve a file path consistently across direct and symlinked buffer names.
--- Provenance: vibed=true, reviewed=false.
function M.canonical_file_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local absolute = vim.fn.fnamemodify(path, ":p")
  return vim.uv.fs_realpath(absolute) or vim.fs.normalize(absolute)
end

---Return whether a normal editor window can display file-backed content.
--- Provenance: vibed=true, reviewed=false.
function M.is_normal_window(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local ok, edgy = pcall(require, "edgy")
  if ok and type(edgy.get_win) == "function" then
    local found_ok, edgy_win = pcall(edgy.get_win, win)
    if found_ok and edgy_win ~= nil then
      return false
    end
  end

  local config = vim.api.nvim_win_get_config(win)
  if config.relative and config.relative ~= "" then
    return false
  end

  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

---Focus a Pi terminal window and resume input when requested.
--- Provenance: vibed=true, reviewed=false.
function M.focus_terminal(win, terminal_buffer_only)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end

  vim.api.nvim_set_current_win(win)
  local buf = vim.api.nvim_win_get_buf(win)
  if not terminal_buffer_only or vim.bo[buf].buftype == "terminal" then
    vim.cmd.startinsert()
  end
end

---Run a callback, then restore the current window and terminal-input mode.
--- Provenance: vibed=true, reviewed=false.
function M.with_preserved_focus(callback, ignore_errors)
  local previous_win = vim.api.nvim_get_current_win()
  local previous_mode = vim.fn.mode():sub(1, 1)

  if ignore_errors then
    pcall(callback)
  else
    callback()
  end

  if vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
    if previous_mode == "t" then
      vim.cmd.startinsert()
    end
  end
end

return M
