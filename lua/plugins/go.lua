-- Personal gopls tweaks layered on top of LazyVim's lang.go extra.
-- LazyVim enables staticcheck in gopls, which surfaces style rules this repo
-- does not enforce (they are absent from .golangci.yml). Silence only those
-- style checks while keeping the rest of staticcheck's bug-catching analyzers
-- active.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        gopls = {
          settings = {
            gopls = {
              hints = {
                assignVariableTypes = false,
                compositeLiteralFields = false,
                compositeLiteralTypes = false,
                constantValues = false,
                functionTypeParameters = false,
                parameterNames = false,
                rangeVariableTypes = false,
              },
              analyses = {
                ST1000 = false,
                ST1003 = false,
              },
            },
          },
        },
      },
    },
  },
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters_by_ft = {
        go = {},
      },
    },
  },
}
