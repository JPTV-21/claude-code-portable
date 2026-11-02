<p align="center">
  <strong>Portable</strong>, zero-dependency setup for the ClaudeX launcher and
  the Claude Code CLI — one self-contained folder per platform and architecture.
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

A single target installs directly into the install directory:

```text
install-dir/
  ClaudeX.exe                  launcher (ClaudeX on macOS/Linux)
  claudex-config.json
  claudex-theme.json           created on first launch
  data/                        portable CLAUDE_CONFIG_DIR
  bin/<arch>/<platform>/claude[.exe]
```

With `all`, every target gets its own self-contained folder, so launchers never
overwrite each other:

```text
install-dir/
  windows-x64/
  windows-arm64/
  macos-x64/
  macos-arm64/
  linux-x64/
  linux-arm64/
```

Each folder contains its own launcher, `claudex-config.json`, `data/`, and
`bin/`.

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
