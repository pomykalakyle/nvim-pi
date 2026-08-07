-- Deprecated Codex-only implementation retained for migration reference.
--[=[
local M = {}

local DEFAULT_SILENCE_MS = 10000

local options = {
  silence_ms = DEFAULT_SILENCE_MS,
  state_dir = vim.fn.stdpath("state") .. "/codex-handsfree",
}

local runtime_by_slot = {}

local state = {
  active = false,
  bound_slot_id = nil,
  codex_working = false,
  draft = "",
  finalized = {},
  generation = 0,
  helper_built = false,
  helper_ready = false,
  mode = "inactive",
  partial = {},
  pending_approval = nil,
  process = nil,
  silence_timer = nil,
  speech_active = false,
  stdout_buffer = "",
}

--- Shows a Hands-Free Mode notification.
local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Codex Hands-Free" })
end

--- Requests a redraw after the visible hands-free state changes.
local function redraw()
  pcall(vim.cmd, "redrawstatus")
end

--- Returns the configured helper project directory.
local function helper_root()
  return vim.fn.stdpath("config") .. "/helpers/codex-handsfree"
end

--- Returns the signed speech-helper executable path.
local function helper_executable()
  return helper_root() .. "/.build/CodexHandsfree.app/Contents/MacOS/codex-handsfree"
end

--- Returns the helper build script path.
local function helper_build_script()
  return helper_root() .. "/build"
end

--- Returns the active marker path for one terminal slot.
local function marker_path(slot_id)
  return options.state_dir .. "/active-" .. tostring(slot_id)
end

--- Returns the decision-file path for one approval request.
local function decision_path(request_id)
  return options.state_dir .. "/decision-" .. request_id .. ".json"
end

--- Ensures the private hands-free runtime directory exists.
local function ensure_state_dir()
  vim.fn.mkdir(options.state_dir, "p", tonumber("700", 8))
  pcall(vim.fn.setfperm, options.state_dir, "rwx------")
end

--- Writes an owner-only file atomically.
local function write_atomic(path, contents)
  ensure_state_dir()
  local temporary = path .. "." .. tostring(vim.uv.hrtime()) .. ".tmp"
  local ok = vim.fn.writefile({ contents }, temporary, "s") == 0
  if not ok then
    return false
  end
  pcall(vim.fn.setfperm, temporary, "rw-------")
  local renamed = os.rename(temporary, path)
  if not renamed then
    pcall(os.remove, temporary)
    return false
  end
  return true
end

--- Creates the marker that tells hooks this slot is hands-free controlled.
local function create_active_marker()
  return write_atomic(marker_path(state.bound_slot_id), tostring(vim.fn.getpid()))
end

--- Removes the active marker for the currently bound slot.
local function remove_active_marker()
  if state.bound_slot_id then
    pcall(os.remove, marker_path(state.bound_slot_id))
  end
end

--- Cancels and releases the current silence timer.
local function cancel_silence_timer()
  local timer = state.silence_timer
  state.silence_timer = nil
  if timer then
    pcall(timer.stop, timer)
    if not timer:is_closing() then
      timer:close()
    end
  end
end

--- Updates the visible controller mode from Codex and helper state.
local function refresh_mode()
  if not state.active then
    state.mode = "inactive"
  elseif state.pending_approval then
    state.mode = "approval_pending"
  elseif not state.helper_ready then
    state.mode = "starting"
  elseif state.codex_working then
    state.mode = "working"
  else
    state.mode = "ready"
  end
  redraw()
end

--- Resets draft and provisional transcription state.
local function clear_draft()
  state.draft = ""
  state.partial = {}
  state.finalized = {}
  cancel_silence_timer()
end

--- Writes a pending approval decision for the hook process.
local function write_approval_decision(request, behavior)
  if not request or not request.request_id then
    return false
  end
  return write_atomic(decision_path(request.request_id), vim.json.encode({ behavior = behavior }))
end

--- Resolves the single pending approval and returns to working state.
local function resolve_approval(behavior)
  local request = state.pending_approval
  if not request then
    return false
  end
  if not write_approval_decision(request, behavior) then
    notify("Could not return the spoken approval decision; the request will be denied", vim.log.levels.ERROR)
    behavior = "deny"
    write_approval_decision(request, behavior)
  end
  state.pending_approval = nil
  state.codex_working = true
  refresh_mode()
  notify(behavior == "allow" and "Approved pending Codex action" or "Rejected pending Codex action")
  return true
end

--- Stops the helper process without waiting on its exit callback.
local function terminate_helper()
  local process = state.process
  state.process = nil
  if process then
    pcall(process.kill, process, 15)
  end
end

--- Ends Hands-Free Mode and clears all local state.
local function stop_mode(reason, level, notify_user)
  if not state.active then
    return false
  end

  state.mode = "stopping"
  redraw()
  cancel_silence_timer()
  if state.pending_approval then
    write_approval_decision(state.pending_approval, "deny")
  end
  remove_active_marker()
  state.generation = state.generation + 1
  terminate_helper()

  state.active = false
  state.bound_slot_id = nil
  state.codex_working = false
  state.helper_ready = false
  state.pending_approval = nil
  state.speech_active = false
  state.stdout_buffer = ""
  clear_draft()
  refresh_mode()

  if notify_user ~= false then
    notify(reason or "Hands-Free Mode ended", level)
  end
  return true
end

--- Normalizes one finalized utterance for exact command matching.
local function normalize_command(text)
  return vim.trim((text or ""):lower():gsub("[%s%p]+$", ""):gsub("%s+", " "))
end

--- Sends the accumulated draft to the bound Codex terminal.
local function submit_draft()
  if state.mode ~= "ready" or vim.trim(state.draft) == "" then
    return false
  end

  local provider = require("config.codex_terminal_provider")
  local message = vim.trim(state.draft)
  local generation = state.generation

  --- Ends the mode if the delayed Enter cannot reach the bound terminal.
  local function handle_submission_result(success)
    if success or not state.active or state.generation ~= generation then
      return
    end
    stop_mode("Could not submit the dictated message to Codex", vim.log.levels.ERROR)
  end

  if not provider.send_to_slot(state.bound_slot_id, message, true, handle_submission_result) then
    stop_mode("Could not send the dictated message to Codex", vim.log.levels.ERROR)
    return false
  end

  clear_draft()
  state.codex_working = true
  refresh_mode()
  return true
end

--- Starts the silence timer for a non-empty ready-state draft.
local function start_silence_timer()
  cancel_silence_timer()
  if state.mode ~= "ready" or state.speech_active or vim.trim(state.draft) == "" then
    return
  end

  local generation = state.generation
  local timer = vim.uv.new_timer()
  state.silence_timer = timer
  timer:start(options.silence_ms, 0, function()
    vim.schedule(function()
      if state.active and state.generation == generation and state.silence_timer == timer then
        state.silence_timer = nil
        if not timer:is_closing() then
          timer:close()
        end
        submit_draft()
      end
    end)
  end)
end

--- Interrupts the active Codex turn using its configured Escape binding.
local function interrupt_turn()
  if state.mode ~= "working" then
    return false
  end
  local provider = require("config.codex_terminal_provider")
  if not provider.interrupt_slot(state.bound_slot_id) then
    stop_mode("Could not interrupt the bound Codex turn", vim.log.levels.ERROR)
    return false
  end
  notify("Interrupting the current Codex turn")
  return true
end

--- Interprets one finalized transcript as a command or dictated text.
local function handle_final_transcript(event)
  local utterance_id = tostring(event.utterance_id or "")
  local text = vim.trim(event.text or "")
  if utterance_id == "" or text == "" or state.finalized[utterance_id] then
    return
  end

  state.finalized[utterance_id] = true
  state.partial[utterance_id] = nil
  local command = normalize_command(text)

  if command == "exit hands-free mode" then
    stop_mode("Hands-Free Mode ended")
    return
  end
  if state.mode == "ready" and command == "submit that message" then
    submit_draft()
    return
  end
  if state.mode == "working" and command == "stop" then
    interrupt_turn()
    return
  end
  if state.mode == "approval_pending" and command == "approve" then
    resolve_approval("allow")
    return
  end
  if state.mode == "approval_pending" and command == "reject" then
    resolve_approval("deny")
    return
  end
  if state.mode ~= "ready" then
    return
  end

  state.draft = state.draft == "" and text or (state.draft .. " " .. text)
  if not state.speech_active then
    start_silence_timer()
  end
end

--- Applies one decoded event from the Swift speech helper.
local function handle_helper_event(event)
  if type(event) ~= "table" or not state.active then
    return
  end

  if event.type == "ready" then
    state.helper_ready = true
    refresh_mode()
    if not create_active_marker() then
      stop_mode("Could not activate the Codex hook bridge", vim.log.levels.ERROR)
      return
    end
    notify("Hands-Free Mode active for Codex slot " .. tostring(state.bound_slot_id))
  elseif event.type == "speech_started" then
    state.speech_active = true
    cancel_silence_timer()
  elseif event.type == "speech_ended" then
    state.speech_active = false
    start_silence_timer()
  elseif event.type == "transcript_partial" then
    if event.utterance_id then
      state.partial[tostring(event.utterance_id)] = event.text or ""
    end
  elseif event.type == "transcript_final" then
    handle_final_transcript(event)
  elseif event.type == "error" then
    stop_mode(event.message or "Speech recognition failed", vim.log.levels.ERROR)
  elseif event.type == "stopped" then
    stop_mode("Speech recognition stopped", vim.log.levels.WARN)
  end
end

--- Decodes one complete JSON line from the helper process.
local function handle_helper_line(line, generation)
  if generation ~= state.generation or line == "" then
    return
  end
  local ok, event = pcall(vim.json.decode, line)
  if not ok then
    stop_mode("Speech helper returned invalid data", vim.log.levels.ERROR)
    return
  end
  handle_helper_event(event)
end

--- Buffers chunked helper output and schedules complete event lines.
local function handle_helper_output(data, generation)
  if generation ~= state.generation or not data then
    return
  end
  state.stdout_buffer = state.stdout_buffer .. data
  while true do
    local newline = state.stdout_buffer:find("\n", 1, true)
    if not newline then
      break
    end
    local line = state.stdout_buffer:sub(1, newline - 1)
    state.stdout_buffer = state.stdout_buffer:sub(newline + 1)
    vim.schedule(function()
      handle_helper_line(line, generation)
    end)
  end
end

--- Launches the compiled speech helper for the current generation.
local function launch_helper()
  local generation = state.generation
  state.stdout_buffer = ""
  state.process = vim.system({ helper_executable() }, {
    stdout = function(_, data)
      handle_helper_output(data, generation)
    end,
    stderr = function(_, data)
      if data and data ~= "" then
        vim.schedule(function()
          if state.active and generation == state.generation then
            notify(vim.trim(data), vim.log.levels.WARN)
          end
        end)
      end
    end,
  }, function(result)
    vim.schedule(function()
      if state.active and generation == state.generation then
        stop_mode(
          "Speech helper exited unexpectedly" .. (result.code ~= 0 and (" (" .. result.code .. ")") or ""),
          vim.log.levels.ERROR
        )
      end
    end)
  end)
end

--- Builds the signed helper once per Neovim process and launches it.
local function build_and_launch_helper()
  if state.helper_built and vim.fn.executable(helper_executable()) == 1 then
    launch_helper()
    return
  end

  local generation = state.generation
  notify("Building the Hands-Free speech helper")
  vim.system({ "sh", helper_build_script() }, { text = true }, function(result)
    vim.schedule(function()
      if not state.active or generation ~= state.generation then
        return
      end
      if result.code ~= 0 or vim.fn.executable(helper_executable()) ~= 1 then
        local detail = vim.trim(result.stderr or "")
        stop_mode(
          detail ~= "" and ("Could not build the speech helper: " .. detail) or "Could not build the speech helper",
          vim.log.levels.ERROR
        )
        return
      end
      state.helper_built = true
      launch_helper()
    end)
  end)
end

--- Begins Hands-Free Mode for the selected numbered Codex terminal.
function M.start()
  if state.active then
    notify("Hands-Free Mode is already active for Codex slot " .. tostring(state.bound_slot_id))
    return false
  end

  local provider = require("config.codex_terminal_provider")
  local slot = provider.get_active_slot_info()
  if not slot or slot.exited or not slot.job_id then
    notify("Select a live Codex terminal before starting Hands-Free Mode", vim.log.levels.ERROR)
    return false
  end
  if not slot.handsfree_ready then
    notify("Restart this Codex terminal before starting Hands-Free Mode", vim.log.levels.ERROR)
    return false
  end

  ensure_state_dir()
  state.active = true
  state.bound_slot_id = slot.id
  state.generation = state.generation + 1
  state.helper_ready = false
  state.pending_approval = nil
  state.speech_active = false
  state.codex_working = runtime_by_slot[slot.id] and runtime_by_slot[slot.id].working or false
  clear_draft()
  refresh_mode()
  build_and_launch_helper()
  return true
end

--- Ends Hands-Free Mode at the user's request.
function M.stop()
  return stop_mode("Hands-Free Mode ended")
end

--- Ends the mode when its immutable terminal slot is lost.
function M.on_terminal_lost(slot_id)
  if state.active and tonumber(slot_id) == tonumber(state.bound_slot_id) then
    stop_mode("The bound Codex terminal was lost", vim.log.levels.WARN)
  end
end

--- Returns a short persistent state label for the Codex pane title.
function M.status_label()
  if not state.active then
    return nil
  end
  local labels = {
    approval_pending = "Awaiting approval",
    ready = "Listening",
    starting = "Starting microphone",
    stopping = "Stopping",
    working = "Codex working",
  }
  return labels[state.mode] or state.mode
end

--- Applies one lifecycle event received from the Codex hook bridge.
local function apply_hook_event(payload)
  local slot_id = tonumber(payload._handsfree_slot_id)
  if not slot_id then
    return "inactive"
  end

  local event_name = payload.hook_event_name
  local runtime = runtime_by_slot[slot_id] or {}
  runtime_by_slot[slot_id] = runtime
  if event_name == "SessionStart" then
    runtime.session_id = payload.session_id
    runtime.working = false
  elseif event_name == "UserPromptSubmit" then
    runtime.session_id = payload.session_id
    runtime.turn_id = payload.turn_id
    runtime.working = true
  elseif event_name == "Stop" then
    runtime.session_id = payload.session_id
    runtime.turn_id = nil
    runtime.working = false
  elseif event_name == "SessionEnd" then
    runtime.session_id = nil
    runtime.turn_id = nil
    runtime.working = false
  end

  if not state.active or slot_id ~= tonumber(state.bound_slot_id) then
    return "inactive"
  end

  if event_name == "UserPromptSubmit" then
    state.codex_working = true
    refresh_mode()
  elseif event_name == "Stop" then
    state.codex_working = false
    state.pending_approval = nil
    clear_draft()
    refresh_mode()
  elseif event_name == "SessionEnd" then
    stop_mode("The bound Codex session ended", vim.log.levels.WARN)
  elseif event_name == "PermissionRequest" then
    if state.pending_approval then
      return "busy"
    end
    clear_draft()
    state.codex_working = true
    state.pending_approval = {
      request_id = payload._handsfree_request_id,
      session_id = payload.session_id,
      turn_id = payload.turn_id,
      tool_name = payload.tool_name,
    }
    refresh_mode()
    notify("Codex is awaiting spoken approval or rejection")
    return "pending"
  end
  return "ok"
end

--- Decodes and applies a base64 hook payload received through Neovim RPC.
function M.handle_hook_payload(encoded)
  local ok, decoded = pcall(vim.base64.decode, encoded)
  if not ok then
    return "invalid"
  end
  local parsed, payload = pcall(vim.json.decode, decoded)
  if not parsed or type(payload) ~= "table" then
    return "invalid"
  end
  return apply_hook_event(payload)
end

--- Installs the activation command and runtime options.
function M.setup(user_options)
  options = vim.tbl_deep_extend("force", options, user_options or {})
  ensure_state_dir()
  vim.api.nvim_create_user_command("CodexHandsfree", function()
    M.start()
  end, {
    force = true,
    desc = "Start Hands-Free Mode for the selected Codex terminal",
  })
  vim.api.nvim_create_user_command("CodexHandsfreeStop", function()
    M.stop()
  end, {
    force = true,
    desc = "Stop Hands-Free Mode",
  })
end

--- Returns controller state for focused headless tests.
function M._state_for_test()
  return vim.deepcopy(state)
end

--- Injects one helper event for focused headless tests.
function M._handle_helper_event_for_test(event)
  handle_helper_event(event)
end

--- Activates controller state without launching the speech helper for tests.
function M._activate_for_test(slot_id, codex_working)
  state.active = true
  state.bound_slot_id = slot_id
  state.codex_working = codex_working == true
  state.generation = state.generation + 1
  state.helper_ready = true
  state.pending_approval = nil
  state.speech_active = false
  clear_draft()
  refresh_mode()
  create_active_marker()
end

--- Resets controller state without emitting a user notification for tests.
function M._reset_for_test()
  if state.active then
    stop_mode(nil, nil, false)
  end
  runtime_by_slot = {}
end

return M
]=]
