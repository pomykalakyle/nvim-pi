-- Verifies that Edgy keeps Pi left of Snacks pickers without corrupting the editor layout.

vim.o.cmdheight = 0
require("edgy").setup({
  animate = {
    enabled = false,
  },
  options = {
    left = {
      size = 0.4,
    },
  },
  left = {
    {
      title = "Pi",
      ft = "snacks_terminal",
      --- Matches only the fake Pi terminal used by this test.
      filter = function(buf)
        return vim.b[buf].pi_terminal == true
      end,
      pinned = false,
    },
  },
})

local editor_win = vim.api.nvim_get_current_win()
local terminal = Snacks.win({
  position = "right",
  width = 0.4,
  height = 0,
  bo = {
    filetype = "snacks_terminal",
  },
  b = {
    pi_terminal = true,
  },
})
local terminal_win = terminal.win
assert(vim.w[terminal_win].snacks_win.position == "right")
vim.api.nvim_set_current_win(editor_win)
vim.cmd("rightbelow 20vnew")
local neo_tree_win = vim.api.nvim_get_current_win()
vim.bo.buftype = "nofile"
vim.bo.filetype = "neo-tree"
vim.api.nvim_set_current_win(editor_win)
vim.wait(200)

local before = vim.fn.winlayout()
local editor_width = vim.api.nvim_win_get_width(editor_win)
local picker = Snacks.picker.pick({
  source = "worktrees",
  title = "Worktrees",
  --- Returns the one fake worktree displayed by this test.
  finder = function()
    return { { text = "main", name = "main" } }
  end,
  --- Formats the fake worktree using its name.
  format = function(item)
    return { { item.name } }
  end,
  layout = { preset = "left", preview = false },
})
vim.wait(300)

local terminal_col = vim.api.nvim_win_get_position(terminal_win)[2]
local picker_col = vim.api.nvim_win_get_position(picker.layout.root.win)[2]
local editor_col = vim.api.nvim_win_get_position(editor_win)[2]
local neo_tree_col = vim.api.nvim_win_get_position(neo_tree_win)[2]
assert(terminal_col < picker_col)
assert(picker_col < editor_col)
assert(editor_col < neo_tree_col)
assert(vim.api.nvim_win_get_width(editor_win) < editor_width)
assert(vim.o.cmdheight == 0)

picker:close()
vim.wait(100)
assert(vim.deep_equal(vim.fn.winlayout(), before))
assert(vim.api.nvim_win_get_width(editor_win) >= editor_width)
assert(vim.o.cmdheight == 0)

print("edgy-picker-layout-spec-ok")
