-- Run: nvim --headless -u NONE -i NONE -n -l tests/symbols.lua
-- Picker tests use real Snacks; set SNACKS_PLUGIN to override its path.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local snacks = vim.env.SNACKS_PLUGIN or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
local tmp = vim.fn.tempname()
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(snacks)
vim.fn.mkdir(tmp .. "/.git", "p")
tmp = vim.uv.fs_realpath(tmp)
vim.env.XDG_DATA_HOME = tmp .. "/data"
vim.cmd.cd(tmp)
vim.o.hidden = true
vim.g.mapleader = " "
vim.wo.signcolumn = "yes:2"
local file = tmp .. "/source.txt"
vim.fn.writefile({ "one", "two", "three", "four", "five", "six", "seven", "eight" }, file)
vim.cmd.edit(file)
local wm = require("waymark")
local store = wm.store
wm.setup()
require("snacks").setup({ picker = { enabled = true } })

local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local function flush()
  local done = false
  vim.schedule(function()
    done = true
  end)
  assert(vim.wait(2000, function()
    return done
  end, 5))
end

local function gutter(line)
  vim.cmd.redraw()
  return vim.trim(vim.api.nvim_eval_statusline("%s", {
    winid = vim.api.nvim_get_current_win(),
    use_statuscol_lnum = line,
  }).str)
end

local tests = {}
local function test(name, fn)
  tests[#tests + 1] = { name, fn }
end

test("four sets have independent numbers, hide inactive signs, and preserve edit tracking", function()
  eq(wm.current_symbol(), "q")
  store.set_index(5, file, 2, 1, "q only")
  eq(gutter(2), "5")
  for _, symbol in ipairs({ "w", "e", "r" }) do
    wm.select_symbol(symbol)
    eq(wm.current_symbol(), symbol)
    eq(#store.list(), 0)
    eq(gutter(2), "")
    store.add(file, 4, 1, symbol .. " only")
    eq(store.list()[1].index, 1)
    eq(gutter(4), "1")
  end
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "inserted" })
  eq(gutter(5), "1")
  wm.select_symbol("q")
  eq(store.get_index(5).line, 3)
  eq(gutter(3), "5")
  eq(gutter(5), "")
  press(" %")
  eq(vim.api.nvim_win_get_cursor(0), { 3, 0 })
  wm.select_symbol("w")
  eq(store.get_index(1).line, 5)
  eq(store.get_index(5), nil)
  store.rename(store.get_index(1).id, "w renamed")
  store.compact()
  wm.select_symbol("q")
  eq(store.get_index(5).label, "q only")
end)

test("next/prev fallback navigation history is isolated between sets", function()
  local extra = store.set_index(8, file, 7, 1, "temporary")
  wm.goto_index(8)
  wm.select_symbol("r")
  vim.cmd.enew()
  wm.next()
  eq(vim.api.nvim_win_get_cursor(0), { 5, 0 })
  wm.select_symbol("q")
  vim.cmd.enew()
  wm.previous()
  eq(vim.api.nvim_win_get_cursor(0), { 3, 0 })
  store.remove(extra.id)
end)

test("hidden sets continue tracking edits after files are reloaded", function()
  local hidden = tmp .. "/hidden.txt"
  vim.fn.writefile({ "first", "second", "third" }, hidden)
  vim.cmd.edit(hidden)
  wm.select_symbol("r")
  local loc = store.set_index(9, hidden, 2, 1, "hidden")
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd.edit(file)
  vim.api.nvim_buf_delete(buf, { force = true })
  wm.select_symbol("q")
  vim.cmd.edit(hidden)
  eq(gutter(2), "")
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "inserted" })
  wm.select_symbol("r")
  eq(loc.line, 3)
  eq(gutter(3), "9")
  store.remove(loc.id)
  vim.cmd.edit(file)
  wm.select_symbol("q")
end)

test("notifications include the selected symbol and only list its marks in the current file", function()
  local notify = vim.notify
  local messages = {}
  vim.notify = function(message)
    messages[#messages + 1] = message
  end
  local ok, err = pcall(function()
    wm.select_symbol("w")
    wm.view()
    assert(messages[1]:find("[waymark:w]", 1, true))
    assert(messages[2]:find("w renamed", 1, true))
    assert(not messages[2]:find("q only", 1, true))
    wm.add()
    assert(messages[3]:find("[waymark:w]", 1, true))
    wm.select_symbol("q")
    wm.view()
    assert(messages[#messages]:find("[waymark:q]", 1, true))
    assert(not messages[#messages]:find("w renamed", 1, true))
  end)
  vim.notify = notify
  assert(ok, err)
end)

test("switching sets refreshes an open manager immediately and deletions stay isolated", function()
  local ui = require("waymark.ui")
  ui.open()
  assert(vim.api.nvim_win_get_config(0).title[1][1]:find("[q]", 1, true))
  assert(vim.api.nvim_get_current_line():find("q only", 1, true))
  wm.select_symbol("e")
  eq(ui.is_open(), true)
  assert(vim.api.nvim_win_get_config(0).title[1][1]:find("[e]", 1, true))
  assert(vim.api.nvim_get_current_line():find("e only", 1, true))
  press("dd")
  eq(ui.is_open(), false)
  eq(#store.list(), 0)
  wm.select_symbol("q")
  eq(store.get_index(5).label, "q only")
end)

test("the real picker only displays the selected set and replaces results when switching", function()
  local picker = require("waymark.picker").open()
  flush()
  eq(#picker.opts.items, 1)
  assert(picker.opts.title:find("[q]", 1, true))
  eq(picker.opts.items[1].waymark.label, "q only")
  wm.select_symbol("w")
  flush()
  eq(picker.closed, true)
  local current = require("snacks").picker.get()[1]
  assert(current)
  assert(current.opts.title:find("[w]", 1, true))
  for _, item in ipairs(current.opts.items) do
    assert(not item.text:find("q only", 1, true))
  end
  wm.select_symbol("e")
  flush()
  eq(current.closed, true)
  eq(#require("snacks").picker.get(), 0)
  wm.select_symbol("q")
end)

test("all sets and the selected symbol are persisted and restored across processes", function()
  wm.select_symbol("r")
  local id = store.get_index(1).id
  local child = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE", "-n" }, {
    rpc = true,
    env = { XDG_DATA_HOME = vim.env.XDG_DATA_HOME },
  })
  local ok, err = pcall(
    vim.rpcrequest,
    child,
    "nvim_exec_lua",
    [[
    local root, file, id = ...
    vim.opt.rtp:prepend(root)
    vim.cmd.edit(file)
    local wm = require("waymark")
    wm.setup()
    assert(wm.current_symbol() == "r")
    assert(wm.store.get_index(1).id == id)
    assert(wm.store.get_index(1).line == 5)
    wm.select_symbol("q")
    assert(wm.store.get_index(5).label == "q only")
    wm.select_symbol("e")
    assert(#wm.store.list() == 0)
  ]],
    { root, file, id }
  )
  vim.fn.jobstop(child)
  vim.fn.jobwait({ child }, 1000)
  assert(ok, err)
  store.save()
end)

test("each project restores its own selected set and clears old signs when switching", function()
  local other = tmp .. "/other"
  vim.fn.mkdir(other .. "/.git", "p")
  vim.fn.writefile({ "other" }, other .. "/other.txt")
  local source = vim.api.nvim_get_current_buf()
  vim.cmd.edit(other .. "/other.txt")
  store.ensure_loaded()
  eq(wm.current_symbol(), "q")
  for _, ext in ipairs(vim.api.nvim_buf_get_extmarks(source, store.ns(), 0, -1, { details = true })) do
    eq(ext[4].sign_text, nil)
  end
  wm.select_symbol("w")
  wm.add()
  vim.cmd.edit(file)
  store.ensure_loaded()
  eq(wm.current_symbol(), "r")
  eq(gutter(5), "1")
  vim.cmd.edit(other .. "/other.txt")
  store.ensure_loaded()
  eq(wm.current_symbol(), "w")
  eq(#store.list(), 1)
  vim.cmd.edit(file)
  store.ensure_loaded()
end)

test("manager C clears and persists the current set across files, preserving other sets and signs", function()
  wm.select_symbol("q")
  local other = tmp .. "/clear.txt"
  vim.fn.writefile({ "first", "second" }, other)
  local source_buf = vim.api.nvim_get_current_buf()
  local removed = store.list()
  vim.cmd.edit(other)
  removed[#removed + 1] = store.set_index(9, other, 2, 1, "clear me")
  local other_buf = vim.api.nvim_get_current_buf()
  local ns = vim.api.nvim_create_namespace("other-plugin")
  local sign = vim.api.nvim_buf_set_extmark(other_buf, ns, 0, 0, { sign_text = "!" })
  eq(gutter(2), "9")
  local notify = vim.notify
  local message
  vim.notify = function(text)
    message = text
  end
  local ok, err = pcall(function()
    press(" zmC")
  end)
  vim.notify = notify
  assert(ok, err)
  eq(require("waymark.ui").is_open(), false)
  eq(#store.list(), 0)
  eq(wm.current_symbol(), "q")
  assert(message:find("[waymark:q]", 1, true))
  assert(message:find("removed " .. #removed .. " marks", 1, true))
  for _, loc in ipairs(removed) do
    eq(loc.ext, nil)
  end
  for _, buf in ipairs({ source_buf, other_buf }) do
    for _, ext in ipairs(vim.api.nvim_buf_get_extmarks(buf, store.ns(), 0, -1, { details = true })) do
      eq(ext[4].sign_text, nil)
    end
  end
  assert(#vim.api.nvim_buf_get_extmark_by_id(other_buf, ns, sign, {}) > 0)
  local path = vim.fn.stdpath("data") .. "/waymark/" .. vim.fn.sha256(store.project_root()):sub(1, 16) .. ".json"
  local saved = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  eq(#saved.symbols.q, 0)
  eq(saved.symbols.w[1].label, "w renamed")
  store.init()
  eq(#store.list(), 0)
  eq(store.clear(), 0)
  wm.select_symbol("w")
  eq(store.get_index(1).label, "w renamed")
  vim.cmd.edit(file)
  eq(gutter(5), "1")
  wm.select_symbol("q")
  store.add(file, 3, 1, "fresh")
  eq(store.get_index(1).label, "fresh")
end)

test("legacy v2 data migrates to q with sparse numbers and labels preserved", function()
  local path = vim.fn.stdpath("data") .. "/waymark/" .. vim.fn.sha256(store.project_root()):sub(1, 16) .. ".json"
  vim.fn.writefile({
    vim.json.encode({
      version = 2,
      locations = { { id = "legacy", index = 5, file = file, line = 3, col = 1, label = "legacy label" } },
    }),
  }, path)
  store.init()
  eq(wm.current_symbol(), "q")
  eq(store.get_index(5).id, "legacy")
  eq(store.get_index(5).label, "legacy label")
  wm.select_symbol("w")
  eq(#store.list(), 0)
  eq(wm.select_symbol("invalid"), false)
  eq(wm.current_symbol(), "w")
end)

test("targeted add and navigation leave the active set unchanged", function()
  eq(store.buf_path(0), file)
  for _, symbol in ipairs({ "q", "w", "e", "r" }) do
    wm.select_symbol(symbol)
    store.clear()
  end
  for _, symbol in ipairs({ "q", "w", "e", "r" }) do
    local active = symbol == "q" and "r" or "q"
    wm.select_symbol(active)
    vim.api.nvim_win_set_cursor(0, { 2, 1 })
    press(" z" .. symbol)
    eq(wm.current_symbol(), active)
    wm.select_symbol(symbol)
    eq(#store.list(), 1)
    eq({ store.get_index(1).line, store.get_index(1).col }, { 2, 2 })
    press(" z" .. symbol)
    eq(wm.current_symbol(), symbol)
    eq(#store.list(), 1)
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    press(" zz")
    eq(#store.list(), 2)
    eq(store.get_index(2).line, 6)
  end
  for _, symbol in ipairs({ "q", "w", "e", "r" }) do
    wm.select_symbol(symbol == "q" and "r" or "q")
    local active = wm.current_symbol()
    vim.api.nvim_win_set_cursor(0, { 2, 1 })
    press(" ]" .. symbol)
    eq(wm.current_symbol(), active)
    eq(vim.api.nvim_win_get_cursor(0), { 6, 0 })
    press("]z")
    eq(vim.api.nvim_win_get_cursor(0), { 2, 1 })
    press("[z")
    eq(vim.api.nvim_win_get_cursor(0), { 6, 0 })
    wm.select_symbol(active)
    press(" [" .. symbol)
    eq(wm.current_symbol(), active)
    eq(vim.api.nvim_win_get_cursor(0), { 2, 1 })
    eq(#store.list(), 2)
  end
  store.clear()
  wm.select_symbol("q")
  local cursor = vim.api.nvim_win_get_cursor(0)
  press(" ]r")
  eq(wm.current_symbol(), "q")
  eq(vim.api.nvim_win_get_cursor(0), { 6, 0 })
  eq(#store.list(), 0)
  local path = vim.fn.stdpath("data") .. "/waymark/" .. vim.fn.sha256(store.project_root()):sub(1, 16) .. ".json"
  local saved = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  eq(saved.active_symbol, "q")
  eq(#saved.symbols.q, 0)
  eq(#saved.symbols.r, 2)
end)

test("targeted add, select, and navigation keymaps can be customized or disabled", function()
  for _, symbol in ipairs({ "q", "w", "e", "r" }) do
    vim.keymap.del("n", " z" .. symbol)
    vim.keymap.del("n", " [" .. symbol)
    vim.keymap.del("n", " ]" .. symbol)
    vim.keymap.del("n", " z" .. symbol:upper())
  end
  wm.setup({ keys = {
    symbol_q = "gq",
    symbol_w = false,
    symbol_e = false,
    symbol_r = false,
    select_q = "gQ",
    select_w = false,
    select_e = false,
    select_r = false,
    prev_q = "g[",
    prev_w = false,
    prev_e = false,
    prev_r = false,
    next_q = "g]",
    next_w = false,
    next_e = false,
    next_r = false,
  } })
  for _, symbol in ipairs({ "q", "w", "e", "r" }) do
    eq(vim.fn.maparg(" z" .. symbol, "n"), "")
    eq(vim.fn.maparg(" [" .. symbol, "n"), "")
    eq(vim.fn.maparg(" ]" .. symbol, "n"), "")
    eq(vim.fn.maparg(" z" .. symbol:upper(), "n"), "")
  end
  vim.api.nvim_win_set_cursor(0, { 8, 0 })
  wm.select_symbol("w")
  press("gq")
  eq(wm.current_symbol(), "w")
  wm.select_symbol("q")
  eq(store.get_index(1).line, 8)
  store.add(file, 6, 1, "q nav")
  press("gQ")
  eq(wm.current_symbol(), "q")
  wm.select_symbol("w")
  press("g[")
  eq(wm.current_symbol(), "w")
  eq(vim.api.nvim_win_get_cursor(0), { 6, 0 })
  wm.select_symbol("w")
  press("g]")
  eq(wm.current_symbol(), "w")
  eq(vim.api.nvim_win_get_cursor(0), { 8, 0 })
end)

local failures = 0
for _, case in ipairs(tests) do
  local ok, err = xpcall(case[2], debug.traceback)
  io.stdout:write((ok and "PASS " or "FAIL ") .. case[1] .. "\n")
  if not ok then
    failures = failures + 1
    io.stderr:write(err .. "\n")
  end
end
require("waymark.ui").close()
vim.api.nvim_del_augroup_by_name("waymark")
vim.fn.delete(tmp, "rf")
io.stdout:write(("%d/%d passed\n"):format(#tests - failures, #tests))
vim.cmd(failures == 0 and "qa!" or "cquit")
