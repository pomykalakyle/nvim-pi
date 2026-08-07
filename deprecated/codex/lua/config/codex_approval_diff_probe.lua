-- Deprecated Codex-only implementation retained for migration reference.
--[=[
local M = {}

local function read_payload(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end

  local raw = table.concat(lines, "\n")
  local decoded_ok, payload = pcall(vim.json.decode, raw)
  if decoded_ok and type(payload) == "table" then
    return payload
  end

  return nil
end

function M.ping(path)
  local payload = read_payload(path)
  local patch = ""

  if payload and type(payload.tool_input) == "table" then
    patch = payload.tool_input.command or ""
  end

  vim.schedule(function()
    vim.notify(
      ("apply_patch PreToolUse fired: %d chars"):format(#patch),
      vim.log.levels.INFO,
      { title = "Codex hook probe" }
    )
  end)

  return true
end

return M
]=]
