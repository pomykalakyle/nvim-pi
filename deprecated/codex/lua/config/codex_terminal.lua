-- Deprecated Codex-only implementation retained for migration reference.
--[=[
local M = {}

local terminal_slot_keys = {
  { "[", "<cmd>CodexTerminalPrevious<cr>", mode = { "n", "t" }, desc = "Codex: Previous terminal" },
  { "]", "<cmd>CodexTerminalNext<cr>", mode = { "n", "t" }, desc = "Codex: Next terminal" },
  { "<Bslash>n", "<cmd>CodexTerminalNew<cr>", desc = "Codex: Add terminal" },
  { "<Bslash>x", "<cmd>CodexTerminalClose<cr>", desc = "Codex: Close terminal" },
  { "<Bslash>m", "<cmd>CodexMaximizeToggle<cr>", desc = "Codex: Toggle modal" },
  { "<Bslash>q", "<cmd>Codex<cr>", desc = "Codex: Hide" },
}

for slot = 1, 9 do
  terminal_slot_keys[#terminal_slot_keys + 1] = {
    "<Bslash>" .. slot,
    "<cmd>CodexTerminalSelect " .. slot .. "<cr>",
    desc = "Codex: Terminal " .. slot,
  }
end

--- Reports whether the active Codex terminal has a visible window.
function M.active_terminal_visible()
  local terminal = require("codex.terminal")
  local bufnr = terminal.get_active_terminal_bufnr()
  return bufnr ~= nil and #vim.fn.win_findbuf(bufnr) > 0
end

--- Scrolls the current window by half a page in the given direction.
local function scroll_current_window_half_page(direction)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local height = vim.api.nvim_win_get_height(win)
  -- Convert the direction into a signed half-window distance.
  local lines = direction * math.max(1, math.floor(height / 2))
  -- Keep the viewport within the buffer, including near its final lines.
  local max_topline = math.max(1, line_count - height + 1)
  local current_topline = vim.fn.line("w0")
  local target_topline = math.max(1, math.min(max_topline, current_topline + lines))
  local target_bottom = math.min(line_count, target_topline + height - 1)
  local cursor = vim.api.nvim_win_get_cursor(win)
  -- Move the cursor with the viewport while keeping it on-screen.
  local target_cursor = math.max(target_topline, math.min(target_bottom, cursor[1] + lines))

  vim.api.nvim_win_set_cursor(win, { target_cursor, cursor[2] })
  local view = vim.fn.winsaveview()
  view.topline = target_topline
  view.lnum = target_cursor
  vim.fn.winrestview(view)
end

--- Leaves terminal insert mode if the current mode is terminal.
local function stop_terminal_insert_mode()
  if vim.fn.mode():sub(1, 1) == "t" then
    vim.cmd.stopinsert()
  end
end

--- Re-enters terminal input and sends a literal space to the active job.
local function resume_terminal_with_space(buf)
  vim.cmd.startinsert()
  local job_id = vim.b[buf].terminal_job_id
  if job_id then
    vim.api.nvim_chan_send(job_id, " ")
  end
end

--- Scrolls unfocused visible Codex windows to the latest terminal output.
local function follow_codex_output(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) and win ~= current_win then
      local last_line = vim.api.nvim_buf_line_count(buf)
      vim.api.nvim_win_set_cursor(win, { last_line, 0 })
    end
  end
end

--- Attaches a coalesced output listener that follows Codex only while it is unfocused.
local function attach_output_follow(buf)
  if vim.b[buf].codex_output_follow_attached then
    return
  end

  vim.b[buf].codex_output_follow_attached = true
  local scheduled = false
  vim.api.nvim_buf_attach(buf, false, {
    --- Schedules one output-follow update after the current buffer change completes.
    on_lines = function()
      if scheduled then
        return
      end

      scheduled = true
      --- Runs the coalesced output-follow update outside the buffer callback.
      vim.schedule(function()
        scheduled = false
        follow_codex_output(buf)
      end)
    end,
  })
end

--- Installs terminal-specific keymaps and output following for the active Codex buffer.
function M.attach_active_terminal()
  local terminal = require("codex.terminal")
  local buf = terminal.get_active_terminal_bufnr()
  if not buf then
    return false
  end

  for _, mapping in ipairs(terminal_slot_keys) do
    vim.keymap.set(mapping.mode or "t", mapping[1], mapping[2], {
      buffer = buf,
      silent = true,
      desc = mapping.desc,
    })
  end

  --- Treats Space as terminal input instead of LazyVim's leader after scrolling.
  vim.keymap.set("n", "<Space>", function()
    resume_terminal_with_space(buf)
  end, {
    buffer = buf,
    silent = true,
    desc = "Codex: Resume input with space",
  })

  --- Scrolls Codex down by half the visible window height.
  vim.keymap.set({ "n", "t" }, "<F18>", function()
    stop_terminal_insert_mode()
    scroll_current_window_half_page(1)
  end, {
    buffer = buf,
    silent = true,
    desc = "Codex scroll down",
  })

  --- Scrolls Codex up by half the visible window height.
  vim.keymap.set({ "n", "t" }, "<F19>", function()
    stop_terminal_insert_mode()
    scroll_current_window_half_page(-1)
  end, {
    buffer = buf,
    silent = true,
    desc = "Codex scroll up",
  })

  attach_output_follow(buf)
  return true
end

return M
]=]
