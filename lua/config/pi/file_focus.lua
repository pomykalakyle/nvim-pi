-- Focuses agent-selected file ranges in the editor beside the requesting Pi terminal.

local M = {}

local file_paths = require("config.pi.file_path")
local window_focus = require("config.pi.window_focus")

local TARGET_MARKER = "pi_file_focus_target"
local DIM_HIGHLIGHT = "PiFileFocusDim"
local active_focuses = {}

---Remove one Pi process's temporary dimming and interaction handlers.
--- Reviewed: false.
local function clear_focus(requester_pid)
  local active = active_focuses[requester_pid]
  if not active then
    return false
  end

  active_focuses[requester_pid] = nil
  if vim.api.nvim_buf_is_valid(active.buf) then
    pcall(vim.api.nvim_buf_clear_namespace, active.buf, active.namespace, 0, -1)
  end
  return true
end

---Render or hide one focus's dimming without forgetting its selected range.
--- Reviewed: false.
local function render_focus_dimming(active)
  if not vim.api.nvim_buf_is_valid(active.buf) then
    return false
  end

  vim.api.nvim_buf_clear_namespace(active.buf, active.namespace, 0, -1)
  if not active.enabled then
    return true
  end

  local line_count = vim.api.nvim_buf_line_count(active.buf)
  local extmark_options = {
    end_col = -1,
    hl_eol = true,
    hl_group = DIM_HIGHLIGHT,
    priority = 4096,
    strict = false,
  }

  if active.start_row > 0 then
    vim.api.nvim_buf_set_extmark(
      active.buf,
      active.namespace,
      0,
      0,
      vim.tbl_extend("force", extmark_options, {
        end_row = math.min(active.start_row - 1, line_count - 1),
      })
    )
  end
  if active.end_row < line_count - 1 then
    vim.api.nvim_buf_set_extmark(
      active.buf,
      active.namespace,
      active.end_row + 1,
      0,
      vim.tbl_extend("force", extmark_options, {
        end_row = line_count - 1,
      })
    )
  end
  return true
end

---Dim every line outside the selected range until explicitly cleared or replaced.
--- Reviewed: false.
local function apply_focus_dimming(requester_pid, win, buf, start_row, end_row)
  clear_focus(requester_pid)

  vim.api.nvim_set_hl(0, DIM_HIGHLIGHT, { default = true, link = "LineNr" })
  local active = {
    buf = buf,
    namespace = vim.api.nvim_create_namespace(("pi_file_focus_%d"):format(requester_pid)),
    win = win,
    start_row = start_row,
    end_row = end_row,
    enabled = true,
  }
  active_focuses[requester_pid] = active
  render_focus_dimming(active)
end

---Return a structured rejection that the Pi extension can report as a failed tool call.
--- Reviewed: false.
local function rejection(reason, message, details)
  return vim.tbl_extend("force", {
    ok = false,
    reason = reason,
    message = message,
  }, details or {})
end

---Return whether a normal editor window can display an agent-selected range.
--- Reviewed: false.
local function is_focus_target(win, terminal_win)
  if win == terminal_win or not window_focus.is_normal_window(win) then
    return false
  end

  local preview_ok, is_preview = pcall(vim.api.nvim_win_get_var, win, "pi_diff_preview")
  return not (preview_ok and is_preview == true)
end

---Find the visible terminal window belonging to the Pi process that made the request.
--- Reviewed: false.
local function find_requesting_terminal(requester_pid)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].pi_terminal == true and vim.b[buf].terminal_job_pid == requester_pid then
      return win
    end
  end
end

---Return a candidate's screen position and area for stable target selection.
--- Reviewed: false.
local function candidate_geometry(win)
  local position = vim.fn.win_screenpos(win)
  return {
    win = win,
    row = position[1],
    col = position[2],
    area = vim.api.nvim_win_get_height(win) * vim.api.nvim_win_get_width(win),
  }
end

---Choose the normal editor window associated with the requesting Pi terminal.
--- Reviewed: false.
local function find_focus_target(terminal_win, file_path)
  local tab = vim.api.nvim_win_get_tabpage(terminal_win)
  local terminal_position = vim.fn.win_screenpos(terminal_win)
  local candidates = {}

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if is_focus_target(win, terminal_win) then
      local candidate = candidate_geometry(win)
      local buffer_path = file_paths.canonical(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
      local marker_ok, marked = pcall(vim.api.nvim_win_get_var, win, TARGET_MARKER)
      candidate.shows_file = buffer_path == file_path
      candidate.marked = marker_ok and marked == true
      candidate.to_right = candidate.col > terminal_position[2]
      candidates[#candidates + 1] = candidate
    end
  end

  table.sort(candidates, --[[ Reviewed: false. ]] function(left, right)
    for _, key in ipairs({ "shows_file", "marked", "to_right" }) do
      if left[key] ~= right[key] then
        return left[key]
      end
    end
    if left.area ~= right.area then
      return left.area > right.area
    end
    if left.col ~= right.col then
      return left.col < right.col
    end
    return left.row < right.row
  end)

  return candidates[1] and candidates[1].win or nil
end

---Load or reuse the normal file-backed buffer for a canonical path.
--- Reviewed: false.
local function load_file_buffer(file_path)
  local stat = vim.uv.fs_stat(file_path)
  if not stat or stat.type ~= "file" then
    return nil, "File does not exist or is not a regular file"
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if file_paths.canonical(vim.api.nvim_buf_get_name(buf)) == file_path then
      local loaded, load_error = pcall(vim.fn.bufload, buf)
      if not loaded then
        return nil, tostring(load_error)
      end
      return buf
    end
  end

  local buf = vim.fn.bufadd(file_path)
  local loaded, load_error = pcall(vim.fn.bufload, buf)
  if not loaded then
    return nil, tostring(load_error)
  end
  return buf
end

---Restore the buffer, fold option, and view replaced during a rejected focus.
--- Reviewed: false.
local function restore_target(win, snapshot)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local restored = pcall(--[[ Reviewed: false. ]] function()
    vim.api.nvim_win_set_buf(win, snapshot.buf)
    vim.wo[win].foldenable = snapshot.foldenable
    vim.api.nvim_win_call(win, --[[ Reviewed: false. ]] function()
      vim.fn.winrestview(snapshot.view)
    end)
  end)
  return restored
end

---Return the largest inclusive end row whose fully expanded text fits the window.
--- Reviewed: false.
local function largest_fitting_end(win, start_row, end_row, viewport_rows)
  local low = start_row
  local high = end_row
  local fitting = nil

  while low <= high do
    local middle = math.floor((low + high) / 2)
    local height = vim.api.nvim_win_text_height(win, {
      start_row = start_row,
      end_row = middle,
    }).all

    if height <= viewport_rows then
      fitting = middle
      low = middle + 1
    else
      high = middle - 1
    end
  end

  return fitting
end

---Center the selected range as a unit and return the resulting visible bounds.
--- Reviewed: false.
local function center_range(win, start_row, end_row, range_rows)
  return vim.api.nvim_win_call(win, --[[ Reviewed: false. ]] function()
    local midpoint = vim.api.nvim_win_text_height(win, {
      start_row = start_row,
      end_row = end_row,
      max_height = math.max(1, math.ceil(range_rows / 2)),
    })
    local midpoint_row = math.max(start_row, math.min(end_row, midpoint.end_row))

    vim.api.nvim_win_set_cursor(win, { midpoint_row + 1, 0 })
    vim.cmd("normal! zz")

    local visible_start = vim.fn.line("w0")
    local visible_end = vim.fn.line("w$")
    if start_row + 1 < visible_start then
      vim.api.nvim_win_set_cursor(win, { start_row + 1, 0 })
      vim.cmd("normal! zt")
    elseif end_row + 1 > visible_end then
      vim.api.nvim_win_set_cursor(win, { end_row + 1, 0 })
      vim.cmd("normal! zb")
    end

    return {
      start_line = vim.fn.line("w0"),
      end_line = vim.fn.line("w$"),
    }
  end)
end

---Focus one inclusive file range or return a structured, restorable rejection.
--- Reviewed: false.
function M.focus(payload)
  if type(payload) ~= "table" then
    return rejection("invalid_request", "Focus request must be a table")
  end

  local requester_pid = payload.requester_pid
  local start_line = payload.start_line
  local end_line = payload.end_line
  if type(requester_pid) ~= "number" or requester_pid < 1 then
    return rejection("invalid_request", "requester_pid must be a positive number")
  end
  if type(start_line) ~= "number" or start_line % 1 ~= 0 or start_line < 1 then
    return rejection("invalid_request", "start_line must be a positive integer")
  end
  if type(end_line) ~= "number" or end_line % 1 ~= 0 or end_line < start_line then
    return rejection("invalid_request", "end_line must be an integer at or after start_line")
  end

  local file_path = file_paths.canonical(payload.file_path)
  if not file_path then
    return rejection("invalid_request", "file_path must be a non-empty string")
  end

  local terminal_win = find_requesting_terminal(requester_pid)
  if not terminal_win then
    return rejection("requesting_terminal_not_visible", "The requesting Pi terminal is not visible in Neovim")
  end

  local target_win = find_focus_target(terminal_win, file_path)
  if not target_win then
    return rejection("no_editor_window", "No normal editor window is available beside Pi")
  end

  local file_buf, load_error = load_file_buffer(file_path)
  if not file_buf then
    return rejection("file_unavailable", load_error, { file_path = file_path })
  end

  local line_count = vim.api.nvim_buf_line_count(file_buf)
  if end_line > line_count then
    return rejection(
      "range_out_of_bounds",
      ("Requested lines %d-%d, but the file has %d lines"):format(start_line, end_line, line_count),
      { file_path = file_path, line_count = line_count }
    )
  end

  local snapshot = {
    buf = vim.api.nvim_win_get_buf(target_win),
    view = vim.api.nvim_win_call(target_win, vim.fn.winsaveview),
    foldenable = vim.wo[target_win].foldenable,
  }

  local changed, change_error = pcall(vim.api.nvim_win_set_buf, target_win, file_buf)
  if not changed then
    window_focus.focus_terminal(terminal_win, true)
    return rejection("editor_error", tostring(change_error), { file_path = file_path })
  end

  local start_row = start_line - 1
  local end_row = end_line - 1
  local viewport_rows = vim.api.nvim_win_get_height(target_win)

  -- Measure with folds disabled so a closed fold cannot make hidden text appear to fit.
  vim.wo[target_win].foldenable = false
  local range_rows = vim.api.nvim_win_text_height(target_win, {
    start_row = start_row,
    end_row = end_row,
  }).all

  if range_rows > viewport_rows then
    local fitting_end = largest_fitting_end(target_win, start_row, end_row, viewport_rows)
    local restored = restore_target(target_win, snapshot)
    window_focus.focus_terminal(terminal_win, true)
    return rejection(
      "range_too_tall",
      ("Requested lines %d-%d require %d displayed rows, but Neovim has %d"):format(
        start_line,
        end_line,
        range_rows,
        viewport_rows
      ),
      {
        file_path = file_path,
        start_line = start_line,
        end_line = end_line,
        range_rows = range_rows,
        viewport_rows = viewport_rows,
        suggested_start_line = fitting_end and start_line or nil,
        suggested_end_line = fitting_end and (fitting_end + 1) or nil,
        restored = restored,
      }
    )
  end

  vim.wo[target_win].foldenable = snapshot.foldenable
  vim.api.nvim_win_call(target_win, --[[ Reviewed: false. ]] function()
    pcall(vim.cmd, ("%d,%dfoldopen!"):format(start_line, end_line))
  end)

  local visible = center_range(target_win, start_row, end_row, range_rows)
  if start_line < visible.start_line or end_line > visible.end_line then
    local restored = restore_target(target_win, snapshot)
    window_focus.focus_terminal(terminal_win, true)
    return rejection("range_not_visible", "Neovim could not keep the complete requested range visible", {
      file_path = file_path,
      start_line = start_line,
      end_line = end_line,
      viewport_rows = viewport_rows,
      range_rows = range_rows,
      restored = restored,
    })
  end

  vim.api.nvim_win_set_var(target_win, TARGET_MARKER, true)
  apply_focus_dimming(requester_pid, target_win, file_buf, start_row, end_row)
  window_focus.focus_terminal(terminal_win, true)
  return {
    ok = true,
    file_path = file_path,
    start_line = start_line,
    end_line = end_line,
    viewport_rows = viewport_rows,
    range_rows = range_rows,
    visible_start_line = visible.start_line,
    visible_end_line = visible.end_line,
  }
end

---Clear temporary focus styling owned by one Pi process.
--- Reviewed: false.
function M.clear(requester_pid)
  if type(requester_pid) ~= "number" then
    return false
  end
  return clear_focus(requester_pid)
end

---Toggle temporary focus styling in the current tab while retaining its selected ranges.
--- Reviewed: false.
function M.toggle_current_tab()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local matching_focuses = {}
  local any_enabled = false

  for _, active in pairs(active_focuses) do
    if vim.api.nvim_win_is_valid(active.win) and vim.api.nvim_win_get_tabpage(active.win) == current_tab then
      matching_focuses[#matching_focuses + 1] = active
      any_enabled = any_enabled or active.enabled
    end
  end

  local enable = not any_enabled
  for _, active in ipairs(matching_focuses) do
    active.enabled = enable
    render_focus_dimming(active)
  end
  return {
    count = #matching_focuses,
    enabled = enable and #matching_focuses > 0,
  }
end

---Clear all temporary focus styling in the current tab without disabling future focus calls.
--- Reviewed: false.
function M.clear_current_tab()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local matching_pids = {}
  for requester_pid, active in pairs(active_focuses) do
    if vim.api.nvim_win_is_valid(active.win) and vim.api.nvim_win_get_tabpage(active.win) == current_tab then
      matching_pids[#matching_pids + 1] = requester_pid
    end
  end

  for _, requester_pid in ipairs(matching_pids) do
    clear_focus(requester_pid)
  end
  return #matching_pids
end

vim.api.nvim_create_user_command("PiFocusClear", M.clear_current_tab, {
  desc = "Clear temporary Pi file focus in the current tab",
  force = true,
})

return M
