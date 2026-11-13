-- 汎用コンテナと devcontainer の間で決めておく名前とパス。
--
-- ソケット用の volume 名とマウント先は、ランチャー(launcher/src/run.rs の SOCKET_VOLUME)と
-- イメージ(image/Dockerfile)でも同じものを使っている。
local M = {}

--- UI 側と devcontainer 側の nvim が通信する Unix ソケットを置く named volume。
M.socket_volume = 'nvim-dc-sockets'
--- ソケット用の volume のマウント先。汎用コンテナと devcontainer で同じパスにする。
M.socket_dir = '/run/nvim-dc'
--- devcontainer の中で、汎用イメージの Neovim 本体(/opt/nvim)をマウントする場所。
M.runtime_dir = '/opt/nvim-dc-runtime'

--- devcontainer の中で、プラグインと Neovim の data ディレクトリを置く named volume を
--- マウントする場所。
M.data_dir = '/opt/nvim-dc-data'

--- ランチャーが渡す環境変数。未設定と空文字は nil にする。
local function launcher_env(name)
  local value = vim.env[name]
  return value ~= '' and value or nil
end

--- 汎用イメージの参照。devcontainer に Neovim 本体を渡すときに使う。
function M.image()
  return launcher_env('NVIM_DC_IMAGE')
end

--- ランチャーから起動された汎用コンテナの中かどうか。
function M.is_ui_side()
  return M.image() ~= nil
end

--- ワークスペースのパス(ホストと同じ絶対パス)。
function M.workspace()
  return launcher_env('NVIM_DC_WORKSPACE') or vim.fn.getcwd()
end

--- ホストエージェントのソケット。ランチャーを通さずに起動したときは nil。
function M.host_socket()
  return launcher_env('NVIM_DC_HOST_SOCK')
end

--- ワークスペースの devcontainer.json。devcontainer CLI の既定と同じ順に探す。
function M.find_config(workspace)
  for _, rel in ipairs({ '.devcontainer/devcontainer.json', '.devcontainer.json' }) do
    local path = vim.fs.joinpath(workspace, rel)
    if vim.uv.fs_stat(path) then
      return path
    end
  end
  return nil
end

--- Neovim 本体を入れる named volume の名前。バージョンごとに分ける。
---
--- UI 側とサーバ側のバージョンを一致させるため、名前にこの nvim のバージョンを含める。
--- 開発版のビルドは同じバージョン番号でも中身が変わるので、ビルドの識別子も含める。
function M.runtime_volume()
  local v = vim.version()
  local version = ('%d.%d.%d'):format(v.major, v.minor, v.patch)
  if v.prerelease then
    version = version .. '-' .. tostring(v.build or v.prerelease)
  end
  return 'nvim-dc-nvim-' .. version:gsub('[^%w_.-]', '-')
end

--- devcontainer ごとの、プラグインと Neovim の data ディレクトリを置く named volume の名前。
---
--- コンテナを作る前にマウントを決めるので、コンテナ ID ではなくワークスペースのパスから
--- 決める(devcontainer CLI も、ワークスペースのパスでコンテナを見分ける)。
function M.data_volume(workspace)
  return 'nvim-dc-data-' .. vim.fn.sha256(workspace):sub(1, 12)
end

--- `docker run` や `devcontainer up` の `--mount` に渡す、named volume のマウントの指定。
function M.volume_mount(volume, target)
  return ('type=volume,source=%s,target=%s'):format(volume, target)
end

--- コンテナ ID の短縮形(docker の表示と同じ先頭12桁)。
function M.short_id(container_id)
  return container_id:sub(1, 12)
end

--- devcontainer ごとのソケットのパス。
function M.socket_path(container_id)
  return ('%s/%s.sock'):format(M.socket_dir, M.short_id(container_id))
end

--- devcontainer ごとのサーバのログのパス。
function M.server_log_path(container_id)
  return ('%s/%s.log'):format(M.socket_dir, M.short_id(container_id))
end

return M
