-- waymark.nvim — 轻量 Location List（file + exact cursor position）
--
-- 所有 keymap 集中在 setup() 中配置，如需调整传入:
--   require("waymark").setup({
--     keys = { add = "<leader>zz", prev = "[z", next = "]z",
--              picker = "<leader>zp", manager = "<leader>zm",
--              jump_prefix = "<leader>" },
--   })
--
-- 公共 API:
--   require("waymark").add()        添加当前位置
--   .next() / .prev()               下一个 / 上一个（循环）
--   .goto_index(n)                  直跳第 n 个（<leader>1..9 的底层）
--   .update_index(n)                用当前位置设置编号 n，不存在时按该编号创建
--   require("waymark.picker").open()  搜索
--   require("waymark.ui").open()      管理 popup
--   require("waymark.store")          数据层（list/get/remove/rename/move/...）

local store = require("waymark.store")
local navigation = require("waymark.navigation")

local M = {}

M.store = store
M.navigation = navigation

---@param opts table|nil { keys = {add,prev,next,picker,manager,jump_prefix} }，
---单项设 false 可禁用该键；jump_prefix 生成 <prefix>1..9 的普通模式跳转 / 可视模式更新键
function M.setup(opts)
  opts = opts or {}
  local keys = vim.tbl_extend("force", {
    add = "<leader>zz",
    prev = "[z",
    next = "]z",
    picker = "<leader>zp",
    manager = "<leader>zm",
    jump_prefix = "<leader>",
  }, opts.keys or {})

  store.init()

  local function map(key, fn, desc, mode)
    if not key then -- false/nil = 禁用该键
      return
    end
    vim.keymap.set(mode or "n", key, fn, { desc = desc })
  end

  map(keys.add, M.add, "Waymark add")
  map(keys.prev, M.previous, "Waymark prev")
  map(keys.next, M.next, "Waymark next")
  map(keys.picker, function()
    require("waymark.picker").open()
  end, "Waymark picker")
  map(keys.manager, function()
    require("waymark.ui").open()
  end, "Waymark manager")

  if keys.jump_prefix then -- <prefix>1..9 → 普通模式跳转，可视模式更新第 N 个
    for d = 1, 9 do
      map(keys.jump_prefix .. d, function()
        navigation.goto_index(d)
      end, "Waymark jump #" .. d)
      map(keys.jump_prefix .. d, function()
        vim.cmd("normal! \27") -- 退出可视模式，保留当前光标位置
        M.update_index(d)
      end, "Waymark update #" .. d, "x")
    end
  end

  vim.api.nvim_set_hl(0, "WaymarkMissing", { default = true, link = "DiagnosticError" })

  local group = vim.api.nvim_create_augroup("waymark", { clear = true })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(args)
      store.sync_buffer(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      store.shutdown()
    end,
  })
end

---添加当前位置（<leader>zz）
function M.add()
  store.ensure_loaded()
  local file = store.buf_path(0)
  if not file then
    vim.notify("[waymark] 当前 buffer 没有关联文件", vim.log.levels.WARN)
    return
  end
  local line, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local label = store.make_label(vim.api.nvim_get_current_line())

  local loc, created = store.add(file, line, col0 + 1, label)

  local tail = vim.fs.basename(file)
  if created then
    vim.notify(("Waymark %d added: %s:%d"):format(store.index_of(loc.id), tail, line))
  else
    vim.notify(("Waymark already exists: %s:%d"):format(tail, line))
  end
end

function M.next()
  navigation.next()
end

function M.previous()
  navigation.previous()
end

---直跳编号 n 的 waymark（1-based，编号同 add 提示 / manager 左列，可有空缺）
function M.goto_index(n)
  return navigation.goto_index(n)
end

---用当前文件和光标位置设置编号 n；已有条目保留 id，空槽位直接创建
---@param n integer
---@return boolean ok
function M.update_index(n)
  n = math.floor(tonumber(n) or 0)
  if n < 1 or n == math.huge or n ~= n then
    vim.notify("[waymark] Waymark 编号必须大于 0", vim.log.levels.WARN)
    return false
  end
  store.ensure_loaded()
  local file = store.buf_path(0)
  if not file then
    vim.notify("[waymark] 当前 buffer 没有关联文件", vim.log.levels.WARN)
    return false
  end
  local line, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local label = store.make_label(vim.api.nvim_get_current_line())
  local _, created = store.set_index(n, file, line, col0 + 1, label)
  vim.notify(("Waymark %d %s: %s:%d"):format(n, created and "added" or "updated", vim.fs.basename(file), line))
  return true
end

return M
