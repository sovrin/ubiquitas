//! Connection to the server. Wire format: README.md at the repository root.
use crate::sink::{Sink, decode};
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, aead::Aead};
use gtk::glib;
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::{
    collections::HashMap,
    convert::Infallible,
    error::Error,
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    net::TcpStream,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

pub const PORT: u16 = 24242;
const MAX_FRAME: usize = 1 << 20;
const CHUNK: usize = 65536;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Screen {
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub online: bool,
}

/// JSON control message; `t` says which fields are used (see README).
#[derive(Serialize, Deserialize, Default, Clone, Debug)]
pub struct Control {
    pub t: String,
    pub name: Option<String>,
    pub w: Option<i32>,
    pub h: Option<i32>,
    pub screens: Option<Vec<Screen>>,
    pub text: Option<String>,
    pub id: Option<u32>,
    pub size: Option<u64>,
    pub to: Option<String>,
    pub x: Option<i32>,
    pub y: Option<i32>,
}

pub enum ToUi {
    Status(String),
    Layout(Vec<Screen>),
    Clip(String),
}

/// From the connection to the screen-edge capture (capture.rs).
#[cfg_attr(not(target_os = "linux"), allow(dead_code))] // capture only exists on Linux
pub enum ToCapture {
    Layout(Vec<Screen>),
    /// Give keyboard and mouse back to this desktop, cursor at (x, y) on this screen.
    Release(i32, i32),
    Disconnected,
}

pub fn cipher(psk: &[u8; 32], salt: &[u8], info: &str) -> ChaCha20Poly1305 {
    let mut okm = [0u8; 32];
    Hkdf::<Sha256>::new(Some(salt), psk).expand(info.as_bytes(), &mut okm).unwrap();
    ChaCha20Poly1305::new(&okm.into())
}

pub fn nonce(counter: u64) -> [u8; 12] {
    let mut n = [0u8; 12];
    n[4..].copy_from_slice(&counter.to_be_bytes());
    n
}

pub fn control(c: &Control) -> Vec<u8> {
    let mut m = vec![4];
    m.extend(serde_json::to_vec(c).unwrap());
    m
}

/// Sending half of a session; shared by the UI and file-sending threads.
pub struct Tx {
    stream: TcpStream,
    cipher: ChaCha20Poly1305,
    counter: u64,
}

impl Tx {
    fn send(&mut self, msg: &[u8]) -> io::Result<()> {
        let ct = self.cipher.encrypt(&nonce(self.counter).into(), msg).map_err(|_| io::Error::other("encrypt failed"))?;
        self.counter += 1;
        let mut frame = (ct.len() as u32).to_be_bytes().to_vec();
        frame.extend(ct);
        self.stream.write_all(&frame)
    }
}

pub type SharedTx = Arc<Mutex<Option<Tx>>>;

pub fn send(tx: &SharedTx, msg: &[u8]) -> io::Result<()> {
    tx.lock().unwrap().as_mut().ok_or_else(|| io::Error::other("not connected"))?.send(msg)
}

pub struct Config {
    pub host: String,
    pub psk: [u8; 32],
    pub name: String,
    pub w: i32,
    pub h: i32,
    pub capture: async_channel::Sender<ToCapture>,
}

/// Connects and reconnects forever, replaying input and reporting to the UI.
pub fn run(cfg: Config, tx: SharedTx, ui: async_channel::Sender<ToUi>) {
    let mut sink = match Sink::new() {
        Ok(s) => s,
        Err(e) => {
            let _ = ui.send_blocking(ToUi::Status(format!(
                "cannot create virtual input devices (is /dev/uinput writable? see README): {e}"
            )));
            return;
        }
    };
    let downloads = glib::user_special_dir(glib::UserDirectory::Downloads).unwrap_or_else(glib::home_dir);
    loop {
        let Err(e) = session(&cfg, &tx, &ui, &mut sink, &downloads);
        *tx.lock().unwrap() = None;
        let _ = cfg.capture.send_blocking(ToCapture::Disconnected);
        let _ = ui.send_blocking(ToUi::Status(format!("disconnected: {e} — retrying…")));
        thread::sleep(Duration::from_secs(2));
    }
}

fn session(
    cfg: &Config,
    tx: &SharedTx,
    ui: &async_channel::Sender<ToUi>,
    sink: &mut Sink,
    downloads: &Path,
) -> Result<Infallible, Box<dyn Error>> {
    let mut s = TcpStream::connect((cfg.host.as_str(), PORT))?;
    s.set_nodelay(true)?;
    let mut salt = [0u8; 64]; // server salt || client salt
    s.read_exact(&mut salt[..32])?;
    getrandom::fill(&mut salt[32..])?;
    s.write_all(&salt[32..])?;
    let mut t = Tx { stream: s.try_clone()?, cipher: cipher(&cfg.psk, &salt, "ubiquitas v2 c2s"), counter: 0 };
    let hello = Control { t: "hello".into(), name: Some(cfg.name.clone()), w: Some(cfg.w), h: Some(cfg.h), ..Default::default() };
    t.send(&control(&hello))?;
    *tx.lock().unwrap() = Some(t);
    let _ = ui.send_blocking(ToUi::Status(format!("connected to {} as {}", cfg.host, cfg.name)));

    let rx = cipher(&cfg.psk, &salt, "ubiquitas v2 s2c");
    let mut files: HashMap<u32, (File, u64, PathBuf)> = HashMap::new();
    let mut counter = 0u64;
    loop {
        let mut len = [0u8; 4];
        s.read_exact(&mut len).map_err(|e| match counter {
            0 => format!("server closed the connection before sending anything ({e}); wrong key?"),
            _ => format!("server closed the connection ({e})"),
        })?;
        let len = u32::from_be_bytes(len) as usize;
        if len == 0 || len > MAX_FRAME {
            return Err("bad frame length".into());
        }
        let mut body = vec![0u8; len];
        s.read_exact(&mut body)?;
        let msg = rx.decrypt(&nonce(counter).into(), body.as_ref()).map_err(|_| "received a frame that fails authentication")?;
        counter += 1;

        match msg.first() {
            Some(1..=3) => {
                if let Some(e) = decode(&msg) {
                    sink.apply(e)?;
                }
            }
            Some(4) => {
                let c: Control = serde_json::from_slice(&msg[1..])?;
                match c.t.as_str() {
                    "layout" => {
                        let screens = c.screens.unwrap_or_default();
                        let _ = cfg.capture.send_blocking(ToCapture::Layout(screens.clone()));
                        let _ = ui.send_blocking(ToUi::Layout(screens));
                    }
                    "release" => {
                        let _ = cfg.capture.send_blocking(ToCapture::Release(c.x.unwrap_or(0), c.y.unwrap_or(0)));
                    }
                    "clip" => {
                        let _ = ui.send_blocking(ToUi::Clip(c.text.unwrap_or_default()));
                    }
                    "file" => {
                        let (Some(id), Some(size)) = (c.id, c.size) else { continue };
                        let status = match create_unique(downloads, c.name.as_deref().unwrap_or("file")) {
                            Ok((f, path)) if size > 0 => {
                                let msg = format!("receiving {}…", path.display());
                                files.insert(id, (f, size, path));
                                msg
                            }
                            Ok((_, path)) => format!("received {}", path.display()),
                            Err(e) => format!("cannot save incoming file: {e}"),
                        };
                        let _ = ui.send_blocking(ToUi::Status(status));
                    }
                    _ => {}
                }
            }
            Some(5) if msg.len() >= 5 => {
                let id = u32::from_be_bytes(msg[1..5].try_into().unwrap());
                let Some((f, left, path)) = files.get_mut(&id) else { continue };
                let data = &msg[5..msg.len().min(5 + *left as usize)];
                if let Err(e) = f.write_all(data) {
                    let _ = ui.send_blocking(ToUi::Status(format!("cannot save {}: {e}", path.display())));
                    files.remove(&id);
                    continue;
                }
                *left -= data.len() as u64;
                if *left == 0 {
                    let _ = ui.send_blocking(ToUi::Status(format!("received {}", path.display())));
                    files.remove(&id);
                }
            }
            _ => {} // unknown types are skipped so newer servers stay compatible
        }
    }
}

/// Creates a new file for an incoming transfer without ever overwriting or leaving `dir`.
fn create_unique(dir: &Path, name: &str) -> io::Result<(File, PathBuf)> {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let safe = if base.is_empty() || base == "." || base == ".." || base.contains('\0') { "file" } else { base };
    let (stem, ext) = match safe.rsplit_once('.') {
        Some((s, e)) if !s.is_empty() => (s, format!(".{e}")),
        _ => (safe, String::new()),
    };
    for i in 0..1000 {
        let path = dir.join(if i == 0 { safe.to_string() } else { format!("{stem} ({i}){ext}") });
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(f) => return Ok((f, path)),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::other("too many files with that name"))
}

/// Streams a file to another screen in the background.
pub fn send_file(tx: SharedTx, path: PathBuf, to: String, ui: async_channel::Sender<ToUi>) {
    thread::spawn(move || {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into());
        let _ = ui.send_blocking(ToUi::Status(format!("sending {name} to {to}…")));
        let result = (|| -> io::Result<()> {
            let mut f = File::open(&path)?;
            let size = f.metadata()?.len();
            let id = getrandom::u32().map_err(io::Error::other)?;
            let meta = Control { t: "file".into(), name: Some(name.clone()), id: Some(id), size: Some(size), to: Some(to.clone()), ..Default::default() };
            send(&tx, &control(&meta))?;
            let mut buf = vec![0u8; CHUNK];
            let mut sent = 0u64;
            while sent < size {
                let n = f.read(&mut buf)?;
                if n == 0 {
                    return Err(io::Error::other("file got shorter while sending"));
                }
                let mut m = vec![5];
                m.extend(id.to_be_bytes());
                m.extend(&buf[..n]);
                send(&tx, &m)?;
                sent += n as u64;
            }
            Ok(())
        })();
        let _ = ui.send_blocking(ToUi::Status(match result {
            Ok(()) => format!("sent {name} to {to}"),
            Err(e) => format!("could not send {name}: {e}"),
        }));
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    // Same inputs and expected output as the Swift side (see README "Test vector"),
    // so both implementations are pinned to one wire format.
    #[test]
    fn crypto_matches_swift() {
        let ct = cipher(&[1; 32], &[2; 64], "ubiquitas v2 s2c").encrypt(&nonce(7).into(), [3u8, 0, 30, 1].as_ref()).unwrap();
        let hex: String = ct.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, SWIFT_VECTOR);
    }

    #[test]
    fn file_names_stay_in_dir_and_never_overwrite() {
        let dir = std::env::temp_dir().join(format!("ubiquitas-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (_, a) = create_unique(&dir, "../../etc/passwd").unwrap();
        let (_, b) = create_unique(&dir, "passwd").unwrap();
        let (_, c) = create_unique(&dir, "..").unwrap();
        assert_eq!((a.file_name().unwrap(), b.file_name().unwrap(), c.file_name().unwrap()), ("passwd".as_ref(), "passwd (1)".as_ref(), "file".as_ref()));
        std::fs::remove_dir_all(dir).unwrap();
    }

    const SWIFT_VECTOR: &str = "7d09d8a5ff27ae7596b7277d5f550410f3b5968d";
}
