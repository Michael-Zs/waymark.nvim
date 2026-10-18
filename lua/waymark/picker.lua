-- Picker：基于 Snacks.picker（当前 LazyVim 配置已自带），不引入新依赖。
-- 若 Snacks 不存在则给出提示（不做 fallback UI，保持简单）。

local store = require("waymark.store")
local navigation = require("waymark.navigation")

local M = {}

local function entry(i, loc)
  local missing = not store.file_exists(loc.file)
  local where = vim.fs.basename(loc.file) .. ":" .. loc.line
  return {
    text = ("%d. %s%s  %s"):format(i, missing and "[missing] " or "", where, loc.label or ""),
    -- snacks.picker 标准字段：preview / resolve 需要
    -- 注意：不能把 waymark location 放进 `loc` 字段（snacks 保留给 LSP location）
    file = loc.file,
    pos = { loc.line, loc.col - 1 }, -- { 1-based line, 0-based byte col }
    waymark = loc,
  }
end

local function confirm(picker, item)
  local current = vim.api.nvim_get_current_win()
  local win = picker.main
  -- 先退出输入模式，避免退出时的光标左移被误判为后续导航。
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
    -- 等 picker 完成窗口清理后再跳转；期间的新导航优先。
    vim.schedule(function()
      if
        vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_get_current_win() == win
        and vim.api.nvim_win_get_buf(win) == buf
        and vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor)
      then
        navigation.jump(item.waymark)
      end
    end)
  end)
end

---打开 picker；返回 snacks Picker 实例（便于测试/扩展）
---@return table|nil
function M.open()
  store.ensure_loaded()
  local locs = store.list()
  if #locs == 0 then
    vim.notify("[waymark] 列表为空，先用 <leader>z 添加位置", vim.log.levels.INFO)
    return
  end

  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("[waymark] 需要 snacks.picker（当前配置未安装）", vim.log.levels.WARN)
    return
  end

  local items = {}
  for i, loc in ipairs(locs) do
    items[i] = entry(i, loc)
  end

  return Snacks.picker({
    title = " Waymarks ",
    items = items,
    confirm = confirm,
    actions = {
      waymark_delete = function(picker, item)
        if item then
          store.remove(item.waymark.id)
          vim.notify("[waymark] 已删除: " .. item.waymark.id)
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
end

return M
