-- waymark.nvim — lightweight location list (file + exact cursor position).
--
-- Configure all keymaps through setup():
--   require("waymark").setup({
--     keys = { add = "<leader>zz", prev = "[z", next = "]z",
--              picker = "<leader>zp", manager = "<leader>zm", view = "<leader>zv",
--              open_prefix = "<leader>", jump_prefix = "<leader>" },
--   })
--
-- Public API:
--   require("waymark").add()         Add the current position.
--   .next() / .prev()                Next / previous mark, wrapping around.
--   .goto_index(n)                   Jump to number n (used by <leader>1..9).
--   .update_index(n)                 Set number n to the current position, creating it if empty.
--   .view()                          Notify the current file's marks.
--   .select_symbol("q")              Select an independent set (q / w / e / r).
--   require("waymark.picker").open()  Search marks.
--   require("waymark.ui").open()      Open the popup manager.
--   require("waymark.store")          Data layer (list/get/remove/rename/move/...).

local store = require("waymark.store")
local navigation = require("waymark.navigation")

local M = {}

M.store = store
M.navigation = navigation

---@param opts table|nil { keys = {add,prev,next,picker,manager,view,open_prefix,jump_prefix,symbol_q,symbol_w,symbol_e,symbol_r} }
---Set a key to false to disable it; open_prefix maps <prefix>1..9 to file opens, while jump_prefix maps <prefix>!@#$%^&* to precise jumps.
function M.setup(opts)
  opts = opts or {}
  local keys = vim.tbl_extend("force", {
    add = "<leader>zz",
    prev = "[z",
    next = "]z",
    picker = "<leader>zp",
    manager = "<leader>zm",
    view = "<leader>zv",
    open_prefix = "<leader>",
    jump_prefix = "<leader>",
    symbol_q = "<leader>zq",
    symbol_w = "<leader>zw",
    symbol_e = "<leader>ze",
    symbol_r = "<leader>zr",
  }, opts.keys or {})

  store.init()

  local function map(key, fn, desc, mode)
    if not key then -- false/nil disables the key.
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
  map(keys.view, M.view, "Waymark current file")
  for _, symbol in ipairs({ "q", "w", "e", "r" }) do
    map(keys["symbol_" .. symbol], function()
      M.select_symbol(symbol)
    end, "Waymark select [" .. symbol .. "]")
  end

  if keys.open_prefix then
    for d = 1, 9 do
      map(keys.open_prefix .. d, function()
        navigation.open_index(d)
      end, "Waymark open file #" .. d)
    end
  end

  if keys.jump_prefix then -- Shift+number symbols are !@#$%^&*( on a US keyboard.
    local shifted_digits = { "!", "@", "#", "$", "%", "^", "&", "*", "(" }
    for d, key in ipairs(shifted_digits) do
      map(keys.jump_prefix .. key, function()
        navigation.goto_index(d)
      end, "Waymark jump #" .. d)
      map(keys.jump_prefix .. d, function()
        vim.cmd("normal! \27") -- Leave Visual mode, keeping the current cursor position.
        M.update_index(d)
      end, "Waymark update #" .. d, "x")
    end
  end

  vim.api.nvim_set_hl(0, "WaymarkMissing", { default = true, link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "WaymarkSign", { default = true, link = "Special" })

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

---Add the current position (<leader>zz).
function M.add()
  store.ensure_loaded()
  local file = store.buf_path(0)
  if not file then
    store.notify("The current buffer has no associated file", vim.log.levels.WARN)
    return
  end
  local line, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local label = store.make_label(vim.api.nvim_get_current_line())

  local loc, created = store.add(file, line, col0 + 1, label)

  local tail = vim.fs.basename(file)
  if created then
    store.notify(("Waymark %d added: %s:%d"):format(store.index_of(loc.id), tail, line))
  else
    store.notify(("Waymark already exists: %s:%d"):format(tail, line))
  end
end

---Notify the current file's marks in one message (number, latest line:column, label).
function M.view()
  store.ensure_loaded()
  local file = store.buf_path(0)
  if not file then
    store.notify("The current buffer has no associated file", vim.log.levels.INFO)
    return
  end
  store.pull_buffer(0)
  local lines = {}
  for _, loc in ipairs(store.list()) do
    if loc.file == file then
      local label = (loc.label or ""):gsub("[\r\n]", " ")
      lines[#lines + 1] = ("%d  %d:%d%s"):format(loc.index, loc.line, loc.col, label ~= "" and ("  " .. label) or "")
    end
  end
  if #lines == 0 then
    store.notify("No Waymarks in the current file", vim.log.levels.INFO)
    return
  end
  table.insert(lines, 1, vim.fs.basename(file))
  store.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

function M.current_symbol()
  store.ensure_loaded()
  return store.current_symbol()
end

function M.select_symbol(symbol)
  if not store.select_symbol(symbol) then
    return false
  end
  store.notify(("Selected set %s (%d marks)"):format(symbol, #store.list()), vim.log.levels.INFO)
  return true
end

function M.next()
  navigation.next()
end

function M.previous()
  navigation.previous()
end

---Jump to Waymark number n (1-based, as shown in notifications / manager; gaps are allowed).
function M.goto_index(n)
  return navigation.goto_index(n)
end

---Set number n to the current file and cursor; preserve an existing ID or create an empty slot.
---@param n integer
---@return boolean ok
function M.update_index(n)
  store.ensure_loaded()
  n = math.floor(tonumber(n) or 0)
  if n < 1 or n == math.huge or n ~= n then
    store.notify("Waymark numbers must be greater than 0", vim.log.levels.WARN)
    return false
  end
  local file = store.buf_path(0)
  if not file then
    store.notify("The current buffer has no associated file", vim.log.levels.WARN)
    return false
  end
  local line, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local label = store.make_label(vim.api.nvim_get_current_line())
  local _, created = store.set_index(n, file, line, col0 + 1, label)
  store.notify(("Waymark %d %s: %s:%d"):format(n, created and "added" or "updated", vim.fs.basename(file), line))
  return true
end

return M
