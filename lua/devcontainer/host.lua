-- ホストでしかできない処理を、ランチャーのホストエージェントに依頼する。
--
-- devcontainer.json の `${localEnv:...}` と `initializeCommand` は、ホストで評価される前提の
-- ものだが、devcontainer CLI は汎用コンテナの中で動く。ホストで動いているランチャーが
-- Unix ソケットで依頼を受けるので(launcher/src/agent.rs)、ここからそれを呼ぶ。
-- プロトコルは1接続1依頼で、依頼も応答も1行1つの JSON。
local async = require('devcontainer.async')
local env = require('devcontainer.env')

local M = {}

--- ホストエージェントが使えるか。ランチャーを通さずに起動したときは使えない。
function M.available()
  return env.host_socket() ~= nil
end

--- 依頼を送り、応答の JSON を1つずつ on_reply に渡す。接続が閉じるまで待つ。
local function request(req, on_reply)
  local err = async.await(function(done)
    local pipe = assert(vim.uv.new_pipe(false))
    local finished = false
    local function finish(e)
      if finished then
        return
      end
      finished = true
      pipe:close()
      done(e)
    end

    local pending = ''
    pipe:connect(env.host_socket(), function(connect_err)
      if connect_err then
        return finish('接続できません: ' .. connect_err)
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
  end)
  if err then
    async.fail('ホストエージェントとの通信に失敗しました: ' .. err)
  end
end

--- ホストの環境変数を返す。
function M.env()
  local vars, err
  request({ op = 'env' }, function(reply)
    vars = reply.env or vars
    err = reply.error or err
  end)
  if type(vars) ~= 'table' then
    async.fail('ホストの環境変数を取得できません' .. (err and (': ' .. err) or ''))
  end
  return vars
end

--- ホストで、ワークスペースをカレントディレクトリにしてコマンドを実行する。
---
--- 出力は1行ずつ on_output に渡す(libuv のコールバックの中から呼ばれるので、
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
