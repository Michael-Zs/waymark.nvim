# waymark.nvim

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
| `<leader>z` | 添加当前位置（重复位置不重复添加） |
| `[z` / `]z` | 上一个 / 下一个位置（跨文件，首尾循环） |
| `<leader>1..5` | 直跳第 1-5 个位置（按下立即跳转）。只占 1..5，`6..9` 不覆盖（留给 LazyVim 的 buffer 键） |
| `<leader>sn` | Snacks picker 搜索位置（`<C-d>` 删除） |
| `<leader>bm` | Popup 管理：`<CR>` 跳转 · `dd` 删除 · `r` 重命名 · `J`/`K` 排序 · `q` 关闭 |

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
      jump_prefix = false, -- 禁用 <leader>1..5 数字直跳；也可换成其他前缀，如 "g"
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
- **持久化**：`stdpath("data")/waymark/<sha256(root)>.json`，结构 `{ id, file, line, col, label }`
  （file 绝对路径，line/col 1-based，id 稳定不随排序变化）
- **代码移动跟随**：运行时用 extmark 跟随插入/删除，保存/跳转前回写最新位置
- **容错**：JSON 损坏、文件缺失等只影响单条 location，失效项在 picker/manager 中显示 `[missing]`，可删除
- **依赖**：无硬依赖；picker 需要 snacks.nvim（LazyVim 自带），popup manager 用原生 floating window

## API

```lua
require("waymark").add() / .next() / .prev() / .goto_index(n)
require("waymark.store"):list/get/add/remove/rename/move/save
```
