-- Verifies Pi worktree picking, browsing contexts, and terminal selection.

local original_cwd = vim.fn.getcwd()
local test_root = vim.fn.tempname()
local main_root = test_root .. "/main"
local linked_root = test_root .. "/linked"
local main_file = main_root .. "/main.txt"
local linked_file = linked_root .. "/linked.txt"
local picker_opts = nil
local neo_tree_navigation = {}
local opened_terminals = {}

--- Runs one Git command and asserts that it succeeds.
local function git(arguments)
  local command = { "git" }
  vim.list_extend(command, arguments)
  local output = vim.fn.systemlist(command)
  assert(vim.v.shell_error == 0, table.concat(output, "\n"))
end

vim.fn.mkdir(main_root, "p")
git({ "init", "-b", "main", main_root })
git({ "-C", main_root, "config", "user.name", "Pi Worktree Test" })
git({ "-C", main_root, "config", "user.email", "pi-worktree@example.com" })
vim.fn.writefile({ "main" }, main_file)
git({ "-C", main_root, "add", "main.txt" })
git({ "-C", main_root, "commit", "-m", "initial" })
git({ "-C", main_root, "worktree", "add", "-b", "feature", linked_root })
vim.fn.writefile({ "linked" }, linked_file)

package.preload["lazy"] = function()
  return { load = function() end }
end
package.preload["neo-tree.command"] = function()
  return {
    execute = function(opts)
      neo_tree_navigation[#neo_tree_navigation + 1] = opts
    end,
  }
end
package.preload["config.pi.terminal"] = function()
  return {
    open = function(cwd)
      opened_terminals[#opened_terminals + 1] = cwd
    end,
  }
end

Snacks = {
  picker = {
    pick = function(opts)
      picker_opts = opts
    end,
  },
}

vim.cmd("cd " .. vim.fn.fnameescape(main_root))
vim.cmd("edit " .. vim.fn.fnameescape(main_file))
local main_buf = vim.api.nvim_get_current_buf()
local main_tab = vim.api.nvim_get_current_tabpage()
local initial_tab_count = #vim.api.nvim_list_tabpages()

local git_worktree = require("config.git_worktree")
local normalized_main_root = git_worktree.normalize(main_root)
local normalized_linked_root = git_worktree.normalize(linked_root)
local worktree = require("config.pi.worktree")
worktree.pick()
local items = picker_opts.finder()
assert(#items == 2)
assert(items[1].main == true)
assert(items[2].name == "linked")

assert(worktree.open_worktree(linked_root))
local linked_tab = vim.api.nvim_get_current_tabpage()
assert(linked_tab ~= main_tab)
assert(#vim.api.nvim_list_tabpages() == initial_tab_count + 1)
assert(vim.fn.getcwd() == normalized_linked_root)
assert(opened_terminals[#opened_terminals] == normalized_linked_root)
assert(neo_tree_navigation[#neo_tree_navigation].dir == normalized_linked_root)

vim.cmd("edit " .. vim.fn.fnameescape(linked_file))
local linked_buf = vim.api.nvim_get_current_buf()

assert(worktree.open_worktree(main_root))
assert(vim.api.nvim_get_current_tabpage() == main_tab)
assert(vim.api.nvim_get_current_buf() == main_buf)
assert(vim.fn.getcwd() == normalized_main_root)
assert(opened_terminals[#opened_terminals] == normalized_main_root)

assert(worktree.open_worktree(linked_root))
assert(vim.api.nvim_get_current_tabpage() == linked_tab)
assert(vim.api.nvim_get_current_buf() == linked_buf)
assert(#vim.api.nvim_list_tabpages() == initial_tab_count + 1)

vim.api.nvim_set_current_tabpage(main_tab)
vim.api.nvim_set_current_tabpage(linked_tab)
vim.cmd.tabclose()
vim.api.nvim_set_current_tabpage(main_tab)
vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
vim.fn.delete(test_root, "rf")
print("pi-worktree-spec-ok")
