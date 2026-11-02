<p align="center">
  <strong>Portable</strong> setup scripts for the ClaudeX launcher and the
  Claude Code CLI — one self-contained folder per platform and architecture.
</p>

> **Unofficial project.** These scripts are independent and community-made.
> They are not affiliated with, endorsed by, or supported by Anthropic.
> “Claude” and “Claude Code” are trademarks of Anthropic. The scripts do not
> bundle Claude Code; you need your own installation and account to use it.

This repository contains **only the setup scripts**. The launcher binaries are
published in [JPTV-21/Claudex](https://github.com/JPTV-21/Claudex/releases);
the Claude Code CLI is downloaded from
[anthropics/claude-code](https://github.com/anthropics/claude-code/releases).

## Requirements

- **Windows, PowerShell version:** PowerShell 5.1. Windows 10 1803+ already
  includes `curl.exe` and `tar.exe`, so no Git is required.
- **Windows, `.bat` version:** Git for Windows (Git Bash).
- **Linux / macOS:** POSIX `sh`, `curl`, `perl` with `JSON::PP`, and the
  standard `find` / `awk` / `tar` tools.

## Quick start

### Windows (no Git required)

```powershell
.\setup-portable.ps1
```

### Windows with Git for Windows

```powershell
.\setup-portable.bat
```

### Linux / macOS

```sh
sh setup-portable.sh
```

The scripts ask for:

- **Platform and architecture** — detected values are shown as defaults. Enter
  `all` to download all six combinations.
- **Install directory** — defaults to the script's folder. If the path does not
  exist, the script asks whether to create it.
- **Download progress** — a live meter with transferred/total size and speed.

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
| `-Architecture A` | `--arch A` | `x64` or `arm64` |
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
.\setup-portable.ps1 -Platform macos -Architecture arm64 -NoClaude -Yes
```

```bash
sh setup-portable.sh --all --install-dir /opt/claudex --yes
sh setup-portable.sh --platform linux --arch arm64 --no-claude --yes
```

## License

MIT — see [LICENSE](LICENSE).
