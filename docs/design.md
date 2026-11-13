# 設計方針

このドキュメントは、本プロジェクトで何を作り、どういう構成にするかを決めたものです。設計時に未検証だった前提と、その検証結果は「[未検証の前提](#未検証の前提)」にまとめています。

## 目的

1. devcontainer の標準的な設定ファイル(`devcontainer.json`)に基づいて、Neovim から devcontainer を作成し、接続して編集できる。
2. devcontainer の中で動く Neovim のプラグインと設定を、`devcontainer.json` で宣言できる。

ホストに必要なのは Docker だけとします。ホストに Neovim や `devcontainer` CLI が入っていることは前提にしません。

## 全体像

本プロジェクトは次の3つで構成します。

| 要素 | 実体 | 役割 |
|---|---|---|
| ランチャー | Rust の単一バイナリ | `docker run` を組み立てて汎用コンテナを起動する。自分自身の更新も行う |
| 汎用 Neovim イメージ | Docker イメージ | UI 側の Neovim が動く場所。devcontainer の作成と管理もここから行う |
| プラグイン | Lua | devcontainer の作成・接続・プラグインの導入など、ロジックのすべて |

実行時のコンテナの関係は次のとおりです。

```
ホスト(Docker のみ)
 ├─ 汎用 Neovim コンテナ
 │    UI 側 nvim + 本プラグイン + devcontainer CLI + docker CLI
 │    /var/run/docker.sock をマウントし、devcontainer を兄弟コンテナとして作る
 │
 └─ devcontainer
      プロジェクトのツールチェーン + nvim サーバ(headless)
```

編集の実体は devcontainer の中の Neovim です。汎用コンテナの Neovim は、その画面を表示する UI として繋がります。LSP、フォーマッタ、ターミナルはすべて devcontainer のツールチェーンで動きます。

## 動作の流れ

1. ホストでランチャーを実行すると、汎用コンテナが起動して Neovim が開く。
2. ワークスペースに `devcontainer.json` がなければ、そのまま汎用コンテナの中で編集する。
3. あれば `:DevcontainerUp` で devcontainer を作成し、`:DevcontainerConnect` で UI をその中の nvim サーバに繋ぎ替える。

## ランチャー

### 役割

ランチャーは薄く保ちます。行うのは引数とパスの解決、`docker run` の組み立てと実行、ホストでしかできない処理の肩代わり(「[ホストで評価されるもの](#ホストで評価されるもの)」)、自己更新だけです。devcontainer に関する判断はすべてプラグイン側に置きます。

`docker run` で次を設定します。

- **ワークスペース**: ホストと同じ絶対パスでマウントする。devcontainer を作るのはホストの Docker デーモンなので、bind mount のパスがホスト基準で解釈されるためです。
- **Docker ソケット**: `/var/run/docker.sock` をマウントし、ソケットのグループを `--group-add` で付ける。
- **実行ユーザー**: ホストの UID/GID で動かす。ワークスペースに root 所有のファイルができるのを防ぐためです。
- **Neovim の設定**: ホストの `~/.config/nvim` はマウントしない。汎用コンテナではイメージ同梱の既定設定を使う。
- **永続化**: Neovim の data / state / cache を named volume に置く。

### ホストで評価されるもの

devcontainer.json には、ホストで評価される前提のものが2つあります。devcontainer CLI は汎用コンテナの中で動くので、何もしないと汎用コンテナで評価されてしまいます。

| | 何もしないと | 必要なもの |
|---|---|---|
| `${localEnv:...}` | 汎用コンテナの環境変数で展開される(`HOME` が `/home/nvim-dc` になるなど) | ホストの環境変数の値 |
| `initializeCommand` | 汎用コンテナの中で実行され、ホストのファイルに作用しない | ホストの上で実行すること |

ホストのディレクトリを汎用コンテナにマウントして合わせる方法は採りません。HOME をマウントしても、HOME の外を指す設定(`${localEnv:SSH_AUTH_SOCK}` など)で同じ問題が残るためです。代わりに、ホストで動いている唯一のプロセスであるランチャーが肩代わりします。

- **ホストエージェント**: ランチャーは汎用コンテナが動いているあいだホストに残り、Unix ソケットで依頼を受ける。依頼は「ホストの環境変数を返す」と「ホストでコマンドを実行する」の2つ。ソケットは所有者しか入れないディレクトリ(`$XDG_RUNTIME_DIR/nvim-dc/<PID>`)に置き、汎用コンテナにだけマウントする。
- **変数の展開**: プラグインは、ホストの環境変数を見せて devcontainer CLI を実行する。展開されたパスを解釈するのはホストの Docker デーモンなので、そのパスを汎用コンテナにマウントする必要はない。`PATH` や `DOCKER_HOST` など、CLI 自身の動作に関わるものだけは汎用コンテナの値を使う。
- **initializeCommand**: プラグインが `devcontainer read-configuration` で取り出し、ホストエージェントに実行させる。CLI にはこれを飛ばすオプションがないので、`initializeCommand` を除いた設定を `--override-config` で渡して二重に実行されないようにする。パスの解決やコンテナのラベルには元の設定ファイルが使われる。

汎用コンテナは Docker ソケットを持っていてホストの root 相当なので、ホストでコマンドを実行できるようにしても、新たに渡す権限はありません。

残る制限は次のとおりです。

- CLI 自身がワークスペースの外のファイルを読む設定(ワークスペースより上を指すビルドコンテキストなど)には対応しない。
- オブジェクト形式の `initializeCommand` は、仕様では並列に実行するが、名前の順に1つずつ実行する。

### 実装

- **言語**: Rust。
- **配布形態**: musl で静的リンクした単一バイナリ。対象は linux の x86_64 と aarch64。
- **Docker の操作**: `docker` CLI を子プロセスとして起動し、端末をそのまま引き継がせる。Docker API を直接叩くクレートは使わない。対話 TTY の接続を自前で実装せずに済むためです。ホストエージェントを動かし続けるため、`exec` で自分を置き換えることはしない。
- **設定ファイル**: 追加のマウントやイメージの差し替えを TOML で指定できるようにする。

### コマンド

コマンド名 `nvim-dc` は仮称です。

```
nvim-dc [path]     # 汎用コンテナを起動して nvim を開く
nvim-dc update     # ランチャー自身を最新版に更新する
nvim-dc pull       # 汎用イメージを取得し直す
```

### 自己更新

GitHub Releases から最新版を取得して、実行ファイルを置き換えます。実装には [self_update](https://github.com/jaemk/self_update) クレートを使います。

```toml
self_update = { version = "1.3", default-features = false, features = [
  "github", "ureq", "rustls", "checksums", "archive-tar", "compression-tar-gz",
] }
```

- **チェックサム検証**: `checksums` フィーチャーで、GitHub がリリースアセットごとに公開している SHA-256 ダイジェストと照合する。
- **HTTP と TLS**: `ureq` と `rustls` を使う。OpenSSL に依存しないので musl ビルドと相性がよい。
- **アセットの命名**: `<名前>-<バージョン>-<ターゲット>.<拡張子>` の規約でリリースする。クレートが実行中のターゲットに合うものを選ぶ。
- **更新は明示実行のみ**: 起動のたびに更新を確認することはしない。起動が遅くなり、オフラインで引っかかるためです。
- **リポジトリは公開前提**: 非公開にする場合は Releases の取得にトークンが必要になる。

チェックサムはダウンロードの破損を検出するもので、リリース自体が差し替えられた場合は防げません。必要になったら同じクレートの `signatures` フィーチャー(zipsign による署名検証)を追加します。

検討して採らなかったクレートは次の2つです。

- **axoupdater**: cargo-dist のインストーラが書き出すインストールレシートを前提に動くため、バイナリを置くだけの配布と噛み合わない。
- **self-replace**: 置き換え処理だけの部品で、`self_update` が内部で使っている。直接使う理由がない。

## 汎用 Neovim イメージ

次のものを入れます。

- Neovim 0.12 以上(理由は「[接続](#接続)」を参照)
- 公式の `devcontainer` CLI(`@devcontainers/cli`)と、その実行に必要な Node.js
- docker CLI(compose、buildx を含む)
- git
- 本プラグイン

Docker ソケットをマウントするので、このコンテナの中で動くものはホストの Docker を操作できます。これはホストの root 相当の権限です。個人の開発環境での利用を前提にした割り切りです。

## プラグイン

### コマンド

| コマンド | 動作 |
|---|---|
| `:DevcontainerUp` | `devcontainer.json` から devcontainer を作成する |
| `:DevcontainerConnect` | UI を devcontainer の中の nvim サーバに繋ぎ替える |
| `:DevcontainerRebuild` | devcontainer を作り直す |
| `:DevcontainerDown` | devcontainer を停止する |

### devcontainer の作成

`devcontainer.json` の解釈は公式の `devcontainer` CLI に任せ、プラグインは `devcontainer up` / `exec` を呼びます。Features、Docker Compose、ライフサイクルフックを自前で実装しないためです。

プロジェクトの `devcontainer.json` は書き換えません。Neovim のために必要なマウントなどは、`devcontainer up` の `--mount` や `--additional-features` で外から注入します。VS Code の利用者と同じ設定ファイルをそのまま共有できます。

### devcontainer への Neovim の導入

汎用コンテナと同じ Neovim のビルドを named volume に置き、devcontainer にマウントします。

- UI 側とサーバ側のバージョンが必ず一致する。
- devcontainer のイメージを作り直す必要がない。

volume はバージョンごとに `nvim-dc-nvim-<バージョン>` の名前で作ります。空の named volume を汎用イメージの `/opt/nvim` にマウントするとイメージ側の内容がコピーされるので、その仕組みで中身を入れます。devcontainer CLI の `--mount` は読み取り専用を指定できないので、マウントは読み書き可能になります。

devcontainer CLI は、ワークスペースのパスから既存のコンテナを探して使い回します。VS Code などで作ったコンテナには Neovim 用のマウント(Neovim 本体、ソケット、プラグインの置き場所)がないので、その場合はコンテナの削除を促すエラーにします。

Neovim の公式ビルドは glibc を前提にしているので、Alpine など musl 系のイメージではこの方法が使えません。その場合は `--additional-features` で Neovim を入れる Feature を注入する方式に切り替えます。

### 接続

devcontainer の中で `nvim --headless --listen <socket>` を起動し、汎用コンテナの Neovim を UI として繋ぎます。

- **経路**: 汎用コンテナと devcontainer の両方に同じ named volume をマウントし、その上の Unix ソケットで繋ぐ。
- **繋ぎ替え**: 起動中の Neovim から、その場で接続先を切り替える `:connect` を使う。これが Neovim 0.12 以上を必須にする理由です。

`:DevcontainerConnect` の流れは次のとおりです。

1. `devcontainer up` で devcontainer を用意する(起動済みならそれを使う)。
2. ソケット `/run/nvim-dc/<コンテナ ID の先頭12桁>.sock` の先でサーバが応答しなければ、`devcontainer exec` でサーバをバックグラウンドで起動する。`devcontainer exec` を使うのは、`remoteUser` や `remoteEnv`、`userEnvProbe` で決まる環境(PATH など)をサーバに引き継ぐためです。
3. `:connect!` で UI を繋ぎ替え、汎用コンテナ側の nvim は止める。未保存の変更があるときは繋ぎ替えない。

サーバは UI から独立して動くので、`:detach` で UI を外しても編集の状態が残り、次の `:DevcontainerConnect` でそのまま繋ぎ直せます。`:qa` するとサーバも終了します。

サーバを起動するときは、次の2点に注意しています。

- **umask**: `docker exec` で起動したプロセスは umask が 0000 になる(`docker run` では 0022)。そのままだと保存したファイルが誰でも書き込める権限になるので、`docker run` の既定と同じ 0022 に揃える。
- **ソケットの権限**: devcontainer 側のユーザーは汎用コンテナの UID と違うことがある(`remoteUser` が root の場合など)。ソケットは 666 にして、どの UID からも接続できるようにする。

ホスト側の Neovim で編集し、LSP だけを `docker exec` でコンテナ内で動かす方式は採りません。パスの変換などプラグインごとの対応が必要になり、破綻しやすいためです。

### プラグインと設定

devcontainer の中の Neovim で使うプラグインと設定は、`devcontainer.json` の `customizations.neovim` に宣言します。`customizations` は仕様が定めるツール別の拡張ポイントで、`customizations.vscode.extensions` と同じ位置づけです。

```jsonc
"customizations": {
  "neovim": {
    "plugins": ["neovim/nvim-lspconfig", "tpope/vim-commentary@v1.3"],
    "config": ".devcontainer/nvim"
  }
}
```

VS Code の `extensions` と `settings` にならって、役割を2つに分けます。

- `plugins`: 何を入れるか。`owner/repo`(GitHub のリポジトリ)か Git の URL を並べる。末尾に `@v1.3` のように付けると、そのタグ・ブランチ・コミットに固定する(VS Code の `publisher.extension@1.2.3` と同じ書き方)。
- `config`: 入れたプラグインの設定(`setup()` の呼び出しやキーマップなど)。Neovim の設定ディレクトリと同じ構成のディレクトリを、ワークスペースからの相対パスで指定する。

プラグインの宣言を `devcontainer.json` に置くのは、次の理由からです。

- `devcontainer.json` を見れば、何が入るかが分かる。
- 取得が `devcontainer up` の一部として、接続の前に終わる。
- 取得は汎用イメージ側で行うので、devcontainer に git が要らない。
- 宣言と実体が一致する(宣言から消せば削除される)。

VS Code の拡張機能と違い、Neovim のプラグインの多くは設定のコードを書かないと動かず、JSON では書けません。それを `config` が受け持ちます。

`plugins` に書けるのは、取得元とバージョンまでにします。遅延読み込みやビルド手順、依存関係の解決まで扱うと、既存のプラグインマネージャの再発明になるためです。それらが必要なときは、`config` の中でプラグインマネージャ(Neovim 標準の `vim.pack` や lazy.nvim など)を使えます。`config` はただの Lua なので止めませんが、これは逃げ道で、基本の置き場所は `plugins` です。

```
.devcontainer/nvim/
  init.lua        起動時に実行される
  lua/            require できる
  plugin/, ftplugin/, after/ など   通常の設定と同じ規則で読まれる
```

ホストや汎用コンテナの Neovim の設定(ローカルの設定)は、devcontainer には持ち込みません。当初はローカルの設定と devcontainer 側の宣言をマージする予定でしたが、ランチャーがホストの設定をマウントしないことにしたのに合わせて、いったんやめています。今後どうするかは決めていません。持ち込む場合は、同じプラグインが両方にあるときの優先順位と、設定を読む順序を決める必要があります。

devcontainer の中にそのユーザーの設定(`~/.config/nvim`)があれば、Neovim が通常どおり読み込みます。順序は `config` のディレクトリが先、ユーザーの設定があとです。

#### `config` の読み込み

サーバを起動するときに、`--cmd` で次のことをします。

- `config` のディレクトリを `runtimepath` の先頭に、その `after/` を末尾に足す。
- `init.lua` があれば実行する。

`--cmd` は Neovim が設定を読む前に実行されるので、`init.lua` が先、`plugin/` があとという、通常の設定と同じ順序になります。`plugins` で宣言したプラグインは、`init.lua` の時点で `require` できます。

Neovim から見た設定ディレクトリ(`stdpath('config')`)は、devcontainer のユーザーの `~/.config/nvim` のままです。環境変数(`XDG_CONFIG_HOME`)で `config` のディレクトリに向けることもできますが、nvim から起動するコマンド(git など)の設定の場所まで変わるので採りません。このため、`config` の中で `vim.pack` を使うと、ロックファイル(`nvim-pack-lock.json`)は `~/.config/nvim` に作られ、リポジトリには入らず、コンテナを作り直すと消えます。devcontainer に git も必要です。これも、プラグインの宣言を `plugins` に置く理由の1つです。

#### `plugins` の取得

`plugins` のプラグインは、devcontainer 内の専用ディレクトリ `pack/devcontainer/start/` にインストールします。Neovim 標準のパッケージ機構を使うので、`config` やユーザーの設定がどのプラグインマネージャを使っていても動きます。

- **置き場所**: volume `nvim-dc-data-<ワークスペースのパスのハッシュ>` を devcontainer の `/opt/nvim-dc-data` にマウントし、その下の `site/pack/devcontainer/start/` に置く。マウントはコンテナを作るときに決めるので、名前はコンテナ ID ではなくワークスペースのパスから決める。
- **取得**: `devcontainer up` のあと、汎用イメージのコンテナにこの volume をマウントして `git clone` する。devcontainer に git があるとは限らないためです。取得したファイルを devcontainer のユーザーが書き換えられるように、そのユーザーの UID/GID で実行する。
- **宣言との一致**: まだないものと、取得元かバージョンの指定が変わったものを取得し、宣言から消えたプラグインは削除する。何から取得したかは、プラグインのディレクトリの中の `.nvim-dc-source` に記録する。取得に失敗したときは、いままでのものを残す。
- **バージョン**: 指定がなければ、取得した時点の既定ブランチの先頭になり、その後は更新しない。更新の手段は `:DevcontainerRebuild`(ステップ4)で用意する。
- **読み込み**: サーバを起動するときに `site` を `packpath` の先頭に足す。

#### data ディレクトリの永続化

Neovim の data ディレクトリ(`stdpath('data')`)は、同じ volume の `/opt/nvim-dc-data/nvim` に載せます。treesitter のパーサや mason が入れるバイナリ、`config` の中でプラグインマネージャを使った場合のプラグインを、コンテナを作り直しても残すためです。これらは libc や CPU アーキテクチャが違うと動かないので、ホストや汎用コンテナとは共有せず、devcontainer ごとの volume に置きます。

サーバを起動するときに、data ディレクトリ(`~/.local/share/nvim`)を volume へのシンボリックリンクにします。環境変数(`XDG_DATA_HOME`)で場所を変えると nvim から起動するコマンドにも影響するので、リンクにします。すでに data ディレクトリがあるイメージや、HOME に書き込めないユーザーでは何もしません(永続化されないだけで、動作は変わらない)。

`plugins` や `config` の変更は、動いているサーバには反映されません。サーバを起動し直します(`:qa` してから `:DevcontainerConnect`)。

## リリース

1つのタグで、ランチャーとイメージを同じバージョンで公開します。

- GitHub Actions で、タグを打つとランチャーのバイナリを GitHub Releases に、汎用イメージを ghcr.io に公開する。
- ランチャーは、自分と同じバージョンのイメージを使う。`update` でランチャーを更新すると、次回の起動時に対応するイメージが取得される。
- タグと `launcher/Cargo.toml` のバージョンが一致しないときは公開しない。ランチャーが存在しないイメージを探すことになるため。
- イメージは main への push でも `main` と `sha-<コミット>` のタグで公開する。開発中の最新版を試すためのもので、ランチャーの既定には影響しない。設定ファイルの `image` で指定すれば使える。

イメージの公開は [.github/workflows/image.yml](../.github/workflows/image.yml) で行う(ランチャーの公開はステップ5で追加する)。

## リポジトリ構成

```
launcher/   ランチャー(Rust クレート)
image/      汎用 Neovim イメージの Dockerfile
plugin/     プラグインのコマンド定義
lua/        プラグイン本体
docs/       ドキュメント
.github/    リリース用ワークフロー
```

## 未検証の前提

設計時に未検証だった次の2点は、実装の最初(ステップ1)に Neovim 0.12.6 と Docker 29.9 で確かめ、どちらも成り立ちました。

1. **Neovim 0.12 の `:connect`**: 起動中の Neovim から UI を別のサーバに繋ぎ替えられること。
   - **結果**: 成り立つ。汎用イメージのコンテナで TUI を起動して `:connect <socket>` を実行すると、別コンテナの headless サーバに UI が1つ繋がり、以後の入力はサーバ側で実行された。`:detach` すると UI 側は終了し、サーバは動き続けた。
   - 使えなかった場合の代案は、ランチャーが `nvim --server <socket> --remote-ui` を起動し直す方式だった。
2. **named volume 上の Unix ソケット**: 2つのコンテナが同じ volume 上のソケットで通信できること。
   - **結果**: 成り立つ。一方のコンテナで `nvim --headless --listen` したソケットに、もう一方から `--remote-expr` で問い合わせて応答が返った。
   - **注意**: 新規の named volume は root 所有になるので、root 以外で動くサーバはソケットを作れずに終了した。ソケット用の volume は、サーバ側のユーザーが書き込めるように権限を整えておく必要がある。ステップ2で、イメージ側のマウント先 `/run/nvim-dc` を 1777 で用意し、volume が初回マウント時にその権限を引き継ぐようにした。
   - 通らなかった場合の代案は、`docker exec -i` を経由した中継だった。

`self_update` のフィーチャー指定は、名前は README と `Cargo.toml` で確認しましたが、ビルドは試していません(ステップ5で確かめる)。

## 実装の順序

1. **検証用の最小構成**: イメージと、`docker run` を組み立てるだけのランチャーを作り、上の未検証の前提2点を確かめる。
2. **Up / Connect**: `devcontainer.json` から devcontainer を作成して接続するまで。
3. **プラグインと設定**: `customizations.neovim` の読み取りと適用。
4. **Rebuild / Down と仕上げ**: musl 系イメージ向けの Feature への切り替えを含む。
5. **自己更新とリリース**: `update` サブコマンドと、リリース用のワークフロー。

開発中は、リポジトリを汎用コンテナにマウントしてプラグインを読み込ませます(手順は [development.md](development.md))。
