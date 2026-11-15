# Architecture decision records, tradeoffs and open issues

## ADR-001 — separate Rust CLI instead of a Python/PS wrapper

**Decision:** Rust `nhk` directly consumes the Core host's versioned local protocol. **Reason:** proves independent Core artifact; simplest developer distribution; no external runtime. **Cost:** Rust client must implement its own IPC framing/callback pump. **Alternatives:** Python CLI wrapper (rejected), `nhk` in-process renderer (rejected), separate GUI backend binary (deferred).

## ADR-002 — same executable is launcher and backend

**Decision:** external command and hidden internal `__internal-backend` share one binary. **Reason:** minimizes installation artifacts and reuse code. **Cost:** careful role/env authentication. **Alternative:** separate helper binary if isolation/security merits it later.

## ADR-003 — atomic file receipt first, not stdout relay

**Decision:** authenticated backend writes explicit, validated result receipt into private session folder; launcher prints selected original data. **Reason:** current Core captures and bounds backend stdout; keeps pipe semantics reliable. **Cost:** temp/ACL and crash cleanup. **Alternative:** inherited anonymous pipe/session socket, worth prototyping only if temp stage becomes bottleneck.

## ADR-004 — snapshot before window

**Decision:** input must reach EOF and remain within 4 MiB / 2,000 rows P1/P2 caps. **Reason:** deterministic results and bounded memory; eliminates initial streaming/cancellation race. **Cost:** streaming input doesn't display. **Future:** `--follow` uses producer/consumer with bounded queue and UI coalescing.

## ADR-005 — preserve original records

**Decision:** selected row identities point to canonical data; UI rendering is projection only. Output stays original input order. **Reason:** safe shell composability. **Cost:** backend and launcher must share validated index mapping; need tests for search/sort/paging and duplicate labels.

## ADR-006 — no v1 Core protocol break

**Decision:** keep current environment names/handshake while extracting repo. **Reason:** less migration risk and immediate reuse of qualified engine. **Cost:** old `UI4ME_*` wire identifiers persist temporarily. **Future:** deliberate protocol-v2 rebrand with client compatibility tests.

## ADR-007 — status 10 for user cancellation

**Decision:** normal Cancel/Escape/close prints nothing and exits 10. **Reason:** distinct from successful empty selection and operational error. **Cost:** shell pipeline operators may mask statuses absent `pipefail`; document this.

## Risk register

| Risk | Likelihood / impact | Owner / mitigation |
|---|---|---|
| Host lifecycle cannot guarantee cancel receipt before backend kill | Medium / High | CLI agent: test `before_close` decision race, patch lifecycle if necessary |
| Windows console detachment consumes stdout or loses ctrl events | Medium / High | keep wrapper a console binary; host detached separately; test `cmd`, PS 7, PS 5.1 |
| Linux systemd supervision interaction with outer CLI process | Medium / High | qualify kill-on-host-death and terminal-close including launcher PID tree |
| Rendering 2,000 records all at once is slow/breaches HTML frame | High / Medium | render 50/page and cap displayed text; microbenchmarks |
| Untrusted input HTML injection | Medium / High | strict escaping and native text operations; adversarial corpus |
| ABI/version drift after split | High / High | pin host artifact checksum; protocol fixture matrix; require capability check |
| Privileged or remote context doesn't have visible GUI | High / Medium | preflight and status 3; separate future interactive broker |
| Windows PowerShell 5.1 encodes UTF-8 differently | High / Medium | concrete examples, encoding tests, later native wrapper cmdlet |
| CLI name `nhk` conflicts with existing global command/package names | Unknown / Low | confirm namespace; reserve `nativehtmlkit` alternative |
| Broken pipe after partial stdout | Medium / Medium | error status 6, document non-atomic nature of arbitrary OS pipe writing |
| Unintended CSV formula execution after spreadsheet import | Medium / High | explicit warning and future opt-in spreadsheet-safe output; no silent data mutation |
| Build/release pipeline too coupled across repos | High / Medium | host-first immutable binary artifacts + hash and license provenance |

## Open questions — resolve by spike, not by debate

- What level of machine reproducibility will Core artifacts guarantee on Windows and Linux? Establish reproducibility/provenance definitions before publishing new names.
- Is the current native close/quit decision handler sufficient to write a cancellation receipt before host shutdown on both platforms? Build a small spike.
- Does the host support a fully accessible row-selection table with keyboard semantics without an additional Core feature? Verify with NVDA/AT-SPI.
- Which exact `nhk`/`nativehtmlkit` executable and GitHub package names are available? Confirm registration separately.
- Can P2 CSV preserve all values consistently using an existing parsing crate without surprising TSV semantics? Pick dialect and test fixtures.
- Should V1 stdout `result-json` be a selected-record envelope or always an index/result record? This ZIP specifies a proposed envelope; lock only when implemented.

## Explicit hold points

Pause **scope**, not progress, if a blocker arises: implement the smallest safe workaround with a regression test, document deviation, and preserve the initial CLI proof. Do not add a general daemon, browser, runtime dependencies or MCP just to avoid an engineering obstacle.
