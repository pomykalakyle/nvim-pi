-- Deprecated Codex-only test retained for migration reference.
--[=[
local original_cwd = vim.fn.getcwd()
local test_root = vim.fn.tempname()
local main_root = test_root .. "/main"
local linked_root = test_root .. "/feature"

--- Runs one Git command and asserts that it succeeds.
local function git(arguments)
  local command = { "git" }
  vim.list_extend(command, arguments)
  local output = vim.fn.systemlist(command)
  assert(vim.v.shell_error == 0, table.concat(output, "\n"))
  return output
end

vim.fn.mkdir(main_root, "p")
git({ "init", "-b", "main", main_root })
git({
  "-C",
  main_root,
  "-c",
  "user.name=Codex Worktree Test",
  "-c",
  "user.email=codex-worktree@example.com",
  "commit",
  "--allow-empty",
  "-m",
  "initial",
})
git({ "-C", main_root, "worktree", "add", "-b", "feature", linked_root })

local git_worktree = require("config.git_worktree")
local worktrees = assert(git_worktree.list(main_root))
assert(#worktrees == 2)
assert(worktrees[1].path == git_worktree.normalize(main_root))
assert(worktrees[1].main == true)
assert(worktrees[2].path == git_worktree.normalize(linked_root))
assert(worktrees[2].name == "feature")
assert(git_worktree.common_dir(main_root) == git_worktree.common_dir(linked_root))
assert(git_worktree.contains(main_root, main_root .. "/README.md"))
assert(not git_worktree.contains(main_root, linked_root .. "/README.md"))

local active_root = main_root
local resumed = nil
local neo_tree_node = nil
local neo_tree_navigation = {}
package.loaded["lazy"] = {
  --- Records that a lazy plugin load was requested.
  load = function() end,
}
package.loaded["neo-tree.sources.manager"] = {
  --- Returns deterministic Neo-tree state for context tracking.
  get_state = function()
    return {
      tree = {
        --- Returns the selected fake Neo-tree node.
        get_node = function()
          return neo_tree_node
        end,
      },
    }
  end,
}
package.loaded["neo-tree.command"] = {
  --- Records one fake Neo-tree navigation.
  execute = function(arguments)
    neo_tree_navigation[#neo_tree_navigation + 1] = arguments
  end,
}
package.loaded["config.codex_terminal_provider"] = {
  --- Returns the worktree represented by the active fake Codex slot.
  get_active_worktree = function()
    return active_root
  end,

  --- Returns deterministic identity for the active fake Codex slot.
  get_slot_info = function(slot_id)
    if slot_id == 7 then
      return { id = 7, worktree = git_worktree.normalize(main_root) }
    end
  end,

  --- Records a requested fake conversation resume.
  resume_slot_in_worktree = function(slot_id, path, session_id, metadata)
    resumed = {
      slot_id = slot_id,
      path = path,
      session_id = session_id,
      metadata = metadata,
    }
    return true
  end,
}

local worktree = require("config.codex_worktree")
worktree.setup()

local main_file = main_root .. "/main.txt"
local linked_file = linked_root .. "/feature.txt"
vim.fn.writefile({ "main" }, main_file)
vim.fn.writefile({ "feature" }, linked_file)

vim.cmd("cd " .. vim.fn.fnameescape(main_root))
vim.cmd("edit " .. vim.fn.fnameescape(main_file))
neo_tree_node = { path = main_file }
active_root = linked_root
assert(worktree.switch_context(linked_root))
assert(vim.fn.getcwd() == git_worktree.normalize(linked_root))
assert(vim.api.nvim_buf_get_name(0) == "")
assert(neo_tree_navigation[#neo_tree_navigation].dir == git_worktree.normalize(linked_root))
assert(neo_tree_navigation[#neo_tree_navigation].reveal_file == nil)

vim.cmd("edit " .. vim.fn.fnameescape(linked_file))
neo_tree_node = { path = linked_file }
active_root = main_root
assert(worktree.switch_context(main_root))
assert(vim.fn.getcwd() == git_worktree.normalize(main_root))
assert(vim.api.nvim_buf_get_name(0) == git_worktree.normalize(main_file))
assert(neo_tree_navigation[#neo_tree_navigation].reveal_file == git_worktree.normalize(main_file))

local handoff = {
  base_commit = string.rep("a", 40),
  base_ref = "origin/main",
  branch = "feature",
  new_worktree = linked_root,
  old_worktree = main_root,
  session_id = "abc-def",
  slot_id = "7",
}
assert(worktree.schedule_handoff(vim.base64.encode(vim.json.encode(handoff))) == "scheduled")

local stop_payload = vim.base64.encode(vim.json.encode({
  _handsfree_slot_id = "7",
  hook_event_name = "Stop",
  session_id = "abc-def",
}))
assert(worktree.handle_hook_payload(stop_payload) == "ok")

--- Reports whether the deferred fake conversation resume has occurred.
local function resume_completed()
  return resumed ~= nil
end

assert(vim.wait(1000, resume_completed))
assert(resumed.slot_id == 7)
assert(resumed.path == git_worktree.normalize(linked_root))
assert(resumed.session_id == "abc-def")
assert(resumed.metadata.base_ref == "origin/main")

vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
vim.fn.delete(test_root, "rf")
print("codex-worktree-spec-ok")
]=]
