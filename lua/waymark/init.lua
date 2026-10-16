-- waymark.nvim — 轻量 Location List（file + exact cursor position）
--
-- 所有 keymap 集中在 setup() 中配置，如需调整传入:
--   require("waymark").setup({
--     keys = { add = "<leader>z", prev = "[z", next = "]z",
--              picker = "<leader>sn", manager = "<leader>bm" },
--   })
--
-- 公共 API:
--   require("waymark").add()        添加当前位置
--   .next() / .prev()               下一个 / 上一个（循环）
--   require("waymark.picker").open()  搜索
--   require("waymark.ui").open()      管理 popup
--   require("waymark.store")          数据层（list/get/remove/rename/move/...）

local store = require("waymark.store")
local navigation = require("waymark.navigation")

local M = {}

M.store = store
M.navigation = navigation

---@param opts table|nil { keys = {add,prev,next,picker,manager} }
function M.setup(opts)
  opts = opts or {}
  local keys = vim.tbl_extend("force", {
    add = "<leader>z",
    prev = "[z",
    next = "]z",
    picker = "<leader>sn",
    manager = "<leader>bm",
  }, opts.keys or {})

  store.init()

  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { desc = desc })
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

---添加当前位置（<leader>z）
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

return M
