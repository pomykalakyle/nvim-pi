-- NERV: a Neovim port of wongmjane's NERV VS Code/Cursor theme.
-- Palette extracted from the original nerv-color-theme.json.

vim.cmd("highlight clear")
if vim.fn.exists("syntax_on") == 1 then
  vim.cmd("syntax reset")
end

vim.o.termguicolors = true
vim.o.background = "dark"
vim.g.colors_name = "nerv"

local c = {
  bg = "#0a1612", -- editor background (deep green-black)
  bg_alt = "#0f1f1a", -- floats, popups, current line
  fg = "#8fb3a5", -- default foreground / variables (sage)
  orange = "#e85d04", -- keywords, storage, accent, cursor
  green = "#4a8c5c", -- strings
  gold = "#d4a017", -- numbers, numeric constants
  teal = "#3a7a8c", -- types, classes
  magenta = "#8a5a8a", -- functions
  clay = "#c97a4a", -- object keys / struct fields
  comment = "#4a6a5d", -- comments, inactive line numbers
  operator = "#5a7a6d", -- operators
  punct = "#8e8e93", -- punctuation, brackets
  lang_const = "#5a9a8c", -- language constants, booleans
  escape = "#659d74", -- string escapes
  red = "#c92a2a", -- regex, errors, deletions
  indent = "#2a4a3d", -- indent guides
  indent_active = "#4a6a5d", -- active indent guide

  -- Pre-blended translucent colors (NERV uses alpha over the background).
  selection = "#502c0e", -- orange @ 31% over bg
  search = "#6e5b14", -- gold @ 50% over bg
  diff_add = "#12251b",
  diff_change = "#242813",
  diff_delete = "#221815",
  diff_text = "#3c3813",
}

local groups = {
  -- Editor UI
  Normal = { fg = c.fg, bg = c.bg },
  NormalNC = { fg = c.fg, bg = c.bg },
  NormalFloat = { fg = c.fg, bg = c.bg_alt },
  FloatBorder = { fg = c.punct, bg = c.bg_alt },
  FloatTitle = { fg = c.orange, bg = c.bg_alt, bold = true },
  ColorColumn = { bg = c.bg_alt },
  Cursor = { fg = c.bg, bg = c.orange },
  lCursor = { fg = c.bg, bg = c.orange },
  CursorLine = { bg = c.bg_alt },
  CursorColumn = { bg = c.bg_alt },
  CursorLineNr = { fg = c.orange, bold = true },
  LineNr = { fg = c.comment },
  SignColumn = { bg = c.bg },
  FoldColumn = { fg = c.comment, bg = c.bg },
  Folded = { fg = c.comment, bg = c.bg_alt },
  Visual = { bg = c.selection },
  VisualNOS = { bg = c.selection },
  Search = { fg = c.fg, bg = c.search },
  IncSearch = { fg = c.bg, bg = c.orange },
  CurSearch = { fg = c.bg, bg = c.orange },
  Substitute = { fg = c.bg, bg = c.gold },
  MatchParen = { fg = c.orange, bold = true, underline = true },
  NonText = { fg = c.indent },
  EndOfBuffer = { fg = c.bg },
  Whitespace = { fg = c.indent },
  SpecialKey = { fg = c.comment },
  Conceal = { fg = c.comment },
  Directory = { fg = c.teal },
  Title = { fg = c.orange, bold = true },
  ErrorMsg = { fg = c.red },
  WarningMsg = { fg = c.gold },
  ModeMsg = { fg = c.fg },
  MoreMsg = { fg = c.green },
  Question = { fg = c.green },
  QuickFixLine = { bg = c.bg_alt, bold = true },
  WinSeparator = { fg = c.indent, bg = c.bg },
  VertSplit = { fg = c.indent, bg = c.bg },

  -- Popup menu / statusline / tabs
  Pmenu = { fg = c.fg, bg = c.bg_alt },
  PmenuSel = { fg = c.bg, bg = c.orange },
  PmenuSbar = { bg = c.bg_alt },
  PmenuThumb = { bg = c.punct },
  WildMenu = { fg = c.bg, bg = c.orange },
  StatusLine = { fg = c.fg, bg = c.bg_alt },
  StatusLineNC = { fg = c.comment, bg = c.bg },
  TabLine = { fg = c.comment, bg = c.bg_alt },
  TabLineFill = { bg = c.bg },
  TabLineSel = { fg = c.orange, bg = c.bg, bold = true },

  -- Legacy syntax groups
  Comment = { fg = c.comment, italic = true },
  Constant = { fg = c.lang_const },
  String = { fg = c.green },
  Character = { fg = c.green },
  Number = { fg = c.gold },
  Float = { fg = c.gold },
  Boolean = { fg = c.lang_const },
  Identifier = { fg = c.fg },
  Function = { fg = c.magenta },
  Statement = { fg = c.orange },
  Conditional = { fg = c.orange },
  Repeat = { fg = c.orange },
  Label = { fg = c.orange },
  Operator = { fg = c.operator },
  Keyword = { fg = c.orange },
  Exception = { fg = c.orange },
  PreProc = { fg = c.orange },
  Include = { fg = c.orange },
  Define = { fg = c.orange },
  Macro = { fg = c.orange },
  PreCondit = { fg = c.orange },
  Type = { fg = c.teal },
  StorageClass = { fg = c.orange },
  Structure = { fg = c.teal },
  Typedef = { fg = c.teal },
  Special = { fg = c.escape },
  SpecialChar = { fg = c.escape },
  Delimiter = { fg = c.punct },
  SpecialComment = { fg = c.comment, italic = true },
  Underlined = { fg = c.teal, underline = true },
  Error = { fg = c.red },
  Todo = { fg = c.gold, bg = c.bg_alt, bold = true },

  -- Treesitter
  ["@comment"] = { link = "Comment" },
  ["@comment.error"] = { fg = c.red },
  ["@comment.warning"] = { fg = c.gold },
  ["@comment.todo"] = { link = "Todo" },
  ["@comment.note"] = { fg = c.teal },
  ["@keyword"] = { fg = c.orange },
  ["@keyword.function"] = { fg = c.orange },
  ["@keyword.operator"] = { fg = c.operator, italic = true },
  ["@keyword.return"] = { fg = c.orange },
  ["@keyword.import"] = { fg = c.orange },
  ["@keyword.conditional"] = { fg = c.orange },
  ["@keyword.repeat"] = { fg = c.orange },
  ["@keyword.exception"] = { fg = c.orange },
  ["@function"] = { fg = c.magenta },
  ["@function.call"] = { fg = c.magenta },
  ["@function.builtin"] = { fg = c.magenta },
  ["@function.method"] = { fg = c.magenta },
  ["@function.method.call"] = { fg = c.magenta },
  ["@constructor"] = { fg = c.teal },
  ["@type"] = { fg = c.teal },
  ["@type.builtin"] = { fg = c.teal },
  ["@type.definition"] = { fg = c.teal },
  ["@storageclass"] = { fg = c.orange },
  ["@string"] = { fg = c.green },
  ["@string.regexp"] = { fg = c.red },
  ["@string.escape"] = { fg = c.escape },
  ["@string.special"] = { fg = c.escape },
  ["@character"] = { fg = c.green },
  ["@number"] = { fg = c.gold },
  ["@number.float"] = { fg = c.gold },
  ["@boolean"] = { fg = c.lang_const },
  ["@constant"] = { fg = c.lang_const },
  ["@constant.builtin"] = { fg = c.lang_const },
  ["@constant.macro"] = { fg = c.orange },
  ["@variable"] = { fg = c.fg, italic = true }, -- NERV uses bold+italic; add bold = true for the exact look
  ["@variable.builtin"] = { fg = c.lang_const },
  ["@variable.parameter"] = { fg = c.fg },
  ["@variable.member"] = { fg = c.clay },
  ["@property"] = { fg = c.clay },
  ["@field"] = { fg = c.clay },
  ["@punctuation.bracket"] = { fg = c.punct },
  ["@punctuation.delimiter"] = { fg = c.punct },
  ["@punctuation.special"] = { fg = c.punct },
  ["@operator"] = { fg = c.operator },
  ["@label"] = { fg = c.orange },
  ["@module"] = { fg = c.fg },
  ["@namespace"] = { fg = c.fg },
  ["@attribute"] = { fg = c.gold },
  ["@tag"] = { fg = c.orange },
  ["@tag.attribute"] = { fg = c.clay },
  ["@tag.delimiter"] = { fg = c.punct },

  -- Markup (markdown, help)
  ["@markup.heading"] = { fg = c.orange, bold = true },
  ["@markup.strong"] = { bold = true },
  ["@markup.italic"] = { italic = true },
  ["@markup.link"] = { fg = c.teal, underline = true },
  ["@markup.link.url"] = { fg = c.teal, underline = true },
  ["@markup.raw"] = { fg = c.green },
  ["@markup.list"] = { fg = c.orange },
  ["@markup.quote"] = { fg = c.comment, italic = true },

  -- LSP semantic tokens (gopls etc. emit these and they win over treesitter)
  ["@lsp.type.namespace"] = { fg = c.fg },
  ["@lsp.type.type"] = { fg = c.teal },
  ["@lsp.type.class"] = { fg = c.teal },
  ["@lsp.type.struct"] = { fg = c.teal },
  ["@lsp.type.interface"] = { fg = c.teal },
  ["@lsp.type.enum"] = { fg = c.teal },
  ["@lsp.type.enumMember"] = { fg = c.lang_const },
  ["@lsp.type.function"] = { fg = c.magenta },
  ["@lsp.type.method"] = { fg = c.magenta },
  ["@lsp.type.keyword"] = { fg = c.orange },
  ["@lsp.type.variable"] = { fg = c.fg },
  ["@lsp.type.parameter"] = { fg = c.fg },
  ["@lsp.type.property"] = { fg = c.clay },
  ["@lsp.type.string"] = { fg = c.green },
  ["@lsp.type.number"] = { fg = c.gold },
  ["@lsp.type.comment"] = { fg = c.comment },
  ["@lsp.type.macro"] = { fg = c.orange },

  -- Diagnostics
  DiagnosticError = { fg = c.red },
  DiagnosticWarn = { fg = c.gold },
  DiagnosticInfo = { fg = c.teal },
  DiagnosticHint = { fg = c.lang_const },
  DiagnosticOk = { fg = c.green },
  DiagnosticUnderlineError = { undercurl = true, sp = c.red },
  DiagnosticUnderlineWarn = { undercurl = true, sp = c.gold },
  DiagnosticUnderlineInfo = { undercurl = true, sp = c.teal },
  DiagnosticUnderlineHint = { undercurl = true, sp = c.lang_const },
  DiagnosticVirtualTextError = { fg = c.red, bg = c.bg_alt },
  DiagnosticVirtualTextWarn = { fg = c.gold, bg = c.bg_alt },
  DiagnosticVirtualTextInfo = { fg = c.teal, bg = c.bg_alt },
  DiagnosticVirtualTextHint = { fg = c.lang_const, bg = c.bg_alt },

  -- Diff / git
  DiffAdd = { bg = c.diff_add },
  DiffChange = { bg = c.diff_change },
  DiffDelete = { fg = c.red, bg = c.diff_delete },
  DiffText = { bg = c.diff_text },
  diffAdded = { fg = c.green },
  diffRemoved = { fg = c.red },
  diffChanged = { fg = c.gold },
  GitSignsAdd = { fg = c.green },
  GitSignsChange = { fg = c.gold },
  GitSignsDelete = { fg = c.red },

  -- Indent guides (snacks / indent-blankline)
  SnacksIndent = { fg = c.indent },
  SnacksIndentScope = { fg = c.indent_active },
  IblIndent = { fg = c.indent },
  IblScope = { fg = c.indent_active },

  -- Neo-tree
  NeoTreeNormal = { fg = c.fg, bg = c.bg },
  NeoTreeNormalNC = { fg = c.fg, bg = c.bg },
  NeoTreeRootName = { fg = c.orange, bold = true },
  NeoTreeDirectoryName = { fg = c.fg },
  NeoTreeDirectoryIcon = { fg = c.teal },
  NeoTreeFileName = { fg = c.fg },
  NeoTreeFileNameOpened = { fg = c.orange },
  NeoTreeIndentMarker = { fg = c.indent },
  NeoTreeGitAdded = { fg = c.green },
  NeoTreeGitModified = { fg = c.gold },
  NeoTreeGitDeleted = { fg = c.red },
  NeoTreeGitUntracked = { fg = c.comment },
  NeoTreeFloatBorder = { fg = c.punct, bg = c.bg_alt },
  NeoTreeWinSeparator = { fg = c.indent, bg = c.bg },
  NeoTreeTitleBar = { fg = c.bg, bg = c.orange },

  -- Snacks picker
  SnacksNormal = { fg = c.fg, bg = c.bg_alt },
  SnacksWinBorder = { fg = c.punct, bg = c.bg_alt },
  SnacksPicker = { fg = c.fg, bg = c.bg_alt },
  SnacksPickerBorder = { fg = c.punct, bg = c.bg_alt },
  SnacksPickerTitle = { fg = c.orange, bold = true },
  SnacksPickerMatch = { fg = c.orange, bold = true },
  SnacksPickerDir = { fg = c.comment },
  SnacksPickerPrompt = { fg = c.orange },
  SnacksPickerSelected = { fg = c.orange },

  -- which-key
  WhichKey = { fg = c.orange },
  WhichKeyGroup = { fg = c.teal },
  WhichKeyDesc = { fg = c.fg },
  WhichKeySeparator = { fg = c.comment },
  WhichKeyFloat = { bg = c.bg_alt },
  WhichKeyValue = { fg = c.comment },

  -- blink.cmp
  BlinkCmpMenu = { fg = c.fg, bg = c.bg_alt },
  BlinkCmpMenuBorder = { fg = c.punct, bg = c.bg_alt },
  BlinkCmpLabelMatch = { fg = c.orange, bold = true },
  BlinkCmpKind = { fg = c.teal },
}

for group, opts in pairs(groups) do
  vim.api.nvim_set_hl(0, group, opts)
end
