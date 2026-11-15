# Performance, quality budgets and observability

The project is at a stage where performance should be **measured**, not guessed. These are the required benchmark dimensions and baseline-pinning rules, not fabricated throughput claims.

## Workload matrix

| Workload | Measurements |
|---|---|
| No-host `nhk --help` / `doctor` | binary startup, CPU and memory, compatibility-check latency |
| P1 3/100/2,000 line rows | stdin parse time, time to visible window, initial paint, event-to-selection latency, peak memory |
| P2 200/2,000 JSON objects × 5/24 fields | parse time, HTML generation bytes, page-switch latency, search latency, output serialization time |
| Large fields up to 64KiB/record | display truncation correctness, original result preservation, HTML size |
| Cancel and Submit | time to host process exit, receipt commit latency, temp cleanup |
| 10 simultaneous instances | cross-run isolation, open-window reliability, OS handles and memory |
| Broken stderr/stdout consumers | no GUI/main-thread deadlock, bounded queues, correct failure status |

## Benchmark policy

- Report median and p95 for each scenario across repeated cold/warm runs. Record exact CPU, RAM, OS, session, Core hash, CLI hash and input fixture SHA.
- Attribute time separately to stdin read/parse, host spawn, OS window startup, HTML document load, user interaction, receipt commit, host shutdown and stdout write.
- Record peak RSS separately for launcher, host and backend; aggregate totals only after these three are visible.
- Compare every new build against **its own same-machine baseline**; don't invent universal startup claims from unrelated machines. Propose alert threshold for regressions (for example 25% median/p95 increase) only after initial baseline has been measured.
- Verify `no-UI-headless` tests don't accidentally count as desktop paint performance.

## Diagnostics

- `nhk doctor --json` reports target OS/arch, host located or missing, host SHA/build version, protocol support, desktop prerequisites and supported input-format features. Do not include secrets, user process paths or arbitrary environment variables by default.
- Opt-in `--verbose` writes structured lifecycle milestones to **stderr**, not stdout, and redacts session nonce and protocol token.
- A failed CLI test should preserve anonymized: phase, exit code, host version/build, cause, OS, protocol capabilities and elapsed durations.
- CLI runtime logs must never contain full stdin, submitted passwords, tokens or raw result values unless a dedicated opt-in secure debug mode is explicitly designed.

## Optional future improvements

- Performance-driven virtualization for 10,000+ records with filtered-row metadata and minimal DOM updates.
- Streaming mode with bounded ingest channels, explicit drop/backpressure strategy and UI coalescing.
- Native diagnostic screenshots for CI, without acquiring full desktop screenshots that include unrelated private content.
