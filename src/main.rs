mod backend;
mod input;
mod model;
mod output;
mod protocol;
mod render;
mod runner;
mod session;

use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand};
use model::{InputFormat, Mode, OutputFormat, Session};
use std::path::PathBuf;

#[derive(Parser, Debug)]
#[command(
    name = "nativehtmlkit",
    version,
    about = "Native HTML/CSS windows for shell pipelines (alias: nhk)"
)]
struct Cli {
    #[arg(
        long,
        global = true,
        help = "Explicit NativeHTMLKit Core host executable"
    )]
    host: Option<PathBuf>,
    #[command(subcommand)]
    action: Action,
}

#[derive(Debug, Args)]
struct InputArgs {
    #[arg(long, default_value = "lines", value_enum)]
    input_format: InputFormat,
    #[arg(long, help = "Treat first CSV/TSV row as data, not column headers")]
    no_headers: bool,
}

#[derive(Debug, Args)]
struct SelectArgs {
    #[command(flatten)]
    input: InputArgs,
    #[arg(long, help = "Allow selecting more than one row")]
    multi: bool,
    #[arg(long, help = "Permit Submit with nothing selected")]
    allow_empty: bool,
    #[arg(long, default_value = "same", value_enum)]
    output_format: OutputFormat,
    #[arg(long, default_value = "Select an item")]
    title: String,
    #[arg(long, help = "Path to trusted CSS file (no remote resources)")]
    css: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct ViewArgs {
    #[command(flatten)]
    input: InputArgs,
    #[arg(long, default_value = "Output viewer")]
    title: String,
    #[arg(long)]
    css: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct FormArgs {
    #[arg(long, help = "Trusted HTML fragment containing <form id=nhk-form>")]
    html: PathBuf,
    #[arg(long, default_value = "Input form")]
    title: String,
    #[arg(long)]
    css: Option<PathBuf>,
}

#[derive(Debug, Subcommand)]
enum Action {
    Select(SelectArgs),
    View(ViewArgs),
    Form(FormArgs),
    Doctor,
    #[command(name = "__backend", hide = true)]
    Backend {
        session_dir: PathBuf,
    },
}

fn read_file(path: Option<PathBuf>) -> Result<Option<String>> {
    path.map(|p| {
        let text = std::fs::read_to_string(&p).with_context(|| format!("read {}", p.display()))?;
        if text.len() > 256 * 1024 {
            anyhow::bail!("custom HTML or CSS file exceeds 256 KiB");
        }
        Ok(text)
    })
    .transpose()
}

fn make_session(
    mode: Mode,
    title: String,
    data: model::Data,
    multi: bool,
    allow_empty: bool,
    css: Option<PathBuf>,
    html: Option<PathBuf>,
) -> Result<Session> {
    // Core validates app.name as nonempty, <= 128 characters, no control characters.
    // Check here so the user gets a clear error instead of a host manifest failure.
    if title.trim().is_empty() || title.chars().count() > 128 || title.chars().any(char::is_control)
    {
        anyhow::bail!(
            "--title must be nonempty, at most 128 characters, with no control characters"
        );
    }
    Ok(Session {
        schema: 1,
        mode,
        title,
        data,
        multi,
        allow_empty,
        css: read_file(css)?,
        html: read_file(html)?,
    })
}

fn execute(cli: Cli) -> Result<i32> {
    match cli.action {
        Action::Doctor => {
            runner::doctor(cli.host.as_deref())?;
            Ok(0)
        }
        Action::Backend { session_dir } => {
            backend::run(&session_dir)?;
            Ok(0)
        }
        Action::Select(args) => {
            input::require_piped_stdin()?;
            let content = input::read_stdin()?;
            let data = input::parse(&content, args.input.input_format, args.input.no_headers)?;
            input::assert_usable(&data, Mode::Select)?;
            let configured = make_session(
                Mode::Select,
                args.title,
                data,
                args.multi,
                args.allow_empty,
                args.css,
                None,
            )?;
            runner::run(cli.host.as_deref(), configured, args.output_format)
        }
        Action::View(args) => {
            input::require_piped_stdin()?;
            let content = input::read_stdin()?;
            let data = input::parse(&content, args.input.input_format, args.input.no_headers)?;
            let configured =
                make_session(Mode::View, args.title, data, false, true, args.css, None)?;
            runner::run(cli.host.as_deref(), configured, OutputFormat::Same)
        }
        Action::Form(args) => {
            let configured = make_session(
                Mode::Form,
                args.title,
                input::empty_data(),
                false,
                false,
                args.css,
                Some(args.html),
            )?;
            runner::run(cli.host.as_deref(), configured, OutputFormat::Json)
        }
    }
}

fn main() {
    // clap exits with status 2 on usage errors, which would be indistinguishable from
    // "user cancelled". Map usage errors to 1; --help/--version still succeed with 0.
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => {
            let code = if error.use_stderr() { 1 } else { 0 };
            let _ = error.print();
            std::process::exit(code);
        }
    };
    let code = match execute(cli) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("nativehtmlkit: {error:#}");
            1
        }
    };
    std::process::exit(code);
}
