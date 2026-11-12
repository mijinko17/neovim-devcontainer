-- devcontainer の作成と接続。
--
-- devcontainer.json の解釈は公式の devcontainer CLI に任せ、ここでは CLI と docker を呼ぶだけにする。
-- プロジェクトの devcontainer.json は書き換えず、Neovim に必要なマウントは `--mount` で外から注入する。
local async = require('devcontainer.async')
local env = require('devcontainer.env')
local log = require('devcontainer.log')

local M = {}

--- サーバの起動を待つ上限(ミリ秒)。
local SERVER_TIMEOUT_MS = 10000

--- devcontainer の中で nvim サーバを起動するスクリプト。
---
--- 引数は ソケット ログ nvim [ファイル...]。サーバはバックグラウンドで動かし続け、
--- ソケットができたら終了する。devcontainer 側のユーザーは汎用コンテナの UID と
--- 違うことがあるので、ソケットは誰でも接続できるようにする。ソケット用の volume は
--- 汎用コンテナと devcontainer にしかマウントしないので、権限の緩さは問題にしない。
---
--- `docker exec` で起動したプロセスは umask が 0000 になり、サーバで保存したファイルが
--- 誰でも書き込める権限になってしまう。`docker run` の既定と同じ 0022 に揃える。
local START_SERVER = [[
set -eu
umask 0022
sock=$1 log=$2 nvim=$3
shift 3
rm -f "$sock"
"$nvim" --headless --listen "$sock" -- "$@" </dev/null >"$log" 2>&1 &
pid=$!
i=0
while [ ! -S "$sock" ]; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "nvim サーバが終了しました:" >&2
    cat "$log" >&2
    exit 1
  fi
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    echo "nvim サーバのソケットができません(ログ: $log)" >&2
    exit 1
  fi
  sleep 0.1
done
chmod 666 "$sock"
]]

local busy = false

--- 同時に1つしか動かさない。devcontainer up を並行して走らせると同じコンテナを二重に作るため。
local function exclusive(fn)
  if busy then
    vim.notify('devcontainer の処理が実行中です', vim.log.levels.WARN)
    return
  end
  busy = true
  async.run(fn, function()
    busy = false
  end)
end

local function info(msg)
  vim.notify(msg, vim.log.levels.INFO)
end

--- コマンドを実行し、失敗したら標準エラー出力を添えて fail() する。
local function check(cmd, what)
  local res = async.system(cmd, { text = true })
  if res.code ~= 0 then
    async.fail(('%sに失敗しました: %s'):format(what, vim.trim(res.stderr or '')))
  end
  return res
end

--- devcontainer に渡す Neovim 本体を、named volume に用意する。
---
--- 空の named volume を汎用イメージの /opt/nvim にマウントすると、Docker がイメージ側の
--- 内容を volume にコピーする。その仕組みを使って、コンテナを起動してすぐ終わらせる。
local function ensure_runtime_volume()
  local volume = env.runtime_volume()
  if async.system({ 'docker', 'volume', 'inspect', volume }).code == 0 then
    return volume
  end

  local image = env.image()
  if not image then
    async.fail('汎用イメージが分かりません(ランチャーから起動した汎用コンテナの中で実行してください)')
  end
  info('devcontainer に渡す Neovim を volume ' .. volume .. ' に用意しています')
  check({ 'docker', 'volume', 'create', '--label', 'nvim-dc.runtime=' .. tostring(vim.version()), volume }, 'volume の作成')
  local res = async.system({
    'docker', 'run', '--rm', '--entrypoint', 'true',
    '--mount', ('type=volume,source=%s,target=/opt/nvim'):format(volume),
    image,
  }, { text = true })
  if res.code ~= 0 then
    -- 中途半端な volume を残すと、次回以降もそれを使ってしまう。
    async.system({ 'docker', 'volume', 'rm', volume })
    async.fail(('Neovim の volume の用意に失敗しました: %s'):format(vim.trim(res.stderr or '')))
  end
  return volume
end

--- devcontainer に注入するマウント。
local function mounts(runtime_volume)
  return {
    { volume = runtime_volume, target = env.runtime_dir },
    { volume = env.socket_volume, target = env.socket_dir },
  }
end

--- 既存のコンテナが、必要なマウントなしで作られていないかを確かめる。
---
--- devcontainer CLI はワークスペースのパスからコンテナを探して使い回すので、VS Code や
--- 古いバージョンの Neovim で作ったコンテナには `--mount` が反映されない。
local function check_mounts(container_id, expected)
  local res = check({ 'docker', 'inspect', '--format', '{{json .Mounts}}', container_id }, 'コンテナの確認')
  local actual = vim.json.decode(res.stdout)
  if type(actual) ~= 'table' then
    actual = {} -- マウントがないと null になる
  end
  local missing = {}
  for _, want in ipairs(expected) do
    local found = vim.iter(actual):any(function(m)
      return m.Type == 'volume' and m.Name == want.volume and m.Destination == want.target
    end)
    if not found then
      table.insert(missing, ('%s → %s'):format(want.volume, want.target))
    end
  end
  if #missing > 0 then
    async.fail(table.concat({
      ('既存の devcontainer(%s)に、Neovim 用のマウントがありません:'):format(env.short_id(container_id)),
      '  ' .. table.concat(missing, '\n  '),
      'コンテナを削除してから、もう一度実行してください: docker rm -f ' .. env.short_id(container_id),
    }, '\n'))
  end
end

--- `devcontainer up` を実行し、結果(containerId、remoteWorkspaceFolder など)を返す。
local function up(workspace)
  if not env.find_config(workspace) then
    async.fail(workspace .. ' に devcontainer.json がありません')
  end
  local runtime_volume = ensure_runtime_volume()
  local expected = mounts(runtime_volume)

  local cmd = { 'devcontainer', 'up', '--workspace-folder', workspace }
  for _, m in ipairs(expected) do
    vim.list_extend(cmd, { '--mount', ('type=volume,source=%s,target=%s'):format(m.volume, m.target) })
  end

  log.clear()
  log.append({ '$ ' .. table.concat(cmd, ' ') })
  log.open()
  info('devcontainer を起動しています')
  local res = async.system(cmd, { text = true, stderr = log.writer() })

  -- 結果は標準出力の最後の行に JSON で出る。
  local lines = vim.split(vim.trim(res.stdout or ''), '\n')
  local ok, result = pcall(vim.json.decode, lines[#lines])
  if not ok or type(result) ~= 'table' then
    async.fail('devcontainer up に失敗しました(ログ: devcontainer://log)')
  end
  if result.outcome ~= 'success' then
    async.fail(('devcontainer up に失敗しました: %s %s'):format(result.message or '', result.description or ''))
  end

  check_mounts(result.containerId, expected)
  log.close()
  return result
end

--- ソケットの先で nvim サーバが応答するか。
local function server_alive(sock)
  if not vim.uv.fs_stat(sock) then
    return false
  end
  local ok, chan = pcall(vim.fn.sockconnect, 'pipe', sock, { rpc = true })
  if not ok or chan == 0 then
    return false
  end
  local alive = pcall(vim.rpcrequest, chan, 'nvim_get_api_info')
  vim.fn.chanclose(chan)
  return alive
end

--- 新しく起動するサーバで開くファイル。カレントバッファがワークスペースの中のファイルなら、
--- devcontainer のワークスペースでの相対パスで開き直す。
local function files_to_open(workspace)
  local name = vim.api.nvim_buf_get_name(0)
  if vim.bo.buftype ~= '' or name == '' then
    return {}
  end
  local rel = vim.fs.relpath(workspace, name)
  if not rel or rel == '.' then
    return {}
  end
  return { rel }
end

--- devcontainer の中で nvim サーバを起動し、応答するまで待つ。
local function start_server(workspace, result, sock)
  local args = {
    'devcontainer', 'exec', '--workspace-folder', workspace, '--container-id', result.containerId,
    'sh', '-c', START_SERVER, 'sh',
    sock, env.server_log_path(result.containerId), env.runtime_dir .. '/bin/nvim',
  }
  vim.list_extend(args, files_to_open(workspace))
  info('devcontainer の中で nvim を起動しています')
  check(args, 'nvim サーバの起動')

  local waited = 0
  while not server_alive(sock) do
    if waited >= SERVER_TIMEOUT_MS then
      async.fail('nvim サーバに接続できません: ' .. sock)
    end
    async.sleep(100)
    waited = waited + 100
  end
end

--- 未保存の変更があるバッファの名前。
local function modified_buffers()
  return vim.iter(vim.api.nvim_list_bufs())
    :filter(function(b)
      return vim.bo[b].modified and vim.bo[b].buftype == ''
    end)
    :map(function(b)
      local name = vim.api.nvim_buf_get_name(b)
      return name ~= '' and vim.fn.fnamemodify(name, ':~:.') or ('[No Name] ' .. b)
    end)
    :totable()
end

--- devcontainer.json から devcontainer を作成する。
function M.up()
  exclusive(function()
    local result = up(env.workspace())
    info(('devcontainer を起動しました(%s)'):format(env.short_id(result.containerId)))
  end)
end

--- devcontainer を(なければ作成して)、UI をその中の nvim サーバに繋ぎ替える。
---
--- 汎用コンテナ側の nvim は `:connect!` で止めるので、未保存の変更があれば中断する。
function M.connect()
  local modified = modified_buffers()
  if #modified > 0 then
    vim.notify('未保存の変更があります: ' .. table.concat(modified, ', '), vim.log.levels.ERROR)
    return
  end

  exclusive(function()
    local workspace = env.workspace()
    local result = up(workspace)
    local sock = env.socket_path(result.containerId)
    if not server_alive(sock) then
      start_server(workspace, result, sock)
    end
    -- 待っているあいだに編集された場合に備えて、もう一度確かめる。
    modified = modified_buffers()
    if #modified > 0 then
      async.fail('未保存の変更があります: ' .. table.concat(modified, ', '))
    end
    vim.cmd('connect! ' .. vim.fn.fnameescape(sock))
  end)
end

return M
