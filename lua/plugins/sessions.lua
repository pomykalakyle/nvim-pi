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
    init = function()
      vim.opt.sessionoptions:append("globals")
    end,
    opts = {
      projects = {
        "~/Documents/projects/sail",
        "~/Documents/projects/api-server",
        "~/Documents/projects/lakesail-session-demo",
        "~/Documents/projects/gate",
        "~/Documents/projects/Fall",
        "~/Documents/projects/nvim-pi",
        "~/Documents",
        "~/.config/nvim",
      },
      last_session_on_startup = true,
      dashboard_mode = vim.g.user_project_picker_on_startup == true,
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
    config = function(_, opts)
      require("neovim-project").setup(opts)
      require("config.project_picker.picker").install()
    end,
    keys = {
      {
        "<leader>fp",
        function()
          require("config.project_picker.picker").pick_project(false)
        end,
        desc = "Projects",
      },
      {
        "<leader>fP",
        function()
          require("config.project_picker.picker").pick_project(true)
        end,
        desc = "Project History",
      },
    },
  },

  {
    "folke/persistence.nvim",
    enabled = false,
  },
}
