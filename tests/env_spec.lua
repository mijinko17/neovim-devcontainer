local t = require('helpers')
local env = require('devcontainer.env')

--- 環境変数を一時的に差し替えて fn を実行する。
local function with_env(vars, fn)
  local saved = {}
  for name, value in pairs(vars) do
    saved[name] = vim.env[name] or false
    vim.env[name] = value or nil
  end
  local ok, err = pcall(fn)
  for name, value in pairs(saved) do
    vim.env[name] = value or nil
  end
  if not ok then
    error(err, 0)
  end
end

return {
  ['ランチャーの環境変数は、未設定と空文字を nil にする'] = function()
    with_env({ NVIM_DC_IMAGE = 'nvim-dc:dev', NVIM_DC_HOST_SOCK = '/run/nvim-dc-host/agent.sock' }, function()
      t.eq('nvim-dc:dev', env.image())
      t.eq(true, env.is_ui_side())
      t.eq('/run/nvim-dc-host/agent.sock', env.host_socket())
    end)
    with_env({ NVIM_DC_IMAGE = '', NVIM_DC_HOST_SOCK = false }, function()
      t.eq(nil, env.image())
      t.eq(false, env.is_ui_side())
      t.eq(nil, env.host_socket())
    end)
  end,

  ['workspace は環境変数がなければカレントディレクトリ'] = function()
    with_env({ NVIM_DC_WORKSPACE = '/work/project' }, function()
      t.eq('/work/project', env.workspace())
    end)
    with_env({ NVIM_DC_WORKSPACE = false }, function()
      t.eq(vim.fn.getcwd(), env.workspace())
    end)
  end,

  ['find_config は devcontainer CLI と同じ順に探す'] = function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. '/.devcontainer', 'p')
    t.eq(nil, env.find_config(dir))
    vim.fn.writefile({ '{}' }, dir .. '/.devcontainer.json')
    t.eq(dir .. '/.devcontainer.json', env.find_config(dir))
    vim.fn.writefile({ '{}' }, dir .. '/.devcontainer/devcontainer.json')
    t.eq(dir .. '/.devcontainer/devcontainer.json', env.find_config(dir))
    vim.fn.delete(dir, 'rf')
  end,

  ['runtime_volume は nvim のバージョンを含み、volume 名に使える文字だけになる'] = function()
    local name = env.runtime_volume()
    local v = vim.version()
    local prefix = ('nvim-dc-nvim-%d.%d.%d'):format(v.major, v.minor, v.patch)
    t.eq(prefix, name:sub(1, #prefix))
    t.eq(name, name:match('^[%w_.-]+$'))
  end,

  ['data_volume はワークスペースごとに決まる'] = function()
    local a = env.data_volume('/work/a')
    t.eq(a, env.data_volume('/work/a'))
    t.eq(a, a:match('^nvim%-dc%-data%-%x+$'))
    t.eq(#'nvim-dc-data-' + 12, #a)
    t.eq(false, a == env.data_volume('/work/b'))
  end,

  ['volume_mount は --mount の値を作る'] = function()
    t.eq('type=volume,source=vol,target=/opt/x', env.volume_mount('vol', '/opt/x'))
  end,

  ['ソケットとログのパスはコンテナ ID の先頭12桁から決まる'] = function()
    local id = '0123456789abcdef0123456789abcdef'
    t.eq('0123456789ab', env.short_id(id))
    t.eq('/run/nvim-dc/0123456789ab.sock', env.socket_path(id))
    t.eq('/run/nvim-dc/0123456789ab.log', env.server_log_path(id))
  end,
}
