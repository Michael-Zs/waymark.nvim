# waymark.nvim

[English](README.md) | 简体中文

轻量 Location List：基本单位是 **file + exact cursor position**（同一文件可有多个位置）。

## 安装（lazy.nvim / LazyVim）

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

| 键 | 功能 |
|---|---|
| `<leader>zz` | 用最小空闲编号添加当前位置（重复位置不重复添加） |
| `<leader>zq` / `<leader>zw` / `<leader>ze` / `<leader>zr` | 选择独立的 `q` / `w` / `e` / `r` 标记分组 |
| `[z` / `]z` | 上一个 / 下一个位置（跨文件，首尾循环） |
| `<leader>1..9` | 打开第 1-9 个位置对应的文件，并恢复该文件上次的光标位置 |
| `<leader>!@#$%^&*(`（Shift+1..9） | 精确跳转到标记位置 |
| `V` 后按 `<leader>1..9` | 将指定编号设置为所选行的光标位置；该编号为空时直接创建，并退出可视模式 |
| `<leader>zp` | Snacks picker 搜索位置（`<C-d>` 删除） |
| `<leader>zm` | Popup 管理：`<CR>` 跳转 · `dd` 删除 · `C` 清空当前分组 · `r` 重命名 · `J`/`K` 排序 · `U` 填补编号空缺 · `q` 关闭 |
| `<leader>zv` | 用一条通知显示当前文件的所有位置（编号、行:列、标签） |

例如，即使列表为空，按 `V` 再按 `<leader>5`，也会直接设置编号 **5**。普通模式下，`<leader>5` 会在上次光标位置打开对应文件；按 `<leader>%`（Shift+5）可精确跳回标记位置，1-4 可以保持为空。设置已有编号会保留 ID，以新行文本刷新标签；不同编号可以指向同一个位置。变更和指定编号会立即保存。可视模式更新使用当前光标位置（多行选择也一样）。

删除条目会空出该编号，其他条目不会重新编号。manager 和 picker 显示实际编号，上一个/下一个导航会跳过空编号。manager 中的 `J`/`K` 在已有编号之间重排条目。

在 manager 中按大写 `U`，会按当前顺序将所有条目从 1 连续编号，例如 **1、3、5 → 1、2、3**。新编号立即保存，光标仍停留在同一条目上。

在 manager 中按大写 `C`，会清空当前分组在所有文件中的标记，关闭 manager、移除 gutter 编号并立即保存。通知显示当前分组标识及删除数量。

### 独立标记分组

每个项目有 **q、w、e、r** 四个分组，分别用 `<leader>zq`、`<leader>zw`、`<leader>ze`、`<leader>zr` 选择。各组拥有独立的位置、编号、标签和导航记录，添加、更新、删除、排序和跳转都作用于当前分组。

gutter、manager、picker 和 `<leader>zv` 通知只显示当前分组。manager 和 picker 标题包含当前分组标识，切换时立即刷新；切到空分组会关闭已打开的列表。所有通知也会带上当前标识，例如 `[waymark:w] Waymark 1 added: main.lua:42`。

四组数据及当前选择按项目保存，重启后自动恢复。旧数据自动迁移到 **q**，保留原有 ID、编号和标签。隐藏分组仍会跟随代码编辑移动，但不会显示 gutter 标记。

### 自定义键位

所有键位集中在插件的 `setup()`，通过 `keys` 表覆盖，未写的保持默认；单项设为 `false` 可禁用该键：

```lua
{
  "Michael-Zs/waymark.nvim",
  lazy = false,
  opts = {
    keys = {
      add = "<leader>x",  -- 修改添加键
      picker = false,     -- 禁用 picker 键，需要时用 :lua require("waymark.picker").open()
      -- prev / next / manager / view 同理
      open_prefix = false, -- 禁用 <prefix>1..9 打开文件
      jump_prefix = false, -- 禁用 Shift+数字精确跳转和可视模式更新；也可换成其他前缀，如 "g"
      symbol_q = "<leader>zq", -- symbol_w / symbol_e / symbol_r 同理；设为 false 可禁用
    },
  },
  config = function(_, opts)
    require("waymark").setup(opts)
  end,
}
```

改完重启或 `:Lazy reload waymark.nvim` 生效。

## Gutter 编号

已标记行会在 Neovim 左侧的 sign column 显示 Waymark 编号。编号随代码编辑移动，并在位置更新、删除、排序（`J`/`K`）或连续编号（`U`）后同步刷新。重新打开文件时会恢复已保存的标记。

高亮组 `WaymarkSign` 默认链接到 `Special`，sign 优先级为 20，显示遵循你的 `signcolumn` 设置。同一行有多个标记或其他 sign 时，可用 `vim.opt.signcolumn = "auto:3"` 显示多个。原生 sign 最多占两列，因此大于 99 的编号显示为 `++`；manager 和 picker 仍显示完整编号。

## 设计

- **project-local**：`vim.fs.root(0, {".git"})`，fallback `cwd`；每个 project 一个 JSON 文件
- **持久化**：`stdpath("data")/waymark/<sha256(root)>.json`，版本 3 保存 `active_symbol` 和 `symbols = { q, w, e, r }`，各组条目结构为 `{ id, index, file, line, col, label }`
  （file 绝对路径，编号及 line/col 1-based，id 稳定不随排序变化；版本 1/2 数据迁入 `q`，保留原来的编号）
- **代码移动跟随**：运行时用 extmark 跟随插入/删除，保存/跳转前回写最新位置
- **容错**：JSON 损坏、文件缺失等只影响单条 location，失效项在 picker/manager 中显示 `[missing]`，可删除
- **依赖**：无硬依赖；picker 需要 snacks.nvim（LazyVim 自带），popup manager 用原生 floating window

## API

```lua
require("waymark").add() / .next() / .prev() / .goto_index(n)
require("waymark").update_index(n) -- 用当前位置创建或更新指定编号 n
require("waymark").select_symbol("w") -- 选择 q / w / e / r，成功返回 true
require("waymark").current_symbol() -- 当前项目选中的分组标识
require("waymark").view() -- 通知显示当前文件的位置列表，使用最新行列
require("waymark.store"):list/get/get_index/set_index/add/update/remove/clear/rename/move/compact/save
```

`store.list()` 返回当前分组按 `loc.index` 排序、仅包含已有条目的连续数组；查询指定编号请使用 `store.get_index(n)`，该编号可能为空。数据修改仅作用于当前分组，`store.save()` 保存所有分组。切换分组会触发 `User WaymarkSymbolChanged` autocmd，可通过 `ev.data.symbol` 获取分组标识。
