# Install the CLI and find its host

The CLI is a single executable that drives a separate **Core host** executable, which draws
the window. Release archives contain both, already matched.

## Linux x86-64

```bash
gh release download v0.1.2 -R nativehtmlkit/nativehtmlkit-cli -p '*linux-x64*' -p SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS          # nativehtmlkit-cli-v0.1.2-linux-x64.tar.gz: OK
tar -xzf nativehtmlkit-cli-v0.1.2-linux-x64.tar.gz
cd nativehtmlkit-cli-v0.1.2-linux-x64
sha256sum -c SHA256SUMS                           # the files inside the archive
./nhk doctor
```

The directory holds `nativehtmlkit`, the alias `nhk` (a symbolic link), `nativehtmlkit-host`
(Core 1.0.3), `manifest.json` (hashes, source commits, protocol version), licences and
`examples/sample-form.html`. To put it on `PATH`, link the executable and leave the host where
it is; the CLI resolves its own path and finds the host beside it:

```bash
sudo mv nativehtmlkit-cli-v0.1.2-linux-x64 /opt/nativehtmlkit-cli
ln -s /opt/nativehtmlkit-cli/nativehtmlkit ~/.local/bin/nativehtmlkit
ln -s /opt/nativehtmlkit-cli/nativehtmlkit ~/.local/bin/nhk
nativehtmlkit doctor
```

## Windows x86-64

```powershell
gh release download v0.1.2 -R nativehtmlkit/nativehtmlkit-cli -p '*windows-x64*' -p SHA256SUMS
(Get-FileHash .\nativehtmlkit-cli-v0.1.2-windows-x64.zip -Algorithm SHA256).Hash   # compare with SHA256SUMS
Expand-Archive .\nativehtmlkit-cli-v0.1.2-windows-x64.zip -DestinationPath C:\Tools
$env:Path += ';C:\Tools\nativehtmlkit-cli-v0.1.2-windows-x64'
nativehtmlkit doctor
```

The archive contains `nativehtmlkit.exe`, `nhk.exe` (an identical copy),
`nativehtmlkit-host.exe` and the same metadata files. Keep the executables together.

## Which host is used

`--host PATH` > `NATIVEHTMLKIT_HOST_BINARY` > `nativehtmlkit-host` beside the CLI > `PATH`
([details](../reference/global-options.md#host-discovery)). `nativehtmlkit doctor` prints
the choice and the host's version:

```text
NativeHTMLKit CLI 0.1.2
Core host: /opt/nativehtmlkit-cli/nativehtmlkit-host
nativehtmlkit-host 1.0.3
```

CLI 0.1.2 is qualified with Core host 1.0.3. Use the override only for development:

```bash
NATIVEHTMLKIT_HOST_BINARY=$HOME/src/core/target/release/nativehtmlkit-host nativehtmlkit doctor
nativehtmlkit --host ./nativehtmlkit-host select < items.txt
```

## Uninstall

Delete the directory (and any links you made). The CLI writes no configuration; each session
uses a private temporary directory that is removed when the command ends (only a SIGKILLed CLI
leaves one behind, without user data in it).
