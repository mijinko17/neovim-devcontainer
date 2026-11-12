# 開発手順

開発用の devcontainer(`.devcontainer/`)の中で作業する前提です。Docker は docker-in-docker なので、ここで作ったコンテナはホストの Docker を汚しません。

## 汎用イメージのビルド

```sh
docker build -t nvim-dc:dev image/
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
| Neovim の設定 | ホストの `~/.config/nvim` があれば `/home/nvim-dc/.config/nvim` に読み取り専用で。シンボリックリンクは実体を辿る。なければイメージ同梱の `/etc/xdg/nvim/init.lua` |
| 永続化 | named volume `nvim-dc-data` / `nvim-dc-state` / `nvim-dc-cache` |
| 環境変数 | `TERM` / `COLORTERM` / `TERM_PROGRAM` をホストから引き継ぐ。イメージに端末定義がない `TERM` は `xterm-256color` に置き換える |

イメージは任意の UID で動くように、次のようにしています。

- HOME(`/home/nvim-dc`)と永続化先のディレクトリを 1777 で用意する。
- エントリポイント([image/entrypoint.sh](../image/entrypoint.sh))が、実行時の UID/GID を `/etc/passwd` と `/etc/group` に登録してから nvim を起動する。登録がないと、Node の `os.userInfo()` や ssh など、ユーザー情報を引くものが失敗するため。
