use crate::model::{Data, InputFormat, Outcome, OutputFormat};
use anyhow::{bail, Context, Result};
use serde_json::Value;
use std::collections::HashSet;

pub fn encode(data: &Data, outcome: &Outcome, format: OutputFormat) -> Result<Vec<u8>> {
    let selected = match outcome {
        Outcome::Selected { indices } => indices,
        Outcome::Form { entries } => {
            let mut bytes = serde_json::to_vec(&serde_json::json!({"entries": entries}))?;
            bytes.push(b'\n');
            return Ok(bytes);
        }
        Outcome::Viewed | Outcome::TimedOut => return Ok(Vec::new()),
    };
    let mut seen = HashSet::new();
    for &i in selected {
        if i >= data.rows.len() || !seen.insert(i) {
            bail!("invalid or duplicate selection index {i}");
        }
    }
    let fmt = match format {
        OutputFormat::Same => match data.format {
            InputFormat::Lines => OutputFormat::Lines,
            InputFormat::Csv => OutputFormat::Csv,
            InputFormat::Tsv => OutputFormat::Tsv,
            InputFormat::Json => OutputFormat::Json,
            InputFormat::Ndjson => OutputFormat::Ndjson,
        },
        other => other,
    };
    match fmt {
        OutputFormat::Same => unreachable!(),
        OutputFormat::Lines => {
            let mut output = Vec::new();
            for &i in selected {
                let row = &data.rows[i];
                let val = if let Value::String(s) = &row.value {
                    s.clone()
                } else {
                    row.cells.join("\t")
                };
                // Delimited line output must not silently inject multiple output records.
                if val.contains('\n') || val.contains('\r') {
                    bail!("selected value contains newline: use --output-format json or ndjson");
                }
                output.extend(val.as_bytes());
                output.push(b'\n');
            }
            Ok(output)
        }
        OutputFormat::Json => {
            let rows: Vec<_> = selected
                .iter()
                .map(|&i| data.rows[i].value.clone())
                .collect();
            let mut b = serde_json::to_vec(&rows)?;
            b.push(b'\n');
            Ok(b)
        }
        OutputFormat::Ndjson => {
            let mut b = Vec::new();
            for &i in selected {
                b.extend(serde_json::to_vec(&data.rows[i].value)?);
                b.push(b'\n');
            }
            Ok(b)
        }
        OutputFormat::Csv | OutputFormat::Tsv => {
            let delimiter = if fmt == OutputFormat::Csv {
                b','
            } else {
                b'\t'
            };
            let mut w = csv::WriterBuilder::new()
                .delimiter(delimiter)
                .from_writer(Vec::new());
            w.write_record(&data.columns)?;
            for &i in selected {
                w.write_record(&data.rows[i].cells)?;
            }
            w.into_inner().context("CSV/TSV writer failed")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::parse;
    #[test]
    fn exact_selection_preserves_order_and_data() {
        let data = parse("first\nsecond\nthird\n", InputFormat::Lines, false).unwrap();
        let bytes = encode(
            &data,
            &Outcome::Selected {
                indices: vec![2, 0],
            },
            OutputFormat::Same,
        )
        .unwrap();
        assert_eq!(bytes, b"third\nfirst\n");
    }
    #[test]
    fn json_selection_is_one_array_with_a_trailing_newline() {
        let data = parse("[{\"a\":1}]", InputFormat::Json, false).unwrap();
        assert_eq!(
            encode(
                &data,
                &Outcome::Selected { indices: vec![0] },
                OutputFormat::Same
            )
            .unwrap(),
            b"[{\"a\":1}]\n"
        );
    }
    #[test]
    /// Key order and number text (big integers, trailing zeros) survive; serde_json only
    /// normalises an exponent sign (`1e3` -> `1e+3`), which is the same JSON number.
    fn json_records_keep_key_order_and_number_text() {
        let input = r#"[{"z":1,"a":12345678901234567890123,"m":1e3,"f":2.50}]"#;
        let data = parse(input, InputFormat::Json, false).unwrap();
        assert_eq!(data.columns, ["z", "a", "m", "f"]);
        let out = encode(
            &data,
            &Outcome::Selected { indices: vec![0] },
            OutputFormat::Ndjson,
        )
        .unwrap();
        assert_eq!(
            out,
            b"{\"z\":1,\"a\":12345678901234567890123,\"m\":1e+3,\"f\":2.50}\n"
        );
    }

    #[test]
    fn malformed_selection_fails_closed() {
        let data = parse("a\n", InputFormat::Lines, false).unwrap();
        assert!(encode(
            &data,
            &Outcome::Selected { indices: vec![42] },
            OutputFormat::Lines
        )
        .is_err());
        assert!(encode(
            &data,
            &Outcome::Selected {
                indices: vec![0, 0]
            },
            OutputFormat::Lines
        )
        .is_err());
    }
}
