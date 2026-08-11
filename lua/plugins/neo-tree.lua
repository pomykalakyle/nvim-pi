-- Colemak-DH navigation inside Neo-tree: use virtual m/n/e/i to navigate.
--   m -> close_node (collapse folder / step to parent)
--   i -> open       (expand folder / open file)
--   n / e -> down / up come from the global Colemak remaps in `config.colemak`,
--            so `e` is disabled here ("none" makes Neo-tree skip it) to let the
--            global remap fall through. `i` is re-bound per source, so override
--            it there too.
local quick_jump = {
  "quick_jump",
  config = {
    on_jump = "open_or_toggle",
    -- Default Neo-tree labels translated through the Colemak-DH virtual-key map
    -- from `config.colemak`, preserving the same physical-key priority.
    jump_labels = "ntesiramgklvpzjbhudfycw;qx",
  },
}

return {
  "nvim-neo-tree/neo-tree.nvim",
  keys = {
    {
      "<leader>k",
      --[[ Reviewed: false. ]]
      function()
        -- Reveal the current file in the tree when we're in a real file
        -- buffer; otherwise just open/focus the tree (no "nothing to
        -- reveal" error from scratch/terminal/no-name buffers).
        if vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) ~= "" then
          vim.cmd("Neotree reveal")
        else
          vim.cmd("Neotree focus")
        end
      end,
      desc = "Focus Neo-tree (reveal current file if any)",
    },
  },
  opts = {
    window = {
      position = "right",
      mappings = {
        ["<C-s>"] = "none",
        ["f"] = quick_jump,
        ["m"] = "close_node",
        ["i"] = "open",
        ["e"] = "none",
      },
    },
    filesystem = {
      window = {
        mappings = {
          ["f"] = quick_jump,
          ["F"] = "filter_on_submit",
          ["i"] = "open",
        },
      },
    },
    buffers = {
      window = {
        mappings = {
          ["i"] = "open",
        },
      },
    },
    git_status = {
      window = {
        mappings = {
          ["i"] = "open",
        },
      },
    },
  },
}
