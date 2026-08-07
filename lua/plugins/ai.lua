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
        "<leader>cx",
        --- Stops the interactive Pi terminal process.
        function()
          require("config.pi.terminal").stop()
        end,
        desc = "Pi: Stop",
      },
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

  -- Reserve <leader>cc for Pi instead of LazyVim's LSP code-action mapping.
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        ["*"] = {
          keys = {
            { "<leader>cc", false },
          },
        },
      },
    },
  },
}
