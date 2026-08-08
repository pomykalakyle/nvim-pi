-- Displays read-only Pi edit proposals while approval remains in the Pi terminal.

local M = {}

local editor = require("config.editor")

local active_display = nil
local preferred_layout = vim.g.pi_diff_preview_layout == "side_by_side" and "side_by_side" or "unified"
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

---Remember the selected layout for subsequent previews in this Neovim session.
local function set_preferred_layout(layout)
  preferred_layout = layout
  vim.g.pi_diff_preview_layout = layout
end

---Return whether a decoded RPC argument has every required proposal field.
---Reject malformed values before they can affect the editor layout.
local function is_valid_payload(payload)
  if type(payload) ~= "table" then
    return false
  end
  for _, key in ipairs({ "tool_call_id", "file_path", "old_content", "new_content" }) do
    if type(payload[key]) ~= "string" then
      return false
    end
  end
  if type(payload.unfolded_ranges) ~= "table" or #payload.unfolded_ranges == 0 then
    return false
  end
  for _, range in ipairs(payload.unfolded_ranges) do
    if
      type(range) ~= "table"
      or type(range.start_line) ~= "number"
      or range.start_line % 1 ~= 0
      or range.start_line < 1
      or type(range.end_line) ~= "number"
      or range.end_line % 1 ~= 0
      or range.end_line < range.start_line
    then
      return false
    end
  end
  return true
end

---Split text into lines accepted by nvim_buf_set_lines().
---Represent empty text as the single empty line required by a buffer.
local function split_lines(text)
  if text == "" then
    return { "" }
  end

  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return #lines > 0 and lines or { "" }
end

---Load CodeDiff before accessing its internal computation and rendering modules.
local function load_codediff_module(module_name)
  local lazy_ok, lazy = pcall(require, "lazy")
  if lazy_ok then
    local loaded, load_error = pcall(lazy.load, { plugins = { "codediff.nvim" } })
    if not loaded then
      return nil, tostring(load_error)
    end
  end

  local ok, module = pcall(require, module_name)
  if not ok then
    return nil, tostring(module)
  end
  return module, nil
end

---Sort proposed-file ranges and combine overlaps or gaps too small to fold.
local function normalize_ranges(ranges, line_count)
  local sorted = vim.deepcopy(ranges)
  table.sort(sorted, function(left, right)
    return left.start_line < right.start_line
      or (left.start_line == right.start_line and left.end_line < right.end_line)
  end)

  local normalized = {}
  for index, range in ipairs(sorted) do
    if range.end_line > line_count then
      return nil,
        ("unfolded_ranges[%d] ends at proposed line %d, but the proposed file has %d lines"):format(
          index,
          range.end_line,
          line_count
        )
    end

    local current = normalized[#normalized]
    -- A one-line fold occupies one row and Neovim will not create it, so show
    -- that line by merging ranges separated by a single line.
    if current and range.start_line <= current.end_line + 2 then
      current.end_line = math.max(current.end_line, range.end_line)
    else
      normalized[#normalized + 1] = {
        start_line = range.start_line,
        end_line = range.end_line,
      }
    end
  end

  if normalized[1] and normalized[1].start_line == 2 then
    normalized[1].start_line = 1
  end
  local last = normalized[#normalized]
  if last and last.end_line == line_count - 1 then
    last.end_line = line_count
  end
  return normalized
end

local function range_contains(ranges, start_line, end_line)
  for _, range in ipairs(ranges) do
    if range.start_line <= start_line and range.end_line >= end_line then
      return true
    end
  end
  return false
end

local function flags_to_ranges(flags, line_count)
  local ranges = {}
  local start_line = nil
  for line = 1, line_count + 1 do
    if line <= line_count and flags[line] then
      start_line = start_line or line
    elseif start_line then
      ranges[#ranges + 1] = { start_line = start_line, end_line = line - 1 }
      start_line = nil
    end
  end
  return normalize_ranges(ranges, line_count)
end

---Validate that the requested proposed-file ranges expose every computed hunk.
---Also map visible unchanged and changed lines onto the original buffer.
local function build_visible_ranges(payload)
  local original_lines = split_lines(payload.old_content)
  local proposed_lines = split_lines(payload.new_content)
  local proposed_ranges, range_error = normalize_ranges(payload.unfolded_ranges, #proposed_lines)
  if not proposed_ranges then
    return nil, { reason = "preview_range_out_of_bounds", message = range_error }
  end

  local diff_module, load_error = load_codediff_module("codediff.core.diff")
  if not diff_module then
    return nil,
      {
        reason = "preview_render_failed",
        message = "failed to load CodeDiff: " .. load_error,
      }
  end
  local diff_result = diff_module.compute_diff(original_lines, proposed_lines, {
    max_computation_time_ms = 5000,
    ignore_trim_whitespace = false,
    compute_moves = false,
  })
  if not diff_result then
    return nil,
      {
        reason = "preview_render_failed",
        message = "CodeDiff failed to compute the preview",
      }
  end
  if diff_result.hit_timeout == true then
    return nil,
      {
        reason = "preview_render_failed",
        message = "CodeDiff timed out before it could compute the complete preview",
      }
  end

  local original_visible = {}
  local proposed_visible = {}
  for _, range in ipairs(proposed_ranges) do
    for line = range.start_line, range.end_line do
      proposed_visible[line] = true
    end
  end

  local original_cursor = 1
  local proposed_cursor = 1
  for _, change in ipairs(diff_result.changes or {}) do
    local original_boundary = change.original.start_line
    local original_count = change.original.end_line - original_boundary
    local proposed_boundary = change.modified.start_line
    local proposed_count = change.modified.end_line - proposed_boundary

    while original_cursor < original_boundary and proposed_cursor < proposed_boundary do
      if proposed_visible[proposed_cursor] then
        original_visible[original_cursor] = true
      end
      original_cursor = original_cursor + 1
      proposed_cursor = proposed_cursor + 1
    end

    local visible_start
    local visible_end
    if proposed_count > 0 then
      visible_start = proposed_boundary
      visible_end = proposed_boundary + proposed_count - 1
    else
      -- CodeDiff anchors a pure deletion above the following proposed line.
      -- A deletion at EOF is anchored to the final remaining display line.
      visible_start = math.max(1, math.min(#proposed_lines, proposed_boundary))
      visible_end = visible_start
    end
    if not range_contains(proposed_ranges, visible_start, visible_end) then
      local description = proposed_count > 0 and ("changed proposed lines %d-%d"):format(visible_start, visible_end)
        or ("the deletion anchored at proposed line %d"):format(visible_start)
      return nil,
        {
          reason = "preview_change_not_visible",
          message = ("unfolded_ranges do not fully contain %s"):format(description),
        }
    end

    -- Side-by-side filler for a pure deletion is attached to the preceding
    -- proposed line, while unified virtual lines use the following line.
    if proposed_count == 0 and visible_start > 1 then
      proposed_visible[visible_start - 1] = true
    end

    for line = original_boundary, original_boundary + original_count - 1 do
      original_visible[line] = true
    end
    if original_count == 0 and #original_lines > 0 then
      local anchor = math.max(1, math.min(#original_lines, original_boundary))
      original_visible[anchor] = true
    end

    original_cursor = original_boundary + original_count
    proposed_cursor = proposed_boundary + proposed_count
  end

  while original_cursor <= #original_lines and proposed_cursor <= #proposed_lines do
    if proposed_visible[proposed_cursor] then
      original_visible[original_cursor] = true
    end
    original_cursor = original_cursor + 1
    proposed_cursor = proposed_cursor + 1
  end

  local original_ranges = flags_to_ranges(original_visible, #original_lines)
  if not original_ranges or #original_ranges == 0 then
    original_ranges = { { start_line = 1, end_line = 1 } }
  end
  local rendered_proposed_ranges = flags_to_ranges(proposed_visible, #proposed_lines)
  return {
    original = original_ranges,
    proposed = rendered_proposed_ranges,
    diff_result = diff_result,
  }
end

---Return whether a window belongs to the active Pi preview.
---Window markers distinguish previews from ordinary editor splits.
local function is_preview_window(win)
  local ok, value = pcall(vim.api.nvim_win_get_var, win, "pi_diff_preview")
  return ok and value == true
end

---Return the visible Pi terminal window or fail before preview construction.
---The terminal buffer marker identifies the exact embedded Pi instance.
local function require_pi_terminal_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].pi_terminal == true then
      return win
    end
  end

  error("Pi terminal is not visible in the current tab")
end

---Return whether a window can host the preview.
---Only normal, non-floating editor windows are eligible.
local function is_review_target(win)
  return not is_preview_window(win) and editor.is_normal_window(win)
end

---Return the leftmost normal editor window.
---Stable screen-position ordering keeps preview placement predictable.
local function find_review_target()
  local candidates = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_review_target(win) then
      candidates[#candidates + 1] = win
    end
  end

  table.sort(candidates, function(left, right)
    local left_pos = vim.fn.win_screenpos(left)
    local right_pos = vim.fn.win_screenpos(right)
    if left_pos[1] == right_pos[1] then
      return left_pos[2] < right_pos[2]
    end
    return left_pos[1] < right_pos[1]
  end)

  return candidates[1]
end

---Create one read-only scratch buffer for the preview.
---Infer the target filetype so both diff sides retain syntax highlighting.
local function make_preview_buffer(name, file_path, content)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, split_lines(content))
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

  vim.keymap.set("n", "t", M.toggle_layout, {
    buffer = buf,
    desc = "Pi: Toggle diff layout",
    nowait = true,
    silent = true,
  })

  return buf
end

---Reload loaded buffers for a file changed successfully by a Pi tool.
---Preserve unsaved editor changes and warn instead of overwriting them.
function M.refresh(file_path)
  local target_path = editor.canonical_file_path(file_path)
  if not target_path then
    return false
  end

  local matched = false
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local buffer_path = editor.canonical_file_path(vim.api.nvim_buf_get_name(buf))
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

---Load CodeDiff's inline renderer after the shared diff has been computed.
local function load_inline_renderer()
  local inline, load_error = load_codediff_module("codediff.ui.inline")
  return inline, load_error
end

---Remove the virtual lines and highlights added by CodeDiff.
---The underlying proposed text stays untouched.
local function clear_inline_preview(preview)
  if preview.inline_renderer and vim.api.nvim_buf_is_valid(preview.proposed_buf) then
    pcall(preview.inline_renderer.clear, preview.proposed_buf)
  end
end

---Annotate the proposed buffer with additions, changes, and virtual deleted lines.
---This prepares the buffer for unified display but does not change any windows.
local function render_inline_preview(preview)
  local inline, load_error = load_inline_renderer()
  if not inline then
    error("failed to load CodeDiff: " .. load_error, 0)
  end

  local original_lines = vim.api.nvim_buf_get_lines(preview.before_buf, 0, -1, false)
  local proposed_lines = vim.api.nvim_buf_get_lines(preview.proposed_buf, 0, -1, false)
  inline.render_inline_diff(
    preview.proposed_buf,
    preview.diff_result,
    original_lines,
    proposed_lines,
    { filetype = vim.bo[preview.proposed_buf].filetype }
  )
  preview.inline_renderer = inline
end

---Remove CodeDiff's side-by-side highlights, filler rows, and scroll binding.
local function clear_side_by_side_preview(preview)
  local lifecycle = load_codediff_module("codediff.ui.lifecycle")
  if lifecycle then
    for _, buf in ipairs({ preview.before_buf, preview.proposed_buf }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(lifecycle.clear_highlights, buf)
      end
    end
  end

  local scroll = load_codediff_module("codediff.ui.scroll")
  if scroll and preview.before_win and vim.api.nvim_win_is_valid(preview.before_win) then
    pcall(scroll.teardown, vim.api.nvim_win_get_tabpage(preview.before_win))
  end
end

---Render CodeDiff's paired-buffer highlights and virtual filler rows.
local function render_side_by_side_preview(preview)
  local core, core_error = load_codediff_module("codediff.ui.core")
  if not core then
    error("failed to load CodeDiff: " .. core_error, 0)
  end

  local original_lines = vim.api.nvim_buf_get_lines(preview.before_buf, 0, -1, false)
  local proposed_lines = vim.api.nvim_buf_get_lines(preview.proposed_buf, 0, -1, false)
  core.render_diff(preview.before_buf, preview.proposed_buf, original_lines, proposed_lines, preview.diff_result)
end

---Bind scrolling after folds have changed the two panes' visible structure.
local function synchronize_side_by_side_preview(preview)
  local scroll, scroll_error = load_codediff_module("codediff.ui.scroll")
  if not scroll then
    error("failed to load CodeDiff: " .. scroll_error, 0)
  end
  local tabpage = vim.api.nvim_win_get_tabpage(preview.proposed_win)
  scroll.bind(tabpage, { preview.before_win, preview.proposed_win })
  scroll.resync(tabpage, preview.proposed_win)
end

local function capture_window_options(win)
  local options = {}
  for _, name in ipairs(restored_window_options) do
    options[name] = vim.wo[win][name]
  end
  return options
end

local function restore_window_options(win, options)
  for name, value in pairs(options or {}) do
    vim.wo[win][name] = value
  end
end

---Capture a window's cursor and scroll state without moving focus to it.
local function save_view(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end

---Restore a captured cursor and scroll state without moving focus.
local function restore_view(win, view)
  if win and view and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview(view)
    end)
  end
end

---Mark and label a window as part of the active preview.
---Buffer options enforce read-only behavior; these options control its presentation.
local function configure_window(preview, win, label)
  vim.api.nvim_win_set_var(win, "pi_diff_preview", true)
  vim.wo[win].wrap = false
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "yes"
  vim.wo[win].foldcolumn = "1"
  vim.wo[win].diff = false
  vim.wo[win].winbar = (" Pi proposal: %s — %s "):format(preview.file_name, label)
end

---Close every manual fold outside the model-selected visible ranges.
---The complete scratch buffer remains available so the user can open any fold.
local function apply_preview_folds(win, ranges)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.api.nvim_win_call(win, function()
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

---Return the rendered height of the tallest preview pane and its viewport.
---nvim_win_text_height includes closed folds, diff filler, and virtual lines.
local function preview_geometry(preview)
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

---Show the proposal with CodeDiff's paired-buffer renderer.
local function show_side_by_side(preview)
  clear_inline_preview(preview)
  clear_side_by_side_preview(preview)

  vim.api.nvim_set_current_win(preview.before_win)
  vim.api.nvim_win_set_buf(preview.before_win, preview.before_buf)
  configure_window(preview, preview.before_win, "Original")

  vim.cmd("rightbelow vsplit")
  preview.proposed_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(preview.proposed_win, preview.proposed_buf)
  configure_window(preview, preview.proposed_win, "Proposed")

  render_side_by_side_preview(preview)
  apply_preview_folds(preview.before_win, preview.visible_ranges.original)
  apply_preview_folds(preview.proposed_win, preview.visible_ranges.proposed)
  restore_view(preview.before_win, preview.side_views and preview.side_views.before)
  restore_view(preview.proposed_win, preview.side_views and preview.side_views.proposed)
  synchronize_side_by_side_preview(preview)
  preview.layout = "side_by_side"
end

---Collapse the two-window native diff into one annotated proposed buffer.
---Rendering and layout changes stay separate so rendering failures leave the split intact.
local function show_unified(preview)
  clear_side_by_side_preview(preview)
  render_inline_preview(preview)

  -- Preserve each side's position for a later switch back to side-by-side.
  preview.side_views = {
    before = save_view(preview.before_win),
    proposed = save_view(preview.proposed_win),
  }

  -- The original window becomes the single preview window, so only the extra
  -- proposed split needs to be closed.
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

---Toggle the active proposal between side-by-side and unified layouts.
function M.toggle_layout()
  local display = active_display
  local preview = display and display.preview
  if not preview or not preview.before_win or not vim.api.nvim_win_is_valid(preview.before_win) then
    error("Pi diff preview: no active preview", 0)
  end

  local original_win = vim.api.nvim_get_current_win()
  local focused_proposed = original_win == preview.proposed_win
  local focused_outside_preview = original_win ~= preview.before_win and not focused_proposed
  local toggled, toggle_error = pcall(function()
    if preview.layout == "unified" then
      preview.unified_view = save_view(preview.before_win)
      show_side_by_side(preview)
    else
      show_unified(preview)
    end
  end)

  if not toggled then
    if vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
    error(toggle_error, 0)
  end

  set_preferred_layout(preview.layout)
  if focused_outside_preview and vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
  elseif preview.layout == "side_by_side" and focused_proposed then
    vim.api.nvim_set_current_win(preview.proposed_win)
  else
    vim.api.nvim_set_current_win(preview.before_win)
  end
end

---Close the active preview and restore the replaced editor buffer.
---An optional tool-call ID prevents stale cleanup from closing a newer preview.
function M.close(tool_call_id)
  local display = active_display
  if not display then
    return true
  end
  if tool_call_id and tool_call_id ~= "" and display.tool_call_id ~= tool_call_id then
    return false
  end

  -- Claim this display before cleanup so another close cannot process it again.
  active_display = nil
  local preview = display.preview
  local restore = display.restore

  clear_inline_preview(preview)
  clear_side_by_side_preview(preview)

  -- Close the extra split created by the side-by-side layout.
  if preview.proposed_win and vim.api.nvim_win_is_valid(preview.proposed_win) then
    pcall(vim.api.nvim_win_close, preview.proposed_win, true)
  end

  -- Put the real editor buffer and its previous view back in the reused window.
  if preview.before_win and vim.api.nvim_win_is_valid(preview.before_win) then
    vim.api.nvim_win_set_var(preview.before_win, "pi_diff_preview", false)
    vim.api.nvim_win_set_buf(preview.before_win, restore.buf)
    restore_window_options(preview.before_win, restore.options)
    restore_view(preview.before_win, restore.view)
  end

  -- Hidden preview buffers use "hide" so layouts can toggle; delete them explicitly.
  for _, buf in ipairs({ preview.before_buf, preview.proposed_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  editor.focus_terminal(display.pi_terminal_win)
  return true
end

---Open a read-only preview in the preferred layout and return focus to Pi.
---Pi retains approval control while the editor displays both proposal versions.
function M.open(payload)
  if not is_valid_payload(payload) then
    local message = "Pi diff preview requires valid nonempty unfolded_ranges with start_line <= end_line"
    vim.notify(message, vim.log.levels.ERROR)
    return {
      ok = false,
      reason = "preview_invalid_request",
      message = message,
    }
  end

  local pi_terminal_win = require_pi_terminal_window()
  local target = find_review_target()
  if not target then
    vim.notify("Pi diff preview: no normal editor window is available", vim.log.levels.ERROR)
    return false
  end

  -- Remove an older proposal before reusing the editor area.
  M.close()

  local visible_ranges, visibility_error = build_visible_ranges(payload)
  if not visible_ranges then
    return {
      ok = false,
      reason = visibility_error.reason,
      message = visibility_error.message,
      file_path = payload.file_path,
    }
  end

  -- Remember the target window's state so M.close() can restore it later.
  local restore = {
    buf = vim.api.nvim_win_get_buf(target),
    view = vim.api.nvim_win_call(target, vim.fn.winsaveview),
    options = capture_window_options(target),
  }
  local basename = vim.fn.fnamemodify(payload.file_path, ":t")
  if basename == "" then
    basename = "file"
  end

  -- Build read-only scratch buffers from the RPC proposal contents.
  local preview_before_buf = make_preview_buffer(
    ("pi://proposal/%s/original/%s"):format(payload.tool_call_id, basename),
    payload.file_path,
    payload.old_content
  )
  local preview_proposed_buf = make_preview_buffer(
    ("pi://proposal/%s/proposed/%s"):format(payload.tool_call_id, basename),
    payload.file_path,
    payload.new_content
  )

  -- Group temporary preview resources separately from editor restoration data.
  active_display = {
    tool_call_id = payload.tool_call_id,
    pi_terminal_win = pi_terminal_win,
    preview = {
      before_win = target,
      proposed_win = nil,
      before_buf = preview_before_buf,
      proposed_buf = preview_proposed_buf,
      file_name = basename,
      visible_ranges = visible_ranges,
      diff_result = visible_ranges.diff_result,
      layout = "side_by_side",
    },
    restore = restore,
  }

  local displayed, display_error = pcall(function()
    if preferred_layout == "unified" then
      show_unified(active_display.preview)
    else
      show_side_by_side(active_display.preview)
    end
  end)
  if not displayed then
    M.close(payload.tool_call_id)
    return {
      ok = false,
      reason = "preview_render_failed",
      message = "CodeDiff failed to render the preview: " .. tostring(display_error),
      file_path = payload.file_path,
    }
  end

  local preview_rows, viewport_rows = preview_geometry(active_display.preview)
  if preview_rows > viewport_rows then
    M.close(payload.tool_call_id)
    return {
      ok = false,
      reason = "preview_too_tall",
      message = ("The proposed %s diff requires %d displayed rows, but Neovim has %d"):format(
        basename,
        preview_rows,
        viewport_rows
      ),
      file_path = payload.file_path,
      preview_rows = preview_rows,
      viewport_rows = viewport_rows,
    }
  end

  -- Approval remains in Pi, so return focus after constructing the display.
  editor.focus_terminal(pi_terminal_win)
  return {
    ok = true,
    file_path = payload.file_path,
    preview_rows = preview_rows,
    viewport_rows = viewport_rows,
  }
end

vim.api.nvim_create_user_command("PiDiffToggle", M.toggle_layout, {
  desc = "Toggle the active Pi proposal diff layout",
  force = true,
})

return M
