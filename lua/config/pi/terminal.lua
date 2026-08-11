-- Creates and controls Pi terminal processes owned by workspaces.

local M = {}

---Builds the Pi command used for a normal continuation or one-time session fork.
--- Reviewed: false.
local function terminal_command(arguments)
  local command = { vim.fn.expand("~/.config/pi/launch.zsh") }
  vim.list_extend(command, arguments or { "--continue" })
  return command
end

---Returns the Snacks options for an independent workspace terminal.
--- Reviewed: false.
local function terminal_options(cwd, env, workspace_id)
  return {
    cwd = cwd,
    env = env,
    count = workspace_id,
    interactive = true,
    auto_close = false,
    win = {
      position = "right",
      width = 0.4,
      b = {
        pi_terminal = true,
        pi_workspace_id = workspace_id,
      },
      wo = {
        winbar = "%{get(b:, 'pi_terminal_title', 'Pi')}",
        winfixwidth = true,
      },
    },
  }
end

---Scrolls the current terminal window by half its visible height.
--- Reviewed: false.
local function scroll_current_window_half_page(direction)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local height = vim.api.nvim_win_get_height(win)
  local lines = direction * math.max(1, math.floor(height / 2))
  local max_topline = math.max(1, line_count - height + 1)
  local current_topline = vim.fn.line("w0")
  local target_topline = math.max(1, math.min(max_topline, current_topline + lines))
  local target_bottom = math.min(line_count, target_topline + height - 1)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local target_cursor = math.max(target_topline, math.min(target_bottom, cursor[1] + lines))

  vim.api.nvim_win_set_cursor(win, { target_cursor, cursor[2] })
  local view = vim.fn.winsaveview()
  view.topline = target_topline
  view.lnum = target_cursor
  vim.fn.winrestview(view)
end

---Leaves terminal-input mode before manipulating Neovim's scrollback.
--- Reviewed: false.
local function stop_terminal_insert_mode()
  if vim.fn.mode():sub(1, 1) == "t" then
    vim.cmd.stopinsert()
  end
end

---Re-enters Pi input and forwards the Space used to resume typing.
--- Reviewed: false.
local function resume_terminal_with_space(buf)
  vim.cmd.startinsert()
  local job_id = vim.b[buf].terminal_job_id
  if job_id then
    vim.api.nvim_chan_send(job_id, " ")
  end
end

---Installs terminal and workspace controls on one Pi terminal buffer.
--- Reviewed: false.
local function attach_terminal_keymaps(terminal)
  if not terminal:buf_valid() or vim.b[terminal.buf].pi_terminal_keymaps_attached then
    return
  end

  vim.b[terminal.buf].pi_terminal_keymaps_attached = true
  vim.keymap.set({ "n", "t" }, "<F18>", --[[ Reviewed: false. ]] function()
    stop_terminal_insert_mode()
    scroll_current_window_half_page(1)
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Scroll down half a page" })
  vim.keymap.set({ "n", "t" }, "<F19>", --[[ Reviewed: false. ]] function()
    stop_terminal_insert_mode()
    scroll_current_window_half_page(-1)
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Scroll up half a page" })
  vim.keymap.set({ "n", "t" }, "<F17>", --[[ Reviewed: false. ]] function()
    local job_id = vim.b[terminal.buf].terminal_job_id
    if job_id then
      vim.api.nvim_chan_send(job_id, "/back\r")
    end
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Abort and restore previous prompt" })
  vim.keymap.set("n", "<Space>", --[[ Reviewed: false. ]] function()
    resume_terminal_with_space(terminal.buf)
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Resume input with space" })
  vim.keymap.set({ "n", "t" }, "[", --[[ Reviewed: false. ]] function()
    require("config.pi.workspace").cycle(-1)
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Previous workspace" })
  vim.keymap.set({ "n", "t" }, "]", --[[ Reviewed: false. ]] function()
    require("config.pi.workspace").cycle(1)
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Next workspace" })
  vim.keymap.set({ "n", "t" }, "\\n", --[[ Reviewed: false. ]] function()
    require("config.pi.workspace").create(nil, {})
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Add workspace" })
  vim.keymap.set({ "n", "t" }, "\\x", --[[ Reviewed: false. ]] function()
    require("config.pi.workspace").stop()
  end, { buffer = terminal.buf, silent = true, desc = "Pi: Close workspace" })
  for index = 1, 9 do
    local slot = index
    vim.keymap.set({ "n", "t" }, "\\" .. slot, --[[ Reviewed: false. ]] function()
      require("config.pi.workspace").switch(slot)
    end, { buffer = terminal.buf, silent = true, desc = "Pi: Workspace " .. slot })
  end
end

---Starts a Pi process for a workspace without registering or focusing it.
--- Reviewed: false.
function M.spawn(root, arguments, env, workspace_id)
  local terminal = Snacks.terminal.get(terminal_command(arguments), terminal_options(root, env, workspace_id))
  if not (terminal and terminal:buf_valid()) then
    return nil
  end
  attach_terminal_keymaps(terminal)
  return terminal
end

---Focuses a visible terminal instance and enters terminal-input mode.
--- Reviewed: false.
function M.focus_instance(terminal)
  if terminal and terminal:win_valid() then
    terminal:focus()
    vim.cmd.startinsert()
  end
end

---Opens or focuses the workspace in the current tab.
--- Reviewed: false.
function M.open(cwd, arguments, env)
  return require("config.pi.workspace").open(cwd, arguments, env)
end

---Creates a workspace while preserving the former terminal API name.
--- Reviewed: false.
function M.create_session(cwd, arguments, env)
  return require("config.pi.workspace").create(cwd, arguments, env)
end

---Switches workspaces while preserving the former terminal API name.
--- Reviewed: false.
function M.switch_to_session(index)
  return require("config.pi.workspace").switch(index)
end

---Cycles workspaces while preserving the former terminal API name.
--- Reviewed: false.
function M.cycle_session(direction)
  return require("config.pi.workspace").cycle(direction)
end

---Focuses the current or most recently active workspace.
--- Reviewed: false.
function M.focus_existing()
  return require("config.pi.workspace").focus_existing()
end

---Toggles the current workspace's Pi terminal.
--- Reviewed: false.
function M.toggle()
  return require("config.pi.workspace").toggle()
end

---Shows and focuses Pi in the current workspace.
--- Reviewed: false.
function M.focus()
  return require("config.pi.workspace").focus()
end

---Stops the current workspace and closes its native tab.
--- Reviewed: false.
function M.stop()
  return require("config.pi.workspace").stop()
end

---Reports whether the current workspace's Pi terminal is visible.
--- Reviewed: false.
function M.is_visible()
  return require("config.pi.workspace").is_visible()
end

---Lists workspaces while preserving the former terminal API name.
--- Reviewed: false.
function M.list_sessions()
  return require("config.pi.workspace").list()
end

---Returns the workspace header used by Snacks and Edgy.
--- Reviewed: false.
function M.workspace_title(win)
  return require("config.pi.workspace").title(win)
end

return M
