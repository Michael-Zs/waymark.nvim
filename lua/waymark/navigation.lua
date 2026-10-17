-- 跳转：jump / next / previous / goto_index（<leader>1..5 数字直跳），循环遍历 + cursor 恢复。

local store = require("waymark.store")

local M = {}

local last_index = 0 -- 上一次 step 跳到的位置（1-based），current 检测失败时使用

---跳转到 location。文件不存在时 notify 并安全返回 false。
---@param loc table
---@return boolean ok
function M.jump(loc)
  if not store.file_exists(loc.file) then
    vim.notify("[waymark] File not found: " .. loc.file, vim.log.levels.WARN)
    return false
  end

  -- 找已加载 buffer，否则打开文件（复用当前窗口）
  local buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == loc.file then
      buf = b
      break
    end
  end
  if not buf then
    vim.cmd("keepjumps edit " .. vim.fn.fnameescape(loc.file))
    buf = vim.api.nvim_get_current_buf()
  else
    vim.api.nvim_win_set_buf(0, buf)
  end

  store.sync_buffer(buf) -- 确保 extmark 挂上（重开文件的情况）

  -- 位置优先取 extmark（代码移动后的最新位置），fallback 持久化值
  local line, col = loc.line, loc.col
  if loc.ext and loc.ext.buf == buf then
    local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, store.ns(), loc.ext.id, {})
    if ok and type(pos) == "table" and pos[1] then
      line, col = pos[1] + 1, pos[2] + 1
    end
  end

  -- clamp 到 buffer 范围内
  local count = math.max(vim.api.nvim_buf_line_count(buf), 1)
  if line > count then
    line = count
  end

  local win = vim.api.nvim_get_current_win()
  local function place()
    pcall(vim.api.nvim_win_set_cursor, win, { line, math.max(0, col - 1) })
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd("normal! zv") -- 展开光标处 fold
    end)
  end

  place()
  -- 关键：再 schedule 一次最终定位。vim.schedule 队列 FIFO，
  -- 必然排在 BufWinEnter 触发的异步 view 恢复（如 mkview/loadview）之后，
  -- 覆盖它们对光标的改动。
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      place()
    end
  end)
  return true
end

---判断当前光标在列表中的 index：
---1) 同文件且完全相同的 line/col；2) 同文件距离最近的行；3) 上一次 step 的 index
local function current_index()
  local locs = store.list()
  local file = store.buf_path(0)
  if not file then
    return nil
  end
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local col = col0 + 1
  local best, best_dist
  for i, loc in ipairs(locs) do
    if loc.file == file then
      if loc.line == row and loc.col == col then
        return i
      end
      local d = math.abs(loc.line - row)
      if not best_dist or d < best_dist then
        best, best_dist = i, d
      end
    end
  end
  return best
end

---按列表顺序遍历，首尾循环。delta = 1 (next) / -1 (previous)
function M.step(delta)
  store.ensure_loaded()
  local locs = store.list()
  local n = #locs
  if n == 0 then
    vim.notify("[waymark] 列表为空，先用 <leader>z 添加位置", vim.log.levels.INFO)
    return
  end
  local cur = current_index() or last_index
  local idx = math.floor((cur - 1 + delta) % n) + 1 -- lua % 保证循环
  last_index = idx
  M.jump(locs[idx])
end

function M.next()
  M.step(1)
end

function M.previous()
  M.step(-1)
end

---跳转到列表中第 n 个 location（1-based，即 add 时提示的编号 / manager 左列数字）
---@param n integer
---@return boolean ok
function M.goto_index(n)
  n = math.floor(tonumber(n) or 0)
  store.ensure_loaded()
  local locs = store.list()
  local loc = locs[n]
  if not loc then
    vim.notify(("[waymark] 没有 Waymark %d（共 %d 条）"):format(n, #locs), vim.log.levels.WARN)
    return false
  end
  last_index = n -- 后续 next/prev 从这里继续
  return M.jump(loc)
end

return M
