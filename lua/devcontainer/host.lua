-- ホストでしかできない処理を、ランチャーのホストエージェントに依頼する。
--
-- devcontainer.json の `${localEnv:...}` と `initializeCommand` は、ホストで評価される前提の
-- ものだが、devcontainer CLI は汎用コンテナの中で動く。ホストで動いているランチャーが
-- Unix ソケットで依頼を受けるので(launcher/src/agent.rs)、ここからそれを呼ぶ。
-- プロトコルは1接続1依頼で、依頼も応答も1行1つの JSON。
local async = require('devcontainer.async')

local M = {}

--- ホストエージェントのソケット。ランチャーが環境変数で渡す。
local function socket()
  local path = vim.env.NVIM_DC_HOST_SOCK
  if path and path ~= '' then
    return path
  end
  return nil
end

--- ホストエージェントが使えるか。ランチャーを通さずに起動したときは使えない。
function M.available()
  return socket() ~= nil
end

--- 依頼を送り、応答の JSON を1つずつ on_reply に渡す。接続が閉じるまで待つ。
local function request(req, on_reply)
  local co = assert(coroutine.running(), 'host.request はコルーチンの中で呼ぶ')
  local pipe = assert(vim.uv.new_pipe(false))
  local finished = false
  local function finish(err)
    if finished then
      return
    end
    finished = true
    pipe:close()
    vim.schedule(function()
      async.resume(co, err)
    end)
  end

  local pending = ''
  pipe:connect(socket(), function(err)
    if err then
      return finish('接続できません: ' .. err)
    end
    pipe:write(vim.json.encode(req) .. '\n')
    pipe:read_start(function(read_err, data)
      if read_err then
        return finish(read_err)
      end
      if not data then
        return finish()
      end
      local lines = vim.split(pending .. data, '\n', { plain = true })
      pending = table.remove(lines)
      for _, line in ipairs(lines) do
        local ok, reply = pcall(vim.json.decode, line)
        if not ok then
          return finish('応答を解釈できません: ' .. line)
        end
        on_reply(reply)
      end
    end)
  end)

  local err = coroutine.yield()
  if err then
    async.fail('ホストエージェントとの通信に失敗しました: ' .. err)
  end
end

--- ホストの環境変数を返す。
function M.env()
  local env, err
  request({ op = 'env' }, function(reply)
    env = reply.env or env
    err = reply.error or err
  end)
  if type(env) ~= 'table' then
    async.fail('ホストの環境変数を取得できません' .. (err and (': ' .. err) or ''))
  end
  return env
end

--- ホストで、ワークスペースをカレントディレクトリにしてコマンドを実行する。
---
--- 出力は1行ずつ on_output に渡す(応答を受け取ったスレッドから呼ばれるので、
--- エディタに触るなら vim.schedule すること)。戻り値は終了コード。
function M.run(argv, on_output)
  local code, err
  request({ op = 'run', argv = argv }, function(reply)
    if reply.out then
      on_output(reply.out)
    elseif reply.exit then
      code = reply.exit
    elseif reply.error then
      err = reply.error
    end
  end)
  if err then
    async.fail('ホストでコマンドを実行できません: ' .. err)
  end
  if not code then
    async.fail('ホストでのコマンドの結果を受け取れませんでした')
  end
  return code
end

return M
