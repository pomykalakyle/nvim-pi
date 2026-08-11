-- Installs Colemak-DH movement, editing, and VS Code compatibility mappings.

local M = {}

local setup_done = false

--- Reviewed: false.
local function setup_sticky()
  local sticky = {
    active = false,
    timer = vim.uv.new_timer(),
    timeout = 600,
  }

  --- Reviewed: false.
  local function toggle()
    sticky.active = true
    sticky.timer:stop()
    sticky.timer:start(
      sticky.timeout,
      0,
      vim.schedule_wrap(--[[ Reviewed: false. ]] function()
        sticky.active = false
      end)
    )
  end

  return sticky, toggle
end

--- Reviewed: false.
function M.setup(opts)
  if setup_done then
    return
  end
  setup_done = true

  opts = opts or {}

  local map = vim.keymap.set
  local nvo = { "n", "v", "o" }
  local nv = { "n", "v" }
  local sticky, sticky_toggle = setup_sticky()

  -- NOTE: Colemak-DH via OS-level interceptor
  -- An OS-level tool remaps physical keys before Neovim sees them.
  -- Example: pressing physical "c" is delivered to apps as "d".
  -- Impact on text-objects: after operators (d/c), Neovim expects literal "i"/"a".
  -- Remapping "i" in operator-pending or visual modes breaks sequences like "diw" (becomes "dl").
  --
  -- All mappings below use the virtual keys that Neovim receives.
  -- Physical -> virtual remaps happen at the OS level and are not referenced in mappings.
  --
  -- Colemak-DH legend (PHYSICAL -> VIRTUAL). Shifted keys follow the same mapping.
  -- Top   : q->q  w->w  e->f  r->p  t->b   |   y->j  u->l  i->u  o->y  p->;  [->[  ]->]  \->\
  -- Home  : a->a  s->r  d->s  f->t  g->g   |   h->m  j->n  k->e  l->i  ;->o  '->'
  -- Bottom: z->x  x->c  c->d  v->v  b->z   |   n->k  m->h  ,->,  .->.  /->/
  -- Space : space->space
  --
  -- In mapping descriptions, prefer "Physical X / Virtual Y: action".
  -- Example: "Physical j / Virtual n: Move down."
  -- Another example: "Physical ss / Virtual dd: Delete line."

  map(nvo, "m", "h", { desc = "Physical h / Virtual m: Left" })
  map(nvo, "i", "l", { desc = "Physical l / Virtual i: Right" })

  map(nvo, "<BS>m", "^", { desc = "Physical <BS>h / Virtual <BS>m: Line start" })
  map(nvo, "<BS>i", "$", { desc = "Physical <BS>l / Virtual <BS>i: Line end" })
  map(nvo, "<leader>m", "^", { desc = "Physical <Space>h / Virtual <leader>m: Line start" })
  map(nvo, "<leader>i", "$", { desc = "Physical <Space>l / Virtual <leader>i: Line end" })

  map(nvo, "<BS>n", --[[ Reviewed: false. ]] function()
    sticky_toggle()
    return "5j"
  end, { silent = true, expr = true, desc = "Physical <BS>j / Virtual <BS>n: Sticky jump down" })

  map(nvo, "<BS>e", --[[ Reviewed: false. ]] function()
    sticky_toggle()
    return "5k"
  end, { silent = true, expr = true, desc = "Physical <BS>k / Virtual <BS>e: Sticky jump up" })

  map(nvo, "n", --[[ Reviewed: false. ]] function()
    if sticky.active then
      sticky_toggle()
      return "5j"
    end
    return "j"
  end, { silent = true, expr = true, desc = "Physical j / Virtual n: Down (5 lines when sticky active)" })

  map(nvo, "e", --[[ Reviewed: false. ]] function()
    if sticky.active then
      sticky_toggle()
      return "5k"
    end
    return "k"
  end, { silent = true, expr = true, desc = "Physical k / Virtual e: Up (5 lines when sticky active)" })

  map(nvo, "<BS>", "<Nop>", {
    silent = true,
    desc = "Physical <BS> / Virtual <BS>: Reserved for line nav",
  })

  for _, lhs in ipairs({ "<M-BS>", "<A-BS>", "<M-C-H>", "<A-C-H>" }) do
    map("i", lhs, "<C-w>", { desc = "Option-Backspace: Delete previous word" })
    map("n", lhs, "db", { desc = "Option-Backspace: Delete previous word" })
  end

  map("n", "y", "o<Esc>", { desc = "Physical o / Virtual y: Add line below, stay normal" })
  map("n", "Y", "O<Esc>", { desc = "Physical O / Virtual Y: Add line above, stay normal" })
  map("n", "<BS>y", "o", { desc = "Physical <BS>o / Virtual <BS>y: Add line below and insert" })
  map("n", "<BS>Y", "O", { desc = "Physical <BS>O / Virtual <BS>Y: Add line above and insert" })

  map(nvo, "u", "i", { desc = "Physical i / Virtual u: Insert or inside" })
  map(nv, "j", "y", { desc = "Physical y / Virtual j: Yank" })
  map(nv, "l", "u", { desc = "Physical u / Virtual l: Undo" })
  map(nv, "c", "x", { desc = "Physical x / Virtual c: Delete character" })
  map(nv, "d", "<C-d>", { desc = "Physical c / Virtual d: Half page down" })
  map(nv, "D", "c", { desc = "Physical C / Virtual D: Change" })
  map(nvo, "s", "d", { desc = "Physical d / Virtual s: Delete" })

  map(nvo, "f", "e", { desc = "Physical e / Virtual f: Word end" })
  -- Keep virtual z as Vim's built-in z-prefix for spell/fold/window commands
  -- like z=, zg, and zz. Backward-word motion is still available on virtual b.
  -- map(nvo, "z", "b", { desc = "Physical b / Virtual z: Word start" })
  map(nv, "h", "<C-u>", { desc = "Physical m / Virtual h: Half page up" })
  -- Search next/prev moved off k/K onto Ctrl chords so K is free for LSP hover.
  -- Mnemonic: in this layout virtual n = down and e = up, so <C-n> goes
  -- forward/down to the next match and <C-e> goes back/up to the previous match.
  -- Kept in n/v/o (matching the old k/K) so operator+search motions still work
  -- (e.g. delete-to-next-match). Insert-mode <C-n> completion and picker
  -- navigation are unaffected because those are insert/buffer-local.
  map(nvo, "<C-n>", "n", { desc = "Virtual <C-n>: Next search match" })
  map(nvo, "<C-e>", "N", { desc = "Virtual <C-e>: Previous search match" })

  -- K (freed from previous-search) now shows LSP hover docs, like VSCode's
  -- Shift+K. Normal mode only; mapped globally here so it is consistent even in
  -- buffers without an LSP attached (where it simply opens an empty hover).
  map("n", "K", --[[ Reviewed: false. ]] function()
    vim.lsp.buf.hover()
  end, { desc = "Virtual K: LSP hover (doc info)" })

  if opts.vscode then
    --- Reviewed: false.
    local function notify(action)
      vim.fn.VSCodeNotify(action)
    end

    map("n", "gb", --[[ Reviewed: false. ]] function()
      notify("workbench.action.previousEditor")
    end, { silent = true, desc = "Physical gt / Virtual gb: Previous tab" })

    map("n", "<BS>c", --[[ Reviewed: false. ]] function()
      notify("workbench.view.explorer")
    end, { silent = true, desc = "Focus Explorer" })

    map("n", "<BS>k", --[[ Reviewed: false. ]] function()
      notify("workbench.files.action.focusFilesExplorer")
    end, { silent = true, desc = "Focus Files Explorer" })

    local ord = { "First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth", "Ninth" }
    for i = 1, 9 do
      map("n", "<BS>" .. i, --[[ Reviewed: false. ]] function()
        notify("workbench.action.focus" .. ord[i] .. "EditorGroup")
      end, { silent = true, desc = "Focus editor group " .. i })
    end

    map("n", "gD", --[[ Reviewed: false. ]] function()
      notify("editor.action.revealDefinitionAside")
      vim.defer_fn(--[[ Reviewed: false. ]] function()
        notify("workbench.action.focusSecondEditorGroup")
      end, 30)
    end, { silent = true, desc = "Definition to Group 2 and focus there" })

    map("n", "gS", --[[ Reviewed: false. ]] function()
      notify("editor.action.revealDefinitionAside")
      vim.defer_fn(--[[ Reviewed: false. ]] function()
        notify("workbench.action.focusRightGroup")
        notify("workbench.action.moveEditorToFirstGroup")
        notify("workbench.action.focusFirstEditorGroup")
      end, 60)
    end, { silent = true, desc = "Definition -> Group 1" })

    map("n", "gp", --[[ Reviewed: false. ]] function()
      notify("editor.action.peekDefinition")
    end, { silent = true, desc = "Physical gr / Virtual gp: Peek definition" })

    map("n", "gh", --[[ Reviewed: false. ]] function()
      notify("editor.showCallHierarchy")
    end, { silent = true, desc = "Peek call hierarchy" })
  end
end

return M
