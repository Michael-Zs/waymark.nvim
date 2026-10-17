# waymark.nvim

English | [简体中文](README.zh-CN.md)

A lightweight location list where the basic unit is a **file + exact cursor position** (a single file can hold multiple marks).

## Install (lazy.nvim / LazyVim)

```lua
{
  "Michael-Zs/waymark.nvim",
  lazy = false,
  config = function()
    require("waymark").setup({})
  end,
}
```

## Keymaps

| Key | Action |
|---|---|
| `<leader>z` | Add current position (duplicate positions are skipped) |
| `[z` / `]z` | Previous / next mark (across files, wraps around) |
| `<leader>1..5` | Jump directly to mark 1-5 (jumps immediately on keypress). Only claims 1..5; `6..9` are left free (reserved for LazyVim buffer keys) |
| `<leader>sn` | Search marks with Snacks picker (`<C-d>` to delete) |
| `<leader>bm` | Popup manager: `<CR>` jump · `dd` delete · `r` rename · `J`/`K` reorder · `q` close |

### Custom keymaps

All keymaps live in the plugin's `setup()` and are overridden via the `keys` table; anything unspecified keeps its default. Set an entry to `false` to disable that key:

```lua
{
  "Michael-Zs/waymark.nvim",
  lazy = false,
  opts = {
    keys = {
      add = "<leader>x",  -- change the add key
      picker = false,     -- disable the picker key; open it via :lua require("waymark.picker").open()
      -- prev / next / manager work the same way
      jump_prefix = false, -- disable <leader>1..5 direct jumps; or set another prefix, e.g. "g"
    },
  },
  config = function(_, opts)
    require("waymark").setup(opts)
  end,
}
```

Restart Neovim or run `:Lazy reload waymark.nvim` for changes to take effect.

## Design

- **Project-local**: root is `vim.fs.root(0, {".git"})` with `cwd` fallback; one JSON file per project
- **Persistence**: `stdpath("data")/waymark/<sha256(root)>.json`, structure `{ id, file, line, col, label }`
  (absolute file path, 1-based line/col, ids are stable and unaffected by reordering)
- **Follows code movement**: extmarks track insertions/deletions at runtime, and the latest positions are written back before save/jump
- **Fault tolerant**: corrupted JSON, missing files, etc. only affect a single location; invalid entries show `[missing]` in the picker/manager and can be deleted
- **Dependencies**: none required; the picker needs snacks.nvim (bundled with LazyVim), the popup manager uses a native floating window

## API

```lua
require("waymark").add() / .next() / .prev() / .goto_index(n)
require("waymark.store"):list/get/add/remove/rename/move/save
```
