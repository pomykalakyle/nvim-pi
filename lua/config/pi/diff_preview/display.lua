-- Owns Pi preview buffers, windows, layouts, rendering, and editor-buffer refresh.

local M = {}

local codediff = require("config.pi.diff_preview.codediff")
local file_paths = require("config.pi.file_path")
local window_focus = require("config.pi.window_focus")

local restored_window_options = {
  "wrap",
  "number",
  "relativenumber",
  "signcolumn",
  "foldcolumn",
  "foldenable",
  "foldmethod",
  "foldlevel",
  "foldtext",
  "diff",
  "scrollbind",
  "cursorbind",
  "winbar",
}

---Return whether a window belongs to an active Pi preview.
--- Reviewed: false.
local function is_preview_window(win)
  local ok, value = pcall(vim.api.nvim_win_get_var, win, "pi_diff_preview")
  return ok and value == true
end

---Return whether a window can host a preview.
--- Reviewed: false.
local function is_review_target(win)
  return not is_preview_window(win) and window_focus.is_normal_window(win)
end

---Capture a window's cursor and scroll state without moving focus to it.
--- Reviewed: false.
local function save_view(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end

---Restore a captured cursor and scroll state without moving focus.
--- Reviewed: false.
local function restore_view(win, view)
  if win and view and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_call, win, --[[ Reviewed: false. ]] function()
      vim.fn.winrestview(view)
    end)
  end
end

---Capture the presentation options changed while a window hosts a preview.
--- Reviewed: false.
local function capture_window_options(win)
  local options = {}
  for _, name in ipairs(restored_window_options) do
    options[name] = vim.wo[win][name]
  end
  return options
end

---Restore presentation options after a preview releases a window.
--- Reviewed: false.
local function restore_window_options(win, options)
  for name, value in pairs(options or {}) do
    vim.wo[win][name] = value
  end
end

---Mark and label a window as part of the active preview.
--- Reviewed: false.
local function configure_window(preview, win, label)
  vim.api.nvim_win_set_var(win, "pi_diff_preview", true)
  vim.wo[win].wrap = true
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "yes"
  vim.wo[win].foldcolumn = "1"
  vim.wo[win].diff = false
  vim.wo[win].winbar = (" Pi proposal: %s — %s "):format(preview.file_name, label)
end

---Close every manual fold outside the model-selected visible ranges.
---The complete scratch buffer remains available so the user can open any fold.
--- Reviewed: false.
local function apply_preview_folds(win, ranges)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.api.nvim_win_call(win, --[[ Reviewed: false. ]] function()
    vim.wo.foldenable = true
    vim.wo.foldmethod = "manual"
    vim.wo.foldlevel = 0
    vim.cmd("silent! normal! zE")

    local line_count = vim.api.nvim_buf_line_count(0)
    local next_line = 1
    for _, range in ipairs(ranges) do
      if range.start_line - next_line >= 2 then
        vim.cmd(("silent! %d,%dfold"):format(next_line, range.start_line - 1))
      end
      next_line = range.end_line + 1
    end
    if line_count - next_line + 1 >= 2 then
      vim.cmd(("silent! %d,%dfold"):format(next_line, line_count))
    end
    vim.cmd("silent! normal! zM")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("silent! normal! zt")
  end)
end

---Return the visible Pi terminal window owned by a workspace.
--- Reviewed: false.
function M.require_terminal_window(workspace)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(workspace.tabpage)) do
    if vim.api.nvim_win_get_buf(win) == workspace.terminal.buf then
      return win
    end
  end

  error("Pi terminal is not visible in the requesting workspace")
end

---Return the leftmost normal editor window available for a preview.
--- Reviewed: false.
function M.find_review_target(tabpage)
  local candidates = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if is_review_target(win) then
      candidates[#candidates + 1] = win
    end
  end

  table.sort(candidates, --[[ Reviewed: false. ]] function(left, right)
    local left_pos = vim.fn.win_screenpos(left)
    local right_pos = vim.fn.win_screenpos(right)
    if left_pos[1] == right_pos[1] then
      return left_pos[2] < right_pos[2]
    end
    return left_pos[1] < right_pos[1]
  end)

  return candidates[1]
end

---Create one read-only scratch buffer for a preview file version.
--- Reviewed: false.
function M.make_buffer(name, file_path, lines, toggle_layout)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  -- Both versions must survive while one is hidden by the unified layout.
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.b[buf].pi_diff_preview = true

  local filetype = vim.filetype.match({ filename = file_path })
  if filetype then
    vim.bo[buf].filetype = filetype
  end

  vim.keymap.set("n", "t", toggle_layout, {
    buffer = buf,
    desc = "Pi: Toggle diff layout",
    nowait = true,
    silent = true,
  })

  return buf
end

---Capture the editor state that a preview must restore when it closes.
--- Reviewed: false.
function M.capture_target(win)
  return {
    buf = vim.api.nvim_win_get_buf(win),
    view = save_view(win),
    options = capture_window_options(win),
  }
end

---Show the proposal with CodeDiff's paired-buffer renderer.
--- Reviewed: false.
function M.show_side_by_side(preview)
  codediff.clear_inline(preview)
  codediff.clear_side_by_side(preview)

  vim.api.nvim_set_current_win(preview.before_win)
  vim.api.nvim_win_set_buf(preview.before_win, preview.before_buf)
  configure_window(preview, preview.before_win, "Original")

  vim.cmd("rightbelow vsplit")
  preview.proposed_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(preview.proposed_win, preview.proposed_buf)
  configure_window(preview, preview.proposed_win, "Proposed")

  codediff.render_side_by_side(preview)
  apply_preview_folds(preview.before_win, preview.visible_ranges.original)
  apply_preview_folds(preview.proposed_win, preview.visible_ranges.proposed)
  restore_view(preview.before_win, preview.side_views and preview.side_views.before)
  restore_view(preview.proposed_win, preview.side_views and preview.side_views.proposed)
  codediff.synchronize_side_by_side(preview)
  preview.layout = "side_by_side"
end

---Collapse the paired preview into one annotated proposed buffer.
--- Reviewed: false.
function M.show_unified(preview)
  codediff.clear_side_by_side(preview)
  codediff.render_inline(preview)

  preview.side_views = {
    before = save_view(preview.before_win),
    proposed = save_view(preview.proposed_win),
  }

  if preview.proposed_win and vim.api.nvim_win_is_valid(preview.proposed_win) then
    vim.api.nvim_win_close(preview.proposed_win, true)
  end
  preview.proposed_win = nil

  vim.api.nvim_win_set_buf(preview.before_win, preview.proposed_buf)
  configure_window(preview, preview.before_win, "Unified")
  apply_preview_folds(preview.before_win, preview.visible_ranges.proposed)
  restore_view(preview.before_win, preview.unified_view)
  preview.layout = "unified"
end

---Switch one preview between its unified and paired layouts.
--- Reviewed: false.
function M.toggle_layout(preview)
  if preview.layout == "unified" then
    preview.unified_view = save_view(preview.before_win)
    M.show_side_by_side(preview)
  else
    M.show_unified(preview)
  end
end

---Return the rendered height of the tallest preview pane and its viewport.
--- Reviewed: false.
function M.geometry(preview)
  local viewport_rows = nil
  local preview_rows = 0
  for _, win in ipairs({ preview.before_win, preview.proposed_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
      local end_row = math.max(line_count - 1, 0)
      local rows = vim.api.nvim_win_text_height(win, { start_row = 0, end_row = end_row }).all
      viewport_rows = math.min(viewport_rows or math.huge, vim.api.nvim_win_get_height(win))
      preview_rows = math.max(preview_rows, rows)
    end
  end
  return preview_rows, viewport_rows or 0
end

---Release preview buffers and restore the editor window they replaced.
--- Reviewed: false.
function M.close(preview, restore)
  codediff.clear_inline(preview)
  codediff.clear_side_by_side(preview)

  if preview.proposed_win and vim.api.nvim_win_is_valid(preview.proposed_win) then
    pcall(vim.api.nvim_win_close, preview.proposed_win, true)
  end

  if preview.before_win and vim.api.nvim_win_is_valid(preview.before_win) then
    vim.api.nvim_win_set_var(preview.before_win, "pi_diff_preview", false)
    vim.api.nvim_win_set_buf(preview.before_win, restore.buf)
    restore_window_options(preview.before_win, restore.options)
    restore_view(preview.before_win, restore.view)
  end

  for _, buf in ipairs({ preview.before_buf, preview.proposed_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---Reload loaded buffers for a file changed successfully by a Pi tool.
---Preserve unsaved editor changes and warn instead of overwriting them.
--- Reviewed: false.
function M.refresh(file_path)
  local target_path = file_paths.canonical(file_path)
  if not target_path then
    return false
  end

  local matched = false
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local buffer_path = file_paths.canonical(vim.api.nvim_buf_get_name(buf))
      if buffer_path == target_path then
        matched = true
        if vim.bo[buf].modified then
          vim.notify(
            ("Pi updated %s on disk, but its buffer has unsaved changes and was not reloaded"):format(file_path),
            vim.log.levels.WARN
          )
        else
          vim.cmd(("silent! checktime %d"):format(buf))
        end
      end
    end
  end

  return matched
end

return M
