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
      waymark_rename = function(picker, item)
        if not item then
          return
        end
        local loc = item.waymark
        picker:norm(function()
          picker:close()
          vim.schedule(function()
            vim.ui.input({
              prompt = "Waymark label: ",
              default = loc.label or "",
            }, function(input)
              if type(input) == "string" then
                store.rename(loc.id, vim.trim(input))
              end
              M.open()
            end)
          end)
        end)
      end,
    },
    win = {
      input = {
        keys = {
          ["<C-d>"] = { "waymark_delete", mode = { "n", "i" }, desc = "Delete waymark" },
          ["dd"] = { "waymark_delete", mode = { "n" }, desc = "Delete waymark" },
          ["<C-r>"] = { "waymark_rename", mode = { "n", "i" }, desc = "Rename waymark" },
          ["R"] = { "waymark_rename", mode = { "n" }, desc = "Rename waymark" },
        },
      },
      list = {
        keys = {
          ["<C-d>"] = { "waymark_delete", mode = { "n" }, desc = "Delete waymark" },
          ["dd"] = { "waymark_delete", mode = { "n" }, desc = "Delete waymark" },
          ["<C-r>"] = { "waymark_rename", mode = { "n" }, desc = "Rename waymark" },
          ["R"] = { "waymark_rename", mode = { "n" }, desc = "Rename waymark" },
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

local function format_snapshot_preview(locs)
  if #locs == 0 then
    return " No waymarks in snapshot"
  end
  local cells = {}
  local w_where = 0
  for i, loc in ipairs(locs) do
    local missing = not store.file_exists(loc.file)
    local where = vim.fs.basename(loc.file) .. ":" .. loc.line
    if missing then
      where = "[missing] " .. where
    end
    local label = loc.label or ""
    cells[i] = { index = loc.index, where = where, label = label }
    w_where = math.max(w_where, vim.fn.strdisplaywidth(where))
  end
  local w_idx = math.max(#tostring(locs[#locs] and locs[#locs].index or 0), 2)
  local lines = {}
  for i, cell in ipairs(cells) do
    lines[i] = (" %-" .. w_idx .. "d  %-" .. w_where .. "s  %s"):format(cell.index, cell.where, cell.label)
  end
  return table.concat(lines, "\n")
end

local function snapshot_entry(name)
  local locs = store.read_snapshot(name) or {}
  local count = #locs
  return {
    text = ("%s  (%d %s)"):format(name, count, count == 1 and "mark" or "marks"),
    snapshot = name,
    locations = locs,
    preview = {
      text = format_snapshot_preview(locs),
      ft = "waymark",
    },
  }
end

---Open the snapshot picker to load, overwrite, rename, or delete saved snapshots.
---@param opts? { action?: "load"|"save", on_done?: fun(), fallback_select?: boolean }
---@return table|nil
function M.snapshots(opts)
  opts = opts or {}
  local action = opts.action or "load"
  local on_done = opts.on_done

  store.ensure_loaded()
  store.pull_extmarks()
  local names = store.list_snapshots()
  if #names == 0 then
    store.notify("No saved waymark snapshots for this project", vim.log.levels.INFO)
    if on_done then
      on_done()
    end
    return
  end

  local ok, Snacks = pcall(require, "snacks")
  if not (ok and Snacks.picker) then
    if opts.fallback_select then
      local prompt = action == "save" and "Save waymarks to snapshot:" or "Load waymark snapshot:"
      vim.ui.select(names, { prompt = prompt }, function(name)
        if name then
          if action == "save" then
            local saved, err = store.save_snapshot(name)
            store.notify(
              saved and ("Saved waymarks as " .. name) or err,
              saved and vim.log.levels.INFO or vim.log.levels.WARN
            )
          else
            local loaded, err = store.load_snapshot(name)
            store.notify(
              loaded and ("Loaded waymarks: " .. name) or err,
              loaded and vim.log.levels.INFO or vim.log.levels.WARN
            )
          end
        end
        if on_done then
          on_done()
        end
      end)
      return
    end
    store.notify("snacks.picker is required but is not installed", vim.log.levels.WARN)
    return
  end

  local items = {}
  for i, name in ipairs(names) do
    items[i] = snapshot_entry(name)
  end

  local reopening = false
  local title = action == "save" and (" Save Waymarks [" .. store.current_symbol() .. "] ")
    or (" Waymark Snapshots [" .. store.current_symbol() .. "] ")

  active_picker = Snacks.picker({
    title = title,
    items = items,
    preview = "preview",
    confirm = function(picker, item)
      picker:norm(function()
        if picker.closed then
          return
        end
        if item and item.snapshot then
          if action == "save" then
            local saved, err = store.save_snapshot(item.snapshot)
            store.notify(
              saved and ("Saved waymarks as " .. item.snapshot) or err,
              saved and vim.log.levels.INFO or vim.log.levels.WARN
            )
          else
            local loaded, err = store.load_snapshot(item.snapshot)
            store.notify(
              loaded and ("Loaded waymarks: " .. item.snapshot) or err,
              loaded and vim.log.levels.INFO or vim.log.levels.WARN
            )
          end
        end
        picker:close()
      end)
    end,
    on_close = function()
      if not reopening and on_done then
        vim.schedule(on_done)
      end
    end,
    actions = {
      snapshot_delete = function(picker, item)
        if not (item and item.snapshot) then
          return
        end
        local deleted, err = store.delete_snapshot(item.snapshot)
        store.notify(
          deleted and ("Deleted snapshot: " .. item.snapshot) or err,
          deleted and vim.log.levels.INFO or vim.log.levels.WARN
        )
        if deleted and #store.list_snapshots() > 0 then
          reopening = true
          picker:close()
          vim.schedule(function()
            M.snapshots(opts)
          end)
        else
          picker:close()
        end
      end,
      snapshot_rename = function(picker, item)
        if not (item and item.snapshot) then
          return
        end
        local old_name = item.snapshot
        reopening = true
        picker:norm(function()
          picker:close()
          vim.schedule(function()
            vim.ui.input({
              prompt = "Rename snapshot: ",
              default = old_name,
            }, function(input)
              if type(input) == "string" then
                local new_name = vim.trim(input)
                if new_name ~= "" and new_name ~= old_name then
                  local renamed, err = store.rename_snapshot(old_name, new_name)
                  store.notify(
                    renamed and ("Renamed snapshot: " .. old_name .. " -> " .. new_name) or err,
                    renamed and vim.log.levels.INFO or vim.log.levels.WARN
                  )
                end
              end
              M.snapshots(opts)
            end)
          end)
        end)
      end,
    },
    win = {
      input = {
        keys = {
          ["<C-d>"] = { "snapshot_delete", mode = { "n", "i" }, desc = "Delete snapshot" },
          ["dd"] = { "snapshot_delete", mode = { "n" }, desc = "Delete snapshot" },
          ["<C-r>"] = { "snapshot_rename", mode = { "n", "i" }, desc = "Rename snapshot" },
          ["R"] = { "snapshot_rename", mode = { "n" }, desc = "Rename snapshot" },
        },
      },
      list = {
        keys = {
          ["<C-d>"] = { "snapshot_delete", mode = { "n" }, desc = "Delete snapshot" },
          ["dd"] = { "snapshot_delete", mode = { "n" }, desc = "Delete snapshot" },
          ["<C-r>"] = { "snapshot_rename", mode = { "n" }, desc = "Rename snapshot" },
          ["R"] = { "snapshot_rename", mode = { "n" }, desc = "Rename snapshot" },
        },
      },
    },
  })
  vim.api.nvim_create_autocmd("User", {
    pattern = "WaymarkSymbolChanged",
    group = vim.api.nvim_create_augroup("waymark-picker", { clear = true }),
    callback = function()
      if active_picker and not active_picker.closed then
        reopening = true
        active_picker:close()
        M.snapshots(opts)
      end
    end,
  })
  return active_picker
end

return M
