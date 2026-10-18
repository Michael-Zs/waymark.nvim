-- 运行：nvim --headless -u NONE -i NONE -n -l tests/navigation.lua
-- Picker 用例使用真实 Snacks；可用 SNACKS_PLUGIN 指定其路径。
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local snacks = vim.env.SNACKS_PLUGIN or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
local tmp = vim.fn.tempname()
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(snacks)
vim.env.XDG_DATA_HOME = tmp .. "/data"
vim.fn.mkdir(tmp .. "/.git", "p")
vim.cmd.cd(tmp)
vim.o.hidden = true

local file = tmp .. "/target.txt"
local lines = {}
for i = 1, 100 do
  lines[i] = ("line %03d: example text"):format(i)
end
vim.fn.writefile(lines, file)

local store = require("waymark.store")
local navigation = require("waymark.navigation")
require("snacks").setup({ picker = { enabled = true } })
store.init()

local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function flush()
  local done = false
  vim.schedule(function()
    done = true
  end)
  assert(
    vim.wait(1000, function()
      return done
    end, 5),
    "scheduled callbacks did not complete"
  )
end

local tests = {}
local function test(name, fn)
  tests[#tests + 1] = { name, fn }
end

local function jump(line, col)
  assert(navigation.jump({ file = file, line = line or 30, col = col or 4 }))
end

local picker
local function confirm()
  local source = vim.api.nvim_get_current_win()
  picker = require("waymark.picker").open()
  flush()
  eq(picker.main, source)
  picker.opts.confirm(picker, { waymark = store.list()[1] })
  return source
end

test("主动跳转立即定位，延迟后位置不变", function()
  jump()
  eq(vim.api.nvim_win_get_cursor(0), { 30, 3 })
  flush()
  eq(vim.api.nvim_win_get_cursor(0), { 30, 3 })
end)

test("后续移动光标不会被旧跳转覆盖", function()
  jump()
  vim.api.nvim_win_set_cursor(0, { 70, 6 })
  flush()
  eq(vim.api.nvim_win_get_cursor(0), { 70, 6 })
end)

test("连续跳转后，以最新位置为准", function()
  jump(20)
  jump(80)
  flush()
  eq(vim.api.nvim_win_get_cursor(0), { 80, 3 })
end)

test("切换窗口后不再修改原窗口", function()
  jump()
  local source = vim.api.nvim_get_current_win()
  vim.cmd.vsplit()
  local current = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(source, { 80, 5 })
  vim.api.nvim_win_set_cursor(current, { 90, 7 })
  flush()
  eq(vim.api.nvim_get_current_win(), current)
  eq(vim.api.nvim_win_get_cursor(source), { 80, 5 })
  eq(vim.api.nvim_win_get_cursor(current), { 90, 7 })
end)

test("延迟恢复折叠后目标可见，越界列使用实际位置", function()
  vim.cmd.edit(file)
  vim.schedule(function()
    local view = vim.fn.winsaveview()
    vim.cmd("20,40fold")
    vim.fn.winrestview(view)
  end)
  jump(30, 1000)
  local cursor = vim.api.nvim_win_get_cursor(0)
  flush()
  eq(vim.api.nvim_win_get_cursor(0), cursor)
  eq(vim.fn.foldclosed(30), -1)
end)

test("旧跳转不会展开新位置的折叠", function()
  vim.cmd.edit(file)
  vim.cmd("60,80fold")
  jump()
  vim.api.nvim_win_set_cursor(0, { 60, 0 })
  flush()
  eq(vim.api.nvim_win_get_cursor(0), { 60, 0 })
  eq(vim.fn.foldclosed(60), 60)
end)

test("代码移动后的 extmark 跟踪仍保留", function()
  vim.cmd.edit(file)
  local loc = store.list()[1]
  store.sync_buffer(vim.api.nvim_get_current_buf())
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "inserted" })
  assert(navigation.jump(loc))
  flush()
  eq(vim.api.nvim_win_get_cursor(0), { 31, 3 })
  vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
end)

test("Picker 正常确认后在原窗口跳转", function()
  local source = confirm()
  flush()
  eq(vim.api.nvim_get_current_win(), source)
  eq(vim.api.nvim_buf_get_name(0), file)
  eq(vim.api.nvim_win_get_cursor(0), { 30, 3 })
end)

test("Picker 确认后切换窗口，取消旧跳转", function()
  local buf = vim.api.nvim_create_buf(true, false)
  local other = vim.api.nvim_open_win(buf, false, { split = "right" })
  local source_buf = vim.api.nvim_get_current_buf()
  local source = confirm()
  vim.api.nvim_set_current_win(other)
  flush()
  eq(vim.api.nvim_get_current_win(), other)
  eq(vim.api.nvim_win_get_buf(other), buf)
  eq(vim.api.nvim_win_get_buf(source), source_buf)
end)

test("Picker 确认后切换 buffer，取消旧跳转", function()
  confirm()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, buf)
  flush()
  eq(vim.api.nvim_get_current_buf(), buf)
end)

test("Picker 确认后移动光标，取消旧跳转", function()
  vim.cmd.edit(file)
  confirm()
  vim.api.nvim_win_set_cursor(0, { 70, 6 })
  flush()
  eq(vim.api.nvim_win_get_cursor(0), { 70, 6 })
end)

test("Picker 目标窗口关闭后，不跳到其他窗口", function()
  local buf = vim.api.nvim_create_buf(true, false)
  local other = vim.api.nvim_open_win(buf, false, { split = "right" })
  local source = confirm()
  vim.api.nvim_win_close(source, true)
  flush()
  eq(vim.api.nvim_get_current_win(), other)
  eq(vim.api.nvim_get_current_buf(), buf)
end)

test("真实 UI 中从输入模式按 Enter 可精确跳转", function()
  local child = vim.fn.jobstart({ vim.v.progpath, "--embed", "-u", "NONE", "-i", "NONE", "-n" }, {
    rpc = true,
    env = { XDG_DATA_HOME = tmp .. "/insert-data" },
  })
  local function exec(code, ...)
    return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
  end
  local ok, err = xpcall(function()
    vim.rpcrequest(child, "nvim_ui_attach", 120, 40, { rgb = true })
    exec(
      [[
      local root, snacks, file = ...
      vim.opt.rtp:prepend(root)
      vim.opt.rtp:append(snacks)
      vim.cmd.edit(file)
      local store = require("waymark.store")
      store.init()
      store.add(file, 30, 4)
      vim.api.nvim_win_set_cursor(0, { 10, 8 })
      _G.source = vim.api.nvim_get_current_win()
      require("snacks").setup({ picker = { enabled = true } })
      _G.picker = require("waymark.picker").open()
    ]],
      root,
      snacks,
      file
    )
    assert(
      vim.wait(2000, function()
        return exec("return vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' and picker:current() ~= nil")
      end, 10),
      "picker did not enter insert mode"
    )
    vim.rpcrequest(child, "nvim_input", "\r")
    assert(
      vim.wait(2000, function()
        return exec([[
        return picker.closed and vim.api.nvim_get_current_win() == source
          and vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 30, 3 })
      ]])
      end, 10),
      "insert-mode confirmation did not reach the target"
    )
  end, debug.traceback)
  vim.fn.jobstop(child)
  vim.fn.jobwait({ child }, 1000)
  assert(ok, err)
end)

test("稀疏编号在真实 Picker 中显示并可确认跳转", function()
  local loc = store.list()[1]
  assert(store.move(loc.id, 5))
  vim.cmd.edit(file)
  picker = require("waymark.picker").open()
  flush()
  eq(#picker.opts.items, 1)
  eq(picker.opts.items[1].text:match("^(%d+)%."), "5")
  eq(picker.opts.items[1].waymark.id, loc.id)
  picker.opts.confirm(picker, picker.opts.items[1])
  flush()
  eq(vim.api.nvim_win_get_cursor(0), { 30, 3 })
  assert(store.move(loc.id, 1))
end)

vim.cmd.edit(file)
store.add(file, 30, 4)

local failures = 0
for _, case in ipairs(tests) do
  local ok, err = xpcall(function()
    vim.cmd("silent! only!")
    vim.cmd.enew()
    vim.wo.foldmethod = "manual"
    flush()
    case[2]()
  end, debug.traceback)
  if picker and not picker.closed then
    picker:close()
  end
  flush()
  io.stdout:write((ok and "PASS " or "FAIL ") .. case[1] .. "\n")
  if not ok then
    failures = failures + 1
    io.stderr:write(err .. "\n")
  end
end

vim.fn.delete(tmp, "rf")
io.stdout:write(("%d/%d passed\n"):format(#tests - failures, #tests))
vim.cmd(failures == 0 and "qa!" or "cquit")
