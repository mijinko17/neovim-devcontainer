# 開発手順

開発用の devcontainer(`.devcontainer/`)の中で作業する前提です。Docker は docker-in-docker なので、ここで作ったコンテナはホストの Docker を汚しません。

## 汎用イメージのビルド

プラグイン(`plugin/`、`lua/`)もイメージに入れるので、ビルドコンテキストはリポジトリのルートにします。

```sh
docker build -t nvim-dc:dev -f image/Dockerfile .
```

## ランチャーのビルドとテスト

```sh
cd launcher
cargo test
cargo build --release --target "$(uname -m)-unknown-linux-musl"
```

成果物は `launcher/target/<arch>-unknown-linux-musl/release/nvim-dc`(`<arch>` は `x86_64` か `aarch64`)で、静的リンクの単一バイナリです。

## リリース

1. `launcher/Cargo.toml` の `version` を上げ、`cargo build` で `Cargo.lock` に反映してコミットする。
2. そのバージョンに `v` を付けたタグ(`0.2.0` なら `v0.2.0`)を打って push する。

```sh
git tag v0.2.0
git push origin main v0.2.0
```

タグの push で、2つのワークフローが動きます。

- [image.yml](../.github/workflows/image.yml): 汎用イメージを `ghcr.io/mijinko17/neovim-devcontainer:0.2.0` で公開する。
- [release.yml](../.github/workflows/release.yml): ランチャーを x86_64 と aarch64 向けにビルドし、イメージの公開を待ってから、`nvim-dc-0.2.0-<ターゲット>.tar.gz` を GitHub Releases に公開する。

タグと `launcher/Cargo.toml` のバージョンが一致しないと、どちらも失敗します。release.yml は手動でも実行でき(Actions の画面か `gh workflow run release.yml`)、その場合はビルドした成果物を残すだけでリリースは作りません。

利用者は `nvim-dc update` で最新のリリースに更新できます。実行ファイルをその場で置き換えるので、置き場所に書き込めるユーザーで実行します。

## ローカルでビルドしたイメージで起動する

既定では `ghcr.io/mijinko17/neovim-devcontainer:<ランチャーのバージョン>` を使います。ローカルのイメージを使うには、設定ファイル `~/.config/nvim-dc/config.toml`(`$XDG_CONFIG_HOME` があればその下)で差し替えます。

```toml
image = "nvim-dc:dev"

# 追加のマウント。`docker run --mount` の値をそのまま書く。
mounts = [
  "type=bind,source=/home/me/.gitconfig,target=/home/nvim-dc/.gitconfig,readonly",
]
```

```sh
launcher/target/"$(uname -m)"-unknown-linux-musl/release/nvim-dc [path]
```

開発中のプラグインを、イメージを作り直さずに試すには、リポジトリをイメージ内のプラグインの場所(`/opt/nvim-dc`)に重ねてマウントします。

```toml
mounts = [
  "type=bind,source=/workspaces/neovim-devcontainer,target=/opt/nvim-dc,readonly",
]
```

`path` がディレクトリならそこをワークスペースにし、ファイルなら親ディレクトリをワークスペースにしてそのファイルを開きます。ファイルがシンボリックリンクでも、リンク先ではなく指定したパスの親ディレクトリをワークスペースにします。

次の場合は起動せずにエラーにします。

- 標準入力か標準出力が端末でない(パイプやリダイレクトを含む)。
- ワークスペースが `/`、`/usr`、`/etc`、`/home` など、コンテナの動作に必要なパスと重なる。ホストと同じパスにマウントするので、イメージ側のファイルが隠れてしまうため。
- Docker の接続先が `unix://` のソケットでない。

## 汎用コンテナの構成

ランチャーが組み立てる `docker run` は次のとおりです。

| 項目 | 内容 |
|---|---|
| 実行ユーザー | ホストの UID/GID。Docker ソケットの所有グループを `--group-add` で追加 |
| ワークスペース | ホストと同じ絶対パスで bind mount し、作業ディレクトリにする |
| Docker ソケット | `docker context`(`DOCKER_HOST` を含む)が指すホストのソケットを、コンテナの `/var/run/docker.sock` に |
| Neovim の設定 | ホストの設定はマウントせず、イメージ同梱の `/etc/xdg/nvim/init.lua` を使う |
| 永続化 | named volume `nvim-dc-data` / `nvim-dc-state` / `nvim-dc-cache` |
| ソケット | named volume `nvim-dc-sockets` を `/run/nvim-dc` に。devcontainer の中の nvim サーバとの通信に使う |
| ホストエージェント | ランチャーが待ち受けるソケットのディレクトリ(`$XDG_RUNTIME_DIR/nvim-dc/<PID>`)を `/run/nvim-dc-host` に。プラグインが、ホストの環境変数の取得と `initializeCommand` の実行を依頼する。ソケットのパスは `NVIM_DC_HOST_SOCK` で渡す |
| 環境変数 | `TERM` / `COLORTERM` / `TERM_PROGRAM` をホストから引き継ぐ。イメージに端末定義がない `TERM` は `xterm-256color` に置き換える。プラグイン用に `NVIM_DC_WORKSPACE`(ワークスペース)と `NVIM_DC_IMAGE`(汎用イメージ)を渡す |

イメージは任意の UID で動くように、次のようにしています。

- HOME(`/home/nvim-dc`)と永続化先のディレクトリを 1777 で用意する。
- エントリポイント([image/entrypoint.sh](../image/entrypoint.sh))が、実行時の UID/GID を `/etc/passwd` と `/etc/group` に登録してから nvim を起動する。登録がないと、Node の `os.userInfo()` や ssh など、ユーザー情報を引くものが失敗するため。

本プラグインは、エントリポイントが `--cmd` で `/opt/nvim-dc/plugin/devcontainer.lua` を読み込みます。runtimepath に頼らないので、ユーザー設定のプラグインマネージャ(lazy.nvim など)が runtimepath をリセットしてもコマンドは消えません。

## 動作確認

ワークスペースに `devcontainer.json` を置いて汎用コンテナを起動し、`:DevcontainerConnect` を実行します。初回は devcontainer のイメージのビルドで時間がかかり、その間は画面下に `devcontainer up` のログが出ます。

- `:DevcontainerUp` は devcontainer を作成する(宣言されたプラグインの取得を含む)だけで、接続はしない。
- `customizations.neovim` の `plugins` には `owner/repo` か Git の URL を書き、`@v1.3` のようにタグ・ブランチ・コミットを付けて固定できる。
- `customizations.neovim` の `plugins` は、volume `nvim-dc-data-<ワークスペースのパスのハッシュ>` の `site/pack/devcontainer/start/` に入る。devcontainer の中では `/opt/nvim-dc-data` にある。取得のログも画面下に出る。
- `customizations.neovim` の `config` のディレクトリは、devcontainer の中の nvim の runtimepath に足され、その `init.lua` が起動時に実行される。`plugins` で入れたプラグインの設定をここに書く。
- devcontainer の中の `~/.local/share/nvim` は、同じ volume の `nvim/` へのシンボリックリンクになる。`config` の中で `vim.pack` などが入れたプラグインはここに残る。
- `plugins` や `config` を変えたら、devcontainer の中の nvim を `:qa` で終了してから `:DevcontainerConnect` し直す。動いているサーバには反映されない。
- サーバのログは、ソケットと同じ `/run/nvim-dc/<コンテナ ID の先頭12桁>.log` にある。
- 以前に別の方法(VS Code など)で作った devcontainer は、Neovim 用のマウントがないのでエラーになる。表示される `docker rm -f` でコンテナを削除してから実行し直す。
