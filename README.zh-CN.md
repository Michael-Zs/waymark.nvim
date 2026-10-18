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
| `<leader>z` | 用最小空闲编号添加当前位置（重复位置不重复添加） |
| `[z` / `]z` | 上一个 / 下一个位置（跨文件，首尾循环） |
| `<leader>1..9` | 直跳第 1-9 个位置（按下立即跳转） |
| `V` 后按 `<leader>1..9` | 将指定编号设置为所选行的光标位置；该编号为空时直接创建，并退出可视模式 |
| `<leader>sn` | Snacks picker 搜索位置（`<C-d>` 删除） |
| `<leader>bm` | Popup 管理：`<CR>` 跳转 · `dd` 删除 · `r` 重命名 · `J`/`K` 排序 · `q` 关闭 |

例如，即使列表为空，按 `V` 再按 `<leader>5`，也会直接设置编号 **5**，之后在普通模式按 `<leader>5` 即可跳回该位置，1-4 可以保持为空。设置已有编号会保留 ID，以新行文本刷新标签；不同编号可以指向同一个位置。变更和指定编号会立即保存。可视模式更新使用当前光标位置（多行选择也一样）。

删除条目会空出该编号，其他条目不会重新编号。manager 和 picker 显示实际编号，上一个/下一个导航会跳过空编号。manager 中的 `J`/`K` 在已有编号之间重排条目。

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
      -- prev / next / manager 同理
      jump_prefix = false, -- 禁用数字直跳和可视模式更新；也可换成其他前缀，如 "g"
    },
  },
  config = function(_, opts)
    require("waymark").setup(opts)
  end,
}
```

改完重启或 `:Lazy reload waymark.nvim` 生效。

## 设计

- **project-local**：`vim.fs.root(0, {".git"})`，fallback `cwd`；每个 project 一个 JSON 文件
- **持久化**：`stdpath("data")/waymark/<sha256(root)>.json`，结构 `{ id, index, file, line, col, label }`
  （file 绝对路径，编号及 line/col 1-based，id 稳定不随排序变化；旧数据保留原来的编号）
- **代码移动跟随**：运行时用 extmark 跟随插入/删除，保存/跳转前回写最新位置
- **容错**：JSON 损坏、文件缺失等只影响单条 location，失效项在 picker/manager 中显示 `[missing]`，可删除
- **依赖**：无硬依赖；picker 需要 snacks.nvim（LazyVim 自带），popup manager 用原生 floating window

## API

```lua
require("waymark").add() / .next() / .prev() / .goto_index(n)
require("waymark").update_index(n) -- 用当前位置创建或更新指定编号 n
require("waymark.store"):list/get/get_index/set_index/add/update/remove/rename/move/save
```

`store.list()` 返回按 `loc.index` 排序、仅包含已有条目的连续数组；查询指定编号请使用 `store.get_index(n)`，该编号可能为空。
