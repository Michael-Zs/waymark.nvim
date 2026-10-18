# waymark.nvim

English | [Simplified Chinese](README.zh-CN.md)

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
| `<leader>zz` | Add current position using the lowest free number (duplicate positions are skipped) |
| `<leader>zq` / `<leader>zw` / `<leader>ze` / `<leader>zr` | Select the independent `q` / `w` / `e` / `r` mark set |
| `[z` / `]z` | Previous / next mark (across files, wraps around) |
| `<leader>1..9` | Jump directly to mark 1-9 (jumps immediately on keypress) |
| `V` then `<leader>1..9` | Set the chosen mark number to the selected line's cursor position, creating it if empty, then leave Visual mode |
| `<leader>zp` | Search marks with Snacks picker (`<C-d>` to delete) |
| `<leader>zm` | Popup manager: `<CR>` jump · `dd` delete · `C` clear current set · `r` rename · `J`/`K` reorder · `U` fill numbering gaps · `q` close |
| `<leader>zv` | Show only the current file's marks in one notification (number, line:column, label) |

For example, press `V` then `<leader>5` to set mark **5**, even when the list is empty. You can then press `<leader>5` in Normal mode to jump back to it. Numbers 1-4 can stay empty. Setting an existing number keeps its ID and refreshes its label from the new line; different numbers may point to the same position. Changes are saved immediately, including the chosen number. Visual updates use the current cursor position (also for multi-line selections).

Deleting a mark leaves its number free without renumbering the others. The manager and picker show the actual numbers, and previous/next navigation skips empty numbers. `J`/`K` in the manager reorder marks between occupied numbers.

Press uppercase `U` in the manager to renumber all marks consecutively from 1 in their current order, e.g. **1, 3, 5 → 1, 2, 3**. The new numbers are saved immediately, and the cursor stays on the same entry.

Press uppercase `C` in the manager to clear all marks in the current set across all files. The manager closes, gutter signs are removed, and the empty set is saved immediately. The notification includes the current symbol and the number of removed marks.

### Independent mark sets

Each project has four sets, identified by the symbols **q**, **w**, **e**, and **r**. Select one with `<leader>zq`, `<leader>zw`, `<leader>ze`, or `<leader>zr`. Each set has its own marks, numbering, labels, and navigation history. Adding, updating, deleting, reordering, and jumping all operate on the selected set.

Only the selected set appears in the gutter, manager, picker, and `<leader>zv` notification. Manager and picker titles include the symbol and refresh when you switch sets; switching to an empty set closes the open list. Notifications include the current symbol, for example `[waymark:w] Waymark 1 added: main.lua:42`.

All four sets and the selected symbol are saved per project and restored on restart. Existing marks migrate automatically into **q**, preserving their IDs, numbers, and labels. Hidden sets continue tracking code edits without displaying gutter signs.

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
      -- prev / next / manager / view work the same way
      jump_prefix = false, -- disable numeric jumps and Visual updates; or use another prefix, e.g. "g"
      symbol_q = "<leader>zq", -- symbol_w / symbol_e / symbol_r work the same way; false disables a key
    },
  },
  config = function(_, opts)
    require("waymark").setup(opts)
  end,
}
```

Restart Neovim or run `:Lazy reload waymark.nvim` for changes to take effect.

## Gutter numbers

Marked lines show their Waymark number in Neovim's sign column. The numbers follow edits and update when marks are moved, deleted, reordered (`J`/`K`), or renumbered (`U`). Saved marks reappear when their files are opened.

The `WaymarkSign` highlight group defaults to `Special`. Signs use priority 20 and respect your `signcolumn` setting. To show multiple marks or other signs on the same line, use `vim.opt.signcolumn = "auto:3"`. Native signs are limited to two columns, so numbers above 99 display as `++`; the manager and picker show the full number.

## Design

- **Project-local**: root is `vim.fs.root(0, {".git"})` with `cwd` fallback; one JSON file per project
- **Persistence**: `stdpath("data")/waymark/<sha256(root)>.json`, version 3 with `active_symbol` and `symbols = { q, w, e, r }`; each set contains `{ id, index, file, line, col, label }` entries
  (absolute file path, 1-based number/line/col, ids are stable and unaffected by reordering; version 1/2 data migrates into `q` with its original numbering)
- **Follows code movement**: extmarks track insertions/deletions at runtime, and the latest positions are written back before save/jump
- **Fault tolerant**: corrupted JSON, missing files, etc. only affect a single location; invalid entries show `[missing]` in the picker/manager and can be deleted
- **Dependencies**: none required; the picker needs snacks.nvim (bundled with LazyVim), the popup manager uses a native floating window

## API

```lua
require("waymark").add() / .next() / .prev() / .goto_index(n)
require("waymark").update_index(n) -- create or update exactly number n with the current position
require("waymark").select_symbol("w") -- select q / w / e / r; returns true on success
require("waymark").current_symbol() -- selected symbol for the current project
require("waymark").view() -- notify the current file's marks with their latest positions
require("waymark.store"):list/get/get_index/set_index/add/update/remove/clear/rename/move/compact/save
```

`store.list()` returns a dense array of the selected set's existing marks sorted by `loc.index`; use `store.get_index(n)` to look up a specific number, which may be empty. Store mutations affect only the selected set; `store.save()` saves all sets. Switching sets emits the `User WaymarkSymbolChanged` autocmd with `ev.data.symbol`.
