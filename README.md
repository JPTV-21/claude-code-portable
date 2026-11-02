<p align="center">
  <strong>Portable</strong>, zero-dependency setup for the ClaudeX launcher and
  the Claude Code CLI — all builds in one self-contained folder.
</p>

> **Unofficial project.** These scripts are independent and community-made.
> They are not affiliated with, endorsed by, or supported by Anthropic.
> “Claude” and “Claude Code” are trademarks of Anthropic. The scripts do not
> bundle Claude Code; you need your own installation and account to use it.

This repository contains **only the setup scripts**. The launcher binaries are
published in [JPTV-21/Claudex](https://github.com/JPTV-21/Claudex/releases);
the Claude Code CLI is downloaded from
[anthropics/claude-code](https://github.com/anthropics/claude-code/releases).

## Quick start (always the latest script)

### Windows

Windows PowerShell 5.1 is built into Windows 10/11. **No Git, curl, perl, or
other tools are required.**

```powershell
$p="$env:TEMP\claudex-setup.ps1"; iwr 'https://api.github.com/repos/JPTV-21/claude-code-portable/contents/setup-portable.ps1' -Headers @{'Accept'='application/vnd.github.raw';'User-Agent'='claudex-setup'} -UseBasicParsing -OutFile $p; iex (Get-Content $p -Raw)
```

This downloads the newest `setup-portable.ps1` from the default branch and runs
it in the current directory. The script then asks for the target platform,
architecture, and install directory.

To pass options to an online run:

```powershell
$p="$env:TEMP\claudex-setup.ps1"; iwr 'https://api.github.com/repos/JPTV-21/claude-code-portable/contents/setup-portable.ps1' -Headers @{'Accept'='application/vnd.github.raw';'User-Agent'='claudex-setup'} -UseBasicParsing -OutFile $p; & ([scriptblock]::Create((Get-Content $p -Raw))) -All -InstallDir D:\ClaudexAll
```

### Linux / macOS

Download the latest script, then run it:

```sh
curl -fsSL -H 'Accept: application/vnd.github.raw' -H 'User-Agent: claudex-setup' \
  'https://api.github.com/repos/JPTV-21/claude-code-portable/contents/setup-portable.sh' \
  -o setup-portable.sh
sh setup-portable.sh
```

The POSIX script uses only standard system tools: `sh`, `curl`, `perl` with
`JSON::PP`, and `find` / `awk` / `tar`.

## What the scripts do

- Detect the current platform and architecture and use them as defaults.
- Let you pick another target. Both the platform prompt and the architecture
  prompt accept `all`: platform `all` covers Windows/macOS/Linux, architecture
  `all` covers x64/arm64, and `all` in both gives the six combinations.
- Download the matching ClaudeX release and Claude Code CLI with retry and
  byte-range resume.
- Show a live progress meter with transferred/total size and speed.
- Write a portable `claudex-config.json` pointing at `./data` and
  `./bin/<arch>/<platform>`.

## Layout

Every build is installed into the same folder and named after its platform and
architecture, so all variants can coexist without overwriting each other:

```text
install-dir/
  ClaudeX-windows-x64.exe
  ClaudeX-windows-arm64.exe
  ClaudeX-macos-x64
  ClaudeX-macos-arm64
  ClaudeX-linux-x64
  ClaudeX-linux-arm64
  claudex-config.json
  claudex-theme.json           created on first launch
  data/                        portable CLAUDE_CONFIG_DIR
  bin/x64/windows/claude.exe
  bin/arm64/windows/claude.exe
  bin/x64/macos/claude
  ...
```

Only the selected targets are downloaded. A single target produces just its own
launcher, for example `ClaudeX-linux-arm64`.

Launcher binaries always live in the install root (`./`), never inside `bin/`.
`claudex-config.json` points `claudePath` at the host target when it was
installed, otherwise at the first selected target.

## Options

| PowerShell | sh | Meaning |
| --- | --- | --- |
| `-Update` | `--update` | Re-download ClaudeX and Claude Code even if present |
| `-NoClaudex` | `--no-claudex` | Skip the launcher download |
| `-NoClaude` | `--no-claude` | Skip the Claude Code download |
| `-Platform P` | `--platform P` | `windows`, `macos`, `linux`, or `all` |
| `-Architecture A` | `--arch A` | `x64`, `arm64`, or `all` |
| `-All` | `--all` | Install all six platform/architecture combinations |
| `-InstallDir D` | `--install-dir D` | Installation directory |
| `-Yes` | `--yes` | Non-interactive; use defaults and explicit options |
| `-NoProgress` | — | Disable the download progress meter |
| `-Repo OWNER/REPO` | `--claudex-repo OWNER/REPO` | Launcher repository (default `JPTV-21/Claudex`) |
| `-ClaudeRepo OWNER/REPO` | `--claude-repo OWNER/REPO` | Claude Code repository (default `anthropics/claude-code`) |
| `-Help` | `--help` | Show help |

### Unattended examples

```powershell
.\setup-portable.ps1 -All -InstallDir D:\ClaudexAll -Yes
.\setup-portable.ps1 -Platform windows -Architecture all -InstallDir D:\ClaudexWin -Yes
.\setup-portable.ps1 -Platform macos -Architecture arm64 -NoClaude -Yes
```

```bash
sh setup-portable.sh --all --install-dir /opt/claudex --yes
sh setup-portable.sh --platform linux --arch arm64 --no-claude --yes
```

### Proxy

Downloads go direct by default. Set `CLAUDEX_PROXY` to a proxy URL if your
network requires one:

```powershell
$env:CLAUDEX_PROXY = 'http://127.0.0.1:7890'
```

## Notes

- On Windows, the only non-PowerShell component used is the built-in
  `System32\tar.exe`, and only when installing macOS/Linux targets. Windows
  targets use `.zip` and `Expand-Archive`.
- Execution policy: if PowerShell blocks local scripts, use
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once, or run the online
  command above (it uses `iex` and does not save a script file).

## License

MIT — see [LICENSE](LICENSE).
