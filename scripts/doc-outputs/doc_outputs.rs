//! Documentation check, not part of the CLI: compiled only by scripts/test-docs.py into a
//! copy of the released source (as a test module of src/backend.rs) to prove that the
//! output shown in docs/linux and docs/windows is what the released code prints.
//!
//! Each case carries the exact stdin and options a documented command gave the real CLI
//! (recorded while it ran headless) and the rows a user ticks. The case replays what
//! happens after Submit: the host reports the ticked controls as form entries
//! (`selection` = row index), `selection()` validates them, `input::parse` and
//! `output::encode` produce the bytes written to stdout.
use super::{selection, Rejection};
use crate::model::{InputFormat, OutputFormat, Outcome};
use clap::ValueEnum;
use serde_json::{json, Value};

#[test]
fn doc_outputs() {
    let path = std::env::var("NHK_DOC_OUTPUT_CASES").expect("NHK_DOC_OUTPUT_CASES");
    let cases: Vec<Value> = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let mut failed = 0;
    for case in &cases {
        let name = case["name"].as_str().unwrap();
        let (ok, detail) = run(case);
        if !ok {
            failed += 1;
        }
        println!("DOC-OUTPUT {}\t{}\t{}", if ok { "PASS" } else { "FAIL" }, name, detail.replace('\n', "\\n"));
    }
    assert_eq!(failed, 0, "{failed} documented outputs differ");
}

fn run(case: &Value) -> (bool, String) {
    let input = InputFormat::from_str(case["input_format"].as_str().unwrap(), true).unwrap();
    let output = OutputFormat::from_str(case["output_format"].as_str().unwrap(), true).unwrap();
    let data = match crate::input::parse(
        case["stdin"].as_str().unwrap(),
        input,
        case["no_headers"].as_bool().unwrap(),
    ) {
        Ok(d) => d,
        Err(e) => return (false, format!("input refused: {e:#}")),
    };
    let entries: Vec<Value> = case["picks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| json!({"kind": "text", "name": "selection", "value": (p.as_u64().unwrap() - 1).to_string()}))
        .collect();
    let indices = match selection(
        &entries,
        data.rows.len(),
        case["multi"].as_bool().unwrap(),
        case["allow_empty"].as_bool().unwrap(),
    ) {
        Ok(i) => i,
        Err(Rejection::Empty) => {
            let want = case["expect_rejected"].as_str() == Some("empty");
            return (want, "Submit refused: nothing selected (window stays open)".into());
        }
        Err(Rejection::Invalid(m)) => return (false, format!("selection invalid: {m}")),
    };
    match crate::output::encode(&data, &Outcome::Selected { indices }, output) {
        Ok(bytes) => {
            let got = String::from_utf8(bytes).unwrap();
            match case["expect"].as_str() {
                Some(want) if want == got => (true, format!("prints {got:?}")),
                Some(want) => (false, format!("prints {got:?}, documented {want:?}")),
                None => (false, format!("prints {got:?}, documented a failure")),
            }
        }
        Err(e) => {
            let msg = format!("{e:#}");
            match case["expect_error"].as_str() {
                Some(want) if msg.contains(want) => (true, format!("fails: {msg}")),
                _ => (false, format!("fails: {msg}")),
            }
        }
    }
}
