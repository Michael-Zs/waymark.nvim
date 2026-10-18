-- 运行：nvim --headless -u NONE -i NONE -n -l tests/update.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local tmp = vim.fn.tempname()
vim.opt.rtp:prepend(root)
vim.fn.mkdir(tmp .. "/.git", "p")
tmp = vim.uv.fs_realpath(tmp)
vim.env.XDG_DATA_HOME = tmp .. "/data"
vim.cmd.cd(tmp)
vim.o.hidden = true
vim.g.mapleader = " "

local source, target = tmp .. "/source.txt", tmp .. "/target.txt"
local lines = {}
for i = 1, 20 do
  lines[i] = ("  line %02d: example text"):format(i)
end
vim.fn.writefile(lines, source)
vim.fn.writefile(lines, target)

local wm = require("waymark")
local store = wm.store
wm.setup()

local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function clear_number_maps()
  for _, mode in ipairs({ "n", "x" }) do
    for _, prefix in ipairs({ " ", "g" }) do
      for n = 1, 5 do
        pcall(vim.keymap.del, mode, prefix .. n)
      end
    end
  end
end

local tests = {}
local function test(name, fn)
  tests[#tests + 1] = { name, fn }
end

test("V + 数字键更新全部 1-5 项，保留编号并刷新标签", function()
  local before = vim.deepcopy(store.list())
  for n = 1, 5 do
    vim.api.nvim_win_set_cursor(0, { n + 10, 4 })
    press("V " .. n)
    eq(vim.api.nvim_get_mode().mode, "n")
    eq(vim.api.nvim_win_get_cursor(0), { n + 10, 4 })
    local locs = store.list()
    eq(#locs, 5)
    for i, loc in ipairs(locs) do
      eq(loc.id, before[i].id)
    end
    eq({ locs[n].file, locs[n].line, locs[n].col }, { source, n + 10, 5 })
    eq(locs[n].label, lines[n + 10]:sub(3))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    press(" " .. n)
    eq(vim.api.nvim_win_get_cursor(0), { n + 10, 4 })
  end
end)

test("跨文件替换移除旧 extmark，跟随新文件编辑并立即持久化", function()
  local loc = store.list()[1]
  local old_ext = vim.deepcopy(loc.ext)
  local id = loc.id
  vim.cmd.edit(target)
  vim.api.nvim_win_set_cursor(0, { 12, 6 })
  press("V 1")
  eq({ loc.id, loc.file, loc.line, loc.col }, { id, target, 12, 7 })
  eq(vim.api.nvim_buf_get_extmark_by_id(old_ext.buf, store.ns(), old_ext.id, {}), {})
  vim.api.nvim_buf_set_lines(old_ext.buf, 0, 0, false, { "old file insertion" })
  store.pull_extmarks()
  eq(loc.line, 12)
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "new file insertion" })
  store.save()
  eq(loc.line, 13)
  local path = vim.fn.stdpath("data") .. "/waymark/" .. vim.fn.sha256(store.project_root()):sub(1, 16) .. ".json"
  local saved = vim.json.decode(table.concat(vim.fn.readfile(path), "\n")).locations
  eq({ saved[1].id, saved[1].file, saved[1].line, saved[1].col }, { id, target, 13, 7 })
  vim.api.nvim_set_current_buf(old_ext.buf)
  press(" 1")
  eq(store.buf_path(0), target)
  eq(vim.api.nvim_win_get_cursor(0), { 13, 6 })
end)

test("多行可视选择使用当前光标端点", function()
  vim.api.nvim_win_set_cursor(0, { 12, 4 })
  press("Vkk 2")
  eq({ store.list()[2].line, store.list()[2].col }, { 10, 5 })
  eq(vim.api.nvim_get_mode().mode, "n")
end)

test("编号不存在时不新增条目", function()
  store.remove(store.list()[5].id)
  local before = vim.deepcopy(store.list())
  vim.api.nvim_win_set_cursor(0, { 12, 4 })
  press("V 5")
  eq(store.list(), before)
  eq(vim.api.nvim_get_mode().mode, "n")
end)

test("无名 buffer 不覆盖已有位置", function()
  local before = vim.deepcopy(store.list())
  vim.cmd.enew()
  press("V 1")
  eq(store.list(), before)
end)

test("自定义前缀同时支持跳转和可视更新", function()
  clear_number_maps()
  wm.setup({ keys = { jump_prefix = "g" } })
  vim.api.nvim_win_set_cursor(0, { 12, 4 })
  press("Vg3")
  eq({ store.list()[3].line, store.list()[3].col }, { 12, 5 })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press("g3")
  eq(vim.api.nvim_win_get_cursor(0), { 12, 4 })
end)

test("禁用数字前缀时不注册跳转或可视更新键", function()
  clear_number_maps()
  wm.setup({ keys = { jump_prefix = false } })
  for _, mode in ipairs({ "n", "x" }) do
    for n = 1, 9 do
      eq(vim.fn.maparg(" " .. n, mode), "")
    end
  end
end)

local failures = 0
for _, case in ipairs(tests) do
  local ok, err = xpcall(function()
    press("<Esc>")
    for _, loc in ipairs(store.list()) do
      store.remove(loc.id)
    end
    vim.cmd("edit! " .. vim.fn.fnameescape(target))
    vim.cmd("edit! " .. vim.fn.fnameescape(source))
    clear_number_maps()
    wm.setup()
    for n = 1, 5 do
      store.add(source, n, 1, "original " .. n)
    end
    for _, mode in ipairs({ "n", "x" }) do
      for n = 6, 9 do
        eq(vim.fn.maparg(" " .. n, mode), "")
      end
    end
    case[2]()
  end, debug.traceback)
  io.stdout:write((ok and "PASS " or "FAIL ") .. case[1] .. "\n")
  if not ok then
    failures = failures + 1
    io.stderr:write(err .. "\n")
  end
end

vim.api.nvim_del_augroup_by_name("waymark")
vim.fn.delete(tmp, "rf")
io.stdout:write(("%d/%d passed\n"):format(#tests - failures, #tests))
vim.cmd(failures == 0 and "qa!" or "cquit")
