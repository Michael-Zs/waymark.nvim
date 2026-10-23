-- Navigation: jump / next / previous / goto_index (<leader>1..9), with wraparound and cursor positioning.

local store = require("waymark.store")

local M = {}

local last_indices = {} -- Track the previous step independently for each project / set.

local function context(symbol)
	return store.project_root() .. ":" .. (symbol or store.current_symbol())
end

---Jump to a location. Notify and return false if its file is missing.
---@param loc table
---@return boolean ok
local function open_file(file)
  if not store.file_exists(file) then
    store.notify("File not found: " .. file, vim.log.levels.WARN)
    return nil
  end

  -- Reuse a loaded buffer, or open the file in the current window. Switching
  -- buffers this way preserves the window's remembered view/cursor position.
  local buf
  local target = vim.fn.resolve(vim.fn.fnamemodify(file, ":p"))
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name ~= "" and vim.fn.resolve(vim.fn.fnamemodify(name, ":p")) == target then
      buf = b
      break
    end
  end
  if not buf then
    vim.cmd("keepjumps edit " .. vim.fn.fnameescape(file))
    buf = vim.api.nvim_get_current_buf()
  else
    vim.api.nvim_win_set_buf(0, buf)
  end

  store.sync_buffer(buf)
  return buf
end

---Open a location's file without moving to its marked position.
---@param loc table
---@return boolean ok
function M.open_file(loc)
  return open_file(loc.file) ~= nil
end

function M.jump(loc)
  local buf = open_file(loc.file)
  if not buf then
    return false
  end

  -- Prefer the latest extmark position after edits; fall back to the saved position.
  local line, col = loc.line, loc.col
  if loc.ext and loc.ext.buf == buf then
    local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, store.ns(), loc.ext.id, {})
    if ok and type(pos) == "table" and pos[1] then
      line, col = pos[1] + 1, pos[2] + 1
    end
  end

  -- Clamp to the buffer's line range.
  local count = math.max(vim.api.nvim_buf_line_count(buf), 1)
  if line > count then
    line = count
  end

  local win = vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_win_set_cursor, win, { line, math.max(0, col - 1) })
  vim.cmd("normal! zv") -- Open folds at the cursor.

  -- View restoration may close the target fold again; reopen it only if this jump is still current.
  -- Capture the actual cursor (columns may be clamped at EOL); the deferred callback never repositions it.
  local cursor = vim.api.nvim_win_get_cursor(win)
  vim.schedule(function()
    if
      vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_get_current_win() == win
      and vim.api.nvim_win_get_buf(win) == buf
      and vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor)
    then
      vim.cmd("normal! zv")
    end
  end)
  return true
end


---Find the cursor's list index: exact file/line/column match, then nearest line in the same file.
---The caller falls back to the previous step's index if no match is found.
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

---Step through the list with wraparound. delta = 1 (next) / -1 (previous).
local function step(delta, symbol)
  store.ensure_loaded()
  local locs = store.list()
  local n = #locs
  if n == 0 then
    store.notify("No marks in this set; use <leader>zz to add a position", vim.log.levels.INFO)
    return
  end
  store.pull_extmarks()
  local key = context(symbol)
  local cur = current_index() or last_indices[key] or 0
  local idx = math.floor((cur - 1 + delta) % n) + 1 -- Lua's modulo provides wraparound.
  last_indices[key] = idx
  local loc = locs[idx]
  if M.jump(loc) then
    store.notify(("Waymark %d: %s:%d"):format(loc.index, vim.fs.basename(loc.file), loc.line), vim.log.levels.INFO, symbol)
  end
end

function M.step(delta, symbol)
  if symbol then
    return store.with_symbol(symbol, function()
      step(delta, symbol)
    end)
  end
  return step(delta)
end

function M.next()
  M.step(1)
end

function M.previous()
  M.step(-1)
end

---Jump to number n (1-based, as shown in notifications / manager; gaps are allowed).
---@param n integer
---@return boolean ok
function M.goto_index(n)
  n = math.floor(tonumber(n) or 0)
  store.ensure_loaded()
  local locs = store.list()
  local loc = store.get_index(n)
  if not loc then
    store.notify(("No Waymark %d (%d marks in this set)"):format(n, #locs), vim.log.levels.WARN)
    return false
  end
  for i, entry in ipairs(locs) do
    if entry.id == loc.id then
      last_indices[context()] = i -- Step through existing entries, skipping empty slots.
      break
    end
  end
  return M.jump(loc)
end

---Open the file for Waymark number n without moving to its saved location.
---@param n integer
---@return boolean ok
function M.open_index(n)
  n = math.floor(tonumber(n) or 0)
  store.ensure_loaded()
  local locs = store.list()
  local loc = store.get_index(n)
  if not loc then
    store.notify(("No Waymark %d (%d marks in this set)"):format(n, #locs), vim.log.levels.WARN)
    return false
  end
  for i, entry in ipairs(locs) do
    if entry.id == loc.id then
      last_indices[context()] = i
      break
    end
  end
  return M.open_file(loc)
end

return M
