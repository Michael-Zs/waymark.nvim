# waymark.nvim

English | [Simplified Chinese](README.zh-CN.md)

A lightweight location list where the basic unit is a **file + exact cursor position** (a single file can hold multiple marks).

Organize marks into four independent sets per project, jump between them, and save named snapshots for later. Marks follow code edits and are restored when you reopen Neovim.

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

## Quick start

1. Put the cursor on a useful location and press `<leader>zz` to add a mark.
2. Use `[z` / `]z` to jump between marks in the current set.
3. Press `<leader>zm` to open the manager and inspect, reorder, or delete marks.
4. In the manager, press `s` and enter a name to save a snapshot. Press `l` (load) to select a snapshot to load later.

The initial set is `q`. Each project remembers its selected set and saves edits automatically; named snapshots let you keep reusable copies of a set.

## Global keymaps

These are Normal-mode mappings unless noted. `<leader>` uses your Neovim leader key.

| Key | Action |
|---|---|
| `<leader>zz` | Add current position to the current set using the lowest free number (duplicate positions are skipped) |
| `<leader>zq` / `<leader>zw` / `<leader>ze` / `<leader>zr` | Add current position to the `q` / `w` / `e` / `r` set without switching |
| `<leader>zQ` / `<leader>zW` / `<leader>zE` / `<leader>zR` | Switch the current set to `q` / `w` / `e` / `r` without adding a mark |
| `[z` / `]z` | Previous / next mark in the current set (across files, wraps around) |
| `<leader>[q` / `<leader>]q` | Jump to the previous / next mark in the `q` set without switching (`w` / `e` / `r` work the same way) |
| `<leader>1..9` | Open the file for mark 1-9, restoring that file's previous cursor position |
| `<leader>!@#$%^&*(` (Shift+1..9) | Jump precisely to the marked location |
| `V` then `<leader>1..9` | Set the chosen mark number to the selected line's cursor position, creating it if empty, then leave Visual mode |
| `<leader>zp` | Search marks with Snacks picker (`<C-d>` to delete) |
| `<leader>zm` | Open the [manager](#manager) for the current set |
| `<leader>zv` | Show only the current file's marks in one notification (number, line:column, label) |

### Working with numbered marks

- `V` then `<leader>5`: create or update mark **5** at the current cursor position, even if numbers 1–4 are empty.
- `<leader>5` in Normal mode: open mark 5's file at its last cursor position.
- `<leader>%` (Shift+5 on a US keyboard): jump to mark 5's exact line and column.

Updating an existing number keeps its ID and refreshes its label from the new line. Visual updates use the cursor endpoint, including multi-line selections. Different numbers may point to the same position.

Deleting a mark leaves its number free without renumbering the others. The manager and picker show the actual numbers, and previous/next navigation skips empty numbers. `J`/`K` in the manager reorder marks between occupied numbers.

## Manager

Open with `<leader>zm` or `:lua require("waymark.ui").open()`. The title shows the current set, such as `Waymarks [q]`. Each row contains the mark's **number**, **filename:line**, and **label**. Missing files are tagged `[missing]`.

### Manager options and shortcuts

These keys apply inside the manager and are case-sensitive.

| Key | Action |
|---|---|
| `j` / `k` | Select the next / previous row |
| `<CR>` | Jump to the selected mark's exact position and close the manager |
| `dd` | Delete the selected mark; its number becomes available again |
| `C` | Clear all marks in the current set across all files and close the manager |
| `R` | Edit the selected mark's label; an empty label clears it |
| `J` / `K` | Swap the selected mark with the next / previous entry, preserving numbering gaps |
| `U` | Renumber the current set consecutively from 1, e.g. **1, 3, 5 → 1, 2, 3** |
| `s` | Save the current set as a named snapshot |
| `l` | Choose a snapshot to load into the current set |
| `q` / `<Esc>` | Close the manager |

Changes are saved automatically. Reordering and renumbering keep the cursor on the same entry. Deleting the last mark closes the manager; you can reopen it even when the set is empty to load a snapshot.

### Save and load snapshots

**Save:** press `s`, enter a name such as `review`, and confirm. The snapshot captures the current set's file paths, latest positions, labels, and numbers. Saving with an existing name overwrites that snapshot. Names cannot contain `/` or `\`.

**Load:** press `l` and choose a name. The selector lists snapshots for the current project, shared across its four sets. Loading **replaces the current set**, preserves the saved numbers, and leaves the other sets intact. For example, a snapshot saved from `q` can be loaded into `w` after switching to `w`.

The manager reopens after the prompt or selector finishes, including cancellation. With no saved snapshots, `l` displays a notification.

Saving uses `vim.ui.input`; loading uses `vim.ui.select`. Their appearance follows your Neovim UI configuration. The separate mark-search picker (`<leader>zp`) uses Snacks.

See [Storage](#storage) for where automatic saves and snapshots live.

## Independent mark sets

Each project has four sets, identified by the symbols **q**, **w**, **e**, and **r**. `<leader>zq`, `<leader>zw`, `<leader>ze`, and `<leader>zr` add the current position to the corresponding set without changing the current set. `<leader>zQ`, `<leader>zW`, `<leader>zE`, and `<leader>zR` switch the current set without adding a mark. `<leader>[q` / `<leader>]q` navigate the `q` set without switching; replace `q` with `w`, `e`, or `r` for the other sets. Each set has its own marks, numbering, labels, and navigation history. Updating, deleting, reordering, and numbered jumps all operate on the selected set.

Only the selected set appears in the gutter, manager, picker, and `<leader>zv` notification. Manager and picker titles include the symbol and refresh when you switch sets. Switching to an empty set shows an empty manager; the mark-search picker closes. Notifications include the relevant symbol, for example `[waymark:w] Waymark 1 added: main.lua:42`.

All four sets and the selected symbol are saved per project and restored on restart. Existing marks migrate automatically into **q**, preserving their IDs, numbers, and labels. Hidden sets continue tracking code edits without displaying gutter signs.

## Configuration

Override global keymaps through the `keys` table in `setup()`. Unspecified keys keep their defaults; set an entry to `false` to disable it. The manager's internal shortcuts are fixed and are not configured through this table.

```lua
{
  "Michael-Zs/waymark.nvim",
  lazy = false,
  opts = {
    keys = {
      add = "<leader>x",  -- change the add key
      picker = false,     -- disable the picker key; open it via :lua require("waymark.picker").open()
      manager = "<leader>zm", -- open the manager
      -- prev / next / view work the same way
      open_prefix = false, -- disable <prefix>1..9 file opens
      jump_prefix = false, -- disable Shift+number precise jumps and Visual updates; or use another prefix, e.g. "g"
      symbol_q = "<leader>zq", -- add to q without switching; symbol_w / symbol_e / symbol_r work the same way
      select_q = "<leader>zQ", -- switch to q; select_w / select_e / select_r work the same way
      prev_q = "<leader>[q",   -- previous in q without switching; prev_w / prev_e / prev_r work the same way
      next_q = "<leader>]q",   -- next in q without switching; next_w / next_e / next_r work the same way
      -- Set any of these keys to false to disable it.
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

## Storage

Projects are identified by their Git root (`vim.fs.root(0, { ".git" })`), falling back to the current working directory. `<project-hash>` below is the first 16 characters of the project root's SHA-256 hash.

| Data | Location | When saved |
|---|---|---|
| All four sets and the selected set | `stdpath("data")/waymark/<project-hash>.json` | Automatically after changes and on exit |
| A named copy of one set | `stdpath("data")/waymark/snapshots/<project-hash>/<name>.json` | When you press `s` in the manager |

To see the base directory on your machine, run:

```vim
:echo stdpath('data') . '/waymark'
```

These paths are currently fixed; there is no storage-directory option. Snapshots are project-specific and store absolute file paths.

## Design

- **Project-local**: root is `vim.fs.root(0, {".git"})` with `cwd` fallback; one JSON file per project
- **Persistence format**: version 3 with `active_symbol` and `symbols = { q, w, e, r }`; each set contains `{ id, index, file, line, col, label }` entries
  (absolute file path, 1-based number/line/col, ids are stable and unaffected by reordering; version 1/2 data migrates into `q` with its original numbering)
- **Follows code movement**: extmarks track insertions/deletions at runtime, and the latest positions are written back before save/jump
- **Fault tolerant**: corrupted JSON, missing files, etc. only affect a single location; invalid entries show `[missing]` in the picker/manager and can be deleted
- **Dependencies**: none required; the picker needs snacks.nvim (bundled with LazyVim), the popup manager uses a native floating window

## API

```lua
local waymark = require("waymark")
waymark.add()                 -- add to the current set
waymark.add("w")              -- add to w without switching
waymark.next()                -- next mark in the current set; previous: waymark.prev()
waymark.next("w")             -- next in w without switching; previous: waymark.prev("w")
waymark.goto_index(5)         -- jump to mark 5's exact position
waymark.update_index(5)       -- create or update mark 5 at the current cursor position
waymark.select_symbol("w")    -- select q / w / e / r; returns true on success
waymark.current_symbol()     -- selected symbol for the current project
waymark.view()               -- notify the current file's marks with their latest positions

require("waymark.ui").open()     -- manager
require("waymark.picker").open() -- Snacks mark-search picker

local store = waymark.store
store.list()                  -- marks in the selected set, sorted by number
store.get_index(5)            -- mark 5, or nil if that slot is empty
store.save_snapshot("review") -- returns true, path on success; false, error on failure
store.list_snapshots()        -- sorted snapshot names for this project
store.load_snapshot("review") -- replaces the current set; returns true or false, error
```

`store.list()` returns a dense array of the selected set's existing marks sorted by `loc.index`; use `store.get_index(n)` to look up a specific number, which may be empty. Store mutations affect only the selected set; `store.save()` saves all sets. Switching sets emits the `User WaymarkSymbolChanged` autocmd with `ev.data.symbol`.
