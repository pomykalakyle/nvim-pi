local original_cwd = vim.fn.getcwd()
local original_stdpath = vim.fn.stdpath
local original_kill = vim.uv.kill
local test_root = vim.fn.tempname()
local state_root = test_root .. "/state"
local active_repository = test_root .. "/active"
local other_repository = test_root .. "/other"
local launcher_directory = test_root .. "/home"
local fake_pid = 424242

--- Runs one Git command and asserts that it succeeds.
local function git(arguments)
  local command = { "git" }
  vim.list_extend(command, arguments)
  local output = vim.fn.systemlist(command)
  assert(vim.v.shell_error == 0, table.concat(output, "\n"))
end

vim.fn.mkdir(active_repository, "p")
vim.fn.mkdir(other_repository, "p")
vim.fn.mkdir(launcher_directory, "p")
git({ "init", "-b", "main", active_repository })
git({ "init", "-b", "main", other_repository })

vim.fn.stdpath = function(kind)
  if kind == "state" then
    return state_root
  end
  return original_stdpath(kind)
end

vim.uv.kill = function(pid, signal)
  if pid == fake_pid and signal == 0 then
    return 0
  end
  return original_kill(pid, signal)
end

local git_worktree = require("config.git_worktree")
local marker_directory = state_root .. "/project-instance-guard"
vim.fn.mkdir(marker_directory, "p")
vim.fn.writefile({ assert(git_worktree.common_dir(active_repository)) }, marker_directory .. "/" .. fake_pid)

local project_picker = require("config.project_picker.picker")

vim.cmd("cd " .. vim.fn.fnameescape(launcher_directory))
assert(project_picker.bootstrap() == true)
assert(vim.g.user_project_picker_on_startup == true)

vim.cmd("cd " .. vim.fn.fnameescape(active_repository))
assert(project_picker.bootstrap() == true)

vim.cmd("cd " .. vim.fn.fnameescape(other_repository))
assert(project_picker.bootstrap() == false)

vim.uv.kill = original_kill
vim.fn.stdpath = original_stdpath
vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
vim.fn.delete(test_root, "rf")
print("project-picker-spec-ok")
