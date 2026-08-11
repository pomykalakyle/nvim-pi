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
local opened_arguments = {}
local terminal_roots = {}
local terminal_sessions = {}
local selected_session = nil
local return_nil_terminal = false
local suppress_handoff_ack = false

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
package.preload["config.pi.workspace"] = function()
  local workspace = {}

  function workspace.open(cwd, arguments, env)
    local tabpage = vim.api.nvim_get_current_tabpage()
    for _, session in ipairs(terminal_sessions) do
      if session.tabpage == tabpage then
        if arguments then
          error("A Pi workspace already exists in this tab")
        end
        return session.terminal
      end
    end

    if return_nil_terminal then
      return nil
    end

    terminal_roots[cwd] = (terminal_roots[cwd] or 0) + 1
    opened_terminals[#opened_terminals + 1] = cwd
    opened_arguments[#opened_arguments + 1] = arguments
    local instance = { buf = vim.api.nvim_get_current_buf() }
    table.insert(terminal_sessions, { root = cwd, tabpage = tabpage, terminal = instance })
    if env and env.PI_NVIM_HANDOFF_ID and not suppress_handoff_ack then
      vim.schedule(function()
        require("config.pi.worktree").acknowledge_handoff(env.PI_NVIM_HANDOFF_ID)
      end)
    end
    return instance
  end

  function workspace.stop()
    local tabpage = vim.api.nvim_get_current_tabpage()
    for index, session in ipairs(terminal_sessions) do
      if session.tabpage == tabpage then
        terminal_roots[session.root] = terminal_roots[session.root] - 1
        if terminal_roots[session.root] == 0 then
          terminal_roots[session.root] = nil
        end
        table.remove(terminal_sessions, index)
        if #vim.api.nvim_list_tabpages() > 1 then
          vim.cmd.tabclose()
        end
        return true
      end
    end
    return false
  end

  function workspace.list()
    local sessions = {}
    for index, session in ipairs(terminal_sessions) do
      sessions[index] = {
        index = index,
        root = session.root,
        tabpage = session.tabpage,
        title = vim.fn.fnamemodify(session.root, ":t"),
      }
    end
    return sessions
  end

  function workspace.switch(index)
    selected_session = index
    vim.api.nvim_set_current_tabpage(terminal_sessions[index].tabpage)
    return true
  end

  return workspace
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
assert(items[1].kind == "worktree")
assert(items[2].name == "linked [new workspace]")

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

worktree.pick()
items = picker_opts.finder()
assert(picker_opts.title == "Workspaces")
assert(#items == 2)
assert(items[1].kind == "workspace")
assert(items[2].kind == "workspace")
picker_opts.confirm({ close = function() end }, items[2])
vim.wait(20, function()
  return selected_session == 2
end)
assert(selected_session == 2)
assert(vim.api.nvim_get_current_tabpage() == main_tab)

local source_session = test_root .. "/source-session.jsonl"
local handoff_root = test_root .. "/handoff"
git({ "-C", main_root, "worktree", "add", "-b", "handoff", handoff_root })
vim.fn.writefile({ '{"type":"session"}' }, source_session)
vim.api.nvim_set_current_tabpage(main_tab)
local handoff = worktree.handoff({
  worktree = handoff_root,
  session_file = source_session,
})
assert(handoff.ok == true)
assert(handoff.worktree == git_worktree.normalize(handoff_root))
local handoff_tab = vim.api.nvim_get_current_tabpage()
assert(handoff_tab ~= linked_tab)
assert(opened_arguments[#opened_arguments][1] == "--session")
assert(opened_arguments[#opened_arguments][2] == source_session)
assert(require("config.pi.workspace").stop())

vim.api.nvim_set_current_tabpage(main_tab)
local duplicate = worktree.handoff({ worktree = linked_root, session_file = source_session })
assert(duplicate.ok == true)
local duplicate_tab = vim.api.nvim_get_current_tabpage()
assert(duplicate_tab ~= linked_tab)
assert(terminal_roots[normalized_linked_root] == 2)
assert(require("config.pi.workspace").stop())
assert(terminal_roots[normalized_linked_root] == 1)
vim.api.nvim_set_current_tabpage(main_tab)

local failed_root = test_root .. "/failed-handoff"
git({ "-C", main_root, "worktree", "add", "-b", "failed-handoff", failed_root })
suppress_handoff_ack = true
vim.g.pi_worktree_handoff_timeout_ms = 10
local timed_out = worktree.handoff({ worktree = failed_root, session_file = source_session })
vim.g.pi_worktree_handoff_timeout_ms = nil
suppress_handoff_ack = false
assert(timed_out.ok == false)
assert(timed_out.error:find("did not acknowledge", 1, true))
assert(vim.api.nvim_get_current_tabpage() == main_tab)
assert(terminal_roots[git_worktree.normalize(failed_root)] == nil)
assert(#vim.api.nvim_list_tabpages() == initial_tab_count + 1)

local nil_root = test_root .. "/nil-handoff"
git({ "-C", main_root, "worktree", "add", "-b", "nil-handoff", nil_root })
return_nil_terminal = true
local nil_result = worktree.handoff({ worktree = nil_root, session_file = source_session })
return_nil_terminal = false
assert(nil_result.ok == false)
assert(nil_result.error:find("failed to open", 1, true))
assert(vim.api.nvim_get_current_tabpage() == main_tab)
assert(#vim.api.nvim_list_tabpages() == initial_tab_count + 1)

vim.api.nvim_set_current_tabpage(main_tab)
vim.api.nvim_set_current_tabpage(linked_tab)
vim.cmd.tabclose()
vim.api.nvim_set_current_tabpage(main_tab)
vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
vim.fn.delete(test_root, "rf")
print("pi-worktree-spec-ok")
