//! ランチャーの設定ファイル(TOML)。
//!
//! 置き場所は `$XDG_CONFIG_HOME/nvim-dc/config.toml`(未設定なら `~/.config/nvim-dc/config.toml`)。
//! ファイルがなければすべて既定値で動く。

use std::path::{Path, PathBuf};

use serde::Deserialize;

#[derive(Debug, Default, Deserialize, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    /// 汎用イメージの差し替え。開発中にローカルでビルドしたイメージを使うときなど。
    pub image: Option<String>,
    /// 追加のマウント。`docker run --mount` の値をそのまま書く。
    pub mounts: Vec<String>,
}

impl Config {
    pub fn load(path: &Path) -> Result<Self, String> {
        match std::fs::read_to_string(path) {
            Ok(text) => Self::parse(&text).map_err(|e| format!("{}: {e}", path.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }

    fn parse(text: &str) -> Result<Self, toml::de::Error> {
        toml::from_str(text)
    }
}

/// 設定ファイルのパス。`XDG_CONFIG_HOME` と `HOME` の値を受け取る。
pub fn config_path(xdg_config_home: Option<&str>, home: &Path) -> PathBuf {
    config_home(xdg_config_home, home).join("nvim-dc/config.toml")
}

/// XDG の config ディレクトリ。空文字や相対パスは仕様どおり無視する。
pub fn config_home(xdg_config_home: Option<&str>, home: &Path) -> PathBuf {
    match xdg_config_home {
        Some(dir) if Path::new(dir).is_absolute() => PathBuf::from(dir),
        _ => home.join(".config"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_full_config() {
        let config = Config::parse(
            r#"
            image = "nvim-dc:dev"
            mounts = ["type=bind,source=/a,target=/b,readonly"]
            "#,
        )
        .unwrap();
        assert_eq!(
            config,
            Config {
                image: Some("nvim-dc:dev".into()),
                mounts: vec!["type=bind,source=/a,target=/b,readonly".into()],
            }
        );
    }

    #[test]
    fn empty_config_is_default() {
        assert_eq!(Config::parse("").unwrap(), Config::default());
    }

    #[test]
    fn rejects_unknown_keys() {
        assert!(Config::parse("imgae = \"typo\"").is_err());
    }

    #[test]
    fn missing_file_is_default() {
        let config = Config::load(Path::new("/nonexistent/nvim-dc/config.toml")).unwrap();
        assert_eq!(config, Config::default());
    }

    #[test]
    fn config_path_respects_xdg() {
        let home = Path::new("/home/me");
        assert_eq!(
            config_path(Some("/xdg"), home),
            PathBuf::from("/xdg/nvim-dc/config.toml")
        );
        assert_eq!(
            config_path(None, home),
            PathBuf::from("/home/me/.config/nvim-dc/config.toml")
        );
        assert_eq!(
            config_path(Some("relative"), home),
            PathBuf::from("/home/me/.config/nvim-dc/config.toml")
        );
    }
}
