return {
  {
    "folke/snacks.nvim",
    keys = {
      {
        "<F16>",
        --- Focuses Pi before Wispr Flow begins or finishes dictation.
        --[[ Provenance: vibed=true, reviewed=false. ]]
        function()
          require("config.pi.workspace").focus_existing()
        end,
        mode = { "n", "i", "v", "t" },
        desc = "Pi: Focus for dictation",
      },
      {
        "<leader>cc",
        --- Toggles the interactive Pi terminal.
        --[[ Provenance: vibed=true, reviewed=false. ]]
        function()
          require("config.pi.workspace").toggle()
        end,
        desc = "Pi: Toggle",
      },
      {
        "<leader>cf",
        --- Opens and focuses the interactive Pi terminal.
        --[[ Provenance: vibed=true, reviewed=false. ]]
        function()
          require("config.pi.workspace").focus()
        end,
        desc = "Pi: Focus",
      },
      {
        "<leader>ca",
        --- Creates a fresh workspace in the current worktree.
        --[[ Provenance: vibed=true, reviewed=false. ]]
        function()
          require("config.pi.workspace").create(nil, {})
        end,
        desc = "Pi: Add workspace",
      },
      {
        "<leader>cx",
        --- Stops the active workspace and selects a neighboring workspace.
        --[[ Provenance: vibed=true, reviewed=false. ]]
        function()
          require("config.pi.workspace").stop()
        end,
        desc = "Pi: Close workspace",
      },
      {
        "<leader>cn",
        --[[ Provenance: vibed=true, reviewed=false. ]]
        function()
          require("config.pi.workspace").cycle(1)
        end,
        desc = "Pi: Next workspace",
      },
      {
        "<leader>ce",
        --[[ Provenance: vibed=true, reviewed=false. ]]
        function()
          require("config.pi.workspace").cycle(-1)
        end,
        desc = "Pi: Previous workspace",
      },
      unpack(vim.tbl_map(--[[ Provenance: vibed=true, reviewed=false. ]] function(index)
        return {
          "<leader>c" .. index,
          --[[ Provenance: vibed=true, reviewed=false. ]]
          function()
            require("config.pi.workspace").switch(index)
          end,
          desc = "Pi: Workspace " .. index,
        }
      end, vim.fn.range(1, 9))),
    },
  },

  {
    "folke/edgy.nvim",
    lazy = false,
    opts = {
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
          --[[ Provenance: vibed=true, reviewed=false. ]]
          title = function()
            return require("config.pi.workspace").title(vim.g.statusline_winid)
          end,
          ft = "snacks_terminal",
          --- Matches only the interactive Pi terminal buffer.
          --[[ Provenance: vibed=true, reviewed=false. ]]
          filter = function(buf)
            return vim.b[buf].pi_terminal == true
          end,
          pinned = false,
        },
      },
    },
  },

  -- Reserve Pi's workspace shortcuts instead of LazyVim's LSP mappings.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ["*"] = {
          keys = {
            { "<leader>ca", false },
            { "<leader>cc", false },
          },
        },
      },
    },
  },
}
