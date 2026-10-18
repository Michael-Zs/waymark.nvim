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
      for n = 1, 9 do
        pcall(vim.keymap.del, mode, prefix .. n)
      end
    end
  end
end

local tests = {}
local function test(name, fn)
  tests[#tests + 1] = { name, fn }
end

test("V + 数字键更新全部 1-9 项，保留编号并刷新标签", function()
  for n = 6, 9 do
    store.add(source, n, 1, "original " .. n)
  end
  local before = vim.deepcopy(store.list())
  for n = 1, 9 do
    vim.api.nvim_win_set_cursor(0, { n + 10, 4 })
    press("V " .. n)
    eq(vim.api.nvim_get_mode().mode, "n")
    eq(vim.api.nvim_win_get_cursor(0), { n + 10, 4 })
    local locs = store.list()
    eq(#locs, 9)
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

test("编号不存在时直接创建，保留已有条目并可跳转", function()
  store.remove(store.list()[5].id)
  local before = vim.deepcopy(store.list())
  vim.api.nvim_win_set_cursor(0, { 12, 4 })
  press("V 5")
  local locs = store.list()
  eq(#locs, 5)
  for i, loc in ipairs(before) do
    eq(locs[i], loc)
  end
  eq({ locs[5].file, locs[5].line, locs[5].col }, { source, 12, 5 })
  eq(locs[5].label, lines[12]:sub(3))
  eq(vim.api.nvim_get_mode().mode, "n")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press(" 5")
  eq(vim.api.nvim_win_get_cursor(0), { 12, 4 })
end)

test("空列表可直接用数字键依次创建 1-9 项并持久化", function()
  for _, loc in ipairs(store.list()) do
    store.remove(loc.id)
  end
  for n = 1, 9 do
    vim.api.nvim_win_set_cursor(0, { n + 10, 4 })
    press("V " .. n)
    eq(vim.api.nvim_get_mode().mode, "n")
    local locs = store.list()
    eq(#locs, n)
    eq({ locs[n].file, locs[n].line, locs[n].col }, { source, n + 10, 5 })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    press(" " .. n)
    eq(vim.api.nvim_win_get_cursor(0), { n + 10, 4 })
  end
  local path = vim.fn.stdpath("data") .. "/waymark/" .. vim.fn.sha256(store.project_root()):sub(1, 16) .. ".json"
  local saved = vim.json.decode(table.concat(vim.fn.readfile(path), "\n")).locations
  eq(#saved, 9)
  for n, loc in ipairs(saved) do
    eq({ loc.id, loc.file, loc.line, loc.col }, { store.list()[n].id, source, n + 10, 5 })
  end
end)

test("空列表直接设置 5，普通模式按 5 可跳转，重复设置只更新", function()
  for _, loc in ipairs(store.list()) do
    store.remove(loc.id)
  end
  vim.api.nvim_win_set_cursor(0, { 12, 4 })
  local notify = vim.notify
  local messages = {}
  vim.notify = function(message)
    messages[#messages + 1] = message
  end
  press("V 5")
  press("V 5")
  vim.notify = notify
  local locs = store.list()
  eq(#locs, 1)
  eq({ locs[1].index, locs[1].file, locs[1].line, locs[1].col }, { 5, source, 12, 5 })
  eq(messages[1], "Waymark 5 added: source.txt:12")
  eq(messages[2], "Waymark 5 updated: source.txt:12")
  for n = 1, 4 do
    eq(store.get_index(n), nil)
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press(" 5")
  eq(vim.api.nvim_win_get_cursor(0), { 12, 4 })
  local id = locs[1].id
  vim.api.nvim_win_set_cursor(0, { 16, 2 })
  press("V 5")
  eq(#store.list(), 1)
  eq(store.get_index(5).id, id)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press(" 5")
  eq(vim.api.nvim_win_get_cursor(0), { 16, 2 })
end)

test("跨进程加载保留空槽位，仍可按 5 跳转", function()
  for _, loc in ipairs(store.list()) do
    store.remove(loc.id)
  end
  vim.api.nvim_win_set_cursor(0, { 12, 4 })
  press("V 5")
  local id = store.get_index(5).id
  local child = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE", "-n" }, {
    rpc = true,
    env = { XDG_DATA_HOME = vim.env.XDG_DATA_HOME },
  })
  local ok, err = xpcall(function()
    vim.rpcrequest(
      child,
      "nvim_exec_lua",
      [[
        local root, source, id = ...
        vim.opt.rtp:prepend(root)
        vim.g.mapleader = " "
        vim.cmd.edit(source)
        local wm = require("waymark")
        wm.setup()
        assert(#wm.store.list() == 1)
        assert(wm.store.get_index(1) == nil)
        assert(wm.store.get_index(5).id == id)
        vim.api.nvim_feedkeys(" 5", "xt", false)
        assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 12, 4 }))
      ]],
      { root, source, id }
    )
  end, debug.traceback)
  vim.fn.jobstop(child)
  vim.fn.jobwait({ child }, 1000)
  assert(ok, err)
end)

test("乱序设置和删除保留编号，普通添加填充最小空槽位", function()
  for _, loc in ipairs(store.list()) do
    store.remove(loc.id)
  end
  for _, n in ipairs({ 5, 2, 4 }) do
    vim.api.nvim_win_set_cursor(0, { n + 10, 4 })
    press("V " .. n)
  end
  local five = store.get_index(5)
  eq(
    vim.tbl_map(function(loc)
      return loc.index
    end, store.list()),
    { 2, 4, 5 }
  )
  store.remove(store.get_index(2).id)
  eq(store.get_index(2), nil)
  eq(store.get_index(5).id, five.id)
  vim.api.nvim_win_set_cursor(0, { 8, 0 })
  wm.add()
  eq(store.get_index(1).line, 8)
  wm.add()
  eq(#store.list(), 3)
  eq(store.get_index(5).id, five.id)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press(" 5")
  eq(vim.api.nvim_win_get_cursor(0), { 15, 4 })
end)

test("指定编号可以指向已有位置而不覆盖其他编号", function()
  store.remove(store.get_index(5).id)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local first = vim.deepcopy(store.get_index(1))
  press("V 5")
  eq(#store.list(), 5)
  eq(store.get_index(1), first)
  assert(store.get_index(5).id ~= first.id)
  vim.api.nvim_win_set_cursor(0, { 12, 0 })
  press(" 5")
  eq(vim.api.nvim_win_get_cursor(0), { 1, 0 })
end)

test("next/prev 按编号循环并跳过空槽位", function()
  for _, n in ipairs({ 1, 3, 4 }) do
    store.remove(store.get_index(n).id)
  end
  press(" 5")
  wm.next()
  eq(vim.api.nvim_win_get_cursor(0), { 2, 0 })
  wm.next()
  eq(vim.api.nvim_win_get_cursor(0), { 5, 0 })
  wm.previous()
  eq(vim.api.nvim_win_get_cursor(0), { 2, 0 })
  press(" 5")
  vim.cmd.enew()
  wm.next()
  eq(vim.api.nvim_win_get_cursor(0), { 2, 0 })
  vim.cmd.enew()
  wm.previous()
  eq(vim.api.nvim_win_get_cursor(0), { 5, 0 })
end)

test("manager 显示实际编号，重排/删除/跳转使用正确条目", function()
  for _, n in ipairs({ 1, 3, 4 }) do
    store.remove(store.get_index(n).id)
  end
  local second, fifth = store.get_index(2).id, store.get_index(5).id
  local ui = require("waymark.ui")
  ui.open()
  local rendered = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  eq(#rendered, 2)
  eq(rendered[1]:match("^%s*(%d+)"), "2")
  eq(rendered[2]:match("^%s*(%d+)"), "5")
  press("J")
  eq(store.get_index(2).id, fifth)
  eq(store.get_index(5).id, second)
  eq(vim.api.nvim_win_get_cursor(0)[1], 2)
  press("K")
  eq(store.get_index(2).id, second)
  eq(store.get_index(5).id, fifth)
  eq(vim.api.nvim_win_get_cursor(0)[1], 1)
  press("dd")
  eq(store.get_index(2), nil)
  eq(store.get_index(5).id, fifth)
  eq(vim.api.nvim_get_current_line():match("^%s*(%d+)"), "5")
  press("<CR>")
  eq(ui.is_open(), false)
  eq(vim.api.nvim_win_get_cursor(0), { 5, 0 })
end)

test("旧版持久化数据按原顺序迁移编号并保留 id/标签", function()
  for _, loc in ipairs(store.list()) do
    store.remove(loc.id)
  end
  local path = vim.fn.stdpath("data") .. "/waymark/" .. vim.fn.sha256(store.project_root()):sub(1, 16) .. ".json"
  vim.fn.writefile({
    vim.json.encode({
      version = 1,
      locations = {
        { id = "legacy_first", file = source, line = 12, col = 5, label = "renamed" },
        { id = "legacy_second", file = source, line = 16, col = 3 },
      },
    }),
  }, path)
  store.init()
  eq(#store.list(), 2)
  eq(store.get_index(1).id, "legacy_first")
  eq(store.get_index(1).label, "renamed")
  eq(store.get_index(2).id, "legacy_second")
  press(" 2")
  eq(vim.api.nvim_win_get_cursor(0), { 16, 2 })
  vim.api.nvim_win_set_cursor(0, { 8, 0 })
  press("V 5")
  local saved = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  eq(saved.version, 2)
  eq(#saved.locations, 3)
  eq(saved.locations[3].index, 5)
  eq(saved.locations[1].id, "legacy_first")
end)

test("无效编号不会创建条目", function()
  local before = vim.deepcopy(store.list())
  for _, n in ipairs({ 0, -1, "invalid" }) do
    eq(wm.update_index(n), false)
  end
  eq(store.list(), before)
end)

test("无名 buffer 不覆盖已有位置", function()
  local before = vim.deepcopy(store.list())
  vim.cmd.enew()
  press("V 1")
  eq(store.list(), before)
end)

test("无名 buffer 不创建新位置", function()
  for _, loc in ipairs(store.list()) do
    store.remove(loc.id)
  end
  vim.cmd.enew()
  press("V 1")
  eq(store.list(), {})
  eq(vim.api.nvim_get_mode().mode, "n")
end)

test("自定义前缀同时支持跳转和可视更新", function()
  clear_number_maps()
  wm.setup({ keys = { jump_prefix = "g" } })
  vim.api.nvim_win_set_cursor(0, { 12, 4 })
  press("Vg9")
  eq({ store.get_index(9).line, store.get_index(9).col }, { 12, 5 })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  press("g9")
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
    for _, file in ipairs({ target, source }) do
      vim.cmd("edit! " .. vim.fn.fnameescape(file))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      vim.bo.modified = false
    end
    clear_number_maps()
    wm.setup()
    for n = 1, 5 do
      store.add(source, n, 1, "original " .. n)
    end
    case[2]()
  end, debug.traceback)
  require("waymark.ui").close()
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
