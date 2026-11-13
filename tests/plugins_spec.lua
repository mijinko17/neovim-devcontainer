local t = require('helpers')
local plugins = require('devcontainer.plugins')

local function parse(neovim)
  return plugins.parse({ customizations = { neovim = neovim } })
end

--- プラグインの宣言1つを解釈した結果。
local function plugin(spec)
  return parse({ plugins = { spec } }).plugins[1]
end

return {
  ['customizations.neovim がなければ空'] = function()
    t.eq({ plugins = {} }, plugins.parse({}))
    t.eq({ plugins = {} }, plugins.parse({ customizations = {} }))
    t.eq({ plugins = {} }, plugins.parse({ customizations = { vscode = {} } }))
    t.eq({ plugins = {} }, parse({}))
  end,

  ['JSON の null は指定なしと同じ'] = function()
    t.eq({ plugins = {} }, parse({ plugins = vim.NIL, config = vim.NIL }))
  end,

  ['owner/repo は GitHub のリポジトリ'] = function()
    t.eq(
      { name = 'nvim-lspconfig', url = 'https://github.com/neovim/nvim-lspconfig.git', ref = '' },
      plugin('neovim/nvim-lspconfig')
    )
    t.eq(
      { name = 'mini.nvim', url = 'https://github.com/echasnovski/mini.nvim.git', ref = '' },
      plugin('echasnovski/mini.nvim')
    )
    t.eq({ name = 'repo', url = 'https://github.com/owner/repo.git', ref = '' }, plugin('owner/repo.git'))
  end,

  ['@ から先はバージョン'] = function()
    t.eq(
      { name = 'vim-commentary', url = 'https://github.com/tpope/vim-commentary.git', ref = 'v1.3' },
      plugin('tpope/vim-commentary@v1.3')
    )
    t.eq(
      { name = 'repo', url = 'https://example.com/owner/repo.git', ref = 'main' },
      plugin('https://example.com/owner/repo.git@main')
    )
    t.eq(
      { name = 'repo', url = 'git@example.com:owner/repo.git', ref = '0a1b2c3' },
      plugin('git@example.com:owner/repo.git@0a1b2c3')
    )
  end,

  ['URL はそのまま使い、名前は最後の要素から決める'] = function()
    t.eq(
      { name = 'repo', url = 'https://example.com/owner/repo.git', ref = '' },
      plugin('https://example.com/owner/repo.git')
    )
    t.eq(
      { name = 'repo', url = 'https://example.com/owner/repo/', ref = '' },
      plugin('https://example.com/owner/repo/')
    )
  end,

  ['git@host:... の @ はバージョンと見なさない'] = function()
    t.eq({ name = 'repo', url = 'git@example.com:owner/repo.git', ref = '' }, plugin('git@example.com:owner/repo.git'))
    t.eq({ name = 'repo', url = 'git@example.com:repo.git', ref = '' }, plugin('git@example.com:repo.git'))
  end,

  ['解釈できない宣言は失敗する'] = function()
    t.fails('文字列を並べてください', function()
      plugin(42)
    end)
    t.fails('プラグインの指定を解釈できません', function()
      plugin('just-a-name')
    end)
    t.fails('プラグインの指定を解釈できません', function()
      plugin('a/b/c')
    end)
    t.fails('プラグインのバージョンを解釈できません', function()
      plugin('owner/repo@')
    end)
    t.fails('プラグインのバージョンを解釈できません', function()
      plugin('owner/repo@-rf')
    end)
    t.fails('プラグインの名前を決められません', function()
      plugin('https://example.com/..')
    end)
  end,

  ['plugins は配列でなければ失敗する'] = function()
    t.fails('配列で指定してください', function()
      parse({ plugins = 'owner/repo' })
    end)
    t.fails('配列で指定してください', function()
      parse({ plugins = { a = 'owner/repo' } })
    end)
  end,

  ['同じ名前のプラグインは失敗する'] = function()
    t.fails('同じ名前のプラグインが2つあります: repo', function()
      parse({ plugins = { 'a/repo', 'b/repo' } })
    end)
  end,

  ['宣言の順序を保つ'] = function()
    local names = vim.tbl_map(function(p)
      return p.name
    end, parse({ plugins = { 'x/b', 'x/a', 'x/c' } }).plugins)
    t.eq({ 'b', 'a', 'c' }, names)
  end,

  ['config はワークスペースの中の相対パス'] = function()
    t.eq('.devcontainer/nvim', parse({ config = '.devcontainer/nvim' }).config)
    t.eq('.devcontainer/nvim', parse({ config = '.devcontainer/nvim//' }).config)
    t.eq('a..b/nvim', parse({ config = 'a..b/nvim' }).config)
  end,

  ['config がワークスペースの外を指すと失敗する'] = function()
    for _, path in ipairs({ '/etc/nvim', '../nvim', 'a/../../nvim', 'a/..' }) do
      t.fails('相対パスで指定してください', function()
        parse({ config = path })
      end)
    end
    for _, path in ipairs({ '', 42, {} }) do
      t.fails('ディレクトリのパスを指定してください', function()
        parse({ config = path })
      end)
    end
  end,

  ['install_command は取得用のコンテナの引数列を作る'] = function()
    local cmd = plugins.install_command('nvim-dc:dev', 'nvim-dc-data-abc', '1000:1000', {
      { name = 'a', url = 'https://example.com/a.git', ref = '' },
      { name = 'b', url = 'https://example.com/b.git', ref = 'v1' },
    })
    t.eq({ 'docker', 'run', '--rm', '--user', '1000:1000' }, vim.list_slice(cmd, 1, 5))
    t.eq(true, vim.list_contains(cmd, 'type=volume,source=nvim-dc-data-abc,target=/opt/nvim-dc-data'))
    -- スクリプトへの引数は、置き場所に続けて 名前・URL・バージョン の3つ組。
    t.eq({
      'sh',
      '/opt/nvim-dc-data/site/pack/devcontainer/start',
      'a',
      'https://example.com/a.git',
      '',
      'b',
      'https://example.com/b.git',
      'v1',
    }, vim.list_slice(cmd, #cmd - 7))
  end,
}
