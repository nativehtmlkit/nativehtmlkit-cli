use crate::model::{Data, InputFormat, Row};
use anyhow::{anyhow, bail, Context, Result};
use serde_json::{Map, Value};
use std::collections::HashSet;
use std::io::{self, Read};

pub const MAX_INPUT_BYTES: u64 = 8 * 1024 * 1024;
pub const MAX_ROWS: usize = 2000;
pub const MAX_COLUMNS: usize = 32;

/// Refuse to block on an interactive terminal: `select`/`view` read records from a pipe.
pub fn require_piped_stdin() -> Result<()> {
    use std::io::IsTerminal;
    if io::stdin().is_terminal() {
        bail!("stdin is a terminal; pipe records in, e.g. `printf 'a\\nb\\n' | nhk select`");
    }
    Ok(())
}

pub fn read_stdin() -> Result<String> {
    let mut bytes = Vec::new();
    io::stdin()
        .lock()
        .take(MAX_INPUT_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_INPUT_BYTES {
        bail!("input exceeds 8 MiB; use a prefiltered pipeline or smaller selection");
    }
    String::from_utf8(bytes).context("stdin must contain UTF-8; use ConvertTo-Json or UTF-8 output")
}

pub fn parse(source: &str, format: InputFormat, no_headers: bool) -> Result<Data> {
    let data = match format {
        InputFormat::Lines => parse_lines(source),
        InputFormat::Csv => parse_delimited(source, b',', no_headers, format)?,
        InputFormat::Tsv => parse_delimited(source, b'\t', no_headers, format)?,
        InputFormat::Json => parse_json(source, format)?,
        InputFormat::Ndjson => parse_ndjson(source, format)?,
    };
    validate(&data)?;
    Ok(data)
}

fn validate(data: &Data) -> Result<()> {
    if data.rows.len() > MAX_ROWS {
        bail!(
            "{} rows exceeds the {}-row initial GUI limit",
            data.rows.len(),
            MAX_ROWS
        );
    }
    if data.columns.len() > MAX_COLUMNS {
        bail!(
            "{} columns exceeds the {}-column limit",
            data.columns.len(),
            MAX_COLUMNS
        );
    }
    for (index, row) in data.rows.iter().enumerate() {
        if row.cells.len() != data.columns.len() {
            bail!("row {} does not match the column count", index + 1);
        }
    }
    Ok(())
}

fn parse_lines(s: &str) -> Data {
    let rows = s
        .lines()
        .map(|line| {
            let line = line.strip_suffix('\r').unwrap_or(line).to_string();
            Row {
                cells: vec![line.clone()],
                value: Value::String(line),
            }
        })
        .collect();
    Data {
        format: InputFormat::Lines,
        columns: vec!["Value".into()],
        rows,
    }
}

fn parse_delimited(s: &str, delimiter: u8, no_headers: bool, format: InputFormat) -> Result<Data> {
    let mut reader = csv::ReaderBuilder::new()
        .delimiter(delimiter)
        .has_headers(!no_headers)
        .flexible(false)
        .from_reader(s.as_bytes());
    let mut records: Vec<Vec<String>> = Vec::new();
    let columns = if no_headers {
        let iter = reader.records();
        for record in iter {
            let record = record.context("malformed CSV/TSV record")?;
            records.push(record.iter().map(String::from).collect());
            if records.len() > MAX_ROWS {
                bail!("too many records");
            }
        }
        let n = records.first().map(|r| r.len()).unwrap_or(1);
        (1..=n).map(|n| format!("column_{n}")).collect()
    } else {
        let head = reader.headers().context("invalid delimited header")?;
        if head.is_empty() {
            bail!("expected at least one header column");
        }
        let names: Vec<String> = head.iter().map(String::from).collect();
        for record in reader.records() {
            let record = record.context("malformed CSV/TSV record")?;
            records.push(record.iter().map(String::from).collect());
            if records.len() > MAX_ROWS {
                bail!("too many records");
            }
        }
        names
    };
    if columns.len() > MAX_COLUMNS {
        bail!("too many columns");
    }
    // A duplicated column name would silently overwrite a value when exporting
    // CSV/TSV as JSON; reject it rather than corrupting a pipeline result.
    let mut names = HashSet::new();
    if columns.iter().any(|name| !names.insert(name)) {
        bail!("duplicate CSV/TSV column names cannot be represented as JSON objects");
    }
    let rows = records
        .into_iter()
        .map(|cells| {
            let mut map = Map::new();
            for (k, v) in columns.iter().zip(&cells) {
                map.insert(k.clone(), Value::String(v.clone()));
            }
            Row {
                cells,
                value: Value::Object(map),
            }
        })
        .collect();
    Ok(Data {
        format,
        columns,
        rows,
    })
}

fn parse_json(s: &str, format: InputFormat) -> Result<Data> {
    if s.trim().is_empty() {
        return Ok(data_from_values(Vec::new(), format));
    }
    let parsed: Value = serde_json::from_str(s).context("invalid JSON input")?;
    let values = match parsed {
        Value::Array(v) => v,
        other => vec![other],
    };
    Ok(data_from_values(values, format))
}

fn parse_ndjson(s: &str, format: InputFormat) -> Result<Data> {
    let mut values = Vec::new();
    for (i, line) in s.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        values.push(
            serde_json::from_str(line).with_context(|| format!("invalid NDJSON line {}", i + 1))?,
        );
        if values.len() > MAX_ROWS {
            bail!("too many NDJSON rows");
        }
    }
    Ok(data_from_values(values, format))
}

fn data_from_values(values: Vec<Value>, format: InputFormat) -> Data {
    let mut columns: Vec<String> = Vec::new();
    if values.iter().all(|v| v.is_object()) {
        for v in &values {
            if let Some(map) = v.as_object() {
                for k in map.keys() {
                    if !columns.contains(k) {
                        columns.push(k.clone());
                    }
                }
            }
            if columns.len() > MAX_COLUMNS {
                break;
            }
        }
    } else {
        columns.push("Value".into());
    }
    if columns.is_empty() {
        columns.push("Value".into());
    }
    let rows = values
        .into_iter()
        .map(|value| {
            // An object with a single key called "Value" is still an object row.
            // Do not accidentally stringify it as the whole JSON document.
            let cells = if columns.len() == 1 && columns[0] == "Value" && !value.is_object() {
                vec![display_value(&value)]
            } else {
                columns
                    .iter()
                    .map(|key| display_value(value.get(key).unwrap_or(&Value::Null)))
                    .collect()
            };
            Row { value, cells }
        })
        .collect();
    Data {
        format,
        columns,
        rows,
    }
}

fn display_value(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        Value::Bool(_) | Value::Number(_) => value.to_string(),
        _ => value.to_string(),
    }
}

pub fn empty_data() -> Data {
    Data {
        format: InputFormat::Json,
        columns: vec!["Value".into()],
        rows: Vec::new(),
    }
}

pub fn assert_usable(data: &Data, mode: crate::model::Mode) -> Result<()> {
    if data.rows.is_empty() && mode == crate::model::Mode::Select {
        return Err(anyhow!(
            "no selectable input rows; stdin was empty or contained no records"
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lines_preserve_unicode_and_trailing_empty_fields() {
        let d = parse("alpha\nPříliš 😀\n", InputFormat::Lines, false).unwrap();
        assert_eq!(d.rows.len(), 2);
        assert_eq!(d.rows[1].value, Value::String("Příliš 😀".into()));
    }
    #[test]
    fn csv_quotes() {
        let d = parse("name,comment\na,\"hello,world\"\n", InputFormat::Csv, false).unwrap();
        assert_eq!(d.rows[0].cells[1], "hello,world");
        assert_eq!(d.rows[0].value["name"], "a");
    }
    #[test]
    fn ndjson_works() {
        let d = parse("{\"x\":1}\n{\"x\":2}\n", InputFormat::Ndjson, false).unwrap();
        assert_eq!(d.rows.len(), 2);
        assert_eq!(d.rows[0].value["x"], 1);
    }
    #[test]
    fn malformed_json_rejected() {
        assert!(parse("[bad]", InputFormat::Json, false).is_err());
    }
    #[test]
    fn single_value_key_object_displays_field_not_entire_object() {
        let data = parse(
            r#"[{"Value":"one"},{"Value":"two"}]"#,
            InputFormat::Json,
            false,
        )
        .unwrap();
        assert_eq!(data.rows[0].cells, vec!["one".to_owned()]);
        assert_eq!(data.rows[1].cells, vec!["two".to_owned()]);
    }
    #[test]
    fn duplicate_csv_columns_are_rejected_instead_of_losing_data() {
        assert!(parse("name,name\nfirst,second\n", InputFormat::Csv, false).is_err());
    }
    #[test]
    fn bounds() {
        let s = "a\n".repeat(MAX_ROWS + 1);
        assert!(parse(&s, InputFormat::Lines, false).is_err());
    }
}
