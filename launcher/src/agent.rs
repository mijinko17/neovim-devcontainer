//! ホストエージェント: 汎用コンテナの中からの依頼を、ホストで実行する。
//!
//! devcontainer.json には、ホストで評価される前提のものがある(`${localEnv:...}` と
//! `initializeCommand`)。devcontainer CLI は汎用コンテナの中で動くので、そのままでは
//! コンテナの環境変数で展開され、コンテナの中で実行されてしまう。ホストで動いている
//! プロセスはランチャーだけなので、ランチャーが Unix ソケットで依頼を受けて肩代わりする。
//!
//! プロトコルは1接続1依頼で、依頼も応答も1行1つの JSON。
//!
//! - `{"op":"env"}` → `{"env":{"HOME":"/home/me",...}}`
//! - `{"op":"run","argv":["/bin/sh","-c","..."]}` → `{"out":"出力の1行\n"}` が0回以上、
//!   最後に `{"exit":0}`。コマンドはワークスペースをカレントディレクトリにして実行する。
//! - 失敗したときは `{"error":"..."}`。
//!
//! 汎用コンテナは Docker ソケットを持っていてホストの root 相当なので、ホストでコマンドを
//! 実行できるようにしても、新たに渡す権限はない。ソケットは所有者しか入れないディレクトリに
//! 置き、汎用コンテナにだけマウントする。

use std::collections::BTreeMap;
use std::fs::DirBuilder;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::Duration;

use serde::Deserialize;
use serde_json::json;

/// エージェントのディレクトリの中でのソケットのファイル名。
pub const SOCKET_NAME: &str = "agent.sock";

#[derive(Debug, Deserialize, PartialEq)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Env,
    Run { argv: Vec<String> },
}

/// 動作中のエージェント。破棄するとソケットのディレクトリを消す。
pub struct Agent {
    dir: PathBuf,
}

impl Agent {
    /// `dir` を作り、その中のソケットで依頼を待ち受ける。
    ///
    /// `dir` の親は、他のユーザーが書き込めない自分のディレクトリでなければならない。
    /// 他のユーザーが `dir` を偽のソケットに差し替えられると、汎用コンテナが偽の応答を
    /// 受け取ってしまうため。
    pub fn start(dir: PathBuf, workspace: PathBuf, uid: u32) -> io::Result<Self> {
        let parent = dir
            .parent()
            .ok_or_else(|| io::Error::other("親ディレクトリがありません"))?;
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)?;
        let meta = std::fs::metadata(parent)?;
        if meta.uid() != uid || meta.mode() & 0o022 != 0 {
            return Err(io::Error::other(format!(
                "{} は他のユーザーが書き込めるか、所有者が違います",
                parent.display()
            )));
        }

        // 同じ PID の以前のランチャーが残したものがあれば消す。
        let _ = std::fs::remove_dir_all(&dir);
        DirBuilder::new().mode(0o700).create(&dir)?;
        let listener = UnixListener::bind(dir.join(SOCKET_NAME))?;

        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let workspace = workspace.clone();
                thread::spawn(move || handle(stream, &workspace));
            }
        });
        Ok(Self { dir })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn send(stream: &mut UnixStream, value: serde_json::Value) -> io::Result<()> {
    let mut line = value.to_string();
    line.push('\n');
    stream.write_all(line.as_bytes())
}

fn handle(mut stream: UnixStream, workspace: &Path) {
    let result = read_request(&stream).and_then(|request| match request {
        Request::Env => send(&mut stream, json!({ "env": host_env() })),
        Request::Run { argv } => run(&mut stream, &argv, workspace),
    });
    if let Err(e) = result {
        // 相手が切断していれば、この送信も失敗するだけ。
        let _ = send(&mut stream, json!({ "error": e.to_string() }));
    }
}

fn read_request(stream: &UnixStream) -> io::Result<Request> {
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    serde_json::from_str(&line).map_err(|e| io::Error::other(format!("不正な依頼: {e}")))
}

/// ホストの環境変数。UTF-8 でないものは JSON にできないので除く。
fn host_env() -> BTreeMap<String, String> {
    std::env::vars_os()
        .filter_map(|(k, v)| Some((k.into_string().ok()?, v.into_string().ok()?)))
        .collect()
}

/// コマンドの終了を確かめる間隔。終了後に出力が途絶えたとみなすまでの時間でもある。
const POLL_INTERVAL: Duration = Duration::from_millis(100);

/// コマンドを実行し、標準出力と標準エラー出力を1行ずつ、最後に終了コードを送る。
fn run(stream: &mut UnixStream, argv: &[String], workspace: &Path) -> io::Result<()> {
    let (program, args) = argv
        .split_first()
        .ok_or_else(|| io::Error::other("argv が空です"))?;

    // 標準出力と標準エラー出力を、出た順のまま1本のパイプで受ける。
    let (reader, writer) = io::pipe()?;
    let mut command = Command::new(program);
    command
        .args(args)
        .current_dir(workspace)
        .stdin(Stdio::null())
        .stdout(writer.try_clone()?)
        .stderr(writer);
    // 新しいセッションにして、端末から切り離す。端末は nvim の画面が使っているので、
    // コマンドが /dev/tty から入力を待つ(sudo や ssh のパスワードなど)と、キー入力を
    // 奪い合ってしまう。プロセスグループも分かれるので、孫プロセスごと止められる。
    // SAFETY: fork と exec のあいだで呼ぶのは、async-signal-safe な setsid だけ。
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command
        .spawn()
        .map_err(|e| io::Error::other(format!("{program}: {e}")))?;
    // Command がパイプの書き込み側を持ったままだと、子が終わっても読み込みが終わらない。
    drop(command);

    // 読み込みは別スレッドで行う。コマンドが残したバックグラウンドのプロセスがパイプを
    // 持ち続けると、コマンドが終わっても読み込みが終わらないため。
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut reader = BufReader::new(reader);
        loop {
            let mut line = Vec::new();
            match reader.read_until(b'\n', &mut line) {
                Ok(n) if n > 0 => {
                    if tx.send(line).is_err() {
                        break;
                    }
                }
                _ => break,
            }
        }
    });

    let mut exited = false;
    loop {
        match rx.recv_timeout(POLL_INTERVAL) {
            Ok(line) => {
                let sent = send(stream, json!({ "out": String::from_utf8_lossy(&line) }));
                if sent.is_err() {
                    // 依頼した側がいなくなった。結果を受け取る相手がいないので止める。
                    kill_group(&child);
                    break;
                }
            }
            Err(RecvTimeoutError::Disconnected) => break,
            // 終了したあと出力が途絶えたら、パイプが開いたままでも待つのをやめる。
            Err(RecvTimeoutError::Timeout) if exited => break,
            Err(RecvTimeoutError::Timeout) => exited = child.try_wait()?.is_some(),
        }
    }
    let status = child.wait()?;
    send(stream, json!({ "exit": status.code().unwrap_or(-1) }))
}

/// コマンドを、そこから起動されたプロセスごと止める。
fn kill_group(child: &Child) {
    if let Ok(pid) = i32::try_from(child.id()) {
        // SAFETY: 子はまだ wait していないので、PID が別のプロセスに再利用されていることはない。
        // setsid しているので、子の PID がそのままプロセスグループの ID になる。
        unsafe { libc::kill(-pid, libc::SIGKILL) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn start(name: &str) -> (Agent, PathBuf) {
        // SAFETY: getuid は常に成功し、副作用もない。
        let uid = unsafe { libc::getuid() };
        let base =
            std::env::temp_dir().join(format!("nvim-dc-agent-{}-{name}", std::process::id()));
        let workspace = base.join("ws");
        std::fs::create_dir_all(&workspace).unwrap();
        let agent = Agent::start(base.join("agent"), workspace.clone(), uid).unwrap();
        (agent, workspace)
    }

    fn request(agent: &Agent, request: &str) -> Vec<serde_json::Value> {
        let mut stream = UnixStream::connect(agent.dir().join(SOCKET_NAME)).unwrap();
        stream.write_all(request.as_bytes()).unwrap();
        stream.write_all(b"\n").unwrap();
        BufReader::new(stream)
            .lines()
            .map(|line| serde_json::from_str(&line.unwrap()).unwrap())
            .collect()
    }

    #[test]
    fn parses_requests() {
        assert_eq!(
            serde_json::from_str::<Request>(r#"{"op":"env"}"#).unwrap(),
            Request::Env
        );
        assert_eq!(
            serde_json::from_str::<Request>(r#"{"op":"run","argv":["true"]}"#).unwrap(),
            Request::Run {
                argv: vec!["true".into()]
            }
        );
        assert!(serde_json::from_str::<Request>(r#"{"op":"bogus"}"#).is_err());
    }

    #[test]
    fn returns_host_env() {
        let (agent, _) = start("env");
        let replies = request(&agent, r#"{"op":"env"}"#);
        assert_eq!(replies.len(), 1);
        assert_eq!(
            replies[0]["env"]["PATH"].as_str(),
            std::env::var("PATH").ok().as_deref()
        );
    }

    #[test]
    fn runs_command_in_workspace() {
        let (agent, workspace) = start("run");
        let replies = request(
            &agent,
            r#"{"op":"run","argv":["/bin/sh","-c","pwd; echo err >&2; exit 3"]}"#,
        );
        let expected = workspace.canonicalize().unwrap();
        assert_eq!(
            replies,
            [
                json!({ "out": format!("{}\n", expected.display()) }),
                json!({ "out": "err\n" }),
                json!({ "exit": 3 }),
            ]
        );
    }

    #[test]
    fn does_not_wait_for_background_processes() {
        let (agent, _) = start("background");
        let started = std::time::Instant::now();
        let replies = request(
            &agent,
            r#"{"op":"run","argv":["/bin/sh","-c","sleep 5 & echo started"]}"#,
        );
        assert_eq!(
            replies,
            [json!({ "out": "started\n" }), json!({ "exit": 0 })]
        );
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn reports_errors() {
        let (agent, _) = start("err");
        let replies = request(&agent, r#"{"op":"run","argv":["/nonexistent/command"]}"#);
        assert_eq!(replies.len(), 1);
        assert!(
            replies[0]["error"]
                .as_str()
                .unwrap()
                .contains("/nonexistent/command")
        );

        let replies = request(&agent, "not json");
        assert!(replies[0]["error"].is_string());
    }

    #[test]
    fn removes_directory_on_drop() {
        let (agent, _) = start("drop");
        let dir = agent.dir().to_path_buf();
        assert!(dir.join(SOCKET_NAME).exists());
        drop(agent);
        assert!(!dir.exists());
    }
}
