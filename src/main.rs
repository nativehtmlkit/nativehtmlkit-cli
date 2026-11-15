// Failures are terminal, cold paths (at most one per process); boxing them would only add
// noise at every construction site.
#![allow(clippy::result_large_err)]

mod backend;
mod diag;
mod error;
mod input;
mod model;
mod output;
mod protocol;
mod render;
mod runner;
mod session;
mod transport;

use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand};
use error::{code, Failure};
use model::{InputFormat, Mode, OutputFormat, Runtime, Session};
use std::io::Read;
use std::path::PathBuf;
use std::time::Duration;

/// Seconds on the command line, fractions allowed (`0.5`); at most one day.
fn seconds(text: &str) -> Result<Duration, String> {
    match text.trim().parse::<f64>() {
        Ok(value) if value.is_finite() && (0.0..=86_400.0).contains(&value) => {
            Ok(Duration::from_secs_f64(value))
        }
        _ => Err("expected a number of seconds between 0 and 86400".to_owned()),
    }
}

fn positive_seconds(text: &str) -> Result<Duration, String> {
    match seconds(text)? {
        value if value >= Duration::from_millis(10) => Ok(value),
        _ => Err("expected at least 0.01 seconds".to_owned()),
    }
}

#[derive(Parser, Debug)]
#[command(
    name = "nativehtmlkit",
    version,
    about = "Native HTML/CSS windows for shell pipelines (alias: nhk)",
    after_help = "Exit status: 0 submitted/viewed, 1 error, 2 cancelled, 124 --timeout expired, 130 Ctrl+C/SIGINT, 143 SIGTERM, 129 SIGHUP."
)]
struct Cli {
    #[arg(
        long,
        global = true,
        help = "Explicit NativeHTMLKit Core host executable"
    )]
    host: Option<PathBuf>,
    #[arg(
        long,
        global = true,
        value_enum,
        value_name = "LEVEL",
        help = "Structured diagnostics on stderr for the CLI and the Core host [default: $NATIVEHTMLKIT_DIAGNOSTICS or normal]"
    )]
    diagnostics: Option<diag::Level>,
    #[arg(
        long,
        global = true,
        value_name = "SECONDS",
        value_parser = positive_seconds,
        default_value = "30",
        help = "Longest wait for the host to answer one request before it is treated as hung"
    )]
    rpc_timeout: Duration,
    #[arg(
        long,
        global = true,
        value_name = "SECONDS",
        value_parser = seconds,
        default_value = "5",
        help = "Idle time between host liveness probes while the window is open; 0 disables them"
    )]
    liveness_interval: Duration,
    #[arg(
        long,
        global = true,
        value_name = "SECONDS",
        value_parser = positive_seconds,
        default_value = "15",
        help = "Longest wait for the host to open the window"
    )]
    startup_timeout: Duration,
    #[arg(
        long,
        global = true,
        value_name = "SECONDS",
        value_parser = positive_seconds,
        help = "Close the window and exit 124 if the user has not decided in time [default: wait indefinitely]"
    )]
    timeout: Option<Duration>,
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

const MAX_ASSET_BYTES: u64 = 256 * 1024;

/// Read a trusted `--html`/`--css` file. The read itself is bounded, so a device or an
/// endless file fails immediately instead of exhausting memory.
fn read_file(path: Option<PathBuf>) -> Result<Option<String>> {
    path.map(|p| {
        let mut bytes = Vec::new();
        std::fs::File::open(&p)
            .and_then(|file| file.take(MAX_ASSET_BYTES + 1).read_to_end(&mut bytes))
            .with_context(|| format!("read {}", p.display()))?;
        if bytes.len() as u64 > MAX_ASSET_BYTES {
            anyhow::bail!("custom HTML or CSS file exceeds 256 KiB");
        }
        String::from_utf8(bytes).with_context(|| format!("{} is not UTF-8", p.display()))
    })
    .transpose()
}

struct SessionSpec {
    mode: Mode,
    title: String,
    data: model::Data,
    multi: bool,
    allow_empty: bool,
    css: Option<PathBuf>,
    html: Option<PathBuf>,
}

fn make_session(spec: SessionSpec, runtime: Runtime) -> Result<Session> {
    // Core validates app.name as nonempty, <= 128 characters, no control characters.
    // Check here so the user gets a clear error instead of a host manifest failure.
    let title = spec.title;
    if title.trim().is_empty() || title.chars().count() > 128 || title.chars().any(char::is_control)
    {
        return Err(Failure::new(
            code::USAGE,
            "--title must be nonempty, at most 128 characters, with no control characters",
        )
        .into());
    }
    let html = read_file(spec.html)?;
    if let (Mode::Form, Some(fragment)) = (spec.mode, &html) {
        // Without this form Submit can never succeed; say so before a window opens rather
        // than after the user has filled everything in.
        let compact: String = fragment.chars().filter(|c| !c.is_whitespace()).collect();
        if !["id=\"nhk-form\"", "id='nhk-form'", "id=nhk-form"]
            .iter()
            .any(|needle| compact.contains(needle))
        {
            anyhow::bail!("--html must contain <form id=\"nhk-form\"> with the controls to submit");
        }
    }
    let session = Session {
        schema: 1,
        mode: spec.mode,
        title,
        data: spec.data,
        multi: spec.multi,
        allow_empty: spec.allow_empty,
        css: read_file(spec.css)?,
        html,
        runtime,
    };
    // Everything the host would refuse about the document is refused here, before a host
    // process or a window exists.
    render::validate(&session)?;
    Ok(session)
}

fn piped_records(args: &InputArgs) -> Result<model::Data> {
    input::require_piped_stdin()?;
    let content = input::read_stdin()?;
    input::parse(&content, args.input_format, args.no_headers)
}

fn execute(cli: Cli, runtime: Runtime) -> Result<i32> {
    let options = runner::Options {
        host: cli.host,
        startup_timeout: cli.startup_timeout,
        diagnostics_flag: cli.diagnostics,
    };
    // Everything that can go wrong before the host starts is the caller's input.
    let input_error = |error| error::tag(error, code::INPUT);
    let (spec, format) = match cli.action {
        Action::Doctor => {
            runner::doctor(options.host.as_deref())?;
            return Ok(0);
        }
        Action::Backend { session_dir } => {
            backend::run(&session_dir)?;
            return Ok(0);
        }
        Action::Select(args) => {
            let data = piped_records(&args.input).map_err(input_error)?;
            input::assert_usable(&data, Mode::Select).map_err(input_error)?;
            let spec = SessionSpec {
                mode: Mode::Select,
                title: args.title,
                data,
                multi: args.multi,
                allow_empty: args.allow_empty,
                css: args.css,
                html: None,
            };
            (spec, args.output_format)
        }
        Action::View(args) => {
            let spec = SessionSpec {
                mode: Mode::View,
                title: args.title,
                data: piped_records(&args.input).map_err(input_error)?,
                multi: false,
                allow_empty: true,
                css: args.css,
                html: None,
            };
            (spec, OutputFormat::Same)
        }
        Action::Form(args) => {
            let spec = SessionSpec {
                mode: Mode::Form,
                title: args.title,
                data: input::empty_data(),
                multi: false,
                allow_empty: false,
                css: args.css,
                html: Some(args.html),
            };
            (spec, OutputFormat::Json)
        }
    };
    let session = make_session(spec, runtime).map_err(input_error)?;
    runner::run(&options, session, format)
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
    let backend = matches!(cli.action, Action::Backend { .. });
    let level = cli.diagnostics.unwrap_or_else(|| {
        std::env::var(diag::LEVEL_ENV)
            .map(|text| diag::Level::from_env_text(&text))
            .unwrap_or_default()
    });
    let inherited = std::env::var(diag::SESSION_ENV).ok();
    let (session_id, rejected) = diag::resolve_session_id(inherited.as_deref());
    if !backend {
        // The backend records to a file in its session directory instead (see diag.rs).
        diag::init_stderr(level, &session_id, "launcher");
        if rejected {
            diag::record(diag::Level::Normal, "session_id.replaced")
                .tag("reason", "inherited_value_not_identifier_shaped")
                .emit();
        }
    }
    let runtime = Runtime {
        rpc_timeout_ms: cli.rpc_timeout.as_millis() as u64,
        liveness_interval_ms: cli.liveness_interval.as_millis() as u64,
        deadline_ms: cli.timeout.map(|limit| limit.as_millis() as u64),
        diagnostics: level,
        session_id,
    };
    let code = match execute(cli, runtime) {
        Ok(code) => code,
        Err(error) => {
            let failure = error::classify(&error, code::INTERNAL);
            if !backend {
                let level = if failure.is_critical() {
                    diag::Level::Normal
                } else {
                    diag::Level::Debug
                };
                diag::record(level, "session.failed")
                    .failure(&failure)
                    .emit();
            }
            eprintln!("nativehtmlkit: {failure}");
            1
        }
    };
    std::process::exit(code);
}
