-- Picker: uses Snacks.picker (included in LazyVim), with no additional dependencies.
-- Notify when Snacks is unavailable; keep the UI simple without a fallback.

local store = require("waymark.store")
local navigation = require("waymark.navigation")

local M = {}
local active_picker

local function same_context(root, symbol)
  return store.project_root() == root and store.current_symbol() == symbol
end

local function entry(loc)
  local missing = not store.file_exists(loc.file)
  local where = vim.fs.basename(loc.file) .. ":" .. loc.line
  return {
    text = ("%d. %s%s  %s"):format(loc.index, missing and "[missing] " or "", where, loc.label or ""),
    -- Standard Snacks.picker fields used by preview / resolve.
    -- Store Waymark data outside `loc`, which Snacks reserves for LSP locations.
    file = loc.file,
    pos = { loc.line, loc.col - 1 }, -- { 1-based line, 0-based byte col }
    waymark = loc,
  }
end

local function confirm(picker, item)
  local root, symbol = store.project_root(), store.current_symbol()
  local current = vim.api.nvim_get_current_win()
  local win = picker.main
  -- Leave Insert mode first so its cursor shift is not mistaken for subsequent navigation.
  picker:norm(function()
    if picker.closed or vim.api.nvim_get_current_win() ~= current then
      return
    end
    picker:close()
    if not item or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_get_current_win() ~= win then
      return
    end

    local buf = vim.api.nvim_win_get_buf(win)
    local cursor = vim.api.nvim_win_get_cursor(win)
    -- Jump after picker window cleanup; any intervening navigation takes precedence.
    vim.schedule(function()
      if
        vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_get_current_win() == win
        and vim.api.nvim_win_get_buf(win) == buf
        and vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor)
        and same_context(root, symbol)
      then
        navigation.jump(item.waymark)
      end
    end)
  end)
end

---Open the picker and return the Snacks Picker instance for tests / extensions.
---@return table|nil
function M.open()
  store.ensure_loaded()
  store.pull_extmarks()
  local locs = store.list()
  if #locs == 0 then
    store.notify("No marks in this set; use <leader>zz to add a position", vim.log.levels.INFO)
    return
  end

  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    store.notify("snacks.picker is required but is not installed", vim.log.levels.WARN)
    return
  end

  local items = {}
  for i, loc in ipairs(locs) do
    items[i] = entry(loc)
  end

  active_picker = Snacks.picker({
    title = " Waymarks [" .. store.current_symbol() .. "] ",
    items = items,
    confirm = confirm,
    actions = {
      waymark_delete = function(picker, item)
        if item then
          store.remove(item.waymark.id)
          store.notify("Deleted: " .. item.waymark.id)
        end
        picker:close()
      end,
    },
    win = {
      input = {
        keys = {
          ["<C-d>"] = { "waymark_delete", mode = { "n", "i" }, desc = "Delete waymark" },
        },
      },
    },
  })
  vim.api.nvim_create_autocmd("User", {
    pattern = "WaymarkSymbolChanged",
    group = vim.api.nvim_create_augroup("waymark-picker", { clear = true }),
    callback = function()
      if active_picker and not active_picker.closed then
        active_picker:close()
        M.open()
      end
    end,
  })
  return active_picker
end

return M
