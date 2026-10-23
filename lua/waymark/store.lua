-- Location data, project-local persistence, and runtime extmark tracking.
--
-- Data model (per location):
--   {
--     id    = "wm_...",          -- Stable ID, independent of array order and reordering.
--     index = 1-based number,    -- Numbered slot; gaps are allowed. list() returns a dense, sorted array.
--     file  = "/abs/path",       -- Absolute path, unaffected by cwd changes.
--     line  = 1-based line
--     col   = 1-based col        -- Internally 1-based; see navigation for API conversions.
--     label = string|nil         -- Defaults to a shortened version of the line text.
--   }
--
-- Storage (project-local):
--   stdpath("data")/waymark/<sha256(root):16>.json
--   Runtime extmarks follow code edits; their positions are pulled back before persistence.

local M = {}
local detach_extmark

local DATA_DIR = vim.fn.stdpath("data") .. "/waymark"
local ns = vim.api.nvim_create_namespace("waymark")
local symbols = { "q", "w", "e", "r" }

local state = {
  root = nil, -- Current project root (absolute path).
  locations = {}, -- Dense location array sorted by index; empty slots are omitted.
  symbol = "q",
  symbols = {}, -- All sets keep extmarks; only the selected set displays signs.
}

--==========================================================================
-- Paths / utilities
--==========================================================================

function M.ns()
  return ns
end

---Return the normalized absolute buffer filename, or nil for an unnamed buffer.
function M.buf_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name == "" then
    return nil
  end
  return vim.fs.normalize(name)
end

---Identify the project by its Git root, falling back to cwd.
function M.project_root()
  if vim.bo.buftype ~= "" and state.root then
    return state.root
  end
  return vim.fs.normalize(vim.fs.root(0, { ".git" }) or vim.uv.cwd())
end

function M.current_symbol()
  return state.symbol
end

function M.notify(message, level, symbol)
  vim.notify(("[waymark:%s] %s"):format(symbol or state.symbol, message), level)
end

function M.file_exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

local function data_file(root)
  return ("%s/%s.json"):format(DATA_DIR, vim.fn.sha256(root):sub(1, 16))
end

local function snapshot_dir(root)
  return ("%s/snapshots/%s"):format(DATA_DIR, vim.fn.sha256(root):sub(1, 16))
end

local function snapshot_path(name)
  return snapshot_dir(state.root) .. "/" .. name .. ".json"
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

---Shorten the line text for use as a default label.
function M.make_label(text, width)
  text = (text or ""):gsub("^%s+", "")
  if text == "" then
    return nil
  end
  return vim.fn.strcharpart(text, 0, width or 60)
end

--==========================================================================
-- Loading / saving
--==========================================================================

---Validate a saved location; skip invalid entries by returning nil without failing the entire load.
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
      -- Preserve list numbering for legacy entries without index; move duplicate numbers to free slots.
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
      M.notify("Ignored corrupt data file: " .. path, vim.log.levels.WARN)
    end
  end
  -- Clear old marks when reloading or switching projects to avoid stale gutter numbers.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  state.locations = state.symbols[state.symbol]
end

---Pull the latest extmark positions into locations, then save to disk.
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
    M.notify("Unable to write " .. path .. ": " .. tostring(err), vim.log.levels.WARN)
  end
end

---Save the currently selected set as a named snapshot.
function M.save_snapshot(name)
  M.ensure_loaded()
  name = vim.trim(name or "")
  if name == "" or name:find("[/\\]") or name == "." or name == ".." then
    return false, "Snapshot name must be non-empty and cannot contain path separators"
  end
  M.pull_extmarks()
  local payload = { version = 1, root = state.root, symbol = state.symbol, locations = {} }
  for i, loc in ipairs(state.locations) do
    payload.locations[i] = {
      index = loc.index, file = loc.file, line = loc.line, col = loc.col, label = loc.label,
    }
  end
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then
    return false, tostring(encoded)
  end
  local dir = snapshot_dir(state.root)
  vim.fn.mkdir(dir, "p")
  local path = snapshot_path(name)
  local wrote, err = pcall(function()
    local f = assert(io.open(path, "w"))
    f:write(encoded, "\n")
    f:close()
  end)
  if not wrote then
    return false, tostring(err)
  end
  return true, path
end

---List named snapshots for the current project.
function M.list_snapshots()
  M.ensure_loaded()
  local dir = snapshot_dir(state.root)
  local names = {}
  for _, path in ipairs(vim.fn.glob(dir .. "/*.json", false, true)) do
    names[#names + 1] = vim.fn.fnamemodify(path, ":t:r")
  end
  table.sort(names)
  return names
end

---Replace the current set with a named snapshot, preserving other sets.
function M.load_snapshot(name)
  M.ensure_loaded()
  if type(name) ~= "string" or name == "" or name:find("[/\\]") then
    return false, "Invalid snapshot name"
  end
  local path = snapshot_path(name)
  local f = io.open(path, "r")
  if not f then
    return false, "Snapshot not found: " .. name
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" or type(data.locations) ~= "table" then
    return false, "Invalid snapshot: " .. name
  end
  M.pull_extmarks()
  for _, loc in ipairs(state.locations) do
    detach_extmark(loc)
  end
  local locations = sanitize_locations(data.locations)
  for _, loc in ipairs(locations) do
    for _, existing in ipairs(locations) do
      if existing ~= loc and existing.id == loc.id then
        loc.id = new_id()
        break
      end
    end
  end
  state.symbols[state.symbol] = locations
  state.locations = locations
  M.sync_all_buffers()
  M.save()
  return true
end

---Ensure the current project is loaded; save the previous project before switching roots.
function M.ensure_loaded()
  local root = M.project_root()
  if root ~= state.root then
    if state.root then
      M.save() -- Save the previous project, pulling its latest positions first.
    end
    state.root = root
    M.load()
    M.sync_all_buffers()
  end
  return state.root
end

--==========================================================================
-- Runtime extmark tracking
--==========================================================================

detach_extmark = function(loc)
  if loc.ext and vim.api.nvim_buf_is_valid(loc.ext.buf) then
    pcall(vim.api.nvim_buf_del_extmark, loc.ext.buf, ns, loc.ext.id)
  end
  loc.ext = nil
end

local function sign_options(loc)
  local active = false
  for _, current in ipairs(state.symbols[state.symbol] or {}) do
    if current.id == loc.id then
      active = true
      break
    end
  end
  if not active then
    return {}
  end
  return {
    -- Native signs occupy at most two columns; large numbers still retain full position tracking.
    sign_text = loc.index <= 99 and tostring(loc.index) or "++",
    sign_hl_group = "WaymarkSign",
    priority = 20,
  }
end

---Update signs in place after numbering changes, preserving the latest positions after code edits.
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

---Select an independent set, preserving position tracking for every extmark.
function M.select_symbol(symbol)
  M.ensure_loaded()
  if not state.symbols[symbol] then
    M.notify("Unknown set: " .. tostring(symbol), vim.log.levels.WARN)
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

---Attach an extmark with a numbered sign to a location; it follows buffer insertions / deletions.
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

---Attach or restore extmarks for all locations in the given buffer.
---Skip valid extmarks to preserve position changes tracked during code edits.
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
          -- Missing extmarks may return {-1, -1}.
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

---Pull all valid extmark positions into locations before saving / jumping.
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

---Pull one buffer's extmarks before duplicate detection so code edits do not produce false duplicates.
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
-- CRUD / ordering
--==========================================================================

---Return a dense array of existing entries sorted by number; use loc.index / get_index() for slots.
---This is a shallow copy; use this module's API for mutations.
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

---Return the entry's numbered slot, not its array position in list().
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

---Add a location. Return (existing, false) for a matching file+line+col without creating a duplicate.
---New entries use the lowest free number.
---@return table location
---@return boolean created
function M.add(file, line, col, label)
  M.pull_buffer(0) -- Synchronize existing positions in the current buffer after code edits.
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

---Add a location to a specific set without changing the active set.
---@return table|nil location
---@return boolean created
function M.add_to_symbol(symbol, file, line, col, label)
  M.ensure_loaded()
  local locations = state.symbols[symbol]
  if not locations then
    M.notify("Unknown set: " .. tostring(symbol), vim.log.levels.WARN)
    return nil, false
  end
  local active = state.locations
  state.locations = locations
  local ok, loc, created = pcall(M.add, file, line, col, label)
  state.locations = active
  if not ok then
    error(loc)
  end
  return loc, created
end

---Run an operation against a set without changing the active set.
function M.with_symbol(symbol, callback)
  M.ensure_loaded()
  local locations = state.symbols[symbol]
  if not locations then
    M.notify("Unknown set: " .. tostring(symbol), vim.log.levels.WARN)
    return false
  end
  local active = state.locations
  state.locations = locations
  local ok, result = pcall(callback)
  state.locations = active
  if not ok then
    error(result)
  end
  return result
end

---Update a location and label, preserving its stable ID / order and moving its extmark to the current buffer.
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

---Set a numbered slot, creating it if empty; different slots may point to the same position.
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

---Clear the current set, remove all its extmarks, and save once.
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

---Rename a label; nil or an empty string clears it.
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

---Move an ID to a new number; reorder occupied slots when the target is taken, preserving gaps.
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

---Renumber consecutively from 1 in the current order, preserving entries and their extmarks.
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
-- Initialization
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
