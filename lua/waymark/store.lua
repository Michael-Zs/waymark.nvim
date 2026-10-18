-- Location 数据 + project-local 持久化 + extmark 运行时跟踪。
--
-- 数据模型（每个 location）:
--   {
--     id    = "wm_...",          -- 稳定 id（与数组顺序无关，reorder 不变）
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

local state = {
  root = nil, -- 当前 project root（绝对路径）
  locations = {}, -- 有序 location 列表
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
  return vim.fs.normalize(vim.fs.root(0, { ".git" }) or vim.uv.cwd())
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
    file = vim.fs.normalize(loc.file),
    line = math.floor(line),
    col = math.max(1, math.floor(col or 1)),
    label = (type(loc.label) == "string" and loc.label ~= "") and loc.label or nil,
  }
end

function M.load()
  local locations = {}
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
    if decoded and type(data) == "table" and type(data.locations) == "table" then
      for _, loc in ipairs(data.locations) do
        local s = sanitize(loc)
        if s then
          table.insert(locations, s)
        end
      end
    elseif not decoded then
      vim.notify("[waymark] 数据文件损坏，已忽略: " .. path, vim.log.levels.WARN)
    end
  end
  state.locations = locations
end

---把 extmark 最新位置回写 location，然后写盘
function M.save()
  M.pull_extmarks()
  local payload = {
    version = 1,
    root = state.root,
    locations = {},
  }
  for i, loc in ipairs(state.locations) do
    payload.locations[i] = {
      id = loc.id,
      file = loc.file,
      line = loc.line,
      col = loc.col,
      label = loc.label,
    }
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
    vim.notify("[waymark] 无法写入 " .. path .. ": " .. tostring(err), vim.log.levels.WARN)
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

---为单个 location 挂 extmark（buffer 内代码插入/删除时位置自动跟随）
function M.attach_extmark(loc, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  detach_extmark(loc)
  local line = math.min(loc.line, math.max(vim.api.nvim_buf_line_count(bufnr), 1)) - 1
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, math.max(0, loc.col - 1), {})
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
  for _, loc in ipairs(state.locations) do
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

function M.sync_all_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.sync_buffer(buf)
    end
  end
end

---把所有仍有效的 extmark 位置回写到 location（保存/跳转前调用）
function M.pull_extmarks()
  for _, loc in ipairs(state.locations) do
    if loc.ext and vim.api.nvim_buf_is_valid(loc.ext.buf) then
      local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, loc.ext.buf, ns, loc.ext.id, {})
      if ok and type(pos) == "table" and pos[1] then
        loc.line, loc.col = pos[1] + 1, pos[2] + 1
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

---返回当前列表（浅拷贝，避免外部误改内部状态；mutate 请走本模块 API）
function M.list()
  return vim.list_extend({}, state.locations)
end

function M.index_of(id)
  for i, loc in ipairs(state.locations) do
    if loc.id == id then
      return i
    end
  end
  return nil
end

function M.get(id)
  local i = M.index_of(id)
  return i and state.locations[i] or nil
end

---添加 location。相同 file+line+col 已存在时返回 (existing, false)，不产生重复。
---@return table location
---@return boolean created
function M.add(file, line, col, label)
  M.pull_buffer(0) -- 代码可能已移动，先同步当前 buffer 已有位置
  for _, loc in ipairs(state.locations) do
    if loc.file == file and loc.line == line and loc.col == col then
      return loc, false
    end
  end
  local loc = {
    id = new_id(),
    file = file,
    line = line,
    col = col,
    label = label,
    ext = nil,
  }
  table.insert(state.locations, loc)
  M.attach_extmark(loc, vim.api.nvim_get_current_buf())
  M.save()
  return loc, true
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

---@return boolean removed
function M.remove(id)
  local i = M.index_of(id)
  if not i then
    return false
  end
  detach_extmark(state.locations[i])
  table.remove(state.locations, i)
  M.save()
  return true
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

---把 id 移到新 index（用于排序）
---@return boolean ok
function M.move(id, new_index)
  local i = M.index_of(id)
  if not i or #state.locations < 2 then
    return false
  end
  new_index = math.max(1, math.min(#state.locations, math.floor(new_index)))
  if new_index == i then
    return false
  end
  local loc = table.remove(state.locations, i)
  table.insert(state.locations, new_index, loc)
  M.save()
  return true
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
