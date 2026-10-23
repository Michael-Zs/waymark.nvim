# waymark.nvim

[English](README.md) | 简体中文

轻量 Location List：基本单位是 **file + exact cursor position**（同一文件可有多个位置）。

每个项目提供四个独立分组，支持位置跳转和命名快照。标记会跟随代码编辑移动，并在重新打开 Neovim 时恢复。

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

## 快速上手

1. 将光标放在需要记录的位置，按 `<leader>zz` 添加标记。
2. 使用 `[z` / `]z` 在当前分组的标记之间跳转。
3. 按 `<leader>zm` 打开 manager，查看、排序或删除标记。
4. 在 manager 中按 `s` 并输入名称保存快照，以后按 `l`（load）选择快照加载。

初始分组是 `q`。每个项目都会记住当前分组并自动保存修改；命名快照用于保留可重复加载的分组副本。

## 全局快捷键

除特别注明外，以下快捷键均用于普通模式。`<leader>` 使用你的 Neovim leader 键。

| 键 | 功能 |
|---|---|
| `<leader>zz` | 用最小空闲编号将当前位置添加到当前分组（重复位置不重复添加） |
| `<leader>zq` / `<leader>zw` / `<leader>ze` / `<leader>zr` | 将当前位置添加到 `q` / `w` / `e` / `r` 分组，不切换当前分组 |
| `<leader>zQ` / `<leader>zW` / `<leader>zE` / `<leader>zR` | 切换当前分组到 `q` / `w` / `e` / `r`，不添加标记 |
| `[z` / `]z` | 当前分组的上一个 / 下一个位置（跨文件，首尾循环） |
| `<leader>[q` / `<leader>]q` | 在 `q` 分组中跳到上一个 / 下一个位置，不切换当前分组（`w` / `e` / `r` 同理） |
| `<leader>1..9` | 打开第 1-9 个位置对应的文件，并恢复该文件上次的光标位置 |
| `<leader>!@#$%^&*(`（Shift+1..9） | 精确跳转到标记位置 |
| `V` 后按 `<leader>1..9` | 将指定编号设置为所选行的光标位置；该编号为空时直接创建，并退出可视模式 |
| `<leader>zp` | Snacks picker 搜索位置（`<C-d>` 删除） |
| `<leader>zm` | 打开当前分组的 [manager](#manager) |
| `<leader>zv` | 用一条通知显示当前文件的所有位置（编号、行:列、标签） |

### 使用编号标记

- `V` 后按 `<leader>5`：在当前光标位置创建或更新编号 **5**，即使 1–4 为空也可以。
- 普通模式下按 `<leader>5`：打开编号 5 对应的文件，恢复该文件上次的光标位置。
- `<leader>%`（US 键盘上的 Shift+5）：跳到编号 5 的精确行列。

更新已有编号会保留 ID，并以新行文本刷新标签。可视模式更新使用光标所在的选择端点，多行选择也一样。不同编号可以指向同一个位置。

删除条目会空出该编号，其他条目不会重新编号。manager 和 picker 显示实际编号，上一个/下一个导航会跳过空编号。manager 中的 `J`/`K` 在已有编号之间重排条目。

## Manager

按 `<leader>zm` 或执行 `:lua require("waymark.ui").open()` 打开。标题显示当前分组，例如 `Waymarks [q]`。每行依次显示标记的**编号**、**文件名:行号**和**标签**；文件不存在时显示 `[missing]`。

### Manager 操作与快捷键

以下按键仅在 manager 内生效，区分大小写。

| 键 | 操作 |
|---|---|
| `j` / `k` | 选择下一行 / 上一行 |
| `<CR>` | 跳到选中标记的精确位置，并关闭 manager |
| `dd` | 删除选中标记，释放其编号 |
| `C` | 清空当前分组在所有文件中的标记，并关闭 manager |
| `R` | 编辑选中标记的标签，输入空内容可清除标签 |
| `J` / `K` | 将选中标记与下一条 / 上一条交换，保留编号空缺 |
| `U` | 将当前分组从 1 连续编号，例如 **1、3、5 → 1、2、3** |
| `s` | 将当前分组保存为命名快照 |
| `l` | 选择快照并加载到当前分组 |
| `q` / `<Esc>` | 关闭 manager |

修改会自动保存。排序和重新编号后，光标仍停留在同一条目上。删除最后一个标记会关闭 manager；分组为空时也可以重新打开以加载快照。

### 保存与加载快照

**保存：**按 `s`，输入名称（例如 `review`）并确认。快照记录当前分组的文件路径、最新位置、标签和编号。同名保存会覆盖已有快照。名称不能包含 `/` 或 `\`。

**加载：**按 `l` 并选择名称。选择器列出当前项目的快照，同一项目的四个分组共享这些快照。加载会**替换当前分组**，保留快照中的编号，其他分组不受影响。例如，可以将 `q` 的快照加载到 `w`，只需先切换到 `w`。

输入或选择结束后（包括取消），manager 会重新打开。没有快照时，按 `l` 会显示通知。

保存使用 `vim.ui.input`，加载使用 `vim.ui.select`，外观取决于你的 Neovim UI 配置。搜索单个标记的 picker（`<leader>zp`）使用 Snacks。

自动保存与快照的文件位置见[存储位置](#存储位置)。

## 独立标记分组

每个项目有 **q、w、e、r** 四个分组。`<leader>zq`、`<leader>zw`、`<leader>ze`、`<leader>zr` 会将当前位置添加到对应分组，但不会改变当前分组；`<leader>zQ`、`<leader>zW`、`<leader>zE`、`<leader>zR` 只切换当前分组，不添加标记。`<leader>[q` / `<leader>]q` 只在 `q` 分组中导航，不切换当前分组，将 `q` 换成 `w`、`e`、`r` 即可操作其他组。各组拥有独立的位置、编号、标签和导航记录，更新、删除、排序和数字跳转都作用于当前分组。

gutter、manager、picker 和 `<leader>zv` 通知只显示当前分组。manager 和 picker 标题包含分组标识，切换时立即刷新。切到空分组时，manager 显示空列表，标记搜索 picker 则关闭。通知带有相关分组标识，例如 `[waymark:w] Waymark 1 added: main.lua:42`。

四组数据及当前选择按项目保存，重启后自动恢复。旧数据自动迁移到 **q**，保留原有 ID、编号和标签。隐藏分组仍会跟随代码编辑移动，但不会显示 gutter 标记。

## 配置

通过 `setup()` 的 `keys` 表覆盖全局快捷键。未指定的键保持默认，单项设为 `false` 可禁用该键。manager 内部快捷键是固定的，不通过此表配置。

```lua
{
  "Michael-Zs/waymark.nvim",
  lazy = false,
  opts = {
    keys = {
      add = "<leader>x",  -- 修改添加键
      picker = false,     -- 禁用 picker 键，需要时用 :lua require("waymark.picker").open()
      manager = "<leader>zm", -- 打开 manager
      -- prev / next / view 同理
      open_prefix = false, -- 禁用 <prefix>1..9 打开文件
      jump_prefix = false, -- 禁用 Shift+数字精确跳转和可视模式更新；也可换成其他前缀，如 "g"
      symbol_q = "<leader>zq", -- 添加到 q 但不切换；symbol_w / symbol_e / symbol_r 同理
      select_q = "<leader>zQ", -- 切换到 q；select_w / select_e / select_r 同理
      prev_q = "<leader>[q",   -- 在 q 中跳到上一个，不切换分组；prev_w / prev_e / prev_r 同理
      next_q = "<leader>]q",   -- 在 q 中跳到下一个，不切换分组；next_w / next_e / next_r 同理
      -- 以上键位均可设为 false 来禁用。
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

## 存储位置

项目以 Git 根目录（`vim.fs.root(0, { ".git" })`）识别，找不到时使用当前工作目录。下方的 `<项目哈希>` 是项目根目录 SHA-256 哈希的前 16 个字符。

| 数据 | 位置 | 保存时机 |
|---|---|---|
| 四个分组及当前选择 | `stdpath("data")/waymark/<项目哈希>.json` | 修改后及退出时自动保存 |
| 单个分组的命名副本 | `stdpath("data")/waymark/snapshots/<项目哈希>/<名称>.json` | 在 manager 中按 `s` 保存 |

在 Neovim 中执行以下命令，查看本机的基础目录：

```vim
:echo stdpath('data') . '/waymark'
```

目前路径固定，没有存储目录配置项。快照按项目隔离，标记使用绝对文件路径。

## 设计

- **project-local**：`vim.fs.root(0, {".git"})`，fallback `cwd`；每个 project 一个 JSON 文件
- **持久化格式**：版本 3 保存 `active_symbol` 和 `symbols = { q, w, e, r }`，各组条目结构为 `{ id, index, file, line, col, label }`
  （file 绝对路径，编号及 line/col 1-based，id 稳定不随排序变化；版本 1/2 数据迁入 `q`，保留原来的编号）
- **代码移动跟随**：运行时用 extmark 跟随插入/删除，保存/跳转前回写最新位置
- **容错**：JSON 损坏、文件缺失等只影响单条 location，失效项在 picker/manager 中显示 `[missing]`，可删除
- **依赖**：无硬依赖；picker 需要 snacks.nvim（LazyVim 自带），popup manager 用原生 floating window

## API

```lua
local waymark = require("waymark")
waymark.add()                 -- 添加到当前分组
waymark.add("w")              -- 添加到 w，不切换分组
waymark.next()                -- 当前分组的下一个；上一个：waymark.prev()
waymark.next("w")             -- w 中的下一个，不切换分组；上一个：waymark.prev("w")
waymark.goto_index(5)         -- 精确跳到编号 5
waymark.update_index(5)       -- 在当前光标位置创建或更新编号 5
waymark.select_symbol("w")    -- 选择 q / w / e / r，成功返回 true
waymark.current_symbol()     -- 当前项目选中的分组标识
waymark.view()               -- 通知显示当前文件的位置列表，使用最新行列

require("waymark.ui").open()     -- manager
require("waymark.picker").open() -- Snacks 标记搜索 picker

local store = waymark.store
store.list()                  -- 当前分组的标记，按编号排序
store.get_index(5)            -- 编号 5 的标记，编号为空时返回 nil
store.save_snapshot("review") -- 成功返回 true, path；失败返回 false, error
store.list_snapshots()        -- 当前项目的快照名称，已排序
store.load_snapshot("review") -- 替换当前分组，返回 true 或 false, error
```

`store.list()` 返回当前分组按 `loc.index` 排序、仅包含已有条目的连续数组；查询指定编号请使用 `store.get_index(n)`，该编号可能为空。数据修改仅作用于当前分组，`store.save()` 保存所有分组。切换分组会触发 `User WaymarkSymbolChanged` autocmd，可通过 `ev.data.symbol` 获取分组标识。
