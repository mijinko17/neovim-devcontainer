-- devcontainer.json の `customizations.neovim` の解釈と、プラグインの取得。
--
-- ```jsonc
-- "customizations": {
--   "neovim": {
--     "plugins": ["neovim/nvim-lspconfig", "tpope/vim-commentary@v1.3"],
--     "config": ".devcontainer/nvim"
--   }
-- }
-- ```
--
-- VS Code の `extensions` と `settings` にならって、何を入れるかは `plugins` に、その設定は
-- `config` に書く。`plugins` のプラグインは devcontainer ごとの named volume の
-- `pack/devcontainer/start/` に置き、サーバ側の nvim が Neovim 標準のパッケージ機構で
-- 読み込む。`config` は Neovim の設定ディレクトリと同じ構成のディレクトリで、サーバ側の
-- nvim の runtimepath に足す。
--
-- `plugins` に書けるのは取得元とバージョンまでにする。遅延読み込みやビルド手順まで扱うと、
-- プラグインマネージャの再発明になるため。
local async = require('devcontainer.async')
local env = require('devcontainer.env')

local M = {}

--- サーバ側の nvim の packpath に足すディレクトリ。
M.site_dir = env.data_dir .. '/site'
--- プラグインを置くディレクトリ。
M.pack_dir = M.site_dir .. '/pack/devcontainer/start'

local NAME_PATTERN = '^[%w_.-]+$'

--- プラグインの宣言1つを、名前と取得元の URL、バージョンにする。
---
--- `owner/repo` は GitHub のリポジトリとして扱う。URL(`https://...` や `git@host:...`)は
--- そのまま使う。名前は URL の最後の要素から決める。末尾に `@v1.2.3` のように付けると、
--- そのタグ・ブランチ・コミットを取得する(VS Code の `publisher.extension@1.2.3` と同じ書き方)。
local function parse_plugin(spec)
  if type(spec) ~= 'string' then
    async.fail('customizations.neovim.plugins には文字列を並べてください')
  end
  -- 最後の `/` より後ろにある `@` から先がバージョン(`git@host:...` の `@` と区別する)。
  -- `git@host:repo.git` のように、`@` の前が取得元として成り立たないものはバージョンと見なさない。
  local source, ref = spec:match('^(.*)@([^@/]*)$')
  if not source or not source:find('[/:]') then
    source, ref = spec, ''
  elseif not ref:find('^%w[%w_.-]*$') then
    async.fail('プラグインのバージョンを解釈できません: ' .. spec)
  end

  local url
  if source:find('^[%w_.-]+/[%w_.-]+$') then
    url = ('https://github.com/%s.git'):format((source:gsub('%.git$', '')))
  elseif source:find('^%a[%w+.-]*://') or source:find('^[%w_.-]+@[%w_.-]+:') then
    url = source
  else
    async.fail(
      ('プラグインの指定を解釈できません: %s(owner/repo か URL で指定してください)'):format(
        spec
      )
    )
  end
  local name = url:gsub('/+$', ''):gsub('%.git$', ''):match('([^/:]+)$')
  if not name or not name:find(NAME_PATTERN) or name == '.' or name == '..' then
    async.fail('プラグインの名前を決められません: ' .. spec)
  end
  return { name = name, url = url, ref = ref }
end

--- ワークスペースからの相対パスであることを確かめる。
local function parse_config(path)
  if type(path) ~= 'string' or path == '' then
    async.fail('customizations.neovim.config にはディレクトリのパスを指定してください')
  end
  local escapes = vim.iter(vim.split(path, '/', { plain = true })):any(function(part)
    return part == '..'
  end)
  if path:sub(1, 1) == '/' or escapes then
    async.fail(
      'customizations.neovim.config はワークスペースの中の相対パスで指定してください: ' .. path
    )
  end
  return (path:gsub('/+$', ''))
end

--- 解釈済みの devcontainer.json から、Neovim 向けの設定を取り出す。
---
--- 戻り値は `{ plugins = { { name, url, ref }, ... }, config = 相対パス または nil }`。
--- ref はバージョンの指定で、なければ空文字。
function M.parse(config)
  local result = { plugins = {} }
  local custom = type(config.customizations) == 'table' and config.customizations.neovim
  if type(custom) ~= 'table' then
    return result
  end

  local plugins = custom.plugins
  if plugins ~= nil and plugins ~= vim.NIL then
    if type(plugins) ~= 'table' or not vim.islist(plugins) then
      async.fail('customizations.neovim.plugins は配列で指定してください')
    end
    local seen = {}
    for _, spec in ipairs(plugins) do
      local plugin = parse_plugin(spec)
      if seen[plugin.name] then
        async.fail('同じ名前のプラグインが2つあります: ' .. plugin.name)
      end
      seen[plugin.name] = true
      table.insert(result.plugins, plugin)
    end
  end

  if custom.config ~= nil and custom.config ~= vim.NIL then
    result.config = parse_config(custom.config)
  end
  return result
end

--- プラグインを取得するスクリプト。引数は 置き場所 [名前 URL バージョン]...(バージョンは
--- 指定がなければ空文字)。
---
--- 宣言から消えたプラグインは消し、まだないものと、取得元かバージョンの指定が変わったものを
--- 取得する。何から取得したかは、プラグインのディレクトリの中の `.nvim-dc-source` に書いておく。
--- 取得に失敗したときに、中途半端なディレクトリが読み込まれたり、いままでのものが消えたり
--- しないように、別の場所に取得してから入れ替える。
local INSTALL = [[
set -eu
dir=$1
shift
[ -n "$dir" ]
tmp=$dir.tmp
rm -rf "$tmp"
mkdir -p "$dir"
for path in "$dir"/*; do
  [ -d "$path" ] || continue
  keep=
  i=0
  for arg in "$@"; do
    [ $((i % 3)) -eq 0 ] && [ "$arg" = "${path##*/}" ] && keep=1
    i=$((i + 1))
  done
  if [ -z "$keep" ]; then
    echo "プラグインを削除します: ${path##*/}"
    rm -rf "$path"
  fi
done
while [ $# -gt 0 ]; do
  name=$1 url=$2 ref=$3
  shift 3
  source="$url $ref"
  [ "$(cat "$dir/$name/.nvim-dc-source" 2>/dev/null || true)" = "$source" ] && continue
  echo "プラグインを取得します: $url${ref:+ ($ref)}"
  if [ -n "$ref" ]; then
    git -c init.defaultBranch=main init --quiet "$tmp"
    git -C "$tmp" remote add origin "$url"
    git -C "$tmp" fetch --quiet --depth 1 origin "$ref"
    git -C "$tmp" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
  else
    git clone --quiet --depth 1 "$url" "$tmp"
  fi
  printf '%s\n' "$source" >"$tmp/.nvim-dc-source"
  rm -rf "$dir/$name"
  mv "$tmp" "$dir/$name"
done
]]

--- プラグインを取得する `docker run` の引数列を作る。
---
--- git は devcontainer にあるとは限らないので、汎用イメージのコンテナで取得する。
--- 取得したファイルを devcontainer のユーザーが書き換えられるように(ヘルプのタグの
--- 生成など)、そのユーザーの UID/GID で実行する。
function M.install_command(image, volume, user, plugins)
  -- オプションと値の組が分かるように、整形はしない。
  -- stylua: ignore
  local cmd = {
    'docker', 'run', '--rm', '--user', user,
    '--env', 'GIT_TERMINAL_PROMPT=0',
    '--mount', env.volume_mount(volume, env.data_dir),
    '--entrypoint', 'sh',
    image, '-c', INSTALL, 'sh', M.pack_dir,
  }
  for _, plugin in ipairs(plugins) do
    vim.list_extend(cmd, { plugin.name, plugin.url, plugin.ref })
  end
  return cmd
end

return M
