-- Location 数据 + project-local 持久化 + extmark 运行时跟踪。
--
-- 数据模型（每个 location）:
--   {
--     id    = "wm_...",          -- 稳定 id（与数组顺序无关，reorder 不变）
--     index = 1-based number,    -- 数字槽位，可有空缺；list() 仍返回按编号排序的连续数组
--     file  = "/abs/path",       -- 绝对路径，避免 cwd 变化失效
--     line  = 1-based line
--     col   = 1-based col        -- 内部统一 1-based，与 API 换算见 navigation
--     label = string|nil         -- 缺省为所在行文本的简短版本
--   }
--
-- 存储（project-local）:
--   stdpath("data")/waymark/<sha256(root):16>.json
--   runtime 用 extmark 跟随代码移动；持久化前把 extmark 位置回写。

local M = {}

local DATA_DIR = vim.fn.stdpath("data") .. "/waymark"
local ns = vim.api.nvim_create_namespace("waymark")
local symbols = { "q", "w", "e", "r" }

local state = {
  root = nil, -- 当前 project root（绝对路径）
  locations = {}, -- 按 index 排序的连续 location 数组，不存放空槽位
  symbol = "q",
  symbols = {}, -- 所有分组都保留 extmark，仅当前分组显示 sign
}

--==========================================================================
-- 路径 / 工具
--==========================================================================

function M.ns()
  return ns
end

---buffer 文件名（绝对、规范化）；无名 buffer 返回 nil
function M.buf_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name == "" then
    return nil
  end
  return vim.fs.normalize(name)
end

---project 标识：git root，否则 cwd
function M.project_root()
  if vim.bo.buftype ~= "" and state.root then
    return state.root
  end
  return vim.fs.normalize(vim.fs.root(0, { ".git" }) or vim.uv.cwd())
end

function M.current_symbol()
  return state.symbol
end

function M.notify(message, level)
  vim.notify(("[waymark:%s] %s"):format(state.symbol, message), level)
end

function M.file_exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function data_file(root)
  return ("%s/%s.json"):format(DATA_DIR, vim.fn.sha256(root):sub(1, 16))
end

local function new_id()
  return ("wm_%x"):format(vim.uv.hrtime())
end

local function valid_index(index)
  return type(index) == "number" and index >= 1 and index < math.huge and index == math.floor(index)
end

local function sort_locations()
  table.sort(state.locations, function(a, b)
    return a.index < b.index
  end)
end

---取行文本的简短版本作为缺省 label
function M.make_label(text, width)
  text = (text or ""):gsub("^%s+", "")
  if text == "" then
    return nil
  end
  return vim.fn.strcharpart(text, 0, width or 60)
end

--==========================================================================
-- 加载 / 保存
--==========================================================================

---从磁盘读出的单条 location 校验；坏条目跳过（返回 nil），不让整体失败
local function sanitize(loc)
  if type(loc) ~= "table" or type(loc.file) ~= "string" or loc.file == "" then
    return nil
  end
  local line = tonumber(loc.line)
  local col = tonumber(loc.col)
  if not line or line < 1 then
    return nil
  end
  return {
    id = (type(loc.id) == "string" and loc.id ~= "") and loc.id or new_id(),
    index = valid_index(loc.index) and loc.index or nil,
    file = vim.fs.normalize(loc.file),
    line = math.floor(line),
    col = math.max(1, math.floor(col or 1)),
    label = (type(loc.label) == "string" and loc.label ~= "") and loc.label or nil,
  }
end

local function sanitize_locations(entries)
  local locations = {}
  local used = {}
  for _, loc in ipairs(type(entries) == "table" and entries or {}) do
    local s = sanitize(loc)
    if s then
      -- 旧格式没有 index，沿用原列表编号；损坏的重复编号分配到空槽位。
      s.index = s.index or (#locations + 1)
      while used[s.index] do
        s.index = s.index + 1
      end
      used[s.index] = true
      table.insert(locations, s)
    end
  end
  table.sort(locations, function(a, b)
    return a.index < b.index
  end)
  return locations
end

function M.load()
  state.symbol = "q"
  state.symbols = {}
  for _, symbol in ipairs(symbols) do
    state.symbols[symbol] = {}
  end
  local path = data_file(state.root)
  local ok, content = pcall(function()
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local c = f:read("*a")
    f:close()
    return c
  end)
  if ok and content and content ~= "" then
    local decoded, data = pcall(vim.json.decode, content)
    if decoded and type(data) == "table" then
      if type(data.symbols) == "table" then
        for _, symbol in ipairs(symbols) do
          state.symbols[symbol] = sanitize_locations(data.symbols[symbol])
        end
        if state.symbols[data.active_symbol] then
          state.symbol = data.active_symbol
        end
      else
        state.symbols.q = sanitize_locations(data.locations)
      end
    elseif not decoded then
      M.notify("数据文件损坏，已忽略: " .. path, vim.log.levels.WARN)
    end
  end
  -- 重载或切换 project 时清理旧标记，避免遗留 gutter 编号。
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  state.locations = state.symbols[state.symbol]
end

---把 extmark 最新位置回写 location，然后写盘
function M.save()
  M.pull_extmarks()
  local payload = {
    version = 3,
    root = state.root,
    active_symbol = state.symbol,
    symbols = {},
  }
  for _, symbol in ipairs(symbols) do
    payload.symbols[symbol] = {}
    for i, loc in ipairs(state.symbols[symbol] or {}) do
      payload.symbols[symbol][i] = {
        id = loc.id,
        index = loc.index,
        file = loc.file,
        line = loc.line,
        col = loc.col,
        label = loc.label,
      }
    end
  end
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then
    return
  end
  vim.fn.mkdir(DATA_DIR, "p")
  local path = data_file(state.root)
  local ok_w, err = pcall(function()
    local f = assert(io.open(path, "w"))
    f:write(encoded, "\n")
    f:close()
  end)
  if not ok_w then
    M.notify("无法写入 " .. path .. ": " .. tostring(err), vim.log.levels.WARN)
  end
end

---确保当前 project 数据已加载；root 变化时先保存旧 project 再切换
function M.ensure_loaded()
  local root = M.project_root()
  if root ~= state.root then
    if state.root then
      M.save() -- 保存旧 project（内部会 pull 最新位置）
    end
    state.root = root
    M.load()
    M.sync_all_buffers()
  end
  return state.root
end

--==========================================================================
-- extmark 运行时跟踪
--==========================================================================

local function detach_extmark(loc)
  if loc.ext and vim.api.nvim_buf_is_valid(loc.ext.buf) then
    pcall(vim.api.nvim_buf_del_extmark, loc.ext.buf, ns, loc.ext.id)
  end
  loc.ext = nil
end

local function sign_options(loc)
  if M.get(loc.id) ~= loc then
    return {}
  end
  return {
    -- 原生 sign 最多占两列；大编号仍保留完整位置跟踪。
    sign_text = loc.index <= 99 and tostring(loc.index) or "++",
    sign_hl_group = "WaymarkSign",
    priority = 20,
  }
end

---编号变化时原地更新 sign，使用 extmark 的最新位置，避免回退代码编辑后的位移。
local function refresh_signs()
  for _, locations in pairs(state.symbols) do
    for _, loc in ipairs(locations) do
      if loc.ext and vim.api.nvim_buf_is_loaded(loc.ext.buf) then
        local pos = vim.api.nvim_buf_get_extmark_by_id(loc.ext.buf, ns, loc.ext.id, {})
        if pos[1] and pos[1] >= 0 then
          local opts = sign_options(loc)
          opts.id = loc.ext.id
          opts.strict = false
          vim.api.nvim_buf_set_extmark(loc.ext.buf, ns, pos[1], pos[2], opts)
        end
      end
    end
  end
end

---切换独立分组，保留所有 extmark 的位置跟踪。
function M.select_symbol(symbol)
  M.ensure_loaded()
  if not state.symbols[symbol] then
    M.notify("未知分组: " .. tostring(symbol), vim.log.levels.WARN)
    return false
  end
  if symbol ~= state.symbol then
    state.symbol = symbol
    state.locations = state.symbols[symbol]
    refresh_signs()
    M.save()
    vim.api.nvim_exec_autocmds("User", { pattern = "WaymarkSymbolChanged", data = { symbol = symbol } })
  end
  return true
end

---为单个 location 挂带编号 sign 的 extmark（buffer 内代码插入/删除时位置自动跟随）
function M.attach_extmark(loc, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  detach_extmark(loc)
  local line = math.min(loc.line, math.max(vim.api.nvim_buf_line_count(bufnr), 1)) - 1
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, math.max(0, loc.col - 1), sign_options(loc))
  if ok then
    loc.ext = { buf = bufnr, id = id }
  end
end

---为指定 buffer 的所有 location（重新）挂 extmark。
---已有有效 extmark 的跳过（避免重挂抹掉 extmark 对代码编辑的漂移跟踪）。
function M.sync_buffer(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local path = M.buf_path(bufnr)
  if not path then
    return
  end
  for _, locations in pairs(state.symbols) do
    for _, loc in ipairs(locations) do
      if loc.file == path then
        local attached = false
        if loc.ext and loc.ext.buf == bufnr then
          local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, ns, loc.ext.id, {})
          -- 不存在的 extmark 返回 {-1, -1}
          attached = ok and type(pos) == "table" and pos[1] ~= nil and pos[1] >= 0
        end
        if not attached then
          M.attach_extmark(loc, bufnr)
        end
      end
    end
  end
end

function M.sync_all_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.sync_buffer(buf)
    end
  end
end

---把所有仍有效的 extmark 位置回写到 location（保存/跳转前调用）
function M.pull_extmarks()
  for _, locations in pairs(state.symbols) do
    for _, loc in ipairs(locations) do
      if loc.ext and vim.api.nvim_buf_is_valid(loc.ext.buf) then
        local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, loc.ext.buf, ns, loc.ext.id, {})
        if ok and type(pos) == "table" and pos[1] and pos[1] >= 0 then
          loc.line, loc.col = pos[1] + 1, pos[2] + 1
        end
      end
    end
  end
end

---只回写某个 buffer 的 extmark（add 去重检测前用，避免代码移动后误判重复）
function M.pull_buffer(bufnr)
  local path = M.buf_path(bufnr)
  if not path then
    return
  end
  for _, loc in ipairs(state.locations) do
    if loc.file == path and loc.ext and vim.api.nvim_buf_is_valid(loc.ext.buf) then
      local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, loc.ext.buf, ns, loc.ext.id, {})
      if ok and type(pos) == "table" and pos[1] then
        loc.line, loc.col = pos[1] + 1, pos[2] + 1
      end
    end
  end
end

--==========================================================================
-- 增删改查 / 排序
--==========================================================================

---返回按编号排序的连续数组，仅含实际条目；数字槽位使用 loc.index / get_index()。
---浅拷贝，mutate 请走本模块 API。
function M.list()
  return vim.list_extend({}, state.locations)
end

local function position_of(id)
  for i, loc in ipairs(state.locations) do
    if loc.id == id then
      return i
    end
  end
  return nil
end

function M.get(id)
  local i = position_of(id)
  return i and state.locations[i] or nil
end

---返回条目的数字槽位，不是 list() 中的数组下标。
function M.index_of(id)
  local loc = M.get(id)
  return loc and loc.index or nil
end

function M.get_index(index)
  for _, loc in ipairs(state.locations) do
    if loc.index == index then
      return loc
    end
  end
end

---添加 location。相同 file+line+col 已存在时返回 (existing, false)，不产生重复。
---新条目使用最小空闲编号。
---@return table location
---@return boolean created
function M.add(file, line, col, label)
  M.pull_buffer(0) -- 代码可能已移动，先同步当前 buffer 已有位置
  for _, loc in ipairs(state.locations) do
    if loc.file == file and loc.line == line and loc.col == col then
      return loc, false
    end
  end
  local index = 1
  for _, loc in ipairs(state.locations) do
    if loc.index ~= index then
      break
    end
    index = index + 1
  end
  return M.set_index(index, file, line, col, label)
end

---更新 location 的位置和 label，保留稳定 id / 列表顺序，并把 extmark 移到当前 buffer。
---@return boolean ok
function M.update(id, file, line, col, label)
  local loc = M.get(id)
  if not loc then
    return false
  end
  loc.file, loc.line, loc.col, loc.label = file, line, col, label
  M.attach_extmark(loc, vim.api.nvim_get_current_buf())
  M.save()
  return true
end

---设置指定数字槽位，不存在时直接创建；允许不同槽位指向相同位置。
---@return table|nil location
---@return boolean created
function M.set_index(index, file, line, col, label)
  if not valid_index(index) then
    return nil, false
  end
  local loc = M.get_index(index)
  if loc then
    M.update(loc.id, file, line, col, label)
    return loc, false
  end
  loc = { id = new_id(), index = index, file = file, line = line, col = col, label = label }
  table.insert(state.locations, loc)
  sort_locations()
  M.attach_extmark(loc, vim.api.nvim_get_current_buf())
  M.save()
  return loc, true
end

---@return boolean removed
function M.remove(id)
  local i = position_of(id)
  if not i then
    return false
  end
  detach_extmark(state.locations[i])
  table.remove(state.locations, i)
  M.save()
  return true
end

---清空当前分组，移除其所有 extmark 并一次性保存。
---@return integer removed
function M.clear()
  local count = #state.locations
  if count == 0 then
    return 0
  end
  for i = count, 1, -1 do
    detach_extmark(state.locations[i])
    state.locations[i] = nil
  end
  M.save()
  return count
end

---修改 label（label 为空串/nil 时清除）
---@return boolean ok
function M.rename(id, label)
  local loc = M.get(id)
  if not loc then
    return false
  end
  loc.label = (label and label ~= "") and label or nil
  M.save()
  return true
end

---把 id 移到新编号；目标已占用时在现有编号间重排，空缺编号保持不变。
---@return boolean ok
function M.move(id, new_index)
  local i = position_of(id)
  if not i or not valid_index(new_index) then
    return false
  end
  local loc = state.locations[i]
  if new_index == loc.index then
    return false
  end
  local target = M.get_index(new_index)
  if target then
    local target_pos = position_of(target.id)
    local indices = {}
    for j, entry in ipairs(state.locations) do
      indices[j] = entry.index
    end
    table.remove(state.locations, i)
    table.insert(state.locations, target_pos, loc)
    for j, entry in ipairs(state.locations) do
      entry.index = indices[j]
    end
  else
    loc.index = new_index
    sort_locations()
  end
  refresh_signs()
  M.save()
  return true
end

---按当前顺序从 1 连续编号，填补空缺，保留条目及其 extmark。
---@return boolean changed
function M.compact()
  local changed = false
  for i, loc in ipairs(state.locations) do
    if loc.index ~= i then
      loc.index = i
      changed = true
    end
  end
  if changed then
    refresh_signs()
    M.save()
  end
  return changed
end

--==========================================================================
-- 初始化
--==========================================================================

function M.init()
  state.root = M.project_root()
  M.load()
  M.sync_all_buffers()
end

function M.shutdown()
  M.save()
end

return M
