-- waymark.nvim smoke test (two phases to verify persistence across processes).
--
-- Run from the repository root:
--   WAYMARK_PLUGIN=$PWD WAYMARK_TMP=$PWD/.tmp-smoke XDG_DATA_HOME=$PWD/.tmp-smoke/data \
--     WAYMARK_PHASE=1 nvim --headless -l tests/smoke.lua
--   Repeat with WAYMARK_PHASE=2 using the same paths.

local uv = vim.uv

local phase = tonumber(uv.os_getenv("WAYMARK_PHASE") or "1")
local plugin = uv.os_getenv("WAYMARK_PLUGIN") or "."
local tmp = uv.os_getenv("WAYMARK_TMP") or (plugin .. "/.tmp-smoke")

local failures = 0
local function check(name, cond)
  local tag = cond and "PASS" or "FAIL"
  if not cond then
    failures = failures + 1
  end
  print(("%s  %s"):format(tag, name))
end

local function write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

vim.opt.rtp:prepend(vim.fn.fnamemodify(plugin, ":p"))

--==========================================================================

if phase == 1 then
  vim.fn.mkdir(tmp .. "/.git", "p")
  local a = {}
  for i = 1, 20 do
    a[i] = ("line %d in a"):format(i)
  end
  write_file(tmp .. "/a.py", table.concat(a, "\n") .. "\n")
  write_file(tmp .. "/b.py", "b1\nb2\nb3\nb4\nb5\n")

  vim.cmd("cd " .. vim.fn.fnameescape(tmp))

  local wm = require("waymark")
  wm.setup({})
  local store = wm.store
  local nav = require("waymark.navigation")

  -- Add: a.py:5 ------------------------------------------------------------
  vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/a.py"))
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  wm.add()
  check("add a:5 → list length 1", #store.list() == 1)

  -- Add the same position again --------------------------------------------
  wm.add()
  check("adding the same position does not create duplicates", #store.list() == 1)

  -- Second position in the same file ---------------------------------------
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  wm.add()
  check("multiple positions in one file are allowed (a:5, a:6)", #store.list() == 2)

  -- Cross-file marks -------------------------------------------------------
  vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/b.py"))
  vim.api.nvim_win_set_cursor(0, { 3, 2 })
  wm.add()
  local locs = store.list()
  check("add across files (b:3)", #locs == 3 and locs[3].file == tmp .. "/b.py")
  -- Normal mode clamps the cursor to a character in the line ("b3" has 2 characters → col0=1).
  check("columns are saved as 1-based", locs[3].col == 2)
  check("IDs are distinct and nonempty", locs[1].id ~= locs[2].id and locs[1].id ~= "")

  -- Extmark tracking: insert 3 lines at the start of a.py --------------------
  vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/a.py"))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "", "", "" })
  store.pull_extmarks()
  locs = store.list()
  check("extmark tracking: a:5 → a:8", locs[1].line == 8)
  check("extmark tracking: a:6 → a:9", locs[2].line == 9)

  -- jump ------------------------------------------------------------------
  check("jump to a:8", nav.jump(locs[1]) and vim.api.nvim_win_get_cursor(0)[1] == 8)
  check(
    "jump to b:3 (switch buffers across files)",
    nav.jump(locs[3]) and vim.fs.basename(store.buf_path(0)) == "b.py" and vim.api.nvim_win_get_cursor(0)[1] == 3
  )

  -- Wraparound: b:3(idx3) → next: idx1(a:8) → idx2(a:9) → idx3(b:3) → idx1.
  nav.step(1)
  check("step(1) wraps to a:8", store.buf_path(0) == tmp .. "/a.py" and vim.api.nvim_win_get_cursor(0)[1] == 8)
  nav.step(1)
  check("step(1) → a:9", vim.api.nvim_win_get_cursor(0)[1] == 9)
  nav.step(1)
  check("step(1) → b:3", store.buf_path(0) == tmp .. "/b.py" and vim.api.nvim_win_get_cursor(0)[1] == 3)
  nav.step(-1)
  check("step(-1) → a:9", store.buf_path(0) == tmp .. "/a.py" and vim.api.nvim_win_get_cursor(0)[1] == 9)

  -- rename / reorder -------------------------------------------------------
  store.rename(locs[2].id, "RENAMED")
  local moved_id = locs[1].id -- Capture before moving to avoid reference ambiguity in the shallow list snapshot.
  store.move(moved_id, 3) -- [a:8, a:9, b:3] → [a:9, b:3, a:8]
  local ordered = store.list()
  check("rename takes effect", ordered[1].label == "RENAMED")
  check("reordering preserves IDs", ordered[3].id == moved_id)

  -- Direct numbered jumps --------------------------------------------------
  check(
    "goto_index(3) → a:8",
    nav.goto_index(3) and vim.fs.basename(store.buf_path(0)) == "a.py" and vim.api.nvim_win_get_cursor(0)[1] == 8
  )
  check(
    "goto_index(2) → b:3",
    nav.goto_index(2) and vim.fs.basename(store.buf_path(0)) == "b.py" and vim.api.nvim_win_get_cursor(0)[1] == 3
  )
  check("goto_index(99) returns false for an absent number", nav.goto_index(99) == false)
  -- Continue after goto_index: b:3(idx2) → next → idx3(a:8).
  nav.step(1)
  check(
    "step(1) continues to a:8 after goto_index",
    store.buf_path(0) == tmp .. "/a.py" and vim.api.nvim_win_get_cursor(0)[1] == 8
  )

  -- Popup manager smoke test -----------------------------------------------
  local ui = require("waymark.ui")
  ui.open()
  check("manager opens", ui.is_open())
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  check("manager renders 3 rows", #lines == 3)
  ui.close()
  check("manager closes", not ui.is_open())

  -- Save IDs to verify stability in phase 2 ---------------------------------
  local ids = {}
  for i, loc in ipairs(store.list()) do
    ids[i] = loc.id
  end
  write_file(tmp .. "/ids.txt", table.concat(ids, "\n"))

  store.shutdown()
elseif phase == 2 then
  -- Simulate deletion of b.py -----------------------------------------------
  uv.fs_unlink(tmp .. "/b.py")

  vim.cmd("cd " .. vim.fn.fnameescape(tmp))

  local wm = require("waymark")
  wm.setup({})
  local store = wm.store
  local nav = require("waymark.navigation")

  local locs = store.list()
  check("persistence: 3 locations", #locs == 3)
  check("persistence: order [a:9, b:3, a:8]", locs[1].line == 9 and locs[2].file:find("b.py") and locs[3].line == 8)
  check("persistence: labels are preserved", locs[1].label == "RENAMED")
  check("persistence: updated extmark line numbers (8/9)", locs[3].line == 8 and locs[1].line == 9)

  local f = io.open(tmp .. "/ids.txt")
  local ids = {}
  if f then
    for line in f:lines() do
      table.insert(ids, line)
    end
    f:close()
  end
  check(
    "persistence: IDs are stable across restarts",
    locs[1].id == ids[1] and locs[2].id == ids[2] and locs[3].id == ids[3]
  )

  -- Missing files ----------------------------------------------------------
  local missing = locs[2]
  check("b.py is detected as missing", not store.file_exists(missing.file))
  local ok_jump = nav.jump(missing)
  check("jumping to a missing file fails without crashing", ok_jump == false)

  -- Manager displays [missing] ----------------------------------------------
  local ui = require("waymark.ui")
  ui.open()
  local found_missing = false
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].filetype == "waymark" then
      for _, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
        if line:find("%[missing%]") then
          found_missing = true
        end
      end
    end
  end
  check("manager displays the [missing] indicator", found_missing)
  ui.close()

  -- Valid jumps after removing a missing entry ------------------------------
  store.remove(missing.id)
  check("remove the missing location", #store.list() == 2)
  check("jump to a:9 still works after deletion", nav.jump(store.list()[1]))

  -- Data file location -----------------------------------------------------
  local data_dir = vim.fn.stdpath("data") .. "/waymark"
  local n = 0
  for _ in vim.fs.dir(data_dir) do
    n = n + 1
  end
  check("JSON is stored in stdpath('data')/waymark/", n >= 1)

  store.shutdown()
end

print(("SMOKE PHASE %d: %s (failures=%d)"):format(phase, failures == 0 and "OK" or "FAILED", failures))
vim.cmd("qa!")
