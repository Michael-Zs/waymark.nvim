-- Run: nvim --headless -u NONE -i NONE -n -l tests/signs.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local tmp = vim.fn.tempname()
vim.opt.rtp:prepend(root)
vim.fn.mkdir(tmp .. "/.git", "p")
tmp = vim.uv.fs_realpath(tmp)
vim.env.XDG_DATA_HOME = tmp .. "/data"
vim.cmd.cd(tmp)
vim.o.hidden = true
vim.g.mapleader = " "
vim.wo.signcolumn = "yes:2"

local source, target = tmp .. "/source.txt", tmp .. "/target.txt"
local lines = {}
for i = 1, 20 do
  lines[i] = ("line %02d: example text"):format(i)
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

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf or 0, store.ns(), 0, -1, { details = true })
end

-- Read actual sign column rendering rather than only checking extmark options.
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

test("adding and Visual updates display gutter numbers without modifying file contents", function()
  vim.api.nvim_win_set_cursor(0, { 3, 2 })
  press(" zz")
  eq(gutter(3), "1")
  vim.api.nvim_win_set_cursor(0, { 8, 4 })
  press("V 5")
  eq(gutter(8), "5")
  eq(gutter(4), "")
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), lines)
  eq(vim.bo.modified, false)
  eq(vim.api.nvim_get_hl(0, { name = "WaymarkSign", link = true }).link, "Special")
end)

test("multiple and two-digit numbers use native signs while large numbers still track edits", function()
  store.set_index(5, source, 3, 1)
  store.set_index(12, source, 3, 4)
  local text = gutter(3)
  assert(text:find("5", 1, true) and text:find("12", 1, true), text)
  local loc = store.set_index(100, source, 8, 2)
  eq(gutter(8), "++")
  assert(loc.ext)
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "inserted" })
  store.pull_extmarks()
  eq({ loc.line, loc.col }, { 9, 2 })
  eq(gutter(9), "++")
end)

test("cross-file updates and deletions remove old gutter numbers", function()
  local loc = store.set_index(5, source, 3, 2)
  local source_buf = vim.api.nvim_get_current_buf()
  vim.cmd.edit(target)
  vim.api.nvim_win_set_cursor(0, { 12, 4 })
  press("V 5")
  eq(#marks(source_buf), 0)
  eq(gutter(12), "5")
  store.remove(loc.id)
  eq(gutter(12), "")
  eq(#marks(), 0)
end)

test("renumbering after edits uses current positions and continues tracking undo", function()
  local loc = store.set_index(5, source, 3, 2)
  local ext = vim.deepcopy(loc.ext)
  press("ggOinserted<Esc>")
  eq(gutter(4), "5")
  store.compact()
  eq(loc.ext, ext)
  eq({ loc.line, loc.col }, { 4, 2 })
  eq(gutter(4), "1")
  eq(gutter(3), "")
  press("u")
  eq(gutter(3), "1")
  store.pull_extmarks()
  eq({ loc.line, loc.col }, { 3, 2 })
end)

test("manager J/U/dd actions synchronize gutter numbers", function()
  store.set_index(1, source, 3, 1)
  store.set_index(3, source, 8, 1)
  store.set_index(5, source, 12, 1)
  press(" zmJUq")
  eq(gutter(8), "1")
  eq(gutter(3), "2")
  eq(gutter(12), "3")
  press(" zmddq")
  eq(gutter(8), "")
  eq(gutter(3), "2")
end)

test("reloads do not duplicate marks and reopening files restores gutter numbers", function()
  store.set_index(5, source, 3, 2)
  for _ = 1, 2 do
    wm.setup()
    eq(#marks(), 1)
    eq(gutter(3), "5")
  end
  local buf = vim.api.nvim_get_current_buf()
  vim.cmd.edit(target)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.cmd.edit(source)
  eq(#marks(), 1)
  eq(gutter(3), "5")
end)

test("project switches clear and restore numbers while preserving other plugins' signs", function()
  local other = tmp .. "/other"
  vim.fn.mkdir(other .. "/.git", "p")
  vim.fn.writefile(lines, other .. "/other.txt")
  store.set_index(5, source, 3, 2)
  local source_buf = vim.api.nvim_get_current_buf()
  local ns = vim.api.nvim_create_namespace("other-plugin")
  local id = vim.api.nvim_buf_set_extmark(source_buf, ns, 0, 0, { sign_text = "!" })
  vim.cmd.edit(other .. "/other.txt")
  store.ensure_loaded()
  eq(#marks(source_buf), 0)
  assert(#vim.api.nvim_buf_get_extmark_by_id(source_buf, ns, id, {}) > 0)
  store.set_index(2, other .. "/other.txt", 8, 1)
  eq(gutter(8), "2")
  local other_buf = vim.api.nvim_get_current_buf()
  vim.cmd.edit(source)
  store.ensure_loaded()
  eq(#marks(other_buf), 0)
  eq(gutter(3), "5")
  vim.api.nvim_buf_clear_namespace(source_buf, ns, 0, -1)
end)

local failures = 0
for _, case in ipairs(tests) do
  local ok, err = xpcall(function()
    for _, loc in ipairs(store.list()) do
      store.remove(loc.id)
    end
    for _, file in ipairs({ target, source }) do
      vim.cmd("edit! " .. vim.fn.fnameescape(file))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      vim.bo.modified = false
    end
    wm.setup()
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
