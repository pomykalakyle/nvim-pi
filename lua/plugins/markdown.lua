local markdownlint_config = vim.fs.joinpath(vim.fn.stdpath("config"), ".markdownlint-cli2.jsonc")

return {
  {
    "mfussenegger/nvim-lint",
    optional = true,
    opts = {
      linters = {
        ["markdownlint-cli2"] = {
          prepend_args = { "--config", markdownlint_config },
        },
      },
    },
  },
  {
    "stevearc/conform.nvim",
    optional = true,
    opts = {
      formatters = {
        ["markdownlint-cli2"] = {
          prepend_args = { "--config", markdownlint_config },
        },
      },
    },
  },
  {
    "MeanderingProgrammer/render-markdown.nvim",
    opts = {
      change_events = { "FileChangedShellPost" },
    },
  },
  {
    "iamcco/markdown-preview.nvim",
    ---Build the browser preview stylesheet with a viewport-wide page container.
    --[[ Reviewed: false. ]]
    config = function()
      local plugin = require("lazy.core.config").plugins["markdown-preview.nvim"]
      local source = vim.fs.joinpath(plugin.dir, "app", "_static", "markdown.css")
      local target = vim.fs.joinpath(vim.fn.stdpath("cache"), "markdown-preview-wide.css")
      local css = vim.fn.readfile(source)

      vim.list_extend(css, {
        "",
        "#page-ctn {",
        "  width: calc(100vw - 32px);",
        "  max-width: none;",
        "}",
      })
      vim.fn.writefile(css, target)
      vim.g.mkdp_markdown_css = target
      vim.cmd([[do FileType]])
    end,
  },
}
