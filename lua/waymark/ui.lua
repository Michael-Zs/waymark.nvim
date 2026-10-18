-- Popup manager：原生 floating window / buffer，无 UI framework 依赖。
--
-- 按键：
--   j/k      移动
--   <CR>     跳转并关闭
--   dd       删除当前行
--   r        重命名 label
--   J / K    与下/上面对调（排序）
--   q / Esc  关闭

local store = require("waymark.store")
local navigation = require("waymark.navigation")

local M = {}

local hl_ns = vim.api.nvim_create_namespace("waymark-ui")
local win = nil
local buf = nil
local prev_win = nil

--==========================================================================
-- 渲染
--==========================================================================

---计算每行的三段内容并渲染到 buffer，返回行数
local function render()
  local locs = store.list()
  local cells = {}
  local w_where = 0
  local w_label = 0

  for i, loc in ipairs(locs) do
    local missing = not store.file_exists(loc.file)
    local where = vim.fs.basename(loc.file) .. ":" .. loc.line
    if missing then
      where = "[missing] " .. where
    end
    local label = loc.label or ""
    cells[i] = { index = loc.index, where = where, label = label, missing = missing }
    w_where = math.max(w_where, vim.fn.strdisplaywidth(where))
    w_label = math.max(w_label, vim.fn.strdisplaywidth(label))
  end

  local w_idx = math.max(#tostring(locs[#locs] and locs[#locs].index or 0), 2)
  local lines = {}
  vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)

  for i, cell in ipairs(cells) do
    lines[i] = (" %-" .. w_idx .. "d  %-" .. w_where .. "s  %s"):format(cell.index, cell.where, cell.label)
    if cell.missing then
      vim.api.nvim_buf_set_extmark(buf, hl_ns, i - 1, 0, {
        line_hl_group = "WaymarkMissing",
      })
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  return #lines
end

local function win_config(n_items, text_width)
  local columns = vim.o.columns
  local screen_lines = vim.o.lines
  local width = math.min(math.max(text_width + 4, 30), math.floor(columns * 0.8))
  local height = math.min(n_items + 2, math.max(math.floor(screen_lines * 0.6), 3))
  return {
    relative = "editor",
    border = "rounded",
    title = " Waymarks ",
    title_pos = "center",
    width = width,
    height = height,
    row = math.floor((screen_lines - height - 2) / 2),
    col = math.floor((columns - width - 2) / 2),
    style = "minimal",
    zindex = 50,
  }
end

---渲染后计算实际需要的宽度（用于窗口自适应）
local function content_width()
  local max = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    max = math.max(max, vim.fn.strdisplaywidth(line))
  end
  return max
end

--==========================================================================
-- 操作
--==========================================================================

local function cursor_index()
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  return vim.api.nvim_win_get_cursor(win)[1]
end

local function clamp_cursor()
  local n = math.max(vim.api.nvim_buf_line_count(buf), 1)
  local row = vim.api.nvim_win_get_cursor(win)[1]
  if row > n then
    vim.api.nvim_win_set_cursor(win, { n, 0 })
  elseif row < 1 then
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  end
end

local function refresh()
  local n = render()
  if n == 0 then
    M.close()
    return
  end
  clamp_cursor()
  local cfg = win_config(n, content_width())
  vim.api.nvim_win_set_config(win, cfg)
end

local function delete_current()
  local idx = cursor_index()
  if not idx then
    return
  end
  local locs = store.list()
  local loc = locs[idx]
  if loc then
    store.remove(loc.id)
    vim.notify("[waymark] 已删除 " .. vim.fs.basename(loc.file) .. ":" .. loc.line)
  end
  if #store.list() == 0 then
    M.close()
  else
    refresh()
  end
end

local function rename_current()
  local idx = cursor_index()
  if not idx then
    return
  end
  local loc = store.list()[idx]
  if not loc then
    return
  end
  -- 关闭 popup 再弹输入框，避免焦点/float 冲突；完成后重开刷新
  M.close()
  vim.ui.input({
    prompt = "Waymark label: ",
    default = loc.label or "",
  }, function(input)
    if type(input) == "string" then
      store.rename(loc.id, vim.trim(input))
    end
    M.open()
  end)
end

local function move_current(delta)
  local idx = cursor_index()
  if not idx then
    return
  end
  local locs = store.list()
  local loc = locs[idx]
  local target = locs[idx + delta]
  if not loc or not target then
    return
  end
  store.move(loc.id, target.index)
  refresh()
  -- 光标跟随移动的条目
  vim.api.nvim_win_set_cursor(win, { idx + delta, 0 })
end

local function jump_current()
  local idx = cursor_index()
  local loc = idx and store.list()[idx]
  M.close()
  if loc then
    navigation.jump(loc)
  end
end

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  buf = nil
  if prev_win and vim.api.nvim_win_is_valid(prev_win) then
    pcall(vim.api.nvim_set_current_win, prev_win)
  end
  prev_win = nil
end

function M.is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

function M.open()
  store.ensure_loaded()
  if M.is_open() then
    M.close()
  end
  local locs = store.list()
  if #locs == 0 then
    vim.notify("[waymark] 列表为空，先用 <leader>z 添加位置", vim.log.levels.INFO)
    return
  end

  prev_win = vim.api.nvim_get_current_win()
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].filetype = "waymark"

  local n = render()
  local cfg = win_config(n, content_width())
  win = vim.api.nvim_open_win(buf, true, cfg)
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, desc = "Waymark: " .. desc, nowait = true })
  end

  map("q", M.close, "close")
  map("<Esc>", M.close, "close")
  map("<CR>", jump_current, "jump")
  map("dd", delete_current, "delete")
  map("r", rename_current, "rename")
  map("J", function()
    move_current(1)
  end, "move down")
  map("K", function()
    move_current(-1)
  end, "move up")

  -- 关联窗口关闭时的清理（如 :q 或其他方式关闭）
  vim.api.nvim_create_autocmd("WinClosed", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if win and not vim.api.nvim_win_is_valid(win) then
          win = nil
          buf = nil
          prev_win = nil
        end
      end)
    end,
  })
end

return M
