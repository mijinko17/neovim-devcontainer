-- 外部コマンドを順に待つ処理を、コールバックを入れ子にせずに書くための小さな道具。
--
-- run() に渡した関数はコルーチンの中で動き、system() や sleep() で待つあいだ
-- エディタを止めない。fail() で投げたエラーは、トレースバックなしで利用者に通知する。
local M = {}

local Failure = {}
Failure.__index = Failure

--- 利用者に見せるエラーを投げる。
function M.fail(msg)
  error(setmetatable({ message = msg }, Failure), 0)
end

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    local msg = getmetatable(err) == Failure and err.message or tostring(err)
    vim.notify(msg, vim.log.levels.ERROR)
  end
end

--- 想定外のエラーにはトレースバックを付ける。fail() のエラーはそのまま通す。
local function with_traceback(err)
  if getmetatable(err) == Failure then
    return err
  end
  return debug.traceback(tostring(err), 2)
end

--- fn をコルーチンで実行する。終わる(またはエラーになる)と on_done を呼ぶ。
function M.run(fn, on_done)
  local co = coroutine.create(function()
    local ok, err = xpcall(fn, with_traceback)
    if on_done then
      on_done()
    end
    if not ok then
      error(err, 0)
    end
  end)
  resume(co)
end

--- vim.system を呼んで、終わるまで待つ。戻り値は vim.SystemCompleted。
---
--- 実行ファイルが見つからないときは fail() で知らせる。
function M.system(cmd, opts)
  local co = assert(coroutine.running(), 'async.system はコルーチンの中で呼ぶ')
  local ok, err = pcall(vim.system, cmd, opts or {}, function(res)
    vim.schedule(function()
      resume(co, res)
    end)
  end)
  if not ok then
    M.fail(('%s を実行できません: %s'):format(cmd[1], err))
  end
  return coroutine.yield()
end

--- ms ミリ秒待つ。
function M.sleep(ms)
  local co = assert(coroutine.running(), 'async.sleep はコルーチンの中で呼ぶ')
  vim.defer_fn(function()
    resume(co)
  end, ms)
  coroutine.yield()
end

return M
