return {
  "folke/snacks.nvim",
  opts = {
    scroll = {
      enabled = false,
    },
  },
  keys = {
    {
      "<leader>ff",
      --[[ Provenance: vibed=true, reviewed=false. ]]
      function()
        LazyVim.pick("files", { layout = { preset = "left" } })()
      end,
      desc = "Find Files (Root Dir)",
    },
    {
      "<leader>fF",
      --[[ Provenance: vibed=true, reviewed=false. ]]
      function()
        LazyVim.pick("files", { root = false, layout = { preset = "left" } })()
      end,
      desc = "Find Files (cwd)",
    },
    {
      "<leader>fw",
      --[[ Provenance: vibed=true, reviewed=false. ]]
      function()
        require("config.pi.worktree").pick()
      end,
      desc = "Workspaces",
    },
  },
}
