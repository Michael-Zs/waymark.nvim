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
| `<leader>z` | Add current position using the lowest free number (duplicate positions are skipped) |
| `[z` / `]z` | Previous / next mark (across files, wraps around) |
| `<leader>1..5` | Jump directly to mark 1-5 (jumps immediately on keypress). Only claims 1..5; `6..9` are left free (reserved for LazyVim buffer keys) |
| `V` then `<leader>1..5` | Set the chosen mark number to the selected line's cursor position, creating it if empty, then leave Visual mode |
| `<leader>sn` | Search marks with Snacks picker (`<C-d>` to delete) |
| `<leader>bm` | Popup manager: `<CR>` jump · `dd` delete · `r` rename · `J`/`K` reorder · `q` close |

For example, press `V` then `<leader>5` to set mark **5**, even when the list is empty. You can then press `<leader>5` in Normal mode to jump back to it. Numbers 1-4 can stay empty. Setting an existing number keeps its ID and refreshes its label from the new line; different numbers may point to the same position. Changes are saved immediately, including the chosen number. Visual updates use the current cursor position (also for multi-line selections).

Deleting a mark leaves its number free without renumbering the others. The manager and picker show the actual numbers, and previous/next navigation skips empty numbers. `J`/`K` in the manager reorder marks between occupied numbers.

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
      jump_prefix = false, -- disable numeric jumps and Visual updates; or use another prefix, e.g. "g"
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
- **Persistence**: `stdpath("data")/waymark/<sha256(root)>.json`, structure `{ id, index, file, line, col, label }`
  (absolute file path, 1-based number/line/col, ids are stable and unaffected by reordering; older data keeps its original numbering)
- **Follows code movement**: extmarks track insertions/deletions at runtime, and the latest positions are written back before save/jump
- **Fault tolerant**: corrupted JSON, missing files, etc. only affect a single location; invalid entries show `[missing]` in the picker/manager and can be deleted
- **Dependencies**: none required; the picker needs snacks.nvim (bundled with LazyVim), the popup manager uses a native floating window

## API

```lua
require("waymark").add() / .next() / .prev() / .goto_index(n)
require("waymark").update_index(n) -- create or update exactly number n with the current position
require("waymark.store"):list/get/get_index/set_index/add/update/remove/rename/move/save
```

`store.list()` returns a dense array of existing marks sorted by `loc.index`; use `store.get_index(n)` to look up a specific number, which may be empty.
