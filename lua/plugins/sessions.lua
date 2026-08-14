return {
  {
    "coffebar/neovim-project",
    lazy = false,
    priority = 100,
    dependencies = {
      "nvim-lua/plenary.nvim",
      "Shatur/neovim-session-manager",
      "folke/snacks.nvim",
    },
    --[[ Reviewed: false. ]]
    init = function()
      vim.opt.sessionoptions:append("globals")
      require("config.startup")
    end,
    opts = {
      projects = {
        "~/Documents/projects",
        "~/Documents/projects/sail",
        "~/Documents/projects/api-server",
        "~/Documents/projects/lakesail-session-demo",
        "~/Documents/projects/gate",
        "~/Documents/projects/Fall",
        "~/Documents/projects/nvim-pi",
        "~/Documents/projects/super-secret-sailor",
        "~/Documents",
        "~/.config/nvim",
      },
      last_session_on_startup = true,
      debug_logging = true,
      session_manager_opts = {
        autosave_ignore_filetypes = {
          "ccc-ui",
          "dap-repl",
          "dap-view",
          "dap-view-term",
          "gitcommit",
          "gitrebase",
          "qf",
          "toggleterm",
          "snacks_terminal",
        },
      },
      picker = {
        type = "snacks",
      },
    },
    --[[ Reviewed: false. ]]
    config = function(_, opts)
      require("neovim-project").setup(opts)
    end,
    keys = {
      {
        "<leader>fp",
        --[[ Reviewed: false. ]]
        function()
          vim.cmd("NeovimProjectDiscover history")
        end,
        desc = "Projects",
      },
    },
  },

  {
    "folke/persistence.nvim",
    enabled = false,
  },
}
