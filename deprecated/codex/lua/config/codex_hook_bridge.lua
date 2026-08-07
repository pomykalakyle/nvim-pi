-- Deprecated Codex-only implementation retained for migration reference.
--[=[
local M = {}

--- Dispatches one Codex hook payload to the active Neovim integrations.
function M.handle_hook_payload(encoded)
  local handsfree_result = require("config.codex_handsfree").handle_hook_payload(encoded)
  --- Keeps worktree lifecycle handling optional for existing hook behavior.
  pcall(function()
    require("config.codex_worktree").handle_hook_payload(encoded)
  end)
  return handsfree_result
end

return M
]=]
