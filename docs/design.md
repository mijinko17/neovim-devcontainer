# 設計方針

このドキュメントは、本プロジェクトで何を作り、どういう構成にするかを決めたものです。設計時に未検証だった前提と、その検証結果は「[未検証の前提](#未検証の前提)」にまとめています。

## 目的

1. devcontainer の標準的な設定ファイル(`devcontainer.json`)に基づいて、Neovim から devcontainer を作成し、接続して編集できる。
2. devcontainer の中で動く Neovim のプラグインを、ローカルのものと devcontainer 側で指定したものをマージして決められる。

ホストに必要なのは Docker だけとします。ホストに Neovim や `devcontainer` CLI が入っていることは前提にしません。

## 全体像

本プロジェクトは次の3つで構成します。

| 要素 | 実体 | 役割 |
|---|---|---|
| ランチャー | Rust の単一バイナリ | `docker run` を組み立てて汎用コンテナを起動する。自分自身の更新も行う |
| 汎用 Neovim イメージ | Docker イメージ | UI 側の Neovim が動く場所。devcontainer の作成と管理もここから行う |
| プラグイン | Lua | devcontainer の作成・接続・プラグインのマージなど、ロジックのすべて |

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

ランチャーは薄く保ちます。行うのは引数とパスの解決、`docker run` の組み立てと実行、自己更新だけです。devcontainer に関する判断はすべてプラグイン側に置きます。

`docker run` で次を設定します。

- **ワークスペース**: ホストと同じ絶対パスでマウントする。devcontainer を作るのはホストの Docker デーモンなので、bind mount のパスがホスト基準で解釈されるためです。
- **Docker ソケット**: `/var/run/docker.sock` をマウントし、ソケットのグループを `--group-add` で付ける。
- **実行ユーザー**: ホストの UID/GID で動かす。ワークスペースに root 所有のファイルができるのを防ぐためです。
- **Neovim の設定**: ホストに `~/.config/nvim` があれば読み取り専用でマウントする。なければイメージ同梱の既定設定を使う。
- **永続化**: Neovim の data / state / cache を named volume に置く。

### 実装

- **言語**: Rust。
- **配布形態**: musl で静的リンクした単一バイナリ。対象は linux の x86_64 と aarch64。
- **Docker の操作**: `docker` CLI を `exec` で呼ぶ。Docker API を直接叩くクレートは使わない。対話 TTY の接続を自前で実装せずに済むためです。
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

devcontainer CLI は、ワークスペースのパスから既存のコンテナを探して使い回します。VS Code などで作ったコンテナにはこのマウントがないので、その場合はコンテナの削除を促すエラーにします。

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

### プラグインのマージ

マージするのはプラグインの「宣言」です。インストールされた実体はホストや汎用コンテナと共有しません。

**ローカル側**は、汎用コンテナが持つ Neovim の設定(ホストの `~/.config/nvim` をマウントしたもの)です。devcontainer にも読み取り専用でマウントし、そのまま読み込みます。

**devcontainer 側**は、`devcontainer.json` の `customizations.neovim` に宣言します。`customizations` は仕様が定めるツール別の拡張ポイントで、`customizations.vscode.extensions` と同じ位置づけです。

```jsonc
"customizations": {
  "neovim": {
    "plugins": ["rust-lang/rust.vim"],
    "lua": ".devcontainer/nvim.lua"
  }
}
```

マージの規則は次のとおりです。

- devcontainer 側のプラグインは、devcontainer 内の専用ディレクトリ `pack/devcontainer/start/` にインストールする。Neovim 標準のパッケージ機構を使うので、ローカル側のプラグインマネージャが何であっても動く。
- 同じプラグインが両方にある場合はローカル側を優先し、devcontainer 側はスキップする。
- 設定はローカルの `init.lua`、devcontainer 側の `lua` の順に読む。後に読む devcontainer 側が上書きする。

プラグインの実体は、devcontainer ごとの named volume に置いたデータディレクトリにインストールします。treesitter のパーサや mason が入れるバイナリは、libc や CPU アーキテクチャが違うと動かないためです。初回の起動は遅くなりますが、volume に残るので2回目以降は再インストールしません。

## リリース

1つのタグで、ランチャーとイメージを同じバージョンで公開します。

- GitHub Actions で、タグを打つとランチャーのバイナリを GitHub Releases に、汎用イメージを ghcr.io に公開する。
- ランチャーは、自分と同じバージョンのイメージを使う。`update` でランチャーを更新すると、次回の起動時に対応するイメージが取得される。

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
3. **プラグインのマージ**: `customizations.neovim` の読み取りと適用。
4. **Rebuild / Down と仕上げ**: musl 系イメージ向けの Feature への切り替えを含む。
5. **自己更新とリリース**: `update` サブコマンドと、リリース用のワークフロー。

開発中は、リポジトリを汎用コンテナにマウントしてプラグインを読み込ませます(手順は [development.md](development.md))。
