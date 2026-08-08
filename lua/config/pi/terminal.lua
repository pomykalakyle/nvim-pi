-- Owns the interactive Pi TUI terminal and its Neovim window lifecycle.

local M = {}

-- Keep interactive terminals independent of later working-directory changes.
local interactive_terminal = nil
local terminals = {}

--- Builds the Pi command used for a normal continuation or one-time fork.
local function terminal_command(arguments)
  local command = { vim.fn.expand("~/.config/pi/launch.zsh") }
  vim.list_extend(command, arguments or { "--continue" })
  return command
end

--- Normalizes the project directory used to identify a Pi terminal.
local function normalize_cwd(cwd)
  return vim.fn.resolve(vim.fn.fnamemodify(cwd or vim.fn.getcwd(), ":p")):gsub("/$", "")
end

--- Returns the Snacks terminal options for an interactive Pi session.
local function terminal_options(cwd, env)
  return {
    cwd = normalize_cwd(cwd),
    env = env,
    interactive = true,
    auto_close = false,
    win = {
      -- Edgy recognizes this buffer and moves it into the left edgebar.
      position = "right",
      width = 0.4,
      b = {
        pi_terminal = true,
      },
      wo = {
        winfixwidth = true,
      },
    },
  }
end

--- Scrolls the current terminal window by half its visible height.
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

--- Leaves terminal-input mode before manipulating Neovim's scrollback.
local function stop_terminal_insert_mode()
  if vim.fn.mode():sub(1, 1) == "t" then
    vim.cmd.stopinsert()
  end
end

--- Re-enters Pi input and forwards the Space used to resume typing.
local function resume_terminal_with_space(buf)
  vim.cmd.startinsert()
  local job_id = vim.b[buf].terminal_job_id
  if job_id then
    vim.api.nvim_chan_send(job_id, " ")
  end
end

--- Installs carrier-key mappings once for a Pi terminal buffer.
local function attach_terminal_keymaps(terminal)
  if not terminal:buf_valid() or vim.b[terminal.buf].pi_terminal_keymaps_attached then
    return
  end

  vim.b[terminal.buf].pi_terminal_keymaps_attached = true
  vim.keymap.set({ "n", "t" }, "<F18>", function()
    stop_terminal_insert_mode()
    scroll_current_window_half_page(1)
  end, {
    buffer = terminal.buf,
    silent = true,
    desc = "Pi: Scroll down half a page",
  })
  vim.keymap.set({ "n", "t" }, "<F19>", function()
    stop_terminal_insert_mode()
    scroll_current_window_half_page(-1)
  end, {
    buffer = terminal.buf,
    silent = true,
    desc = "Pi: Scroll up half a page",
  })
  vim.keymap.set({ "n", "t" }, "<F17>", function()
    local job_id = vim.b[terminal.buf].terminal_job_id
    if job_id then
      vim.api.nvim_chan_send(job_id, "/back\r")
    end
  end, {
    buffer = terminal.buf,
    silent = true,
    desc = "Pi: Abort and restore previous prompt",
  })
  vim.keymap.set("n", "<Space>", function()
    resume_terminal_with_space(terminal.buf)
  end, {
    buffer = terminal.buf,
    silent = true,
    desc = "Pi: Resume input with space",
  })
end

--- Focuses a visible Pi terminal and enters terminal input mode.
local function focus_terminal(terminal)
  if terminal and terminal:win_valid() then
    terminal:focus()
    vim.cmd.startinsert()
  end
end

--- Opens and focuses the interactive Pi terminal for a project directory.
function M.open(cwd, arguments, env)
  local root = normalize_cwd(cwd)
  local terminal, created = terminals[root], false
  if arguments and terminal and terminal:buf_valid() then
    error("A Pi terminal already exists for this worktree")
  end
  if not (terminal and terminal:buf_valid()) then
    terminal, created = Snacks.terminal.get(terminal_command(arguments), terminal_options(root, env))
    terminals[root] = terminal
    attach_terminal_keymaps(terminal)
  end
  if not created then
    terminal:show()
  end
  focus_terminal(terminal)
  interactive_terminal = terminal
  return terminal
end

--- Focuses the existing interactive Pi terminal without creating another one.
function M.focus_existing()
  local terminal = terminals[normalize_cwd()] or interactive_terminal
  if not (terminal and terminal:buf_valid()) then
    return false
  end
  if not terminal:win_valid() then
    terminal:show()
  end
  focus_terminal(terminal)
  interactive_terminal = terminal
  return true
end

--- Toggles the interactive Pi terminal for the current project.
function M.toggle()
  local root = normalize_cwd()
  local terminal, created = terminals[root], false
  if not (terminal and terminal:buf_valid()) then
    terminal, created = Snacks.terminal.get(terminal_command(), terminal_options(root))
    terminals[root] = terminal
    attach_terminal_keymaps(terminal)
  end
  interactive_terminal = terminal
  if not created then
    terminal:toggle()
  end
  focus_terminal(terminal)
  return terminal
end

--- Shows and focuses the interactive Pi terminal for the current project.
function M.focus()
  return M.open()
end

--- Stops the interactive Pi process for the current project.
function M.stop(cwd)
  local root = normalize_cwd(cwd)
  local terminal = terminals[root]
  if not (terminal and terminal:buf_valid()) then
    return false
  end
  terminal:close()
  terminals[root] = nil
  if interactive_terminal == terminal then
    interactive_terminal = nil
  end
  return true
end

--- Reports whether the current project's Pi terminal is visible.
function M.is_visible()
  local terminal = terminals[normalize_cwd()]
  return terminal ~= nil and terminal:buf_valid() and terminal:win_valid()
end

return M
