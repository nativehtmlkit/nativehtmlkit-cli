//! Host-independent Unix contract smoke test. Real native GUI qualification is separate.
#![cfg(unix)]
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::process::Command;
use std::time::Duration;

fn frame(reader: &mut impl Read) -> Value {
    let mut header = [0; 4];
    reader.read_exact(&mut header).unwrap();
    let size = u32::from_be_bytes(header) as usize;
    assert!(size > 0 && size < 2_097_153);
    let mut body = vec![0; size];
    reader.read_exact(&mut body).unwrap();
    serde_json::from_slice(&body).unwrap()
}
fn send(writer: &mut impl Write, msg: Value) {
    let bytes = serde_json::to_vec(&msg).unwrap();
    writer
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .unwrap();
    writer.write_all(&bytes).unwrap();
    writer.flush().unwrap();
}
fn answer(writer: &mut impl Write, request: &Value, result: Value) {
    send(
        writer,
        json!({"jsonrpc":"2.0","id":request["id"],"result":result}),
    );
}
#[test]
fn backend_roundtrips_auth_window_document_selection_and_shutdown() {
    let dir = tempfile::tempdir().unwrap();
    let sock = dir.path().join("host.sock");
    let listener = UnixListener::bind(&sock).unwrap();
    let fixture = json!({
      "schema":1,"mode":"select","title":"Test",
      "data":{"format":"lines","columns":["Value"],"rows":[
         {"cells":["<tag>"],"value":"<tag>"},
         {"cells":["beta"],"value":"beta"}
      ]},"multi":true,"allow_empty":false,"css":null,"html":null
    });
    std::fs::write(
        dir.path().join("session.json"),
        serde_json::to_vec(&fixture).unwrap(),
    )
    .unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_nativehtmlkit"))
        .arg("__backend")
        .arg(dir.path())
        .env("UI4ME_ENDPOINT", sock.to_string_lossy().to_string())
        .env("UI4ME_TOKEN", "a".repeat(64))
        .spawn()
        .unwrap();
    let (mut conn, _) = listener.accept().unwrap();
    conn.set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let hello = frame(&mut conn);
    assert_eq!(hello["method"], "host.hello");
    assert_eq!(hello["params"]["protocol_version"], 1);
    answer(
        &mut conn,
        &hello,
        json!({"protocol_version":1,"host_version":"1.0.1","app_id":"org.nativehtmlkit.Test","capabilities":{}}),
    );
    let win = frame(&mut conn);
    assert_eq!(win["method"], "window.create");
    answer(&mut conn, &win, json!({"window_id":"w1"}));
    let doc = frame(&mut conn);
    assert_eq!(doc["method"], "document.load");
    assert!(doc["params"]["html"]
        .as_str()
        .unwrap()
        .contains("&lt;tag&gt;"));
    answer(&mut conn, &doc, json!({"document_id":"d1","loaded":true}));
    let ready = frame(&mut conn);
    assert_eq!(ready["method"], "app.ready");
    answer(&mut conn, &ready, json!({"ready":true}));
    send(
        &mut conn,
        json!({"jsonrpc":"2.0","method":"document.event","params":{
      "window_id":"w1","document_id":"d1","event":{"type":"click","element":"nhk-submit"}}}),
    );
    let data = frame(&mut conn);
    assert_eq!(data["method"], "document.command");
    assert_eq!(data["params"]["command"]["op"], "get_form_data");
    answer(
        &mut conn,
        &data,
        json!({"entries":[{"name":"selection","kind":"text","value":"1"}]}),
    );
    let quit = frame(&mut conn);
    assert_eq!(quit["method"], "app.request_quit");
    answer(&mut conn, &quit, json!({"requested":true}));
    send(
        &mut conn,
        json!({"jsonrpc":"2.0","method":"app.shutdown","params":{"deadline_ms":5000}}),
    );
    assert!(child.wait().unwrap().success());
    let output: Value =
        serde_json::from_slice(&std::fs::read(dir.path().join("result.json")).unwrap()).unwrap();
    assert_eq!(output["kind"], "selected");
    assert_eq!(output["indices"], json!([1]));
}
