//! ランチャー自身の更新(`nvim-dc update`)。
//!
//! GitHub Releases の最新版が自分より新しければ、実行ファイルを置き換える。
//! リリースのアセットは `nvim-dc-<バージョン>-<ターゲット>.tar.gz` で、アーカイブの直下に
//! `nvim-dc` が入っている(.github/workflows/release.yml)。ダウンロードしたアーカイブは、
//! GitHub がアセットごとに公開している SHA-256 ダイジェストと照合される(`checksums`
//! フィーチャーの既定の動作)。

use self_update::backends::github::Update;
use self_update::{UpdateStrategy, VersionStatus};

const REPO_OWNER: &str = "mijinko17";
const REPO_NAME: &str = "neovim-devcontainer";
const BIN_NAME: &str = env!("CARGO_PKG_NAME");
const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

/// 最新版に更新し、結果を伝えるメッセージを返す。
pub fn update() -> Result<String, String> {
    let status = Update::configure()
        .repo_owner(REPO_OWNER)
        .repo_name(REPO_NAME)
        .bin_name(BIN_NAME)
        .current_version(CURRENT_VERSION)
        // 既定の戦略は semver 互換の範囲を優先するので、0.1.0 から見て 0.1.1 と 0.2.0 が
        // あると 0.1.1 で止まる。常にいちばん新しいリリースへ更新する。
        .update_strategy(UpdateStrategy::Latest)
        // 置き場所に書き込めないときは、ダウンロードする前に失敗させる。
        .check_install_path_writable(true)
        // クレートの出力は英語で、確認のプロンプトも出る。明示的に実行されたコマンドなので
        // 確認はせず、結果だけを自分で表示する。
        .show_output(false)
        .no_confirm(true)
        .build()
        .and_then(|update| update.update())
        .map_err(|e| format!("更新に失敗しました: {e}"))?;
    Ok(message(&status))
}

fn message(status: &VersionStatus) -> String {
    let version = status.version();
    if status.is_updated() {
        // イメージはランチャーと同じバージョンのものを使うので、次回の起動時に取得される。
        format!(
            "{CURRENT_VERSION} から {version} に更新しました。対応するイメージは次回の起動時に取得されます"
        )
    } else {
        format!("すでに最新版です({version})")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_tells_what_happened() {
        assert_eq!(
            message(&VersionStatus::UpToDate("0.1.0".into())),
            "すでに最新版です(0.1.0)"
        );
        let updated = message(&VersionStatus::Updated("9.9.9".into()));
        assert!(updated.contains(CURRENT_VERSION) && updated.contains("9.9.9"));
    }
}
