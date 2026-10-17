-- waymark.nvim 冒烟测试（两阶段，验证持久化需跨进程）
--
-- 运行（在仓库根目录）:
--   WAYMARK_PLUGIN=$PWD WAYMARK_TMP=$PWD/.tmp-smoke XDG_DATA_HOME=$PWD/.tmp-smoke/data \
--     WAYMARK_PHASE=1 nvim --headless -l tests/smoke.lua
--   ... WAYMARK_PHASE=2 ... 同上

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

  -- Add：a.py:5 ------------------------------------------------------------
  vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/a.py"))
  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  wm.add()
  check("add a:5 → 列表长度 1", #store.list() == 1)

  -- 重复添加同位置 ----------------------------------------------------------
  wm.add()
  check("重复 add 同一位置不产生重复", #store.list() == 1)

  -- 同文件第二个位置 --------------------------------------------------------
  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  wm.add()
  check("同文件多位置允许 (a:5, a:6)", #store.list() == 2)

  -- 跨文件 ------------------------------------------------------------------
  vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/b.py"))
  vim.api.nvim_win_set_cursor(0, { 3, 2 })
  wm.add()
  local locs = store.list()
  check("跨文件 add (b:3)", #locs == 3 and locs[3].file == tmp .. "/b.py")
  -- 注：normal 模式 cursor col 被 Neovim 钳制在行内字符上（"b3" 2 字符 → col0=1）
  check("col 按 1-based 保存", locs[3].col == 2)
  check("id 稳定非空", locs[1].id ~= locs[2].id and locs[1].id ~= "")

  -- extmark 跟随：a.py 顶部插入 3 行 ----------------------------------------
  vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/a.py"))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "", "", "" })
  store.pull_extmarks()
  locs = store.list()
  check("extmark 跟随: a:5 → a:8", locs[1].line == 8)
  check("extmark 跟随: a:6 → a:9", locs[2].line == 9)

  -- jump ------------------------------------------------------------------
  check("jump 到 a:8", nav.jump(locs[1]) and vim.api.nvim_win_get_cursor(0)[1] == 8)
  check("jump 到 b:3（跨文件切 buffer）", nav.jump(locs[3])
    and vim.fs.basename(store.buf_path(0)) == "b.py"
    and vim.api.nvim_win_get_cursor(0)[1] == 3)

  -- step 循环: 当前 b:3(idx3) → next: idx1(a:8) → idx2(a:9) → idx3(b:3) → idx1
  nav.step(1)
  check("step(1) 循环回到 a:8", store.buf_path(0) == tmp .. "/a.py"
    and vim.api.nvim_win_get_cursor(0)[1] == 8)
  nav.step(1)
  check("step(1) → a:9", vim.api.nvim_win_get_cursor(0)[1] == 9)
  nav.step(1)
  check("step(1) → b:3", store.buf_path(0) == tmp .. "/b.py"
    and vim.api.nvim_win_get_cursor(0)[1] == 3)
  nav.step(-1)
  check("step(-1) → a:9", store.buf_path(0) == tmp .. "/a.py"
    and vim.api.nvim_win_get_cursor(0)[1] == 9)

  -- rename / reorder -------------------------------------------------------
  store.rename(locs[2].id, "RENAMED")
  local moved_id = locs[1].id -- move 前记录（list() 是快照，但这里防引用歧义）
  store.move(moved_id, 3) -- [a:8, a:9, b:3] → [a:9, b:3, a:8]
  local ordered = store.list()
  check("rename 生效", ordered[1].label == "RENAMED")
  check("reorder 生效（id 不变）", ordered[3].id == moved_id)

  -- goto_index 数字直跳 ------------------------------------------------------
  check("goto_index(3) → a:8", nav.goto_index(3)
    and vim.fs.basename(store.buf_path(0)) == "a.py"
    and vim.api.nvim_win_get_cursor(0)[1] == 8)
  check("goto_index(2) → b:3", nav.goto_index(2)
    and vim.fs.basename(store.buf_path(0)) == "b.py"
    and vim.api.nvim_win_get_cursor(0)[1] == 3)
  check("goto_index(99) 超出范围返回 false", nav.goto_index(99) == false)
  -- goto_index 后 next 应从该位置继续：当前 b:3(idx2) → next → idx3(a:8)
  nav.step(1)
  check("goto_index 后 step(1) 接续 a:8", store.buf_path(0) == tmp .. "/a.py"
    and vim.api.nvim_win_get_cursor(0)[1] == 8)

  -- manager popup 冒烟 -------------------------------------------------------
  local ui = require("waymark.ui")
  ui.open()
  check("manager 打开", ui.is_open())
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  check("manager 渲染了 3 行", #lines == 3)
  ui.close()
  check("manager 关闭", not ui.is_open())

  -- 记录 id，phase2 验证稳定性 ----------------------------------------------
  local ids = {}
  for i, loc in ipairs(store.list()) do
    ids[i] = loc.id
  end
  write_file(tmp .. "/ids.txt", table.concat(ids, "\n"))

  store.shutdown()
elseif phase == 2 then
  -- 模拟 b.py 被删除 --------------------------------------------------------
  uv.fs_unlink(tmp .. "/b.py")

  vim.cmd("cd " .. vim.fn.fnameescape(tmp))

  local wm = require("waymark")
  wm.setup({})
  local store = wm.store
  local nav = require("waymark.navigation")

  local locs = store.list()
  check("持久化: 3 条 location", #locs == 3)
  check("持久化: 顺序 [a:9, b:3, a:8]", locs[1].line == 9 and locs[2].file:find("b.py")
    and locs[3].line == 8)
  check("持久化: label 保留", locs[1].label == "RENAMED")
  check("持久化: extmark 更新后的行号 (8/9)", locs[3].line == 8 and locs[1].line == 9)

  local f = io.open(tmp .. "/ids.txt")
  local ids = {}
  if f then
    for line in f:lines() do
      table.insert(ids, line)
    end
    f:close()
  end
  check("持久化: id 跨重启稳定", locs[1].id == ids[1] and locs[2].id == ids[2]
    and locs[3].id == ids[3])

  -- 缺失文件 ----------------------------------------------------------------
  local missing = locs[2]
  check("b.py 标记 missing", not store.file_exists(missing.file))
  local ok_jump = nav.jump(missing)
  check("跳转 missing 文件不崩溃且失败", ok_jump == false)

  -- manager 显示 [missing] ---------------------------------------------------
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
  check("manager 显示 [missing] 标记", found_missing)
  ui.close()

  -- remove 后恢复有效跳转 ----------------------------------------------------
  store.remove(missing.id)
  check("删除 missing location", #store.list() == 2)
  check("删除后仍可跳转 a:9", nav.jump(store.list()[1]))

  -- 数据文件位置 -------------------------------------------------------------
  local data_dir = vim.fn.stdpath("data") .. "/waymark"
  local n = 0
  for _ in vim.fs.dir(data_dir) do
    n = n + 1
  end
  check("JSON 存储于 stdpath('data')/waymark/", n >= 1)

  store.shutdown()
end

print(("SMOKE PHASE %d: %s (failures=%d)"):format(phase, failures == 0 and "OK" or "FAILED", failures))
vim.cmd("qa!")
