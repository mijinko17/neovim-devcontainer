//! nvim-dc: 汎用 Neovim コンテナを起動するランチャー。
//!
//! 行うのは引数とパスの解決、`docker run` の組み立てと実行、それにホストでしか
//! できない処理の肩代わり(`agent.rs`)だけ。devcontainer に関する判断はすべて
//! プラグイン側に置く。

mod agent;
mod config;
mod run;

use std::ffi::OsString;
use std::io::IsTerminal;
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, ExitStatus, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};

use agent::Agent;
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
            Ok(ExitCode::SUCCESS)
        }
        Cmd::Version => {
            println!("nvim-dc {}", env!("CARGO_PKG_VERSION"));
            Ok(ExitCode::SUCCESS)
        }
        Cmd::Pull => {
            let config = load_config()?;
            exec_docker(&["pull".into(), image(&config)])
        }
        Cmd::Open(path) => {
            let config = load_config()?;
            open(build_spec(path, config)?)
        }
    });
    match result {
        Ok(code) => code,
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

fn load_config() -> Result<Config, String> {
    let xdg_config_home = std::env::var("XDG_CONFIG_HOME").ok();
    let path = config::config_path(xdg_config_home.as_deref(), &home_dir()?);
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
        host_agent_dir: None,
        extra_mounts: config.mounts,
        env,
    })
}

/// ホストエージェントのソケットを置くディレクトリ。ランチャーのプロセスごとに分ける。
///
/// `XDG_RUNTIME_DIR` があればその下に置く。ログインしているユーザー専用で、ログアウト時に
/// 消えるため。なければ一時ディレクトリの下に、ユーザーごとのディレクトリを作る。
fn agent_dir(xdg_runtime_dir: Option<&str>, uid: u32, pid: u32) -> PathBuf {
    let base = match xdg_runtime_dir {
        Some(dir) if Path::new(dir).is_absolute() => Path::new(dir).join("nvim-dc"),
        _ => std::env::temp_dir().join(format!("nvim-dc-{uid}")),
    };
    base.join(pid.to_string())
}

/// ホストエージェントを起動する。
///
/// XDG_RUNTIME_DIR が実在しない、または他のユーザーのもの(su の直後など)で使えない
/// ときは、一時ディレクトリの下でやり直す。
fn start_agent(spec: &RunSpec) -> Result<Agent, String> {
    let xdg_runtime_dir = std::env::var("XDG_RUNTIME_DIR").ok();
    let start = |xdg_runtime_dir: Option<&str>| {
        let dir = agent_dir(xdg_runtime_dir, spec.uid, std::process::id());
        Agent::start(dir, spec.workspace.clone(), spec.uid)
    };
    start(xdg_runtime_dir.as_deref())
        .or_else(|e| match xdg_runtime_dir {
            Some(_) => start(None),
            None => Err(e),
        })
        .map_err(|e| format!("ホストエージェントを起動できません: {e}"))
}

/// 汎用コンテナを起動し、終了するまでホストエージェントを動かす。
///
/// `docker run` は exec せずに子プロセスにする。コンテナが動いているあいだ、ランチャーが
/// ホストに残って依頼を受けるため。端末は子がそのまま引き継ぐ。
fn open(mut spec: RunSpec) -> Result<ExitCode, String> {
    let agent = start_agent(&spec)?;
    spec.host_agent_dir = Some(agent.dir().to_path_buf());

    let mut child = Command::new("docker")
        .args(spec.to_args())
        .spawn()
        .map_err(|e| format!("docker を起動できません: {e}"))?;
    forward_signals_to(&child);
    let status = child.wait();
    DOCKER_PID.store(0, Ordering::SeqCst);
    drop(agent);
    let status = status.map_err(|e| format!("docker の終了を待てません: {e}"))?;
    Ok(exit_code(status))
}

/// 終了を求めるシグナルの転送先(`docker run` の PID)。0 なら転送しない。
static DOCKER_PID: AtomicI32 = AtomicI32::new(0);

extern "C" fn forward_signal(signal: libc::c_int) {
    let pid = DOCKER_PID.load(Ordering::SeqCst);
    if pid > 0 {
        // SAFETY: kill は async-signal-safe。
        unsafe { libc::kill(pid, signal) };
    }
}

/// ランチャーに届いた終了のシグナルを、`docker run` に転送する。
///
/// 転送しないとランチャーだけが終わり、docker が残って、エージェントのディレクトリも
/// 消されない。転送して docker が終われば、いつもどおり後始末をして終了する。
fn forward_signals_to(child: &std::process::Child) {
    let Ok(pid) = i32::try_from(child.id()) else {
        return;
    };
    DOCKER_PID.store(pid, Ordering::SeqCst);
    let handler = forward_signal as extern "C" fn(libc::c_int) as libc::sighandler_t;
    for signal in [libc::SIGTERM, libc::SIGHUP, libc::SIGINT, libc::SIGQUIT] {
        // SAFETY: ハンドラは async-signal-safe な処理(アトミックの読み出しと kill)しかしない。
        unsafe { libc::signal(signal, handler) };
    }
}

/// 子プロセスの終了状態を、そのままランチャーの終了コードにする。
/// シグナルで終わったときは、シェルの慣習に合わせて 128 + シグナル番号にする。
fn exit_code(status: ExitStatus) -> ExitCode {
    let code = status
        .code()
        .or_else(|| status.signal().map(|signal| 128 + signal))
        .unwrap_or(1);
    ExitCode::from(u8::try_from(code).unwrap_or(1))
}

/// `docker` を exec で起動し、このプロセスを置き換える。成功すると戻らない。
fn exec_docker(args: &[String]) -> Result<ExitCode, String> {
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
    fn agent_dir_prefers_xdg_runtime_dir() {
        assert_eq!(
            agent_dir(Some("/run/user/1000"), 1000, 42),
            PathBuf::from("/run/user/1000/nvim-dc/42")
        );
        let fallback = std::env::temp_dir().join("nvim-dc-1000/42");
        assert_eq!(agent_dir(None, 1000, 42), fallback);
        assert_eq!(agent_dir(Some("relative"), 1000, 42), fallback);
    }

    #[test]
    fn exit_code_follows_child() {
        let code = |raw| format!("{:?}", exit_code(ExitStatus::from_raw(raw)));
        assert_eq!(code(0), format!("{:?}", ExitCode::SUCCESS));
        assert_eq!(code(3 << 8), format!("{:?}", ExitCode::from(3)));
        // SIGTERM(15) で終了
        assert_eq!(code(15), format!("{:?}", ExitCode::from(143)));
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
