-- Displays read-only Pi edit proposals while approval remains in the Pi terminal.

local M = {}

local editor = require("config.editor")

local active_display = nil
local preferred_layout = vim.g.pi_diff_preview_layout == "side_by_side" and "side_by_side" or "unified"

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

---Load CodeDiff's computation and inline-rendering modules on demand.
local function load_inline_renderer()
  local lazy_ok, lazy = pcall(require, "lazy")
  if lazy_ok then
    local loaded, load_error = pcall(lazy.load, { plugins = { "codediff.nvim" } })
    if not loaded then
      return nil, nil, tostring(load_error)
    end
  end

  local diff_ok, diff_module = pcall(require, "codediff.core.diff")
  if not diff_ok then
    return nil, nil, tostring(diff_module)
  end

  local inline_ok, inline = pcall(require, "codediff.ui.inline")
  if not inline_ok then
    return nil, nil, tostring(inline)
  end

  return diff_module, inline, nil
end

---Remove CodeDiff decorations from the proposed preview buffer.
local function clear_inline_preview(preview)
  if preview.inline_renderer and vim.api.nvim_buf_is_valid(preview.proposed_buf) then
    pcall(preview.inline_renderer.clear, preview.proposed_buf)
  end
end

---Render the original-to-proposed change over the proposed preview buffer.
local function render_inline_preview(preview)
  local diff_module, inline, load_error = load_inline_renderer()
  if not diff_module then
    vim.notify("Pi diff preview: failed to load CodeDiff: " .. load_error, vim.log.levels.ERROR)
    return false
  end

  local original_lines = vim.api.nvim_buf_get_lines(preview.before_buf, 0, -1, false)
  local proposed_lines = vim.api.nvim_buf_get_lines(preview.proposed_buf, 0, -1, false)
  if not preview.inline_diff_result then
    local computed, result = pcall(diff_module.compute_diff, original_lines, proposed_lines, {
      max_computation_time_ms = 5000,
      ignore_trim_whitespace = false,
      compute_moves = false,
    })
    if not computed or not result then
      vim.notify("Pi diff preview: CodeDiff failed: " .. tostring(result), vim.log.levels.ERROR)
      return false
    end
    preview.inline_diff_result = result
  end

  local rendered, render_error = pcall(
    inline.render_inline_diff,
    preview.proposed_buf,
    preview.inline_diff_result,
    original_lines,
    proposed_lines,
    { filetype = vim.bo[preview.proposed_buf].filetype }
  )
  if not rendered then
    vim.notify("Pi diff preview: CodeDiff render failed: " .. tostring(render_error), vim.log.levels.ERROR)
    return false
  end

  preview.inline_renderer = inline
  return true
end

---Save or restore a view without changing the caller's current window.
local function save_view(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end

local function restore_view(win, view)
  if win and view and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview(view)
    end)
  end
end

---Turn off native diff mode without changing the caller's current window.
local function diffoff(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd("diffoff")
    end)
  end
end

---Apply preview-specific window options.
---The winbar identifies each side without making either buffer editable.
local function configure_window(preview, win, label)
  vim.api.nvim_win_set_var(win, "pi_diff_preview", true)
  vim.wo[win].wrap = false
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "yes"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].foldenable = false
  vim.wo[win].winbar = (" Pi proposal: %s — %s "):format(preview.file_name, label)
end

---Return the tallest fully expanded preview and its available viewport height.
---nvim_win_text_height includes CodeDiff's virtual deleted lines in unified mode.
local function preview_geometry(preview)
  local viewport_rows = nil
  local preview_rows = 0
  for _, win in ipairs({ preview.before_win, preview.proposed_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local line_count = vim.api.nvim_buf_line_count(buf)
      local rows = line_count
      if preview.layout == "unified" then
        local end_row = math.max(line_count - 1, 0)
        rows = vim.api.nvim_win_text_height(win, { start_row = 0, end_row = end_row }).all
      end
      viewport_rows = math.min(viewport_rows or math.huge, vim.api.nvim_win_get_height(win))
      preview_rows = math.max(preview_rows, rows)
    end
  end
  return preview_rows, viewport_rows or 0
end

---Show the proposal as Neovim's native two-window diff.
local function show_side_by_side(preview)
  clear_inline_preview(preview)

  vim.api.nvim_set_current_win(preview.before_win)
  vim.api.nvim_win_set_buf(preview.before_win, preview.before_buf)
  configure_window(preview, preview.before_win, "Original")

  vim.cmd("rightbelow vsplit")
  preview.proposed_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(preview.proposed_win, preview.proposed_buf)
  configure_window(preview, preview.proposed_win, "Proposed")

  vim.api.nvim_set_current_win(preview.before_win)
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(preview.proposed_win)
  vim.cmd("diffthis")

  restore_view(preview.before_win, preview.side_views and preview.side_views.before)
  restore_view(preview.proposed_win, preview.side_views and preview.side_views.proposed)
  preview.layout = "side_by_side"
  return true
end

---Replace the native split with CodeDiff's unified inline rendering.
local function show_unified(preview)
  if not render_inline_preview(preview) then
    return false
  end

  preview.side_views = {
    before = save_view(preview.before_win),
    proposed = save_view(preview.proposed_win),
  }
  diffoff(preview.before_win)
  diffoff(preview.proposed_win)

  if preview.proposed_win and vim.api.nvim_win_is_valid(preview.proposed_win) then
    vim.api.nvim_win_close(preview.proposed_win, true)
  end
  preview.proposed_win = nil

  vim.api.nvim_win_set_buf(preview.before_win, preview.proposed_buf)
  configure_window(preview, preview.before_win, "Unified")
  restore_view(preview.before_win, preview.unified_view)
  preview.layout = "unified"
  return true
end

---Toggle the active proposal between side-by-side and unified layouts.
function M.toggle_layout()
  local display = active_display
  local preview = display and display.preview
  if not preview or not preview.before_win or not vim.api.nvim_win_is_valid(preview.before_win) then
    vim.notify("Pi diff preview: no active preview", vim.log.levels.WARN)
    return false
  end

  local original_win = vim.api.nvim_get_current_win()
  local focused_proposed = original_win == preview.proposed_win
  local focused_outside_preview = original_win ~= preview.before_win and not focused_proposed
  local toggled

  if preview.layout == "unified" then
    preview.unified_view = save_view(preview.before_win)
    toggled = show_side_by_side(preview)
  else
    toggled = show_unified(preview)
  end

  if not toggled then
    if vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
    return false
  end

  set_preferred_layout(preview.layout)
  if focused_outside_preview and vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
  elseif preview.layout == "side_by_side" and focused_proposed then
    vim.api.nvim_set_current_win(preview.proposed_win)
  else
    vim.api.nvim_set_current_win(preview.before_win)
  end

  return true
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

  diffoff(preview.before_win)
  diffoff(preview.proposed_win)
  clear_inline_preview(preview)

  -- Close the extra split created by the side-by-side layout.
  if preview.proposed_win and vim.api.nvim_win_is_valid(preview.proposed_win) then
    pcall(vim.api.nvim_win_close, preview.proposed_win, true)
  end

  -- Put the real editor buffer and its previous view back in the reused window.
  if preview.before_win and vim.api.nvim_win_is_valid(preview.before_win) then
    vim.api.nvim_win_set_var(preview.before_win, "pi_diff_preview", false)
    vim.api.nvim_win_set_buf(preview.before_win, restore.buf)
    vim.wo[preview.before_win].winbar = restore.winbar
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
    vim.notify("Pi diff preview: invalid RPC payload", vim.log.levels.ERROR)
    return false
  end

  local pi_terminal_win = require_pi_terminal_window()
  local target = find_review_target()
  if not target then
    vim.notify("Pi diff preview: no normal editor window is available", vim.log.levels.ERROR)
    return false
  end

  -- Remove an older proposal before reusing the editor area.
  M.close()

  -- Remember the target window's state so M.close() can restore it later.
  local restore = {
    buf = vim.api.nvim_win_get_buf(target),
    view = vim.api.nvim_win_call(target, vim.fn.winsaveview),
    winbar = vim.wo[target].winbar,
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
      layout = "side_by_side",
    },
    restore = restore,
  }

  show_side_by_side(active_display.preview)
  if preferred_layout == "unified" then
    show_unified(active_display.preview)
  end

  local preview_rows, viewport_rows = preview_geometry(active_display.preview)
  if vim.g.pi_diff_preview_enforce_fit ~= false and preview_rows > viewport_rows then
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
