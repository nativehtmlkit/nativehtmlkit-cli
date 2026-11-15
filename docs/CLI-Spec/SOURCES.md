# Research sources and provenance

Research date: **2026-11-15**. These links are research references, not endorsement or license permission to copy code. Core references were inspected through the connected GitHub repository. Public docs were consulted separately. No native runtime tests were executed while preparing this specification.

## Primary source: existing UI4ME Core repository

- Repository: https://github.com/ui4me/ui4me-core
- Reviewed main commit: https://github.com/ui4me/ui4me-core/commit/c6fd71dc5c15dcdfdcdc1500dc156c1b929c216c
- Rust native host CLI: https://github.com/ui4me/ui4me-core/blob/main/crates/ui4me-host/src/main.rs
- Host backend capture and logging: https://github.com/ui4me/ui4me-core/blob/main/crates/ui4me-host/src/backend.rs and https://github.com/ui4me/ui4me-core/blob/main/crates/ui4me-host/src/logging.rs
- Current host protocol: https://github.com/ui4me/ui4me-core/blob/main/docs/reference/protocol.md
- Native host architecture: https://github.com/ui4me/ui4me-core/blob/main/docs/concepts/architecture.md
- Native HTML/CSS scope: https://github.com/ui4me/ui4me-core/blob/main/docs/concepts/html-css-scope.md
- Supported platforms and known limitations: https://github.com/ui4me/ui4me-core/blob/main/docs/guides/platforms.md
- Rust host config and manifest: https://github.com/ui4me/ui4me-core/blob/main/crates/ui4me-host/src/config.rs
- Existing Python build packaging: https://github.com/ui4me/ui4me-core/blob/main/setup.py
- Existing Python publication: https://github.com/ui4me/ui4me-core/blob/main/.github/workflows/publish.yaml
- Existing PowerShell publication and Python-wheel coupling: https://github.com/ui4me/ui4me-core/blob/main/.github/workflows/publish-powershell.yaml
- Release qualification and version alignment: https://github.com/ui4me/ui4me-core/blob/main/docs/release/publishing.md

**Scope note:** `main` might move after the reviewed commit. All migration implementation must re-check the current upstream state and preserve any changes made since this inspection.

## Public comparator/standards sources

- Microsoft `Out-GridView` and `-PassThru` selection: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/out-gridview
- Charmbracelet Gum documented commands, stdout-friendly TUI workflows: https://github.com/charmbracelet/gum
- KDE KDialog developer documentation: https://develop.kde.org/docs/administration/kdialog/
- Zenity manual list/checklist/multiple/print-column options: https://man.archlinux.org/man/zenity.1.en
- IETF CSV RFC 4180: https://datatracker.ietf.org/doc/rfc4180/
- MCP stdio transport (2026-07-28): https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2026-07-28/basic/transports/stdio.mdx
- JSON Schema official 2020-12 spec: https://json-schema.org/draft/2020-12
- JSON Lines format behavior: https://jsonlines.org/ and https://nlohmann.github.io/json/features/parsing/json_lines/
- PowerShell native pipeline semantics: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_pipelines
- PowerShell encoding behavior: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_character_encoding
- PowerShell redirection 7.4 byte preservation: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_redirection
- Microsoft interactive window stations/desktops: https://learn.microsoft.com/en-us/windows/win32/winstation/window-station-and-desktop-creation
- Microsoft Windows interactive service limitations: https://learn.microsoft.com/en-us/windows/desktop/Services/interactive-services
- OWASP CSV injection: https://wstg.owasp.org/latest/4-Web_Application_Security_Testing/07-Injection/21-CSV_Injection/

## Research interpretation policy

- Source documentation describes the **current implementation's documented behavior**, not a guarantee of untested future CLI operations.
- The `nhk` command, form schema and result receipts in this package are **proposals**. There is no claim they are implemented or published.
- The exact legal availability of the `NativeHTMLKit` brand, `nhk` executable, domain names, Rust crates, and registries remains unverified. Validate before public package publication.
