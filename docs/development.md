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

- `:DevcontainerUp` は devcontainer を作成するだけで、接続はしない。
- サーバのログは、ソケットと同じ `/run/nvim-dc/<コンテナ ID の先頭12桁>.log` にある。
- 以前に別の方法(VS Code など)で作った devcontainer は、Neovim 用のマウントがないのでエラーになる。表示される `docker rm -f` でコンテナを削除してから実行し直す。
