-- devcontainer の作成と接続。
--
-- devcontainer.json の解釈は公式の devcontainer CLI に任せ、ここでは CLI と docker を呼ぶだけにする。
-- プロジェクトの devcontainer.json は書き換えず、Neovim に必要なマウントは `--mount` で外から注入する。
local async = require('devcontainer.async')
local env = require('devcontainer.env')
local host = require('devcontainer.host')
local log = require('devcontainer.log')
local plugins = require('devcontainer.plugins')

local M = {}

--- サーバの起動を待つ上限(ミリ秒)。
local SERVER_TIMEOUT_MS = 10000

--- devcontainer の中で nvim サーバを起動するスクリプト。
---
--- 引数は ソケット ログ nvim data用のvolumeの場所 [nvim の引数...]。サーバはバックグラウンドで動かし続け、
--- ソケットができたら終了する。devcontainer 側のユーザーは汎用コンテナの UID と
--- 違うことがあるので、ソケットは誰でも接続できるようにする。ソケット用の volume は
--- 汎用コンテナと devcontainer にしかマウントしないので、権限の緩さは問題にしない。
---
--- `docker exec` で起動したプロセスは umask が 0000 になり、サーバで保存したファイルが
--- 誰でも書き込める権限になってしまう。`docker run` の既定と同じ 0022 に揃える。
---
--- Neovim の data ディレクトリは、プラグイン用の volume へのシンボリックリンクにする。
--- プラグインマネージャが入れたプラグインや treesitter のパーサを、コンテナを作り直しても
--- 残すため。環境変数(XDG_DATA_HOME)で場所を変えると nvim から起動するコマンドにも
--- 影響するので、リンクにする。すでに data ディレクトリがあるときや、HOME に書き込めない
--- ときは何もしない。
local START_SERVER = [[
set -eu
umask 0022
sock=$1 log=$2 nvim=$3 volume=$4
shift 4
data=${XDG_DATA_HOME:-${HOME:-}/.local/share}/nvim
if [ "${data#/}" != "$data" ] && [ ! -e "$data" ] && [ ! -L "$data" ]; then
  mkdir -p "$volume/nvim" "${data%/*}" 2>/dev/null && ln -s "$volume/nvim" "$data" 2>/dev/null || true
fi
rm -f "$sock"
"$nvim" --headless --listen "$sock" "$@" </dev/null >"$log" 2>&1 &
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

--- ホストの環境変数のうち、devcontainer CLI には渡さず、汎用コンテナの値を使うもの。
--- CLI とそこから呼ばれる docker は汎用コンテナの中で動くので、実行ファイルの探し方や
--- Docker への接続先は、コンテナ側に合わせる必要がある。
local CONTAINER_SIDE_ENV = {
  'PATH', 'TMPDIR', 'LD_LIBRARY_PATH', 'LD_PRELOAD',
  'DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH',
}

--- devcontainer CLI に見せる環境変数。ホストエージェントがなければ nil(今の環境のまま)。
---
--- CLI は `${localEnv:...}` を自分の環境変数で展開するので、ホストの環境変数を見せる。
--- 展開されたパスを解釈するのはホストの Docker デーモンなので、そのパスが汎用コンテナに
--- 存在する必要はない。
local function cli_env()
  if not host.available() then
    return nil
  end
  local result = host.env()
  for _, key in ipairs(CONTAINER_SIDE_ENV) do
    result[key] = vim.env[key]
  end
  -- ホストの HOME は汎用コンテナにないので、docker が設定や buildx の状態を置く場所は
  -- コンテナ側の HOME にする。
  result.DOCKER_CONFIG = vim.env.DOCKER_CONFIG or vim.fs.joinpath(vim.env.HOME, '.docker')
  return result
end

--- vim.system に渡すオプション。cli_env が nil なら、今の環境のまま実行する。
local function system_opts(cli, opts)
  opts = vim.tbl_extend('force', { text = true }, opts or {})
  if cli then
    opts.env = cli
    opts.clear_env = true
  end
  return opts
end

--- コマンドを実行し、失敗したら標準エラー出力を添えて fail() する。
local function check(cmd, what, cli)
  local res = async.system(cmd, system_opts(cli))
  if res.code ~= 0 then
    async.fail(('%sに失敗しました: %s'):format(what, vim.trim(res.stderr or '')))
  end
  return res
end

--- 汎用イメージの参照。分からなければ fail() する。
local function generic_image()
  local image = env.image()
  if not image then
    async.fail('汎用イメージが分かりません(ランチャーから起動した汎用コンテナの中で実行してください)')
  end
  return image
end

--- named volume がなければ作り、汎用イメージのコンテナを1回動かして中身を整える。
---
--- run_args は `docker run --rm` に続ける引数列(イメージより前のオプション)、
--- command はイメージに続ける引数列。
local function ensure_volume(volume, what, label, run_args, command)
  if async.system({ 'docker', 'volume', 'inspect', volume }).code == 0 then
    return volume
  end

  local cmd = { 'docker', 'run', '--rm' }
  vim.list_extend(cmd, run_args)
  table.insert(cmd, generic_image())
  vim.list_extend(cmd, command or {})

  info(('%sを volume %s に用意しています'):format(what, volume))
  check({ 'docker', 'volume', 'create', '--label', label, volume }, 'volume の作成')
  local res = async.system(cmd, { text = true })
  if res.code ~= 0 then
    -- 中途半端な volume を残すと、次回以降もそれを使ってしまう。
    async.system({ 'docker', 'volume', 'rm', volume })
    async.fail(('%sの volume の用意に失敗しました: %s'):format(what, vim.trim(res.stderr or '')))
  end
  return volume
end

--- devcontainer に渡す Neovim 本体を、named volume に用意する。
---
--- 空の named volume を汎用イメージの /opt/nvim にマウントすると、Docker がイメージ側の
--- 内容を volume にコピーする。その仕組みを使って、コンテナを起動してすぐ終わらせる。
local function ensure_runtime_volume()
  local volume = env.runtime_volume()
  return ensure_volume(
    volume,
    'devcontainer に渡す Neovim ',
    'nvim-dc.runtime=' .. tostring(vim.version()),
    { '--entrypoint', 'true', '--mount', env.volume_mount(volume, '/opt/nvim') }
  )
end

--- devcontainer ごとの、プラグインを置く named volume を用意する。
---
--- 新しい named volume は root 所有になるので、devcontainer 側のどのユーザーでも
--- 書き込めるように、最上位を 1777 にしておく。
local function ensure_data_volume(workspace)
  local volume = env.data_volume(workspace)
  return ensure_volume(
    volume,
    'プラグインの置き場所',
    'nvim-dc.workspace=' .. workspace,
    { '--user', '0:0', '--entrypoint', 'chmod', '--mount', env.volume_mount(volume, env.data_dir) },
    { '1777', env.data_dir }
  )
end

--- devcontainer に注入するマウント。必要な volume がなければ作る。
local function mounts(workspace)
  return {
    { volume = ensure_runtime_volume(), target = env.runtime_dir },
    { volume = env.socket_volume, target = env.socket_dir },
    { volume = ensure_data_volume(workspace), target = env.data_dir },
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

--- initializeCommand の1つ分を、ホストで実行する argv にする。
--- 文字列はシェルに渡し、配列はそのまま実行する(devcontainer の仕様どおり)。
local function to_argv(command)
  if type(command) == 'string' then
    return vim.trim(command) ~= '' and { '/bin/sh', '-c', command } or nil
  end
  if type(command) == 'table' and vim.islist(command) and #command > 0 then
    return command
  end
  return nil
end

--- initializeCommand をホストで実行する。
---
--- オブジェクト形式(名前付きの複数コマンド)は、仕様では並列に実行するが、ここでは
--- 名前の順に1つずつ実行する。
local function run_initialize_command(command)
  local commands = {}
  if type(command) == 'table' and not vim.islist(command) then
    for _, name in ipairs(vim.fn.sort(vim.tbl_keys(command))) do
      table.insert(commands, { name = name, argv = to_argv(command[name]) })
    end
  else
    table.insert(commands, { argv = to_argv(command) })
  end

  for _, c in ipairs(commands) do
    if c.argv then
      local label = c.name and ('initializeCommand(%s)'):format(c.name) or 'initializeCommand'
      log.append({ ('[ホスト] %s: %s'):format(label, table.concat(c.argv, ' ')) })
      local write = log.writer()
      local code = host.run(c.argv, function(out)
        write(nil, out)
      end)
      write(nil, nil)
      if code ~= 0 then
        async.fail(('%s が失敗しました(終了コード %d、ログ: devcontainer://log)'):format(label, code))
      end
    end
  end
end

--- プラグインが自分で扱う設定の名前。
local OWN_SETTINGS = { 'initializeCommand', 'neovim' }

--- devcontainer.json を CLI に解釈させて読む(コメントの除去や変数の展開を任せる)。
---
--- プラグインが自分で扱う設定がなければ、CLI を1回余分に起動してまで読む必要はないので、
--- 空のテーブルを返す。
local function read_config(workspace, config_path, cli)
  local ok_read, lines = pcall(vim.fn.readfile, config_path)
  if ok_read then
    local text = table.concat(lines, '\n')
    local relevant = vim.iter(OWN_SETTINGS):any(function(name)
      return text:find(name, 1, true) ~= nil
    end)
    if not relevant then
      return {}
    end
  end
  local res = check(
    { 'devcontainer', 'read-configuration', '--workspace-folder', workspace },
    'devcontainer.json の読み込み',
    cli
  )
  local ok, decoded = pcall(vim.json.decode, vim.trim(res.stdout or ''))
  local config = ok and type(decoded) == 'table' and decoded.configuration
  if type(config) ~= 'table' then
    async.fail('devcontainer.json の読み込み結果を解釈できません')
  end
  return config
end

--- initializeCommand をホストで実行し、CLI には実行させないための引数を返す。
---
--- initializeCommand はホストで実行する前提のものだが、CLI に任せると汎用コンテナの中で
--- 実行されてしまう。CLI にはこれを飛ばすオプションがないので、解釈済みの設定から
--- initializeCommand を除いたものを `--override-config` で渡す。パスの解決やコンテナの
--- ラベルには元の設定ファイルが使われるので、他の動作は変わらない。
---
--- 戻り値は、up に足す引数と、後始末の関数。
local function initialize(config)
  local command = config.initializeCommand
  if not host.available() or command == nil or command == vim.NIL then
    return {}, function() end
  end

  run_initialize_command(command)

  local override = vim.tbl_extend('force', {}, config)
  override.initializeCommand = nil
  override.configFilePath = nil -- read-configuration が付ける情報で、設定の一部ではない
  local path = vim.fn.tempname() .. '.json'
  vim.fn.writefile({ vim.json.encode(override) }, path)
  return { '--override-config', path }, function()
    os.remove(path)
  end
end

--- devcontainer.json で宣言されたプラグインを、プラグイン用の volume に取得する。
local function install_plugins(workspace, result, declared, cli)
  -- 取得したファイルの所有者を、サーバを動かすユーザーに合わせる。
  local res = check({
    'devcontainer', 'exec', '--workspace-folder', workspace, '--container-id', result.containerId,
    'sh', '-c', 'echo "$(id -u):$(id -g)"',
  }, 'devcontainer のユーザーの確認', cli)
  local user = vim.trim(res.stdout or ''):match('(%d+:%d+)$')
  if not user then
    async.fail('devcontainer のユーザーを確認できません')
  end

  local cmd = plugins.install_command(generic_image(), env.data_volume(workspace), user, declared)
  -- 行の途中までの出力をためるので、stdout と stderr で別々に作る。
  res = async.system(cmd, { text = true, stdout = log.writer(), stderr = log.writer() })
  if res.code ~= 0 then
    async.fail('プラグインの取得に失敗しました(ログ: devcontainer://log)')
  end
end

--- `devcontainer up` を実行し、プラグインを取得する。
---
--- 戻り値は、up の結果(containerId、remoteWorkspaceFolder など)と、
--- devcontainer.json の Neovim 向けの設定(plugins.parse の戻り値)。
local function up(workspace, cli)
  local config_path = env.find_config(workspace)
  if not config_path then
    async.fail(workspace .. ' に devcontainer.json がありません')
  end
  local expected = mounts(workspace)

  local config = read_config(workspace, config_path, cli)
  -- 設定の誤りは、時間のかかる up の前に知らせる。
  local custom = plugins.parse(config)
  if custom.config and vim.fn.isdirectory(vim.fs.joinpath(workspace, custom.config)) == 0 then
    async.fail('customizations.neovim.config のディレクトリがありません: ' .. custom.config)
  end

  log.clear()
  log.open()
  local config_args, cleanup = initialize(config)

  local cmd = { 'devcontainer', 'up', '--workspace-folder', workspace }
  vim.list_extend(cmd, config_args)
  for _, m in ipairs(expected) do
    vim.list_extend(cmd, { '--mount', env.volume_mount(m.volume, m.target) })
  end

  log.append({ '$ ' .. table.concat(cmd, ' ') })
  info('devcontainer を起動しています')
  local res = async.system(cmd, system_opts(cli, { stderr = log.writer() }))
  cleanup()

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
  if #custom.plugins > 0 then
    install_plugins(workspace, result, custom.plugins, cli)
  end
  log.close()
  return result, custom
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

--- サーバ側の nvim が、設定を読む前に(`--cmd` で)実行する Lua。1行で書く。
---
--- %s は順に、packpath に足すディレクトリと、設定ディレクトリ(どちらも文字列か nil)。
--- 設定ディレクトリは runtimepath に足し、その init.lua を実行する。Neovim が自分の設定を
--- 読むときと同じ順序(init.lua が先、plugin/ があと)になるように、ここで実行する。
local BOOTSTRAP = table.concat({
  'local site, config = %s, %s',
  'if site then vim.opt.packpath:prepend(site) end',
  'if config then',
  'vim.opt.runtimepath:prepend(config)',
  "vim.opt.runtimepath:append(config .. '/after')",
  "local init = config .. '/init.lua'",
  'if vim.uv.fs_stat(init) then dofile(init) end',
  'end',
}, ' ')

--- Lua のソースに埋め込む値(文字列か nil)。
local function lua_literal(value)
  return value and ('%q'):format(value) or 'nil'
end

--- devcontainer の中で nvim サーバを起動し、応答するまで待つ。
local function start_server(workspace, result, custom, sock, cli)
  local args = {
    'devcontainer', 'exec', '--workspace-folder', workspace, '--container-id', result.containerId,
    'sh', '-c', START_SERVER, 'sh',
    sock, env.server_log_path(result.containerId), env.runtime_dir .. '/bin/nvim', env.data_dir,
  }
  local site = #custom.plugins > 0 and plugins.site_dir or nil
  local config = custom.config and vim.fs.joinpath(result.remoteWorkspaceFolder, custom.config) or nil
  if site or config then
    vim.list_extend(args, { '--cmd', 'lua ' .. BOOTSTRAP:format(lua_literal(site), lua_literal(config)) })
  end
  table.insert(args, '--')
  vim.list_extend(args, files_to_open(workspace))
  info('devcontainer の中で nvim を起動しています')
  check(args, 'nvim サーバの起動', cli)

  local waited = 0
  while not server_alive(sock) do
    if waited >= SERVER_TIMEOUT_MS then
      async.fail('nvim サーバに接続できません: ' .. sock)
    end
    async.sleep(100)
    waited = waited + 100
  end
end

--- 未保存の変更があるバッファがあれば fail() する。
local function check_unmodified()
  local names = vim.iter(vim.api.nvim_list_bufs())
    :filter(function(b)
      return vim.bo[b].modified and vim.bo[b].buftype == ''
    end)
    :map(function(b)
      local name = vim.api.nvim_buf_get_name(b)
      return name ~= '' and vim.fn.fnamemodify(name, ':~:.') or ('[No Name] ' .. b)
    end)
    :totable()
  if #names > 0 then
    async.fail('未保存の変更があります: ' .. table.concat(names, ', '))
  end
end

--- devcontainer.json から devcontainer を作成する。
function M.up()
  exclusive(function()
    local result = up(env.workspace(), cli_env())
    info(('devcontainer を起動しました(%s)'):format(env.short_id(result.containerId)))
  end)
end

--- devcontainer を(なければ作成して)、UI をその中の nvim サーバに繋ぎ替える。
---
--- 汎用コンテナ側の nvim は `:connect!` で止めるので、未保存の変更があれば中断する。
function M.connect()
  exclusive(function()
    check_unmodified()
    local workspace = env.workspace()
    local cli = cli_env()
    local result, custom = up(workspace, cli)
    local sock = env.socket_path(result.containerId)
    if not server_alive(sock) then
      start_server(workspace, result, custom, sock, cli)
    end
    -- 待っているあいだに編集された場合に備えて、もう一度確かめる。
    check_unmodified()
    vim.cmd('connect! ' .. vim.fn.fnameescape(sock))
  end)
end

return M
