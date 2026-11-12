//! `docker run` の引数の組み立て。
//!
//! 環境(ファイルシステムや UID)には触れず、[`RunSpec`] から引数列を作るだけにする。

use std::path::{Path, PathBuf};

/// 汎用コンテナの中の HOME。イメージ側で用意してある。
pub const CONTAINER_HOME: &str = "/home/nvim-dc";
/// コンテナ内の Docker ソケットの位置。
pub const CONTAINER_DOCKER_SOCK: &str = "/var/run/docker.sock";

/// Neovim の data / state / cache を置く named volume と、そのマウント先(HOME からの相対)。
pub const PERSISTENT_VOLUMES: [(&str, &str); 3] = [
    ("nvim-dc-data", ".local/share/nvim"),
    ("nvim-dc-state", ".local/state/nvim"),
    ("nvim-dc-cache", ".cache/nvim"),
];

#[derive(Debug, Clone)]
pub struct RunSpec {
    pub image: String,
    /// ホストと同じ絶対パスでマウントするワークスペース。
    pub workspace: PathBuf,
    /// nvim に渡して開くファイル。ディレクトリを指定されたときは `None`。
    pub open_file: Option<PathBuf>,
    pub uid: u32,
    pub gid: u32,
    /// ホスト側の Docker ソケット。
    pub docker_sock: PathBuf,
    /// Docker ソケットの所有グループ。コンテナ内のユーザーに `--group-add` で付ける。
    pub docker_gid: u32,
    /// ホストの Neovim 設定ディレクトリ。なければイメージ同梱の既定設定を使う。
    pub nvim_config: Option<PathBuf>,
    /// 設定ファイルで指定された追加のマウント(`--mount` の値)。
    pub extra_mounts: Vec<String>,
    /// コンテナに引き継ぐ端末関連の環境変数。
    pub env: Vec<(String, String)>,
}

/// 端末の表示に関わるため、ホストから引き継ぐ環境変数。
pub const PASSTHROUGH_ENV: [&str; 3] = ["TERM", "COLORTERM", "TERM_PROGRAM"];

/// コンテナの動作に必要で、ワークスペースのマウントで隠してはいけないパス。
///
/// ワークスペースはホストと同じパスにマウントするので、これらと重なる
/// (どちらかがもう一方の祖先か同一である)パスはワークスペースにできない。
/// たとえば `/usr/local/bin` をワークスペースにすると ENTRYPOINT の nvim が隠れ、
/// `/home` にすると HOME と永続化先が隠れる。
const PROTECTED_PATHS: [&str; 13] = [
    "/bin",
    "/sbin",
    "/lib",
    "/lib64",
    "/usr",
    "/etc",
    "/opt/nvim",
    "/run",
    "/var/run",
    "/proc",
    "/sys",
    "/dev",
    CONTAINER_HOME,
];

/// ワークスペースとしてマウントしてよいパスかを確かめる。
pub fn check_workspace(workspace: &Path) -> Result<(), String> {
    for protected in PROTECTED_PATHS.map(Path::new) {
        if workspace.starts_with(protected) || protected.starts_with(workspace) {
            return Err(format!(
                "{} はワークスペースにできません(コンテナ内の {} と重なります)",
                workspace.display(),
                protected.display()
            ));
        }
    }
    Ok(())
}

impl RunSpec {
    /// `docker` に渡す引数列(先頭の `docker` は含まない)。
    pub fn to_args(&self) -> Vec<String> {
        let mut args: Vec<String> =
            vec!["run".into(), "--rm".into(), "--init".into(), "-it".into()];

        // ホストの UID/GID で動かし、ワークスペースに root 所有のファイルを作らない。
        args.push("--user".into());
        args.push(format!("{}:{}", self.uid, self.gid));
        args.push("--group-add".into());
        args.push(self.docker_gid.to_string());

        // devcontainer を作るのはホストの Docker デーモンなので、bind mount のパスは
        // ホスト基準で解釈される。ワークスペースは同じ絶対パスでマウントする。
        args.push("--mount".into());
        args.push(bind_mount(&self.workspace, &self.workspace, false));
        args.push("--workdir".into());
        args.push(self.workspace.display().to_string());

        args.push("--mount".into());
        args.push(bind_mount(
            &self.docker_sock,
            Path::new(CONTAINER_DOCKER_SOCK),
            false,
        ));

        if let Some(config) = &self.nvim_config {
            args.push("--mount".into());
            args.push(bind_mount(
                config,
                &Path::new(CONTAINER_HOME).join(".config/nvim"),
                true,
            ));
        }

        for (volume, rel) in PERSISTENT_VOLUMES {
            args.push("--mount".into());
            args.push(format!(
                "type=volume,source={volume},target={CONTAINER_HOME}/{rel}"
            ));
        }

        for mount in &self.extra_mounts {
            args.push("--mount".into());
            args.push(mount.clone());
        }

        for (key, value) in &self.env {
            args.push("--env".into());
            args.push(format!("{key}={value}"));
        }

        args.push(self.image.clone());

        // イメージの ENTRYPOINT は nvim。ここから先は nvim の引数になる。
        if let Some(file) = &self.open_file {
            args.push("--".into());
            args.push(file.display().to_string());
        }
        args
    }
}

/// `--mount type=bind,...` の値を作る。
fn bind_mount(source: &Path, target: &Path, readonly: bool) -> String {
    let mut fields = vec![
        "type=bind".to_string(),
        csv_field(&format!("source={}", source.display())),
        csv_field(&format!("target={}", target.display())),
    ];
    if readonly {
        fields.push("readonly".into());
    }
    fields.join(",")
}

/// `--mount` の値は CSV として解釈されるので、カンマや引用符を含むフィールドはクォートする。
fn csv_field(field: &str) -> String {
    if field.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", field.replace('"', "\"\""))
    } else {
        field.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec() -> RunSpec {
        RunSpec {
            image: "nvim-dc:dev".into(),
            workspace: "/home/me/project".into(),
            open_file: None,
            uid: 1000,
            gid: 1001,
            docker_sock: "/var/run/docker.sock".into(),
            docker_gid: 998,
            nvim_config: None,
            extra_mounts: vec![],
            env: vec![],
        }
    }

    /// `flag` の直後に `value` が続いていることを確かめる。
    fn has_pair(args: &[String], flag: &str, value: &str) -> bool {
        args.windows(2).any(|w| w[0] == flag && w[1] == value)
    }

    #[test]
    fn minimal_run() {
        let args = spec().to_args();
        assert_eq!(&args[..4], ["run", "--rm", "--init", "-it"]);
        assert!(has_pair(&args, "--user", "1000:1001"));
        assert!(has_pair(&args, "--group-add", "998"));
        assert!(has_pair(
            &args,
            "--mount",
            "type=bind,source=/home/me/project,target=/home/me/project"
        ));
        assert!(has_pair(&args, "--workdir", "/home/me/project"));
        assert!(has_pair(
            &args,
            "--mount",
            "type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock"
        ));
        assert!(has_pair(
            &args,
            "--mount",
            "type=volume,source=nvim-dc-data,target=/home/nvim-dc/.local/share/nvim"
        ));
        assert!(has_pair(
            &args,
            "--mount",
            "type=volume,source=nvim-dc-state,target=/home/nvim-dc/.local/state/nvim"
        ));
        assert!(has_pair(
            &args,
            "--mount",
            "type=volume,source=nvim-dc-cache,target=/home/nvim-dc/.cache/nvim"
        ));
        assert_eq!(args.last().unwrap(), "nvim-dc:dev");
        assert!(!args.iter().any(|a| a.contains(".config/nvim")));
    }

    #[test]
    fn rejects_workspaces_overlapping_container_paths() {
        for path in [
            "/",
            "/usr",
            "/usr/local/bin",
            "/etc",
            "/opt",
            "/opt/nvim/share",
            "/home",
            "/home/nvim-dc",
            "/home/nvim-dc/work",
            "/var",
            "/var/run",
            "/run/user/1000",
        ] {
            assert!(
                check_workspace(Path::new(path)).is_err(),
                "{path} は拒否されるべき"
            );
        }
    }

    #[test]
    fn accepts_ordinary_workspaces() {
        for path in [
            "/home/me/project",
            "/workspaces/repo",
            "/opt/myproject",
            "/var/www",
            "/tmp/scratch",
            "/srv/app",
            "/home/nvim-dcx",
        ] {
            assert!(
                check_workspace(Path::new(path)).is_ok(),
                "{path} は受け付けるべき"
            );
        }
    }

    #[test]
    fn mounts_nvim_config_readonly() {
        let args = RunSpec {
            nvim_config: Some("/home/me/dotfiles/nvim".into()),
            ..spec()
        }
        .to_args();
        assert!(has_pair(
            &args,
            "--mount",
            "type=bind,source=/home/me/dotfiles/nvim,target=/home/nvim-dc/.config/nvim,readonly"
        ));
    }

    #[test]
    fn host_docker_sock_is_mounted_at_standard_path() {
        let args = RunSpec {
            docker_sock: "/run/user/1000/docker.sock".into(),
            ..spec()
        }
        .to_args();
        assert!(has_pair(
            &args,
            "--mount",
            "type=bind,source=/run/user/1000/docker.sock,target=/var/run/docker.sock"
        ));
    }

    #[test]
    fn extra_mounts_and_env_come_before_image() {
        let args = RunSpec {
            extra_mounts: vec!["type=volume,source=x,target=/x".into()],
            env: vec![("TERM".into(), "xterm-256color".into())],
            ..spec()
        }
        .to_args();
        let image_pos = args.iter().position(|a| a == "nvim-dc:dev").unwrap();
        let mount_pos = args
            .iter()
            .position(|a| a == "type=volume,source=x,target=/x")
            .unwrap();
        let env_pos = args
            .iter()
            .position(|a| a == "TERM=xterm-256color")
            .unwrap();
        assert!(mount_pos < image_pos);
        assert!(env_pos < image_pos);
        assert_eq!(args[env_pos - 1], "--env");
    }

    #[test]
    fn open_file_follows_image() {
        let args = RunSpec {
            open_file: Some("/home/me/project/-weird.txt".into()),
            ..spec()
        }
        .to_args();
        let n = args.len();
        assert_eq!(
            &args[n - 3..],
            ["nvim-dc:dev", "--", "/home/me/project/-weird.txt"]
        );
    }

    #[test]
    fn quotes_paths_with_commas() {
        let args = RunSpec {
            workspace: "/home/me/a,b \"c\"".into(),
            ..spec()
        }
        .to_args();
        assert!(has_pair(
            &args,
            "--mount",
            r#"type=bind,"source=/home/me/a,b ""c""","target=/home/me/a,b ""c""""#
        ));
    }
}
