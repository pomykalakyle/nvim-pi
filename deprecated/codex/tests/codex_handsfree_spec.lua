-- Deprecated Codex-only test retained for migration reference.
--[=[
local sent = {}
local interrupted = {}

local real_provider = require("config.codex_terminal_provider")
assert(
  real_provider._resume_command_for_test("codex -p nvim-approval resume --last", "abc-def")
    == [[codex -p nvim-approval resume -c 'tui.resume_cwd="current"' abc-def]]
)
local original_channel_send = vim.api.nvim_chan_send
local terminal_writes = {}
vim.api.nvim_chan_send = function(job_id, payload)
  terminal_writes[#terminal_writes + 1] = {
    at = vim.uv.hrtime(),
    job_id = job_id,
    payload = payload,
  }
end

local submission_completed = false

--- Records completion of the delayed terminal submission.
local function record_submission_completed(success)
  submission_completed = success
end

assert(real_provider._send_terminal_input_for_test(11, "dictated message", true, record_submission_completed))
assert(#terminal_writes == 1)
assert(terminal_writes[1].payload == "dictated message")
assert(vim.wait(1000, function()
  return submission_completed
end))
assert(#terminal_writes == 2)
assert(terminal_writes[2].payload == "\r")
assert((terminal_writes[2].at - terminal_writes[1].at) / 1000000 >= 180)
vim.api.nvim_chan_send = original_channel_send

package.loaded["config.codex_terminal_provider"] = {
  --- Returns a deterministic active terminal slot.
  get_active_slot_info = function()
    return { id = 7, bufnr = 1, job_id = 11, exited = false }
  end,

  --- Records text sent to the deterministic terminal slot.
  send_to_slot = function(slot_id, text, submit)
    sent[#sent + 1] = { slot_id = slot_id, text = text, submit = submit }
    return true
  end,

  --- Records an interrupt sent to the deterministic terminal slot.
  interrupt_slot = function(slot_id)
    interrupted[#interrupted + 1] = slot_id
    return true
  end,
}

local handsfree = require("config.codex_handsfree")
local test_state_dir = vim.fn.tempname()
handsfree.setup({ state_dir = test_state_dir })
handsfree._activate_for_test(7, false)

handsfree._handle_helper_event_for_test({
  type = "transcript_final",
  utterance_id = "dictation",
  text = "Please inspect the failing test",
})
handsfree._handle_helper_event_for_test({
  type = "transcript_final",
  utterance_id = "submit",
  text = "Submit that message.",
})

assert(#sent == 1)
assert(sent[1].slot_id == 7)
assert(sent[1].text == "Please inspect the failing test")
assert(sent[1].submit == true)
assert(handsfree._state_for_test().mode == "working")

local stop_payload = vim.base64.encode(vim.json.encode({
  _handsfree_slot_id = "7",
  hook_event_name = "Stop",
  session_id = "session",
  turn_id = "turn",
}))
assert(handsfree.handle_hook_payload(stop_payload) == "ok")
assert(handsfree._state_for_test().mode == "ready")

local approval_payload = vim.base64.encode(vim.json.encode({
  _handsfree_request_id = "approval-one",
  _handsfree_slot_id = "7",
  hook_event_name = "PermissionRequest",
  session_id = "session",
  tool_name = "apply_patch",
  turn_id = "turn",
}))
assert(handsfree.handle_hook_payload(approval_payload) == "pending")
assert(handsfree._state_for_test().mode == "approval_pending")

handsfree._handle_helper_event_for_test({
  type = "transcript_final",
  utterance_id = "approve",
  text = "Approve.",
})
local approval = vim.json.decode(table.concat(vim.fn.readfile(test_state_dir .. "/decision-approval-one.json"), "\n"))
assert(approval.behavior == "allow")

local rejection_payload = vim.base64.encode(vim.json.encode({
  _handsfree_request_id = "approval-two",
  _handsfree_slot_id = "7",
  hook_event_name = "PermissionRequest",
  session_id = "session",
  tool_name = "Bash",
  turn_id = "turn",
}))
assert(handsfree.handle_hook_payload(rejection_payload) == "pending")
handsfree._handle_helper_event_for_test({
  type = "transcript_final",
  utterance_id = "reject",
  text = "Reject.",
})
local rejection = vim.json.decode(table.concat(vim.fn.readfile(test_state_dir .. "/decision-approval-two.json"), "\n"))
assert(rejection.behavior == "deny")

local prompt_payload = vim.base64.encode(vim.json.encode({
  _handsfree_slot_id = "7",
  hook_event_name = "UserPromptSubmit",
  session_id = "session",
  turn_id = "turn-two",
}))
assert(handsfree.handle_hook_payload(prompt_payload) == "ok")
handsfree._handle_helper_event_for_test({
  type = "transcript_final",
  utterance_id = "stop",
  text = "Stop.",
})
assert(#interrupted == 1)
assert(interrupted[1] == 7)

handsfree._handle_helper_event_for_test({
  type = "transcript_final",
  utterance_id = "exit",
  text = "Exit hands-free mode.",
})
assert(handsfree._state_for_test().mode == "inactive")

handsfree._activate_for_test(7, false)
vim.cmd("CodexHandsfreeStop")
assert(handsfree._state_for_test().mode == "inactive")

print("codex-handsfree-spec-ok")
]=]
