use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "kebab-case")]
pub enum InputFormat {
    Lines,
    Csv,
    Tsv,
    Json,
    Ndjson,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, ValueEnum)]
#[serde(rename_all = "snake_case")]
#[value(rename_all = "kebab-case")]
pub enum OutputFormat {
    Same,
    Lines,
    Csv,
    Tsv,
    Json,
    Ndjson,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Select,
    View,
    Form,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Row {
    pub cells: Vec<String>,
    pub value: Value,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Data {
    pub format: InputFormat,
    pub columns: Vec<String>,
    pub rows: Vec<Row>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Session {
    pub schema: u32,
    pub mode: Mode,
    pub title: String,
    pub data: Data,
    pub multi: bool,
    pub allow_empty: bool,
    pub css: Option<String>,
    pub html: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Outcome {
    Selected { indices: Vec<usize> },
    Form { entries: Vec<Value> },
    Viewed,
}
