-- Deprecated Codex-only implementation retained for migration reference.
--[=[
local M = {}

local sessions = {}

---Return whether a value is a non-empty string suitable for a session or turn identifier.
local function is_non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

---Register a new turn for a session in the safe disabled state.
function M.begin_turn(session_id, turn_id)
  if not is_non_empty_string(session_id) or not is_non_empty_string(turn_id) then
    return false
  end

  sessions[session_id] = {
    turn_id = turn_id,
    enabled = false,
  }
  return true
end

---Enable Vibing Mode for an already registered session turn.
function M.enable(session_id)
  if not is_non_empty_string(session_id) or sessions[session_id] == nil then
    return false
  end

  sessions[session_id].enabled = true
  return true
end

---Delete any Vibing Mode state for a session.
function M.disable(session_id)
  if is_non_empty_string(session_id) then
    sessions[session_id] = nil
  end
  return true
end

---Return whether the exact session and turn currently have Vibing Mode enabled.
function M.is_active(session_id, turn_id)
  if not is_non_empty_string(session_id) or not is_non_empty_string(turn_id) then
    return false
  end

  local session = sessions[session_id]
  return session ~= nil and session.turn_id == turn_id and session.enabled == true
end

---Delete session state only when the stored turn matches the ending turn.
function M.end_turn(session_id, turn_id)
  if not is_non_empty_string(session_id) or not is_non_empty_string(turn_id) then
    return false
  end

  local session = sessions[session_id]
  if session ~= nil and session.turn_id == turn_id then
    sessions[session_id] = nil
  end
  return true
end

---Return the active, inactive, or unregistered state for a session.
function M.status(session_id)
  if not is_non_empty_string(session_id) or sessions[session_id] == nil then
    return "unregistered"
  end

  if sessions[session_id].enabled == true then
    return "active"
  end
  return "inactive"
end

return M
]=]
