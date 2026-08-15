-- Coordinates read-only Pi edit proposals while approval remains in the Pi terminal.

local M = {}

local display = require("config.pi.diff_preview.display")
local proposal = require("config.pi.diff_preview.proposal")
local window_focus = require("config.pi.window_focus")

local active_displays = {}
local preferred_layout = vim.g.pi_diff_preview_layout == "side_by_side" and "side_by_side" or "unified"

---Remember the selected layout for subsequent previews in this Neovim session.
--- Reviewed: false.
local function set_preferred_layout(layout)
  preferred_layout = layout
  vim.g.pi_diff_preview_layout = layout
end

---Close one workspace's preview and release its editor resources.
--- Reviewed: false.
local function close_display(workspace, tool_call_id)
  local active = active_displays[workspace.id]
  if not active then
    return true
  end
  if tool_call_id and tool_call_id ~= "" and active.tool_call_id ~= tool_call_id then
    return false
  end

  -- Claim this workspace's display before cleanup so another close cannot process it again.
  active_displays[workspace.id] = nil
  display.close(active.preview, active.restore)
  return true
end

---Toggle the active proposal between side-by-side and unified layouts.
--- Reviewed: false.
function M.toggle_layout()
  local workspace = require("config.pi.workspace").current()
  local active = workspace and active_displays[workspace.id]
  local preview = active and active.preview
  if not preview or not preview.before_win or not vim.api.nvim_win_is_valid(preview.before_win) then
    error("Pi diff preview: no active preview", 0)
  end

  local original_win = vim.api.nvim_get_current_win()
  local focused_proposed = original_win == preview.proposed_win
  local focused_outside_preview = original_win ~= preview.before_win and not focused_proposed
  local toggled, toggle_error = pcall(display.toggle_layout, preview)

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

---Close the preview owned by the requesting Pi process.
--- Reviewed: false.
function M.close(requester_pid, tool_call_id)
  local workspace = require("config.pi.workspace").for_process(requester_pid)
  if not workspace then
    for _, active in pairs(active_displays) do
      if active.requester_pid == requester_pid then
        workspace = active.workspace
        break
      end
    end
  end
  if not workspace then
    return false
  end

  local closed = close_display(workspace, tool_call_id)
  if closed and vim.api.nvim_get_current_tabpage() == workspace.tabpage then
    local found, terminal_win = pcall(display.require_terminal_window, workspace)
    if found then
      window_focus.focus_terminal(terminal_win)
    end
  end
  return closed
end

---Close the preview owned by one workspace during workspace teardown.
--- Reviewed: false.
function M.close_workspace_preview(workspace_id, tool_call_id)
  local active = active_displays[workspace_id]
  return active and close_display(active.workspace, tool_call_id) or true
end

---Report whether reloading the preview modules would discard active state.
--- Reviewed: false.
function M.has_active_previews()
  return next(active_displays) ~= nil
end

---Reload the preview modules only when no workspace owns active state.
--- Reviewed: false.
function M.reload_if_idle()
  if M.has_active_previews() then
    return false
  end
  for _, module_name in ipairs({
    "config.pi.diff_preview",
    "config.pi.diff_preview.codediff",
    "config.pi.diff_preview.display",
    "config.pi.diff_preview.proposal",
  }) do
    package.loaded[module_name] = nil
  end
  require("config.pi.diff_preview")
  return true
end

---Open a read-only preview in the requesting Pi workspace and return focus to its terminal.
--- Reviewed: false.
function M.open(payload)
  if not proposal.is_valid(payload) then
    local message = "Pi diff preview requires a requester process and valid nonempty unfolded_ranges"
    vim.notify(message, vim.log.levels.ERROR)
    return {
      ok = false,
      reason = "preview_invalid_request",
      message = message,
    }
  end

  local workspace = require("config.pi.workspace").for_process(payload.requester_pid)
  if not workspace then
    return {
      ok = false,
      reason = "workspace_unavailable",
      message = "The requesting Pi workspace is unavailable",
      file_path = payload.file_path,
    }
  end
  local pi_terminal_win = display.require_terminal_window(workspace)

  -- Revisions replace only this workspace's previous proposal.
  close_display(workspace)
  local target = display.find_review_target(workspace.tabpage)
  if not target then
    vim.notify("Pi diff preview: no normal editor window is available", vim.log.levels.ERROR)
    return false
  end

  local visible_ranges, visibility_error = proposal.build_visible_ranges(payload)
  if not visible_ranges then
    return {
      ok = false,
      reason = visibility_error.reason,
      message = visibility_error.message,
      file_path = payload.file_path,
    }
  end

  local restore = display.capture_target(target)
  local basename = vim.fn.fnamemodify(payload.file_path, ":t")
  if basename == "" then
    basename = "file"
  end

  local preview_before_buf = display.make_buffer(
    ("pi://proposal/%s/%s/original/%s"):format(workspace.id, payload.tool_call_id, basename),
    payload.file_path,
    proposal.split_lines(payload.old_content),
    M.toggle_layout
  )
  local preview_proposed_buf = display.make_buffer(
    ("pi://proposal/%s/%s/proposed/%s"):format(workspace.id, payload.tool_call_id, basename),
    payload.file_path,
    proposal.split_lines(payload.new_content),
    M.toggle_layout
  )

  local active = {
    requester_pid = payload.requester_pid,
    tool_call_id = payload.tool_call_id,
    workspace = workspace,
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
  active_displays[workspace.id] = active

  local displayed, display_error = pcall(--[[ Reviewed: false. ]] function()
    if preferred_layout == "unified" then
      display.show_unified(active.preview)
    else
      display.show_side_by_side(active.preview)
    end
  end)
  if not displayed then
    close_display(workspace, payload.tool_call_id)
    return {
      ok = false,
      reason = "preview_render_failed",
      message = "CodeDiff failed to render the preview: " .. tostring(display_error),
      file_path = payload.file_path,
    }
  end

  local preview_rows, viewport_rows = display.geometry(active.preview)
  if preview_rows > viewport_rows then
    close_display(workspace, payload.tool_call_id)
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

  window_focus.focus_terminal(pi_terminal_win)
  return {
    ok = true,
    file_path = payload.file_path,
    preview_rows = preview_rows,
    viewport_rows = viewport_rows,
  }
end

M.refresh = display.refresh

vim.api.nvim_create_user_command("PiDiffToggle", M.toggle_layout, {
  desc = "Toggle the active Pi proposal diff layout",
  force = true,
})

return M
