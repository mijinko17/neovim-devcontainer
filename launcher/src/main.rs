//! nvim-dc: 汎用 Neovim コンテナを起動するランチャー。
//!
//! 行うのは引数とパスの解決、`docker run` の組み立てと実行だけ。
//! devcontainer に関する判断はすべてプラグイン側に置く。

mod config;
mod run;

use std::ffi::OsString;
use std::io::IsTerminal;
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

use config::Config;
use run::{PASSTHROUGH_ENV, RunSpec};

/// 既定の汎用イメージ。ランチャーは自分と同じバージョンのイメージを使う。
const DEFAULT_IMAGE_REPO: &str = "ghcr.io/mijinko17/neovim-devcontainer";

const USAGE: &str = "\
Usage:
  nvim-dc [path]     汎用コンテナを起動して nvim を開く(既定はカレントディレクトリ)
  nvim-dc pull       汎用イメージを取得し直す
  nvim-dc --help     このヘルプを表示する
  nvim-dc --version  バージョンを表示する

`pull` という名前のディレクトリを開くときは `./pull` と指定してください。";

#[derive(Debug, PartialEq)]
enum Cmd {
    Open(Option<PathBuf>),
    Pull,
    Help,
    Version,
}

fn parse_args(args: &[OsString]) -> Result<Cmd, String> {
    match args {
        [] => Ok(Cmd::Open(None)),
        [arg] => match arg.to_str() {
            Some("pull") => Ok(Cmd::Pull),
            Some("-h" | "--help") => Ok(Cmd::Help),
            Some("-V" | "--version") => Ok(Cmd::Version),
            Some(s) if s.starts_with('-') => Err(format!("不明なオプション: {s}")),
            _ => Ok(Cmd::Open(Some(PathBuf::from(arg)))),
        },
        _ => Err("引数が多すぎます".into()),
    }
}

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let result = parse_args(&args).and_then(|cmd| match cmd {
        Cmd::Help => {
            println!("{USAGE}");
            Ok(())
        }
        Cmd::Version => {
            println!("nvim-dc {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Cmd::Pull => {
            let config = load_config()?;
            exec_docker(&["pull".into(), image(&config)])
        }
        Cmd::Open(path) => {
            let config = load_config()?;
            let spec = build_spec(path, config)?;
            exec_docker(&spec.to_args())
        }
    });
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("nvim-dc: {e}");
            ExitCode::FAILURE
        }
    }
}

fn home_dir() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| "HOME が設定されていません".to_string())
}

fn xdg_config_home() -> Option<String> {
    std::env::var("XDG_CONFIG_HOME").ok()
}

fn load_config() -> Result<Config, String> {
    let path = config::config_path(xdg_config_home().as_deref(), &home_dir()?);
    Config::load(&path)
}

fn image(config: &Config) -> String {
    config
        .image
        .clone()
        .unwrap_or_else(|| format!("{DEFAULT_IMAGE_REPO}:{}", env!("CARGO_PKG_VERSION")))
}

/// ワークスペースと、開くファイルを決める。
///
/// ディレクトリならそれをワークスペースにする。ファイル(未作成のものを含む)なら
/// 親ディレクトリをワークスペースにして、そのファイルを開く。
///
/// ファイルがシンボリックリンクでも実体は辿らない。辿るとリンク先の親ディレクトリが
/// ワークスペースになり、ユーザーが指定したプロジェクトがマウントされないため。
fn resolve_target(path: Option<PathBuf>) -> Result<(PathBuf, Option<PathBuf>), String> {
    let path = match path {
        Some(p) => p,
        None => std::env::current_dir().map_err(|e| format!("カレントディレクトリ: {e}"))?,
    };
    let not_found = || format!("{}: 見つかりません", path.display());

    if path.is_dir() {
        let dir = path.canonicalize().map_err(|_| not_found())?;
        return Ok((dir, None));
    }

    // ファイル、または親ディレクトリがある未作成のファイル。
    let name = path.file_name().ok_or_else(not_found)?;
    let parent = match path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p,
        _ => Path::new("."),
    };
    let parent = parent
        .canonicalize()
        .ok()
        .filter(|p| p.is_dir())
        .ok_or_else(not_found)?;
    let file = parent.join(name);
    Ok((parent, Some(file)))
}

/// ホスト側の Docker ソケット。
///
/// exec する `docker` CLI と同じデーモンを指すように、`docker context` の解決結果を使う。
/// `DOCKER_HOST` が設定されていれば、それも context の解決に反映される。
fn docker_sock() -> Result<PathBuf, String> {
    let output = Command::new("docker")
        .args([
            "context",
            "inspect",
            "--format",
            "{{.Endpoints.docker.Host}}",
        ])
        .stderr(Stdio::inherit())
        .output()
        .map_err(|e| format!("docker を起動できません: {e}"))?;
    if !output.status.success() {
        return Err("docker context の解決に失敗しました".into());
    }
    let host = String::from_utf8_lossy(&output.stdout);
    parse_docker_host(host.trim())
}

/// `unix:///path/to/docker.sock` 形式の Docker エンドポイントからソケットのパスを取り出す。
fn parse_docker_host(host: &str) -> Result<PathBuf, String> {
    let unsupported =
        || format!("Docker のエンドポイント {host:?} には対応していません(unix:// の絶対パスのみ)");
    let path = host.strip_prefix("unix://").ok_or_else(unsupported)?;
    if !path.starts_with('/') || path.contains(['?', '#']) {
        return Err(unsupported());
    }
    Ok(PathBuf::from(path))
}

/// 標準入出力の両方が端末かどうか。nvim の TUI はどちらが欠けても正しく動かない。
fn is_terminal() -> bool {
    std::io::stdin().is_terminal() && std::io::stdout().is_terminal()
}

fn build_spec(path: Option<PathBuf>, config: Config) -> Result<RunSpec, String> {
    if !is_terminal() {
        return Err("端末から実行してください(標準入出力が端末ではありません)".into());
    }

    let (workspace, open_file) = resolve_target(path)?;
    run::check_workspace(&workspace)?;

    let docker_sock = docker_sock()?;
    let docker_gid = std::fs::metadata(&docker_sock)
        .map_err(|e| format!("Docker ソケット {}: {e}", docker_sock.display()))?
        .gid();

    // SAFETY: getuid / getgid は常に成功し、副作用もない。
    let (uid, gid) = unsafe { (libc::getuid(), libc::getgid()) };

    let env = PASSTHROUGH_ENV
        .iter()
        .filter_map(|key| std::env::var(key).ok().map(|v| (key.to_string(), v)))
        .collect();

    Ok(RunSpec {
        image: image(&config),
        workspace,
        open_file,
        uid,
        gid,
        docker_sock,
        docker_gid,
        extra_mounts: config.mounts,
        env,
    })
}

/// `docker` を exec で起動し、このプロセスを置き換える。成功すると戻らない。
fn exec_docker(args: &[String]) -> Result<(), String> {
    let err = Command::new("docker").args(args).exec();
    Err(format!("docker を起動できません: {err}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn os(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    #[test]
    fn parses_commands() {
        assert_eq!(parse_args(&os(&[])), Ok(Cmd::Open(None)));
        assert_eq!(parse_args(&os(&["src"])), Ok(Cmd::Open(Some("src".into()))));
        assert_eq!(
            parse_args(&os(&["./pull"])),
            Ok(Cmd::Open(Some("./pull".into())))
        );
        assert_eq!(parse_args(&os(&["pull"])), Ok(Cmd::Pull));
        assert_eq!(parse_args(&os(&["--help"])), Ok(Cmd::Help));
        assert_eq!(parse_args(&os(&["-V"])), Ok(Cmd::Version));
        assert!(parse_args(&os(&["--bogus"])).is_err());
        assert!(parse_args(&os(&["a", "b"])).is_err());
    }

    #[test]
    fn resolves_directory_and_files() {
        let dir = std::env::temp_dir().join(format!("nvim-dc-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let dir = dir.canonicalize().unwrap();
        let file = dir.join("a.txt");
        std::fs::write(&file, "").unwrap();

        assert_eq!(resolve_target(Some(dir.clone())), Ok((dir.clone(), None)));
        assert_eq!(
            resolve_target(Some(file.clone())),
            Ok((dir.clone(), Some(file.clone())))
        );
        let new_file = dir.join("new.txt");
        assert_eq!(
            resolve_target(Some(new_file.clone())),
            Ok((dir.clone(), Some(new_file)))
        );
        assert!(resolve_target(Some(dir.join("missing/new.txt"))).is_err());

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn symlinked_file_keeps_its_own_directory() {
        let base = std::env::temp_dir().join(format!("nvim-dc-link-{}", std::process::id()));
        let project = base.join("project");
        let secrets = base.join("secrets");
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&secrets).unwrap();
        let project = project.canonicalize().unwrap();
        let real = secrets.join("project.env");
        std::fs::write(&real, "").unwrap();
        let link = project.join(".env");
        std::os::unix::fs::symlink(&real, &link).unwrap();

        assert_eq!(
            resolve_target(Some(link.clone())),
            Ok((project, Some(link)))
        );

        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn parses_docker_host() {
        assert_eq!(
            parse_docker_host("unix:///var/run/docker.sock"),
            Ok(PathBuf::from("/var/run/docker.sock"))
        );
        assert_eq!(
            parse_docker_host("unix:///run/user/1000/docker.sock"),
            Ok(PathBuf::from("/run/user/1000/docker.sock"))
        );
        assert!(parse_docker_host("unix://").is_err());
        assert!(parse_docker_host("unix://relative.sock").is_err());
        assert!(parse_docker_host("unix:///a.sock?x=1").is_err());
        assert!(parse_docker_host("tcp://127.0.0.1:2375").is_err());
        assert!(parse_docker_host("ssh://me@host").is_err());
        assert!(parse_docker_host("").is_err());
    }
}
