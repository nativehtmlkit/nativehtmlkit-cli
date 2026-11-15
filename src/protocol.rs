//! Independent Rust client for the Core v1 local JSON-RPC protocol.
//! The CLI does NOT link Core's renderer or private Rust crates.
use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::time::{Duration, Instant};

pub const MAX_FRAME: usize = 2_097_152;

#[cfg(unix)]
type LocalStream = std::os::unix::net::UnixStream;
#[cfg(windows)]
type LocalStream = std::fs::File;
#[cfg(not(any(windows, unix)))]
compile_error!("NativeHTMLKit CLI currently supports Linux and Windows");

pub fn read_frame(reader: &mut impl Read) -> Result<Value> {
    let mut head = [0_u8; 4];
    reader
        .read_exact(&mut head)
        .context("host disconnected while reading a frame header")?;
    let len = u32::from_be_bytes(head) as usize;
    if len == 0 || len > MAX_FRAME {
        bail!("invalid host frame length {len}");
    }
    let mut bytes = vec![0_u8; len];
    reader
        .read_exact(&mut bytes)
        .context("host disconnected inside a JSON frame")?;
    serde_json::from_slice(&bytes).context("invalid JSON from Core host")
}

pub fn send_frame(writer: &mut impl Write, message: &Value) -> Result<()> {
    let bytes = serde_json::to_vec(message)?;
    if bytes.is_empty() || bytes.len() > MAX_FRAME {
        bail!("outgoing RPC frame exceeds limit");
    }
    writer.write_all(&(bytes.len() as u32).to_be_bytes())?;
    writer.write_all(&bytes)?;
    writer.flush()?;
    Ok(())
}

pub struct Client {
    stream: LocalStream,
    next_id: u64,
    queued: VecDeque<Value>,
}

impl Client {
    pub fn connect(endpoint: &str) -> Result<Self> {
        if endpoint.trim().is_empty() {
            bail!("host endpoint missing");
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            #[cfg(unix)]
            let attempt = std::os::unix::net::UnixStream::connect(endpoint);
            #[cfg(windows)]
            let attempt = std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open(endpoint);
            match attempt {
                Ok(stream) => {
                    return Ok(Self {
                        stream,
                        next_id: 0,
                        queued: VecDeque::new(),
                    })
                }
                Err(e) if Instant::now() < deadline => {
                    if e.kind() == std::io::ErrorKind::PermissionDenied {
                        return Err(e).context("host IPC permission denied");
                    }
                    std::thread::sleep(Duration::from_millis(60));
                }
                Err(e) => {
                    return Err(e)
                        .with_context(|| format!("connect to native host IPC endpoint {endpoint}"))
                }
            }
        }
    }

    pub fn hello(&mut self, token: &str) -> Result<Value> {
        self.call(
            "host.hello",
            json!({"token":token,"protocol_version":1,
         "client":{"name":"nativehtmlkit-cli","version":env!("CARGO_PKG_VERSION")}}),
        )
    }

    pub fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        self.next_id += 1;
        let id = format!("nhk-{}", self.next_id);
        send_frame(
            &mut self.stream,
            &json!({"jsonrpc":"2.0","id":id.clone(),"method":method,"params":params}),
        )?;
        loop {
            let message = read_frame(&mut self.stream)?;
            if let Some(name) = message.get("method").and_then(Value::as_str) {
                if let Some(req_id) = message.get("id").and_then(Value::as_str) {
                    self.reply_host_request(req_id, name)?;
                } else {
                    if self.queued.len() > 4096 {
                        bail!("host notification queue overflow");
                    }
                    self.queued.push_back(message);
                }
                continue;
            }
            if message.get("id").and_then(Value::as_str) != Some(id.as_str()) {
                bail!("unexpected or uncorrelated host response: {message}");
            }
            return response_result(&message);
        }
    }

    fn reply_host_request(&mut self, id: &str, name: &str) -> Result<()> {
        let msg = match name {
            "window.before_close" | "app.before_quit" => {
                json!({"jsonrpc":"2.0","id":id,"result":{"allow":true}})
            }
            _ => {
                json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"method not found"}})
            }
        };
        send_frame(&mut self.stream, &msg)
    }

    pub fn next_event(&mut self) -> Result<Value> {
        if let Some(message) = self.queued.pop_front() {
            return Ok(message);
        }
        loop {
            let message = read_frame(&mut self.stream)?;
            if let Some(method) = message.get("method").and_then(Value::as_str) {
                if let Some(id) = message.get("id").and_then(Value::as_str) {
                    self.reply_host_request(id, method)?;
                    continue;
                }
                return Ok(message);
            }
            // Stray responses are invalid unless we explicitly hold pending IDs.
            bail!("unexpected response outside a client request: {message}");
        }
    }
}

fn response_result(message: &Value) -> Result<Value> {
    if let Some(err) = message.get("error") {
        let code = err.get("code").and_then(Value::as_i64).unwrap_or(-32603);
        let text = err
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("unknown RPC error");
        return Err(anyhow!("Core RPC failed ({code}): {text}"));
    }
    message
        .get("result")
        .cloned()
        .ok_or_else(|| anyhow!("RPC response lacks result"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn framing_roundtrip() {
        let msg = json!({"jsonrpc":"2.0","id":"nhk-1","method":"host.hello","params":{}});
        let mut buffer = Vec::new();
        send_frame(&mut buffer, &msg).unwrap();
        assert_eq!(read_frame(&mut buffer.as_slice()).unwrap(), msg);
    }
    #[test]
    fn reject_bad_frame_sizes() {
        assert!(read_frame(&mut &[0, 0, 0, 0][..]).is_err());
        assert!(read_frame(&mut &[0, 32, 0, 1][..]).is_err());
    }
    #[test]
    fn host_errors_never_return_success() {
        assert!(response_result(&json!({"error":{"code":-32010,"message":"version"}})).is_err());
    }
}
