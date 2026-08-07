-- Deprecated Codex-only implementation retained for migration reference.
--[=[
local M = {}
local git_worktree = require("config.git_worktree")

local MAX_SLOTS = 9
local SUBMIT_KEY_DELAY_MS = 200

local state = {
  active = nil,
  activation_counter = 0,
  closing_all = false,
  config = nil,
  force_focus = nil,
  force_new = false,
  maximized = false,
  next_terminal_id = 1,
  port = nil,
  project_root = nil,
  slots = {},
}

--- Displays a Codex terminal message.
local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Codex terminals" })
end

--- Redraws the Edgy winbar after terminal-slot state changes.
local function redraw_title()
  pcall(vim.cmd, "redrawstatus")
end

--- Starts terminal insert mode in the current window.
local function start_insert()
  vim.cmd.startinsert()
end

--- Sends the carriage return used by Codex's multiline terminal mapping.
local function send_carriage_return()
  vim.api.nvim_feedkeys("\r", "t", true)
end

--- Inserts a newline into the Codex prompt without submitting it.
local function insert_codex_newline()
  vim.api.nvim_feedkeys("\\", "t", true)
  vim.defer_fn(send_carriage_return, 10)
end

--- Normalizes a directory for project-root comparisons.
local function normalize_directory(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/$", "")
end

--- Resolves a directory to its containing Git root or normalized path.
local function resolve_project_root(path)
  return git_worktree.common_dir(path) or normalize_directory(path)
end

--- Returns the currently selected terminal slot.
local function active_slot()
  return state.active and state.slots[state.active] or nil
end

--- Marks one slot as the most recently active terminal.
local function activate_slot(index)
  state.active = index
  state.activation_counter = state.activation_counter + 1
  if state.slots[index] then
    state.slots[index].last_active = state.activation_counter
  end
end

--- Reports whether a terminal slot still owns a valid buffer.
local function slot_is_valid(slot)
  return slot
    and slot.terminal
    and type(slot.terminal.buf_valid) == "function"
    and slot.terminal:buf_valid()
    and slot.bufnr
    and vim.api.nvim_buf_is_valid(slot.bufnr)
end

--- Reports whether a terminal slot currently has a visible window.
local function slot_is_visible(slot)
  return slot_is_valid(slot) and slot.terminal:win_valid()
end

--- Finds a terminal slot by its immutable internal identifier.
local function find_slot_index_by_id(slot_id)
  for index, slot in ipairs(state.slots) do
    if slot.id == slot_id then
      return index
    end
  end
  return nil
end

--- Notifies Hands-Free Mode that an immutable terminal slot was lost.
local function notify_slot_lost(slot_id)
  local loaded, handsfree = pcall(require, "config.codex_handsfree")
  if loaded and type(handsfree.on_terminal_lost) == "function" then
    handsfree.on_terminal_lost(slot_id)
  end
end

--- Closes only a slot's window while preserving its terminal process.
local function close_slot_window(slot)
  if not slot or not slot.terminal then
    return
  end

  require("codex.terminal.window").close_window(slot.terminal.win)
  slot.terminal.win = nil
end

--- Attaches local scrolling and output-follow behavior to the active slot.
local function attach_active_terminal()
  require("config.codex_terminal").attach_active_terminal()
end

--- Refreshes Edgy's layout after a terminal window changes.
local function refresh_edgy_layout()
  local ok, layout = pcall(require, "edgy.layout")
  if ok then
    layout.update()
  end
end

--- Shows a terminal slot in the current pane mode and optionally focuses it.
local function show_slot(slot, focus)
  if not slot_is_valid(slot) then
    return false
  end

  focus = focus ~= false
  if slot_is_visible(slot) then
    if focus then
      slot.terminal:focus()
      if slot.terminal.win and vim.api.nvim_win_is_valid(slot.terminal.win) then
        vim.api.nvim_win_call(slot.terminal.win, start_insert)
      end
    end
    attach_active_terminal()
    redraw_title()
    return true
  end

  local config = slot.config or state.config
  if not config then
    return false
  end

  local terminal_window = require("codex.terminal.window")
  if state.maximized then
    slot.terminal.win = terminal_window.open_existing_buffer_in_float(slot.bufnr, config, focus)
  else
    slot.terminal.win = terminal_window.open_existing_buffer_in_split(slot.bufnr, config, focus)
  end

  refresh_edgy_layout()
  attach_active_terminal()
  redraw_title()
  return slot.terminal.win ~= nil
end

--- Keeps focus on a selected terminal while asynchronous layout work settles.
local function stabilize_slot_focus(slot)
  local slot_id = slot.id

  --- Refocuses the target only while it remains the active terminal slot.
  local function refocus()
    local active = active_slot()
    if not active or active.id ~= slot_id or not slot_is_visible(active) then
      return
    end
    active.terminal:focus()
    vim.api.nvim_win_call(active.terminal.win, start_insert)
  end

  refocus()
  vim.schedule(refocus)
  vim.defer_fn(refocus, 100)
end

--- Shows the active slot after an asynchronous buffer cleanup.
local function show_active_after_cleanup()
  local slot = active_slot()
  if slot then
    show_slot(slot, true)
  end
end

--- Removes a terminal slot from state and selects its nearest neighbor.
local function remove_slot_by_id(slot_id)
  local index = find_slot_index_by_id(slot_id)
  if not index then
    return false
  end

  local was_active = state.active == index
  table.remove(state.slots, index)

  if #state.slots == 0 then
    state.active = nil
    state.maximized = false
  elseif was_active then
    state.active = math.min(index, #state.slots)
  elseif state.active and index < state.active then
    state.active = state.active - 1
  end

  redraw_title()
  if was_active and not state.closing_all and state.active then
    vim.schedule(show_active_after_cleanup)
  end
  return true
end

--- Marks an exited terminal while retaining its buffer and numbered slot.
local function mark_slot_exited(slot_id)
  local index = find_slot_index_by_id(slot_id)
  if index then
    state.slots[index].exited = true
    redraw_title()
  end
  notify_slot_lost(slot_id)
end

--- Closes every terminal slot without selecting replacements.
local function close_all_slots()
  if #state.slots == 0 then
    state.active = nil
    state.maximized = false
    return
  end

  local slots = state.slots
  state.closing_all = true
  state.slots = {}
  state.active = nil
  state.maximized = false
  state.port = nil

  for _, slot in ipairs(slots) do
    notify_slot_lost(slot.id)
    close_slot_window(slot)
    if slot.terminal and slot.terminal:buf_valid() then
      slot.terminal:close()
    end
  end

  state.closing_all = false
  redraw_title()
end

--- Closes old-project terminals and records the newly active project root.
local function update_project_root(cwd)
  local root = resolve_project_root(cwd or vim.fn.getcwd())
  if state.project_root and root and state.project_root ~= root then
    close_all_slots()
  end
  state.project_root = root
  return root
end

--- Builds Snacks window options for one Codex terminal slot.
local function build_window_options(config)
  return vim.tbl_deep_extend("force", {
    position = config.split_side,
    width = config.split_width_percentage,
    height = 0,
    relative = "editor",
    keys = {
      codex_new_line = {
        "<S-CR>",
        insert_codex_newline,
        mode = "t",
        desc = "New line",
      },
    },
  }, config.snacks_win_opts or {})
end

--- Creates and activates one independent Snacks terminal.
local function create_slot(cmd_string, env_table, config, focus, insert_index)
  if #state.slots >= MAX_SLOTS then
    notify("All nine Codex terminal slots are in use", vim.log.levels.WARN)
    return false
  end

  local previous_slot = active_slot()
  local previous_win = vim.api.nvim_get_current_win()
  if previous_slot then
    close_slot_window(previous_slot)
  end

  local terminal_id = state.next_terminal_id
  state.next_terminal_id = state.next_terminal_id + 1
  focus = focus ~= false
  local slot_env = vim.deepcopy(env_table)
  slot_env.CODEX_NVIM_SLOT_ID = tostring(terminal_id)

  local terminal = Snacks.terminal.open(cmd_string, {
    count = terminal_id,
    cwd = config.cwd or vim.fn.getcwd(),
    env = slot_env,
    start_insert = focus,
    auto_insert = focus,
    auto_close = false,
    win = build_window_options(config),
  })

  if not terminal or not terminal:buf_valid() then
    if previous_slot then
      show_slot(previous_slot, true)
    end
    notify("Failed to create a Codex terminal", vim.log.levels.ERROR)
    return false
  end

  local slot = {
    bufnr = terminal.buf,
    command = cmd_string,
    config = vim.deepcopy(config),
    env = slot_env,
    exited = false,
    id = terminal_id,
    worktree = git_worktree.root(config.cwd or vim.fn.getcwd()) or normalize_directory(config.cwd or vim.fn.getcwd()),
    terminal = terminal,
  }
  local slot_index = insert_index or (#state.slots + 1)
  table.insert(state.slots, slot_index, slot)
  activate_slot(slot_index)
  state.port = slot_env.CODEX_CODE_SSE_PORT

  require("codex.terminal.buffer").mark_terminal_buffer(terminal.buf, config)
  vim.b[terminal.buf].codex_terminal_slot_id = terminal_id

  --- Retains terminal output when its Codex process exits.
  local function handle_terminal_exit()
    if slot.restarting then
      local restart_callback = slot.restart_callback
      slot.restart_callback = nil
      if restart_callback then
        vim.schedule(restart_callback)
      end
      return
    end
    mark_slot_exited(terminal_id)
  end

  --- Removes slot state when its terminal buffer is wiped externally.
  local function handle_terminal_wipeout()
    if slot.restarting then
      return
    end
    remove_slot_by_id(terminal_id)
  end

  terminal:on("TermClose", handle_terminal_exit, { buf = true })
  terminal:on("BufWipeout", handle_terminal_wipeout, { buf = true })

  if not focus and vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end

  refresh_edgy_layout()
  attach_active_terminal()
  redraw_title()
  return true
end

--- Requests a fresh slot through codex.nvim so its command and IDE environment stay authoritative.
local function request_new_slot(focus)
  if #state.slots >= MAX_SLOTS then
    notify("All nine Codex terminal slots are in use", vim.log.levels.WARN)
    return false
  end

  state.force_new = true
  state.force_focus = focus ~= false
  local terminal = require("codex.terminal")
  local ok, error_message = pcall(terminal.open, {}, nil)
  state.force_new = false
  state.force_focus = nil

  if not ok then
    notify("Failed to create a Codex terminal: " .. tostring(error_message), vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Ensures an active terminal exists and is visible without stealing editor focus.
local function ensure_active_for_send()
  if not active_slot() and not request_new_slot(false) then
    return false
  end

  local slot = active_slot()
  return slot ~= nil and show_slot(slot, false)
end

--- Formats a file path and optional zero-based range as a Codex mention.
local function format_at_mention(file_path, start_line, end_line)
  local codex = require("codex")
  local formatted_path = file_path
  if type(codex._format_path_for_at_mention) == "function" then
    local ok, path = pcall(codex._format_path_for_at_mention, file_path)
    if ok and type(path) == "string" and path ~= "" then
      formatted_path = path
    end
  end

  local mention = "@" .. formatted_path
  local range = require("codex.mention").format_range(start_line, end_line)
  if range ~= "" then
    mention = mention .. ":" .. range
  end
  return mention
end

--- Inserts one or more file mentions into only the active Codex terminal.
local function send_file_mentions(file_paths)
  if not file_paths or #file_paths == 0 then
    notify("No files selected", vim.log.levels.WARN)
    return false
  end
  if not ensure_active_for_send() then
    return false
  end

  local mentions = {}
  for _, file_path in ipairs(file_paths) do
    mentions[#mentions + 1] = format_at_mention(file_path)
  end
  return require("codex.terminal").send(table.concat(mentions, " ") .. " ", { submit = false })
end

--- Sends a visual line range and its text to only the active Codex terminal.
local function send_visual_range(line1, line2)
  local selection = require("codex.selection").get_range_selection(line1, line2)
  if not selection or not selection.selection or selection.selection.isEmpty then
    notify("No visual selection to send", vim.log.levels.WARN)
    return false
  end
  if not ensure_active_for_send() then
    return false
  end

  local start_line = selection.selection.start and selection.selection.start.line or nil
  local end_line = selection.selection["end"] and selection.selection["end"].line or nil
  local payload = format_at_mention(selection.filePath, start_line, end_line)
  if type(selection.text) == "string" and selection.text ~= "" then
    payload = payload .. "\n" .. selection.text
  end
  return require("codex.terminal").send(payload, { submit = true })
end

--- Returns the selected paths from the current tree buffer.
local function selected_tree_files()
  local files, error_message = require("codex.integrations").get_selected_files_from_tree()
  if error_message then
    notify(error_message, vim.log.levels.ERROR)
    return {}
  end
  return files or {}
end

--- Adds the currently selected tree path to the active Codex terminal.
local function handle_tree_add_normal()
  send_file_mentions(selected_tree_files())
end

--- Adds visually selected tree paths to the active Codex terminal.
local function handle_tree_add_visual(visual_data)
  local files, error_message = require("codex.visual_commands").get_files_from_visual_selection(visual_data)
  if error_message then
    notify(error_message, vim.log.levels.ERROR)
    return
  end
  send_file_mentions(files)
end

--- Sends a command range or selected tree path to the active Codex terminal.
local function handle_send_normal(opts)
  if vim.bo.filetype == "neo-tree" or vim.bo.filetype == "oil" then
    handle_tree_add_normal()
    return
  end
  send_visual_range(opts.line1, opts.line2)
end

--- Sends a visual text or tree selection to the active Codex terminal.
local function handle_send_visual(visual_data, opts)
  if visual_data and visual_data.tree_type then
    handle_tree_add_visual(visual_data)
    return
  end

  local line1 = visual_data and visual_data.start_pos or opts.line1
  local line2 = visual_data and visual_data.end_pos or opts.line2
  send_visual_range(line1, line2)
end

--- Adds an explicitly named file and optional line range to the active terminal.
local function handle_codex_add(opts)
  local args = vim.split(opts.args or "", "%s+", { trimempty = true })
  if #args == 0 or #args > 3 then
    notify("Usage: CodexAdd <file-path> [start-line] [end-line]", vim.log.levels.ERROR)
    return
  end

  local file_path = vim.fn.expand(args[1])
  local start_line = args[2] and tonumber(args[2]) or nil
  local end_line = args[3] and tonumber(args[3]) or nil
  if (args[2] and not start_line) or (args[3] and not end_line) then
    notify("CodexAdd line numbers must be numeric", vim.log.levels.ERROR)
    return
  end
  if (start_line and start_line < 1) or (end_line and end_line < 1) then
    notify("CodexAdd line numbers must be positive", vim.log.levels.ERROR)
    return
  end
  if start_line and end_line and start_line > end_line then
    notify("CodexAdd start line must not exceed the end line", vim.log.levels.ERROR)
    return
  end
  if vim.fn.filereadable(file_path) == 0 and vim.fn.isdirectory(file_path) == 0 then
    notify("File or directory does not exist: " .. file_path, vim.log.levels.ERROR)
    return
  end
  if not ensure_active_for_send() then
    return
  end

  local mention =
    format_at_mention(file_path, start_line and (start_line - 1) or nil, end_line and (end_line - 1) or nil)
  require("codex.terminal").send(mention .. " ", { submit = false })
end

--- Creates a fresh numbered Codex terminal.
local function command_new_slot()
  M.new_slot()
end

--- Closes the active numbered Codex terminal.
local function command_close_slot()
  M.close_active_slot()
end

--- Selects the next numbered Codex terminal.
local function command_next_slot()
  M.cycle_slot(1)
end

--- Selects the previous numbered Codex terminal.
local function command_previous_slot()
  M.cycle_slot(-1)
end

--- Selects a numbered Codex terminal from a command argument.
local function command_select_slot(opts)
  M.switch_to_slot(tonumber(opts.args))
end

--- Configures the custom provider with codex.nvim's effective terminal settings.
function M.setup(config)
  state.config = config
end

--- Reports whether Snacks terminal support is available.
function M.is_available()
  local ok, snacks = pcall(require, "snacks")
  return ok and snacks and snacks.terminal ~= nil
end

--- Opens the active slot or creates Slot 1 from the supplied Codex command.
function M.open(cmd_string, env_table, config, focus)
  state.config = config
  update_project_root(config.cwd or vim.fn.getcwd())

  local port = env_table.CODEX_CODE_SSE_PORT
  if state.port and port and state.port ~= port then
    close_all_slots()
  end

  local force_new = state.force_new
  local force_focus = state.force_focus
  state.force_new = false
  state.force_focus = nil
  if force_focus ~= nil then
    focus = force_focus
  end

  local slot = active_slot()
  if force_new or not slot_is_valid(slot) then
    return create_slot(cmd_string, env_table, config, focus)
  end

  slot.config = vim.deepcopy(config)
  return show_slot(slot, focus)
end

--- Closes the active terminal slot.
function M.close()
  return M.close_active_slot()
end

--- Shows or hides the active terminal without changing slot state.
function M.simple_toggle(cmd_string, env_table, config)
  local slot = active_slot()
  if not slot_is_valid(slot) then
    return create_slot(cmd_string, env_table, config, true)
  end
  if slot_is_visible(slot) then
    close_slot_window(slot)
    redraw_title()
    return true
  end
  return show_slot(slot, true)
end

--- Focuses the active terminal or hides it when it already owns focus.
function M.focus_toggle(cmd_string, env_table, config)
  local slot = active_slot()
  if not slot_is_valid(slot) then
    return create_slot(cmd_string, env_table, config, true)
  end
  if not slot_is_visible(slot) then
    return show_slot(slot, true)
  end
  if vim.api.nvim_get_current_win() == slot.terminal.win then
    close_slot_window(slot)
    redraw_title()
    return true
  end
  return show_slot(slot, true)
end

--- Toggles the active terminal between the Edgy split and modal display.
function M.maximize_toggle(cmd_string, env_table, config)
  local slot = active_slot()
  if not slot_is_valid(slot) then
    if not create_slot(cmd_string, env_table, config, true) then
      return false
    end
    slot = active_slot()
  end

  close_slot_window(slot)
  state.maximized = not state.maximized
  slot.config = vim.deepcopy(config)
  return show_slot(slot, true)
end

--- Ensures the active terminal is visible without taking editor focus.
function M.ensure_visible()
  local slot = active_slot()
  if not slot_is_valid(slot) then
    return request_new_slot(false)
  end
  return show_slot(slot, false)
end

--- Returns the active terminal buffer for codex.nvim integrations.
function M.get_active_bufnr()
  local slot = active_slot()
  return slot_is_valid(slot) and slot.bufnr or nil
end

--- Returns stable identity and channel information for the active slot.
function M.get_active_slot_info()
  local slot = active_slot()
  if not slot_is_valid(slot) then
    return nil
  end
  local job_id = vim.b[slot.bufnr] and vim.b[slot.bufnr].terminal_job_id or nil
  return {
    bufnr = slot.bufnr,
    exited = slot.exited == true,
    handsfree_ready = slot.env.CODEX_HANDSFREE_STATE_DIR ~= nil and slot.env.CODEX_NVIM_SLOT_ID ~= nil,
    id = slot.id,
    job_id = job_id,
    worktree = slot.worktree,
  }
end

--- Returns stable identity and channel information for one immutable slot ID.
function M.get_slot_info(slot_id)
  local index = find_slot_index_by_id(tonumber(slot_id))
  local slot = index and state.slots[index] or nil
  if not slot_is_valid(slot) then
    return nil
  end
  local job_id = vim.b[slot.bufnr] and vim.b[slot.bufnr].terminal_job_id or nil
  return {
    bufnr = slot.bufnr,
    exited = slot.exited == true,
    handsfree_ready = slot.env.CODEX_HANDSFREE_STATE_DIR ~= nil and slot.env.CODEX_NVIM_SLOT_ID ~= nil,
    id = slot.id,
    job_id = job_id,
    worktree = slot.worktree,
  }
end

--- Records a Codex turn start when the optional activity module is available.
local function record_turn_start()
  local loaded, activity = pcall(require, "codex.activity")
  if loaded and type(activity.record_turn_start) == "function" then
    pcall(activity.record_turn_start)
  end
end

--- Writes text first and sends Enter after Codex's paste-suppression window.
local function send_terminal_input(job_id, text, submit, on_complete)
  local payload = type(text) == "string" and text or ""
  if not pcall(vim.api.nvim_chan_send, job_id, payload) then
    return false
  end
  if not submit then
    if on_complete then
      pcall(on_complete, true)
    end
    return true
  end

  vim.defer_fn(function()
    local sent = pcall(vim.api.nvim_chan_send, job_id, "\r")
    if sent then
      record_turn_start()
    end
    if on_complete then
      pcall(on_complete, sent)
    end
  end, SUBMIT_KEY_DELAY_MS)
  return true
end

--- Sends text to a specific immutable terminal slot.
function M.send_to_slot(slot_id, text, submit, on_complete)
  local slot = M.get_slot_info(slot_id)
  if not slot or slot.exited or not slot.job_id then
    return false
  end
  return send_terminal_input(slot.job_id, text, submit, on_complete)
end

--- Sends terminal input through the production timing path for focused tests.
function M._send_terminal_input_for_test(job_id, text, submit, on_complete)
  return send_terminal_input(job_id, text, submit, on_complete)
end

--- Sends the installed Codex TUI's Escape interrupt binding to one slot.
function M.interrupt_slot(slot_id)
  local slot = M.get_slot_info(slot_id)
  if not slot or slot.exited or not slot.job_id then
    return false
  end
  vim.api.nvim_chan_send(slot.job_id, "\27")
  return true
end

--- Returns the active Snacks terminal for codex.nvim diagnostics.
function M._get_terminal_for_test()
  local slot = active_slot()
  return slot and slot.terminal or nil
end

--- Creates and focuses a fresh terminal slot.
function M.new_slot()
  return request_new_slot(true)
end

--- Closes the active slot and selects its nearest remaining neighbor.
function M.close_active_slot()
  local slot = active_slot()
  if not slot then
    notify("No Codex terminal is open", vim.log.levels.WARN)
    return false
  end

  local slot_id = slot.id
  notify_slot_lost(slot_id)
  close_slot_window(slot)
  if slot.terminal and slot.terminal:buf_valid() then
    slot.terminal:close()
  end
  remove_slot_by_id(slot_id)
  return true
end

--- Switches to and focuses a numbered terminal slot.
function M.switch_to_slot(index)
  if type(index) ~= "number" or index < 1 or index > #state.slots then
    notify("No Codex terminal in slot " .. tostring(index or "?"), vim.log.levels.WARN)
    return false
  end

  local previous_index = state.active
  local current = active_slot()
  if current and state.active ~= index then
    close_slot_window(current)
  end
  activate_slot(index)

  local target = active_slot()
  local worktree_changed = not current or current.worktree ~= target.worktree
  if worktree_changed then
    local switched, err = require("config.codex_worktree").switch_context(target.worktree)
    if not switched then
      state.active = previous_index
      if current then
        show_slot(current, true)
      end
      notify("Failed to switch worktrees: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
  end

  local shown = show_slot(target, true)
  if shown and worktree_changed then
    stabilize_slot_focus(target)
  end
  return shown
end

--- Cycles through terminal slots with wraparound.
function M.cycle_slot(direction)
  if #state.slots == 0 then
    notify("No Codex terminal is open", vim.log.levels.WARN)
    return false
  end

  local current = state.active or 1
  local index = ((current - 1 + direction) % #state.slots) + 1
  return M.switch_to_slot(index)
end

--- Closes every terminal belonging to the current project.
function M.close_all()
  close_all_slots()
end

--- Closes old-project slots when Neovim changes project roots.
function M.handle_project_change(cwd)
  update_project_root(cwd)
end

--- Returns the worktree associated with the active terminal slot.
function M.get_active_worktree()
  local slot = active_slot()
  return slot and slot.worktree or git_worktree.root(vim.fn.getcwd())
end

--- Finds the most recently active slot associated with a worktree.
function M.find_recent_slot_for_worktree(path)
  local root = git_worktree.root(path)
  local found_index = nil
  local found_activation = -1
  for index, slot in ipairs(state.slots) do
    if not slot.exited and slot.worktree == root and (slot.last_active or 0) > found_activation then
      found_index = index
      found_activation = slot.last_active or 0
    end
  end
  return found_index
end

--- Builds the command used to resume one exact Codex session.
local function resume_command(command, session_id)
  local base = command:gsub("%s+resume%s+.*$", "")
  local cwd_preference = vim.fn.shellescape('tui.resume_cwd="current"')
  return base .. " resume -c " .. cwd_preference .. " " .. session_id
end

--- Builds a handoff resume command for focused tests.
function M._resume_command_for_test(command, session_id)
  return resume_command(command, session_id)
end

--- Replaces an active slot with the same conversation in another worktree.
function M.resume_slot_in_worktree(slot_id, path, session_id, metadata)
  local index = find_slot_index_by_id(tonumber(slot_id))
  local slot = index and state.slots[index] or nil
  local worktree = git_worktree.root(path)
  if
    not slot_is_valid(slot)
    or state.active ~= index
    or not worktree
    or type(session_id) ~= "string"
    or not session_id:match("^[%x-]+$")
  then
    notify("Unable to resume the Codex conversation in its new worktree", vim.log.levels.ERROR)
    return false
  end

  local command = resume_command(slot.command, session_id)
  local original_worktree = slot.worktree
  local original_env = vim.deepcopy(slot.env)
  local original_config = vim.deepcopy(slot.config)
  original_config.cwd = original_worktree
  local env = vim.deepcopy(slot.env)
  env.CODEX_WORKTREE_ORIGINAL = metadata and metadata.old_worktree or slot.worktree
  env.CODEX_WORKTREE_PATH = worktree
  env.CODEX_WORKTREE_BRANCH = metadata and metadata.branch or nil
  env.CODEX_WORKTREE_BASE_REF = metadata and metadata.base_ref or nil
  env.CODEX_WORKTREE_BASE_COMMIT = metadata and metadata.base_commit or nil
  local config = vim.deepcopy(slot.config)
  config.cwd = worktree

  slot.restarting = true
  --- Starts the replacement terminal after the old terminal buffer closes.
  slot.restart_callback = function()
    require("config.codex_worktree").switch_context(worktree)
    if create_slot(command, env, config, true, index) then
      state.slots[index].handoff = metadata
      return
    end
    notify("Restoring the Codex conversation in its original worktree", vim.log.levels.WARN)
    require("config.codex_worktree").switch_context(original_worktree)
    if create_slot(command, original_env, original_config, true, index) then
      return
    end
    if #state.slots > 0 then
      activate_slot(math.min(index, #state.slots))
      show_slot(active_slot(), true)
    end
  end
  notify_slot_lost(slot.id)
  if slot.terminal and slot.terminal:buf_valid() then
    slot.terminal:close()
  end
  table.remove(state.slots, index)
  state.active = nil
  return true
end

--- Renders the numbered terminal tabs for Edgy's dynamic title.
function M.tab_title()
  local parts = { "Codex" }
  for index = 1, #state.slots do
    parts[#parts + 1] = index == state.active and ("[" .. index .. "]") or tostring(index)
  end
  local loaded, handsfree = pcall(require, "config.codex_handsfree")
  local label = loaded and handsfree.status_label() or nil
  if label then
    parts[#parts + 1] = "· " .. label
  end
  return table.concat(parts, " ")
end

--- Installs slot commands and active-terminal send overrides.
function M.install_commands()
  local visual_commands = require("codex.visual_commands")
  local send_handler = visual_commands.create_visual_command_wrapper(handle_send_normal, handle_send_visual)
  local tree_handler = visual_commands.create_visual_command_wrapper(handle_tree_add_normal, handle_tree_add_visual)

  vim.api.nvim_create_user_command("CodexTerminalNew", command_new_slot, {
    force = true,
    desc = "Create a fresh Codex terminal slot",
  })
  vim.api.nvim_create_user_command("CodexTerminalClose", command_close_slot, {
    force = true,
    desc = "Close the active Codex terminal slot",
  })
  vim.api.nvim_create_user_command("CodexTerminalNext", command_next_slot, {
    force = true,
    desc = "Select the next Codex terminal slot",
  })
  vim.api.nvim_create_user_command("CodexTerminalPrevious", command_previous_slot, {
    force = true,
    desc = "Select the previous Codex terminal slot",
  })
  vim.api.nvim_create_user_command("CodexTerminalSelect", command_select_slot, {
    force = true,
    nargs = 1,
    desc = "Select a numbered Codex terminal slot",
  })
  vim.api.nvim_create_user_command("CodexSend", send_handler, {
    force = true,
    range = true,
    desc = "Send the visual selection to the active Codex terminal",
  })
  vim.api.nvim_create_user_command("CodexTreeAdd", tree_handler, {
    force = true,
    desc = "Add selected tree paths to the active Codex terminal",
  })
  vim.api.nvim_create_user_command("CodexAdd", handle_codex_add, {
    force = true,
    nargs = "+",
    complete = "file",
    desc = "Add a file or directory to the active Codex terminal",
  })
end

return M
]=]
