return {
  {
    "folke/snacks.nvim",
    keys = {
      {
        "<F16>",
        --- Focuses Pi before Wispr Flow begins or finishes dictation.
        function()
          require("config.pi.terminal").focus_existing()
        end,
        mode = { "n", "i", "v", "t" },
        desc = "Pi: Focus for dictation",
      },
      {
        "<leader>cc",
        --- Toggles the interactive Pi terminal.
        function()
          require("config.pi.terminal").toggle()
        end,
        desc = "Pi: Toggle",
      },
      {
        "<leader>cf",
        --- Opens and focuses the interactive Pi terminal.
        function()
          require("config.pi.terminal").focus()
        end,
        desc = "Pi: Focus",
      },
      {
        "<leader>ca",
        --- Creates a fresh conversation in the current worktree.
        function()
          require("config.pi.terminal").create_session(nil, {})
        end,
        desc = "Pi: Add session",
      },
      {
        "<leader>cx",
        --- Stops the active conversation and selects a neighboring session.
        function()
          require("config.pi.terminal").stop()
        end,
        desc = "Pi: Close session",
      },
      {
        "<leader>cn",
        function()
          require("config.pi.terminal").cycle_session(1)
        end,
        desc = "Pi: Next session",
      },
      {
        "<leader>ce",
        function()
          require("config.pi.terminal").cycle_session(-1)
        end,
        desc = "Pi: Previous session",
      },
      unpack(vim.tbl_map(function(index)
        return {
          "<leader>c" .. index,
          function()
            require("config.pi.terminal").switch_to_session(index)
          end,
          desc = "Pi: Session " .. index,
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
          title = "Pi",
          ft = "snacks_terminal",
          --- Matches only the interactive Pi terminal buffer.
          filter = function(buf)
            return vim.b[buf].pi_terminal == true
          end,
          pinned = false,
        },
      },
    },
  },

  -- Reserve Pi's conversation shortcuts instead of LazyVim's LSP mappings.
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
