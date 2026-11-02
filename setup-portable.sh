#!/bin/sh
# ============================================================================
# setup-portable.sh - one-step portable setup for ClaudeX + Claude Code
#
# Features:
#   1. Detect the current operating system and CPU architecture
#      Windows / macOS / Linux, x64 / arm64 (musl is detected on Linux)
#   2. Download the latest ClaudeX and Claude Code from GitHub Releases
#      - ClaudeX goes into the script folder as ./ClaudeX[.exe]
#      - Claude Code goes into ./bin/<arch>/<platform>/claude[.exe]
#   3. Run ClaudeX once to generate claudex-config.json, then close it
#   4. Point claudeConfigDir at data and claudePath at the portable Claude binary
#      bin/<arch>/<platform>/claude*
#
# Directory layout (relative to the script folder):
#   ./ClaudeX[.exe]                      ClaudeX launcher
#   ./claudex-config.json                launcher configuration
#   ./data/                              portable CLAUDE_CONFIG_DIR
#   ./data/tmp/                          portable temporary folder
#   ./bin/<arch>/<platform>/claude*      Claude Code binary
#
# Platform support:
#   - Linux / macOS: run with the system POSIX sh
#   - Windows:       run with Git Bash from Git for Windows
#                    (the script handles .exe, zip, taskkill, and other Windows details)
#
# Dependencies: POSIX sh, curl, tar, perl (JSON::PP), find/awk/sed/grep
#       Windows zip extraction also needs unzip (bundled with Git Bash) or PowerShell as a fallback.
#
# Note: this script does not modify ClaudeX source code; it only downloads releases and updates the runtime config.
# ============================================================================

set -u
export LC_ALL=C

# ---------------------------------------------------------------------------
# Constants and overridable settings
# ---------------------------------------------------------------------------

# TODO: after ClaudeX is published, replace the placeholder below with the real owner/repo.
#       It can also be overridden at runtime with --claudex-repo owner/repo or CLAUDEX_REPO.
#
# Suggested ClaudeX release asset names (platform/arch markers are detected automatically):
#   ClaudeX-windows-x64.zip       ClaudeX-windows-arm64.zip
#   ClaudeX-macos-x64.tar.gz      ClaudeX-macos-arm64.tar.gz
#   ClaudeX-linux-x64.tar.gz      ClaudeX-linux-arm64.tar.gz
# Raw binaries are also supported, for example ClaudeX.exe / ClaudeX-linux-x64.
# The archive should contain an executable named ClaudeX / ClaudeX.exe (case-insensitive);
# if it contains exactly one executable with another name, the script will use it.
CLAUDEX_REPO_PLACEHOLDER="JPTV-21/Claudex"
CLAUDEX_REPO=${CLAUDEX_REPO:-$CLAUDEX_REPO_PLACEHOLDER}
CLAUDE_REPO=${CLAUDE_REPO:-anthropics/claude-code}

API_BASE="https://api.github.com"
GITHUB_BASE="https://github.com"
USER_AGENT="claudex-portable-setup/1.0"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || {
    printf 'error: cannot determine the script directory\n' >&2
    exit 1
}
ROOT=$SCRIPT_DIR

CONFIG_NAME="claudex-config.json"
CONFIG_FILE="$ROOT/$CONFIG_NAME"
DATA_DIR="$ROOT/data"
PORTABLE_TEMP_DIR="$ROOT/data/tmp"

TOKEN=${GITHUB_TOKEN:-${GH_TOKEN:-}}

FORCE_UPDATE=0
DO_CLAUDEX=1
DO_CLAUDE=1
CLAUDEX_ASSET_OVERRIDE=""
PLATFORM_OVERRIDE=""
ARCH_OVERRIDE=""
INSTALL_DIR_OVERRIDE=""
ALL_TARGETS=0
ALL_ARCH=0
MULTI_TARGETS=""
BASE_ROOT=""
ASSUME_YES=0
INTERACTIVE=0
DETECTED_OS=""
DETECTED_ARCH=""
LAUNCHER_TIMEOUT=20

HARD_FAIL=0
WARNINGS=0
CLAUDEX_MISSING_PLACEHOLDER=0

WORK=""
LAUNCHER_PID=""
CURL=""
SHA256_CMD=""
DOWNLOAD_EFFECTIVE_URL=""

OS=""
ARCH=""
LIBC=""
PLATFORM_LABEL=""
CLAUDE_EXE=""
CLAUDEX_EXE=""
CLAUDE_DEST=""
CLAUDE_BIN=""
CLAUDE_MARKER=""
CLAUDEX_BIN=""
CLAUDEX_MARKER=""
CLAUDE_PATH_CONFIG=""
CLAUDE_ASSET=""
LAUNCHER=""

RELEASE_TAG=""
ASSET_NAME=""
ASSET_BROWSER_URL=""
ASSET_API_URL=""
VERIFY_REF=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    BOLD=$(printf '\033[1m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    RED=$(printf '\033[31m')
    CYAN=$(printf '\033[36m')
    RESET=$(printf '\033[0m')
else
    BOLD=''
    GREEN=''
    YELLOW=''
    RED=''
    CYAN=''
    RESET=''
fi

say() {
    printf '%s\n' "$*"
}

info() {
    printf '%s==>%s %s\n' "$CYAN" "$RESET" "$*"
}

ok() {
    printf '%s  ok%s %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

err() {
    printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
}

die() {
    err "$*"
    exit 1
}

usage_error() {
    err "$*"
    say "Run '$0 --help' for usage."
    exit 2
}

# ---------------------------------------------------------------------------
# Process and temporary directory cleanup
# ---------------------------------------------------------------------------

stop_process() {
    pid=$1
    [ -n "$pid" ] || return 0
    i=0
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        while [ "$i" -lt 5 ]; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
            i=$((i + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            if [ "$OS" = "windows" ] && command -v taskkill >/dev/null 2>&1; then
                taskkill //PID "$pid" //F >/dev/null 2>&1 || true
            fi
        fi
    fi
    wait "$pid" 2>/dev/null || true
    return 0
}

cleanup() {
    if [ -n "$LAUNCHER_PID" ]; then
        stop_process "$LAUNCHER_PID"
        LAUNCHER_PID=""
    fi
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf "$WORK"
    fi
    WORK=""
}

trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: sh $0 [options]

One-step portable setup for ClaudeX + Claude Code. The script installs ClaudeX
into the script folder, Claude Code under bin/<arch>/<platform>, and creates
claudex-config.json.

Run this script from the folder you want to use as the portable root; that folder
becomes the root for ClaudeX, data/, and bin/.

Options:
  -u, --update             force re-download of the latest ClaudeX and Claude Code
      --no-claudex         skip the ClaudeX download/update
      --no-claude          skip the Claude Code download/update
      --platform OS        target platform: windows/macos/linux/all (default: detected)
      --arch ARCH          CPU architecture: x64/arm64/all (default: detected)
      --all                download all six platform/arch combinations into one folder
      --install-dir DIR    install directory (default: script folder)
  -y, --yes                use defaults without interactive prompts
      --claudex-repo REPO  ClaudeX repository (owner/repo)
      --claudex-asset NAME asset filename to use from the ClaudeX release
      --claude-repo REPO   Claude Code repository
                           (default: anthropics/claude-code)
      --timeout SECONDS    seconds to wait for ClaudeX to write the config (default: 20)
  -h, --help               show this help

Environment variables:
  GITHUB_TOKEN / GH_TOKEN  raise the GitHub API rate limit
  CLAUDEX_REPO             override the ClaudeX repository
  HTTPS_PROXY / HTTP_PROXY / NO_PROXY
                           used automatically by curl
  NO_COLOR                 disable colored output

Platform support:
  Linux / macOS  run directly with the system POSIX sh
  Windows        run with Git Bash from Git for Windows,
                 for example: bash setup-portable.sh

Examples:
  sh setup-portable.sh
  bash setup-portable.sh --update
  bash setup-portable.sh --install-dir /opt/claudex --yes
  bash setup-portable.sh --platform macos --arch arm64
  bash setup-portable.sh --all --install-dir /opt/claudex
  bash setup-portable.sh --claudex-repo owner/claudex
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing and validation
# ---------------------------------------------------------------------------

validate_repo() {
    repo=$1
    option=$2
    case "$repo" in
        */*)
            printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || {
                err "$option expects owner/repo, got: $repo"
                return 1
            }
            ;;
        *)
                err "$option expects owner/repo, got: $repo"
            return 1
            ;;
    esac
    return 0
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -u|--update)
                FORCE_UPDATE=1
                ;;
            --no-claudex)
                DO_CLAUDEX=0
                ;;
            --no-claude)
                DO_CLAUDE=0
                ;;
            -y|--yes)
                ASSUME_YES=1
                ;;
            --all)
                ALL_TARGETS=1
                ALL_ARCH=1
                ;;
            --platform)
                [ "$#" -ge 2 ] || usage_error "--platform requires a platform name"
                PLATFORM_OVERRIDE=$2
                shift
                ;;
            --platform=*)
                PLATFORM_OVERRIDE=${1#*=}
                ;;
            --arch)
                [ "$#" -ge 2 ] || usage_error "--arch requires an architecture name"
                ARCH_OVERRIDE=$2
                shift
                ;;
            --arch=*)
                ARCH_OVERRIDE=${1#*=}
                ;;
            --install-dir)
                [ "$#" -ge 2 ] || usage_error "--install-dir requires a directory"
                INSTALL_DIR_OVERRIDE=$2
                shift
                ;;
            --install-dir=*)
                INSTALL_DIR_OVERRIDE=${1#*=}
                ;;
            --claudex-repo)
                [ "$#" -ge 2 ] || usage_error "--claudex-repo requires an owner/repo argument"
                CLAUDEX_REPO=$2
                shift
                ;;
            --claudex-repo=*)
                CLAUDEX_REPO=${1#*=}
                ;;
            --claudex-asset)
                [ "$#" -ge 2 ] || usage_error "--claudex-asset requires an asset filename"
                CLAUDEX_ASSET_OVERRIDE=$2
                shift
                ;;
            --claudex-asset=*)
                CLAUDEX_ASSET_OVERRIDE=${1#*=}
                ;;
            --claude-repo)
                [ "$#" -ge 2 ] || usage_error "--claude-repo requires an owner/repo argument"
                CLAUDE_REPO=$2
                shift
                ;;
            --claude-repo=*)
                CLAUDE_REPO=${1#*=}
                ;;
            --timeout)
                [ "$#" -ge 2 ] || usage_error "--timeout requires a number of seconds"
                LAUNCHER_TIMEOUT=$2
                shift
                ;;
            --timeout=*)
                LAUNCHER_TIMEOUT=${1#*=}
                ;;
            --)
                shift
                break
                ;;
            *)
                usage_error "unknown option: $1"
                ;;
        esac
        shift
    done

    case "$LAUNCHER_TIMEOUT" in
        ''|*[!0-9]*)
            usage_error "--timeout must be a positive integer"
            ;;
    esac

    case "$CLAUDEX_ASSET_OVERRIDE" in
        */*|*..*)
            usage_error "--claudex-asset must not contain a path separator or .."
            ;;
    esac

    validate_repo "$CLAUDEX_REPO" "--claudex-repo" || exit 2
    validate_repo "$CLAUDE_REPO" "--claude-repo" || exit 2
}

is_placeholder_repo() {
    case "$1" in
        ""|YOUR_GITHUB_USER/*|OWNER/*|REPLACE_ME/*|YOUR_NAME/*|your-name/*|example/*)
            return 0
            ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

detect_platform() {
    sys=$(uname -s 2>/dev/null || printf 'unknown')
    case "$sys" in
        MINGW*|MSYS*|CYGWIN*|Windows_NT)
            OS="windows"
            ;;
        Darwin)
            OS="macos"
            ;;
        Linux)
            OS="linux"
            ;;
        *)
            die "unsupported operating system: $sys"
            ;;
    esac

    if [ "$OS" = "windows" ]; then
        raw_arch=${PROCESSOR_ARCHITEW6432:-${PROCESSOR_ARCHITECTURE:-$(uname -m 2>/dev/null || printf 'unknown')}}
    else
        raw_arch=$(uname -m 2>/dev/null || printf 'unknown')
    fi

    case "$raw_arch" in
        x86_64|amd64|AMD64|x64)
            ARCH="x64"
            ;;
        arm64|aarch64|ARM64)
            ARCH="arm64"
            ;;
        *)
            die "unsupported CPU architecture: $raw_arch"
            ;;
    esac

    # When an x86_64 shell runs under Rosetta on Apple Silicon, still download the native arm64 build.
    if [ "$OS" = "macos" ] && [ "$ARCH" = "x64" ]; then
        if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || printf '0')" = "1" ]; then
            ARCH="arm64"
        fi
    fi

    LIBC="glibc"
    if [ "$OS" = "linux" ]; then
        if ldd --version 2>&1 | grep -qi musl; then
            LIBC="musl"
        fi
        for candidate in /lib/ld-musl-*.so.1 /lib64/ld-musl-*.so.1; do
            if [ -e "$candidate" ]; then
                LIBC="musl"
                break
            fi
        done
    fi

    DETECTED_OS=$OS
    DETECTED_ARCH=$ARCH
    apply_platform_vars
}

# Recompute every path after the interactive platform/arch/directory choices.
apply_platform_vars() {
    [ "$OS" = "linux" ] || LIBC="glibc"

    case "$OS" in
        windows)
            PLATFORM_LABEL="Windows"
            CLAUDE_EXE="claude.exe"
            ;;
        macos)
            PLATFORM_LABEL="macOS"
            CLAUDE_EXE="claude"
            ;;
        linux)
            PLATFORM_LABEL="Linux"
            CLAUDE_EXE="claude"
            ;;
    esac

    # Every launcher carries its platform and architecture so all builds can
    # share the install root without overwriting each other.
    CLAUDEX_EXE="ClaudeX-$OS-$ARCH"
    [ "$OS" = "windows" ] && CLAUDEX_EXE="$CLAUDEX_EXE.exe"

    CLAUDE_DEST="$ROOT/bin/$ARCH/$OS"
    CLAUDE_BIN="$CLAUDE_DEST/$CLAUDE_EXE"
    CLAUDE_MARKER="$CLAUDE_DEST/.claude-version"
    CLAUDEX_BIN="$ROOT/$CLAUDEX_EXE"
    CLAUDEX_MARKER="$ROOT/.claudex-version-$OS-$ARCH"
    CLAUDE_PATH_CONFIG="bin/$ARCH/$OS/claude*"
    CONFIG_FILE="$ROOT/$CONFIG_NAME"
    DATA_DIR="$ROOT/data"
    PORTABLE_TEMP_DIR="$ROOT/data/tmp"
}

prompt_platform_arch() {
    INTERACTIVE=0
    if [ -t 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
        INTERACTIVE=1
    fi

    [ -z "$PLATFORM_OVERRIDE" ] || OS=$PLATFORM_OVERRIDE
    [ -z "$ARCH_OVERRIDE" ] || ARCH=$ARCH_OVERRIDE

    if [ "$INTERACTIVE" -eq 1 ]; then
        printf 'Install platform [%s] (windows/macos/linux/all): ' "$OS"
        read answer || answer=""
        case "$answer" in
            "") ;;
            windows|macos|linux|all) OS=$answer ;;
            *) warn "invalid platform: $answer; using $OS" ;;
        esac

        default_arch=$ARCH
        [ "$OS" = "all" ] && default_arch=all
        printf 'CPU architecture [%s] (x64/arm64/all): ' "$default_arch"
        read answer || answer=""
        case "$answer" in
            "") ARCH=$default_arch ;;
            x64|arm64|all) ARCH=$answer ;;
            *) warn "invalid architecture: $answer; using $default_arch" ;;
        esac
    elif [ -z "$ARCH_OVERRIDE" ] && [ "$OS" = "all" ]; then
        # Platform "all" without an explicit arch keeps the six-target default.
        ARCH=all
    fi

    case "$OS" in
        windows|macos|linux) ;;
        all) ALL_TARGETS=1 ;;
        *) die "unsupported platform: $OS" ;;
    esac
    case "$ARCH" in
        x64|arm64) ;;
        all) ALL_ARCH=1 ;;
        *) die "unsupported architecture: $ARCH" ;;
    esac

    platform_count=1
    [ "$ALL_TARGETS" -eq 1 ] && platform_count=3
    arch_count=1
    [ "$ALL_ARCH" -eq 1 ] && arch_count=2
    total_count=$((platform_count * arch_count))
    if [ "$total_count" -gt 1 ]; then
        info "Downloading $total_count platform/architecture combinations into one folder."
    elif [ "$OS" != "$DETECTED_OS" ] || [ "$ARCH" != "$DETECTED_ARCH" ]; then
        info "Downloading the $OS/$ARCH build (it cannot run on this host)."
    fi
}

prompt_install_dir() {
    if [ -n "$INSTALL_DIR_OVERRIDE" ]; then
        ROOT=$INSTALL_DIR_OVERRIDE
    elif [ "$INTERACTIVE" -eq 1 ]; then
        printf 'Install directory [%s]: ' "$ROOT"
        read answer || answer=""
        [ -z "$answer" ] || ROOT=$answer
    fi

    case "$ROOT" in
        "~") ROOT=$HOME ;;
        "~/"*) ROOT="$HOME/${ROOT#\~/}" ;;
    esac
    case "$ROOT" in
        /*|[A-Za-z]:*) ;;
        *) ROOT="$PWD/$ROOT" ;;
    esac

    if [ ! -d "$ROOT" ]; then
        if [ "$INTERACTIVE" -eq 1 ]; then
            printf 'Directory does not exist: %s\nCreate it? [Y/n]: ' "$ROOT"
            read answer || answer=""
            case "$answer" in
                n|N|no|NO) die "Cancelled." ;;
            esac
        fi
        mkdir -p "$ROOT" || die "cannot create directory: $ROOT"
        ok "Created directory: $ROOT"
    fi
    [ -w "$ROOT" ] || die "directory is not writable: $ROOT"
}

select_claude_asset_name() {
    case "$OS/$ARCH/$LIBC" in
        windows/x64/*)
            CLAUDE_ASSET="claude-win32-x64.zip"
            ;;
        windows/arm64/*)
            CLAUDE_ASSET="claude-win32-arm64.zip"
            ;;
        macos/x64/*)
            CLAUDE_ASSET="claude-darwin-x64.tar.gz"
            ;;
        macos/arm64/*)
            CLAUDE_ASSET="claude-darwin-arm64.tar.gz"
            ;;
        linux/x64/musl)
            CLAUDE_ASSET="claude-linux-x64-musl.tar.gz"
            ;;
        linux/arm64/musl)
            CLAUDE_ASSET="claude-linux-arm64-musl.tar.gz"
            ;;
        linux/x64/glibc)
            CLAUDE_ASSET="claude-linux-x64.tar.gz"
            ;;
        linux/arm64/glibc)
            CLAUDE_ASSET="claude-linux-arm64.tar.gz"
            ;;
        *)
            die "no Claude Code package for $OS/$ARCH/$LIBC"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Dependencies and temporary directory
# ---------------------------------------------------------------------------

check_dependencies() {
    command -v curl >/dev/null 2>&1 || die "missing curl. On Windows use Git Bash, or install curl."
    command -v tar >/dev/null 2>&1 || die "missing tar."
    command -v perl >/dev/null 2>&1 || die "missing perl."
    perl -MJSON::PP -e '1' >/dev/null 2>&1 || die "missing Perl module JSON::PP."
    command -v find >/dev/null 2>&1 || die "missing find."
    command -v awk >/dev/null 2>&1 || die "missing awk."
    command -v sed >/dev/null 2>&1 || die "missing sed."
    command -v grep >/dev/null 2>&1 || die "missing grep."
    command -v mkdir >/dev/null 2>&1 || die "missing mkdir."
    command -v cp >/dev/null 2>&1 || die "missing cp."
    command -v mv >/dev/null 2>&1 || die "missing mv."
    command -v chmod >/dev/null 2>&1 || die "missing chmod."
    command -v date >/dev/null 2>&1 || die "missing date."

    CURL=$(command -v curl)

    if command -v sha256sum >/dev/null 2>&1; then
        SHA256_CMD="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        SHA256_CMD="shasum"
    else
        SHA256_CMD=""
        warn "sha256sum/shasum not found; skipping SHA-256 verification."
    fi
}

setup_work() {
    if command -v mktemp >/dev/null 2>&1; then
        WORK=$(mktemp -d "${TMPDIR:-/tmp}/claudex-setup.XXXXXX" 2>/dev/null) || WORK=""
    fi
    if [ -z "$WORK" ]; then
        WORK="${TMPDIR:-/tmp}/claudex-setup.$$"
        (umask 077 && mkdir -p "$WORK") || die "cannot create temporary directory: $WORK"
    fi
}

# ---------------------------------------------------------------------------
# Downloads and GitHub API
# ---------------------------------------------------------------------------

download_plain() {
    dl_url=$1
    dl_dest=$2
    dl_label=$3
    dl_api_mode=${4:-0}
    dl_err_file="$WORK/curl.err"
    dl_attempt=1
    dl_max_attempts=3

    while [ "$dl_attempt" -le "$dl_max_attempts" ]; do
        # On a terminal, leave curl's default progress meter enabled. It shows
        # the transferred/total size and the average speed.
        if [ -t 2 ]; then
            set -- -fL --retry 2 --retry-delay 1 --connect-timeout 30 \
                --speed-limit 1024 --speed-time 120 -C -
        else
            set -- -fL -sS --retry 2 --retry-delay 1 --connect-timeout 30 \
                --speed-limit 1024 --speed-time 120 -C -
        fi
        set -- "$@" -H "User-Agent: $USER_AGENT" -o "$dl_dest" -w '%{url_effective}'
        if [ "$dl_api_mode" = "1" ]; then
            set -- "$@" -H "Accept: application/octet-stream"
            if [ -n "$TOKEN" ]; then
                set -- "$@" -H "Authorization: Bearer $TOKEN"
            fi
        fi
        set -- "$@" "$dl_url"

        if [ -t 2 ]; then
            DOWNLOAD_EFFECTIVE_URL=$("$CURL" "$@")
        else
            DOWNLOAD_EFFECTIVE_URL=$("$CURL" "$@" 2>"$dl_err_file")
        fi
        dl_rc=$?
        if [ "$dl_rc" -eq 0 ]; then
            return 0
        fi
        # curl 33: the server does not support byte ranges. Restart cleanly.
        if [ "$dl_rc" -eq 33 ]; then
            rm -f "$dl_dest"
        fi
        if [ "$dl_attempt" -lt "$dl_max_attempts" ]; then
            warn "$dl_label download interrupted (attempt $dl_attempt/$dl_max_attempts); resuming in 2 seconds..."
            sleep 2
        fi
        dl_attempt=$((dl_attempt + 1))
    done

    rm -f "$dl_dest"
    dl_detail=$(tail -n 1 "$dl_err_file" 2>/dev/null | tr -d '\r')
    warn "$dl_label download failed${dl_detail:+: $dl_detail}"
    return 1
}

download_release_asset() {
    dl_label=$1
    dl_dest="$WORK/$ASSET_NAME"

    if [ -n "$ASSET_BROWSER_URL" ]; then
        if download_plain "$ASSET_BROWSER_URL" "$dl_dest" "$dl_label" 0; then
            return 0
        fi
        warn "$dl_label: direct download failed; retrying through the GitHub API."
    fi
    if [ -n "$ASSET_API_URL" ]; then
        if download_plain "$ASSET_API_URL" "$dl_dest" "$dl_label" 1; then
            return 0
        fi
    fi
    warn "$dl_label: download failed."
    return 1
}

fetch_latest_release() {
    repo=$1
    out=$2
    api="$API_BASE/repos/$repo/releases/latest"
    err_file="$WORK/api.err"

    set -- -sS -L --connect-timeout 20 --max-time 120 \
        -H "User-Agent: $USER_AGENT" \
        -H "Accept: application/vnd.github+json" \
        -o "$out" -w '%{http_code}'
    if [ -n "$TOKEN" ]; then
        set -- "$@" -H "Authorization: Bearer $TOKEN"
    fi
    set -- "$@" "$api"

    status=$("$CURL" "$@" 2>"$err_file") || status=000

    case "$status" in
        200)
            return 0
            ;;
        403|429)
            detail=$(head -n 1 "$out" 2>/dev/null | cut -c1-240 | tr -d '\r')
            warn "GitHub API rate limit reached (set GITHUB_TOKEN for a higher limit): $detail"
            return 1
            ;;
        404)
            warn "GitHub repository not found or has no releases: $repo"
            return 1
            ;;
        000)
            detail=$(tail -n 1 "$err_file" 2>/dev/null | tr -d '\r')
            warn "cannot reach the GitHub API${detail:+: $detail}"
            return 1
            ;;
        *)
            detail=$(head -n 1 "$out" 2>/dev/null | cut -c1-240 | tr -d '\r')
            warn "GitHub API returned HTTP $status${detail:+: $detail}"
            return 1
            ;;
    esac
}

# Select the asset for the current platform/architecture from the release JSON.
# Prints two lines (TAB-separated):
#   TAG<TAB>tag
#   ASSET<TAB>filename<TAB>browser_url<TAB>api_url
select_asset_from_release() {
    json_file=$1
    expected=$2
    out=$3

    perl -MJSON::PP -e '
        use strict;
        use warnings;

        my ($file, $expected, $os, $arch, $libc) = @ARGV;
        local $/;
        open my $fh, "<:raw", $file or do {
            print "ERROR\tcannot read release JSON\n";
            exit 1;
        };
        my $raw = <$fh>;
        close $fh;
        $raw =~ s/^\xEF\xBB\xBF//;

        my $rel = eval { JSON::PP->new->utf8->decode($raw) };
        if (!$rel || ref($rel) ne "HASH" || !$rel->{tag_name}) {
            print "ERROR\trelease JSON has no tag_name\n";
            exit 1;
        }

        my $tag = $rel->{tag_name};
        my @assets = @{ $rel->{assets} || [] };

        # Prefer an exact match on the expected asset name (Claude Code asset names are fixed).
        if ($expected ne "") {
            for my $a (@assets) {
                my $name = $a->{name} // "";
                if (lc($name) eq lc($expected)) {
                    print "TAG\t$tag\n";
                    print "ASSET\t$name\t", ($a->{browser_download_url} // ""),
                          "\t", ($a->{url} // ""), "\n";
                    exit 0;
                }
            }
        }

        my @candidates;
        for my $a (@assets) {
            my $name = $a->{name} // "";
            next if $name eq "";
            my $l = lc($name);

            # Checksums, signatures, installers, and source archives are not auto-selected.
            next if $l =~ /(?:sha256|sha512|shasums|checksums?|\.sig$|\.asc$|\.txt$|\.json$|\.sbom$|\.dmg$|\.pkg$|\.msi$|\.deb$|\.rpm$)/;
            next if $l =~ /(?:^|[._-])(?:source|src|setup|installer|install|debug|symbols)(?:[._-]|$)/;

            my $is_windows = ($l =~ /(?:^|[._-])win(?:32|64|dows)?(?:[._-]|$)/ || $l =~ /\.exe$/) ? 1 : 0;
            my $is_macos = ($l =~ /(?:^|[._-])(?:macos|mac|darwin|osx)(?:[._-]|$)/) ? 1 : 0;
            my $is_linux = ($l =~ /(?:^|[._-])linux(?:[._-]|$)/) ? 1 : 0;
            my $any_platform = $is_windows || $is_macos || $is_linux;
            my %platform = (windows => $is_windows, macos => $is_macos, linux => $is_linux);
            next if $any_platform && !$platform{$os};

            my $is_x64 = ($l =~ /(?:^|[._-])(?:x64|x86_64|x86-64|amd64)(?:[._-]|$)/ ||
                          $l =~ /(?:^|[._-])win64(?:[._-]|$)/) ? 1 : 0;
            my $is_arm64 = ($l =~ /(?:^|[._-])(?:arm64|aarch64|armv8)(?:[._-]|$)/) ? 1 : 0;
            my $is_x86_32 = ($l =~ /(?:^|[._-])(?:i[3-6]86|ia32)(?:[._-]|$)/ ||
                             $l =~ /(?:^|[._-])x86(?!_64|-64)(?:[._-]|$)/) ? 1 : 0;
            next if $is_x86_32;

            my $any_arch = $is_x64 || $is_arm64;
            my %arch = (x64 => $is_x64, arm64 => $is_arm64);
            next if $any_arch && !$arch{$arch};

            my $has_musl = $l =~ /musl/ ? 1 : 0;
            my $has_gnu = $l =~ /(?:gnu|glibc)/ ? 1 : 0;
            if ($libc eq "musl") {
                next if $has_gnu && !$has_musl;
            } else {
                next if $has_musl;
            }

            my $score = 0;
            $score += 100 if $any_platform && $platform{$os};
            $score += 50 if $any_arch && $arch{$arch};
            $score += 20 if $has_musl && $libc eq "musl";
            $score += 5 if $has_gnu && $libc ne "musl";

            if ($l =~ /\.zip$/) {
                $score += ($os eq "windows") ? 30 : 8;
            } elsif ($l =~ /\.(?:tar\.gz|tgz)$/) {
                $score += ($os eq "windows") ? 8 : 30;
            } elsif ($l =~ /\.(?:tar\.xz|txz|tar\.bz2|tbz2|tar)$/) {
                $score += 12;
            } elsif ($l =~ /\.exe$/) {
                $score += ($os eq "windows") ? 20 : 2;
            } else {
                $score += 4;
            }
            $score += 10 if $l =~ /claudex/;

            push @candidates, [$score, $name, $a->{browser_download_url} // "", $a->{url} // ""];
        }

        if (!@candidates) {
            print "ERROR\tno release asset matches $os/$arch/$libc\n";
            exit 3;
        }

        @candidates = sort {
            $b->[0] <=> $a->[0] || $a->[1] cmp $b->[1]
        } @candidates;
        my $best = $candidates[0];

        print "TAG\t$tag\n";
        print "ASSET\t$best->[1]\t$best->[2]\t$best->[3]\n";
        exit 0;
    ' "$json_file" "$expected" "$OS" "$ARCH" "$LIBC" >"$out" 2>"$WORK/asset.err"
    rc=$?

    if [ "$rc" -ne 0 ]; then
        if [ -s "$out" ] && grep -q '^ERROR' "$out"; then
            warn "$(grep '^ERROR' "$out" | head -n 1 | cut -f2)"
        else
            detail=$(tail -n 1 "$WORK/asset.err" 2>/dev/null | tr -d '\r')
            warn "cannot parse release assets${detail:+: $detail}"
        fi
        return 1
    fi
    return 0
}

parse_selection() {
    selection=$1
    RELEASE_TAG=$(awk -F '\t' '$1 == "TAG" { print $2; exit }' "$selection")
    ASSET_NAME=$(awk -F '\t' '$1 == "ASSET" { print $2; exit }' "$selection")
    ASSET_BROWSER_URL=$(awk -F '\t' '$1 == "ASSET" { print $3; exit }' "$selection")
    ASSET_API_URL=$(awk -F '\t' '$1 == "ASSET" { print $4; exit }' "$selection")
    VERIFY_REF=$RELEASE_TAG
    if [ -z "$RELEASE_TAG" ] || [ -z "$ASSET_NAME" ]; then
        return 1
    fi
    case "$ASSET_NAME" in
        */*|*..*)
            warn "release returned an invalid asset name: $ASSET_NAME"
            return 1
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# SHA-256 verification
# ---------------------------------------------------------------------------

sha256_of() {
    case "$SHA256_CMD" in
        sha256sum)
            sha256sum "$1" | awk '{ print $1 }'
            ;;
        shasum)
            shasum -a 256 "$1" | awk '{ print $1 }'
            ;;
        *)
            return 1
            ;;
    esac
}

fetch_shasums() {
    repo=$1
    ref=$2
    out=$3
    if [ "$ref" = "latest" ]; then
        url="$GITHUB_BASE/$repo/releases/latest/download/SHASUMS256.txt"
    else
        url="$GITHUB_BASE/$repo/releases/download/$ref/SHASUMS256.txt"
    fi

    if [ -n "$TOKEN" ]; then
        "$CURL" -fsSL --connect-timeout 20 --max-time 60 \
            -H "User-Agent: $USER_AGENT" \
            -H "Authorization: Bearer $TOKEN" \
            -o "$out" "$url" 2>/dev/null
    else
        "$CURL" -fsSL --connect-timeout 20 --max-time 60 \
            -H "User-Agent: $USER_AGENT" \
            -o "$out" "$url" 2>/dev/null
    fi
}

verify_download() {
    label=$1
    ref=$2
    file=$3
    asset=$4
    repo=$5

    if [ ! -s "$file" ]; then
        err "$label: downloaded file is missing or empty; installation aborted."
        return 1
    fi

    if [ -z "$SHA256_CMD" ]; then
        warn "$label: no SHA-256 tool available; skipping verification."
        return 0
    fi

    shasums="$WORK/SHASUMS256.txt"
    if ! fetch_shasums "$repo" "$ref" "$shasums"; then
        warn "$label: cannot fetch SHASUMS256.txt; skipping verification."
        return 0
    fi

    expected=$(awk -v n="$asset" '$2 == n || $2 == ("*" n) { print $1; exit }' "$shasums")
    if [ -z "$expected" ]; then
        warn "$label: SHASUMS256.txt does not list $asset; skipping verification."
        return 0
    fi

    actual=$(sha256_of "$file") || {
        warn "$label: cannot compute SHA-256; skipping verification."
        return 0
    }

    if [ "$actual" != "$expected" ]; then
        err "$label: SHA-256 verification failed"
        err "  expected: $expected"
        err "  actual:   $actual"
        return 1
    fi

    ok "$label: SHA-256 verified"
    return 0
}

# ---------------------------------------------------------------------------
# Extraction and file lookup
# ---------------------------------------------------------------------------

archive_list_safe() {
    list=$1
    awk '{
        sub(/\r$/, "", $0);
        if ($0 ~ /^\// || $0 ~ /^[A-Za-z]:[\\\/]/ || $0 ~ /(^|[\\\/])\.\.([\\\/]|$)/) {
            bad = 1;
            exit;
        }
    } END {
        exit (bad ? 1 : 0);
    }' "$list"
}

extract_tar() {
    archive=$1
    outdir=$2
    list="$WORK/tar-list.txt"

    tar -tf "$archive" >"$list" 2>"$WORK/tar.err" || {
        warn "cannot read the tar archive: $(tail -n 1 "$WORK/tar.err" 2>/dev/null | tr -d '\r')"
        return 1
    }
    if ! archive_list_safe "$list"; then
        warn "the archive contains unsafe paths; extraction refused."
        return 1
    fi
    # Reject symbolic and hard links so extraction cannot escape the temporary directory.
    if tar -tvf "$archive" 2>/dev/null | awk 'substr($1, 1, 1) == "l" || substr($1, 1, 1) == "h" { bad = 1 } END { exit (bad ? 0 : 1) }'; then
        warn "the archive contains symbolic or hard links; extraction refused."
        return 1
    fi

    tar -xf "$archive" -C "$outdir" || {
        warn "tar extraction failed."
        return 1
    }
    return 0
}

extract_zip() {
    archive=$1
    outdir=$2
    list="$WORK/zip-list.txt"

    if command -v unzip >/dev/null 2>&1; then
        unzip -Z1 "$archive" >"$list" 2>/dev/null
        rc=$?
        if [ "$rc" -gt 1 ]; then
            warn "cannot read the zip archive."
            return 1
        fi
        if ! archive_list_safe "$list"; then
            warn "the archive contains unsafe paths; extraction refused."
            return 1
        fi
        unzip -q "$archive" -d "$outdir"
        rc=$?
        # Info-ZIP returns 1 for "completed with warnings" (for example,
        # backslash paths created on Windows); files are usually extracted correctly. Values above 1 are errors.
        if [ "$rc" -gt 1 ]; then
            warn "zip extraction failed (unzip returned $rc)."
            return 1
        fi
        if [ "$rc" -eq 1 ]; then
            warn "zip extraction completed with warnings from unzip (continuing)."
        fi
        return 0
    fi

    # bsdtar can also read zip archives (Windows' bundled tar.exe, some macOS setups).
    if tar -tf "$archive" >"$list" 2>/dev/null; then
        if ! archive_list_safe "$list"; then
            warn "the archive contains unsafe paths; extraction refused."
            return 1
        fi
        tar -xf "$archive" -C "$outdir" || {
            warn "zip extraction failed."
            return 1
        }
        return 0
    fi

    if [ "$OS" = "windows" ] && command -v powershell >/dev/null 2>&1; then
        ARCHIVE_PATH=$archive EXTRACT_PATH=$outdir powershell -NoProfile -ExecutionPolicy Bypass \
            -Command 'Expand-Archive -LiteralPath $env:ARCHIVE_PATH -DestinationPath $env:EXTRACT_PATH -Force' \
            >/dev/null 2>&1 || {
            warn "PowerShell extraction failed."
            return 1
        }
        return 0
    fi

    warn "unzip is missing; cannot extract the zip archive."
    return 1
}

extract_archive() {
    archive=$1
    outdir=$2
    name=$3

    mkdir -p "$outdir" || return 1
    lname=$(printf '%s' "$name" | tr 'A-Z' 'a-z')

    case "$lname" in
        *.zip)
            extract_zip "$archive" "$outdir"
            ;;
        *.tar.gz|*.tgz|*.tar|*.tar.xz|*.txz|*.tar.bz2|*.tbz2)
            extract_tar "$archive" "$outdir"
            ;;
        *)
            # Raw binary (for example ClaudeX.exe / claudex-linux-x64 published directly).
            cp -f "$archive" "$outdir/$(basename "$name")" || {
                warn "cannot copy the raw binary."
                return 1
            }
            chmod 755 "$outdir/$(basename "$name")" 2>/dev/null || true
            ;;
    esac
}

find_component_binary() {
    dir=$1
    kind=$2
    list="$WORK/find-$kind.txt"
    : >"$list"

    if [ "$kind" = "claude" ]; then
        find "$dir" -type f \( -name "claude" -o -name "claude.exe" \) -print >>"$list" 2>/dev/null
    else
        find "$dir" -type f -iname 'claudex*' -print >>"$list" 2>/dev/null
        if [ -s "$list" ]; then
            grep -viE '\.(json|md|txt|log|ini|cfg|conf|dll|so|dylib|pdb|xml|yml|yaml)$' "$list" >"$list.filtered" || true
            mv -f "$list.filtered" "$list"
        fi
        if [ ! -s "$list" ]; then
            # When the filename does not contain claudex, only use a single remaining
            # executable candidate to avoid treating README, DLLs, or scripts as the launcher.
            find "$dir" -type f -print >"$list.all" 2>/dev/null
            grep -viE '\.(json|md|txt|log|ini|cfg|conf|dll|so|dylib|pdb|xml|yml|yaml|html|css|js|png|jpg|jpeg|ico|gif|svg)$' "$list.all" >"$list.filtered" || true
            grep -viE '(^|/)(license|licence|readme|changelog|copying)(\.|$)' "$list.filtered" >"$list" || true
            rm -f "$list.all" "$list.filtered"
            if [ "$(wc -l <"$list" | tr -d ' ')" != "1" ]; then
                : >"$list"
            fi
        fi
    fi

    [ -s "$list" ] || return 1

    if [ "$kind" = "claude" ]; then
        chosen=$(grep -E '/(claude|claude\.exe)$' "$list" | head -n 1)
    else
        chosen=$(grep -Ei '/(ClaudeX|ClaudeX\.exe|claudex|claudex\.exe)$' "$list" | head -n 1)
    fi

    if [ -z "$chosen" ]; then
        chosen=$(awk '{ n = split($0, a, "/"); print n "\t" $0 }' "$list" | sort -n | head -n 1 | cut -f2-)
    fi

    [ -n "$chosen" ] || return 1
    printf '%s\n' "$chosen"
}

install_binary() {
    src=$1
    dest=$2
    mkdir -p "$(dirname "$dest")" || return 1
    tmp="$dest.tmp.$$"
    cp -f "$src" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod 755 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dest" || {
        rm -f "$tmp"
        return 1
    }
    return 0
}

write_marker() {
    marker=$1
    shift
    tmp="$marker.tmp.$$"
    : >"$tmp" || return 1
    for line in "$@"; do
        printf '%s\n' "$line" >>"$tmp" || {
            rm -f "$tmp"
            return 1
        }
    done
    mv -f "$tmp" "$marker" || {
        rm -f "$tmp"
        return 1
    }
    return 0
}

marker_value() {
    marker=$1
    key=$2
    [ -f "$marker" ] || return 1
    sed -n "s/^${key}=//p" "$marker" 2>/dev/null | head -n 1
}

# ---------------------------------------------------------------------------
# Component installation
# ---------------------------------------------------------------------------

install_component_from_release() {
    label=$1
    kind=$2
    install_dest=$3
    marker=$4
    repo=$5

    archive="$WORK/$ASSET_NAME"
    extract_dir="$WORK/extract-$kind"

    rm -f "$archive"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir" || return 1

    info "Downloading $label $RELEASE_TAG ($ASSET_NAME)"
    download_release_asset "$label" || {
        err "$label: download failed; installation aborted."
        return 1
    }

    verify_download "$label" "$VERIFY_REF" "$archive" "$ASSET_NAME" "$repo" || return 1

    extract_archive "$archive" "$extract_dir" "$ASSET_NAME" || return 1

    bin=$(find_component_binary "$extract_dir" "$kind") || {
        warn "$label: no executable found in the archive."
        return 1
    }
    install_binary "$bin" "$install_dest" || {
        warn "$label: failed to install to $install_dest"
        return 1
    }

    sha=""
    if [ -n "$SHA256_CMD" ]; then
        sha=$(sha256_of "$archive" 2>/dev/null || true)
    fi

    if [ "$kind" = "claudex" ]; then
        write_marker "$marker" \
            "repo=$repo" \
            "tag=$RELEASE_TAG" \
            "asset=$ASSET_NAME" \
            "sha256=$sha" \
            "exe=$(basename "$dest")" || warn "$label: cannot write the version marker."
    else
        write_marker "$marker" \
            "repo=$repo" \
            "tag=$RELEASE_TAG" \
            "asset=$ASSET_NAME" \
            "sha256=$sha" || warn "$label: cannot write the version marker."
    fi

    ok "$label installed: $install_dest"
    return 0
}

# Resolve the real tag from the /releases/latest/download/... redirect chain.
resolve_latest_tag() {
    url=$1
    headers="$WORK/latest-headers.txt"
    if "$CURL" -sS -L -r 0-0 -o /dev/null -D "$headers" \
        -H "User-Agent: $USER_AGENT" "$url" 2>/dev/null; then
        tag=$(tr -d '\r' <"$headers" | sed -n 's#^[Ll]ocation: .*/releases/download/\([^/]*\)/.*#\1#p' | head -n 1)
        if [ -n "$tag" ]; then
            printf '%s\n' "$tag"
            return 0
        fi
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Claude Code
# ---------------------------------------------------------------------------

ensure_claude() {
    have=0
    if [ -f "$CLAUDE_BIN" ]; then
        have=1
    fi

    marker_repo=""
    marker_tag=""
    marker_asset=""
    if [ -f "$CLAUDE_MARKER" ]; then
        marker_repo=$(marker_value "$CLAUDE_MARKER" "repo" 2>/dev/null || true)
        marker_tag=$(marker_value "$CLAUDE_MARKER" "tag" 2>/dev/null || true)
        marker_asset=$(marker_value "$CLAUDE_MARKER" "asset" 2>/dev/null || true)
    fi

    release_json="$WORK/claude-release.json"
    selection="$WORK/claude-selection.txt"

    if fetch_latest_release "$CLAUDE_REPO" "$release_json"; then
        if ! select_asset_from_release "$release_json" "$CLAUDE_ASSET" "$selection"; then
            if [ "$have" -eq 1 ]; then
                warn "no Claude Code package in the latest release; keeping the existing version."
                return 0
            fi
            HARD_FAIL=1
            err "no Claude Code package found in the latest release."
            return 1
        fi

        parse_selection "$selection" || {
            if [ "$have" -eq 1 ]; then
                warn "cannot parse the Claude Code release; keeping the existing version."
                return 0
            fi
            HARD_FAIL=1
            err "cannot parse the Claude Code release."
            return 1
        }

        if [ "$have" -eq 1 ] && [ "$FORCE_UPDATE" -eq 0 ] &&
            [ -n "$marker_tag" ] && [ "$marker_repo" = "$CLAUDE_REPO" ] &&
            [ "$marker_tag" = "$RELEASE_TAG" ] && [ "$marker_asset" = "$ASSET_NAME" ]; then
            ok "Claude Code is up to date ($RELEASE_TAG)"
            return 0
        fi

        if [ "$have" -eq 1 ]; then
            if install_component_from_release "Claude Code" "claude" "$CLAUDE_BIN" "$CLAUDE_MARKER" "$CLAUDE_REPO"; then
                return 0
            fi
            warn "Claude Code update failed; keeping the existing version."
            return 0
        fi

        if install_component_from_release "Claude Code" "claude" "$CLAUDE_BIN" "$CLAUDE_MARKER" "$CLAUDE_REPO"; then
            return 0
        fi
        HARD_FAIL=1
        err "Claude Code download/installation failed."
        return 1
    fi

    if [ "$have" -eq 1 ] && [ "$FORCE_UPDATE" -eq 0 ]; then
        warn "cannot check for Claude Code updates (network or GitHub API error); using the existing version."
        return 0
    fi

    # When the API is unavailable, try GitHub's latest direct URL (first install or --update).
    warn "cannot fetch Claude Code release info; trying the latest direct download."
    RELEASE_TAG="latest"
    VERIFY_REF="latest"
    ASSET_NAME="$CLAUDE_ASSET"
    ASSET_BROWSER_URL="$GITHUB_BASE/$CLAUDE_REPO/releases/latest/download/$CLAUDE_ASSET"
    ASSET_API_URL=""

    if install_component_from_release "Claude Code" "claude" "$CLAUDE_BIN" "$CLAUDE_MARKER" "$CLAUDE_REPO"; then
        resolved=$(resolve_latest_tag "$ASSET_BROWSER_URL" 2>/dev/null || true)
        if [ -n "$resolved" ]; then
            write_marker "$CLAUDE_MARKER" \
                "repo=$CLAUDE_REPO" \
                "tag=$resolved" \
                "asset=$ASSET_NAME" \
                "sha256=$([ -n "$SHA256_CMD" ] && sha256_of "$WORK/$ASSET_NAME" 2>/dev/null || true)" \
                || true
        fi
        return 0
    fi

    if [ "$have" -eq 1 ]; then
        warn "Claude Code update failed; keeping the existing version."
        return 0
    fi

    HARD_FAIL=1
        err "Claude Code download failed and no existing version is available."
    return 1
}

# ---------------------------------------------------------------------------
# ClaudeX
# ---------------------------------------------------------------------------

find_existing_claudex() {
    if [ -f "$CLAUDEX_MARKER" ]; then
        marker_exe=$(marker_value "$CLAUDEX_MARKER" "exe" 2>/dev/null || true)
        case "$marker_exe" in
            */*|*..*) marker_exe="" ;;
        esac
        if [ -n "$marker_exe" ] && [ -f "$ROOT/$marker_exe" ]; then
            printf '%s\n' "$ROOT/$marker_exe"
            return 0
        fi
    fi

    if [ -f "$ROOT/$CLAUDEX_EXE" ]; then
        printf '%s\n' "$ROOT/$CLAUDEX_EXE"
        return 0
    fi
    return 1
}

ensure_claudex() {
    existing=$(find_existing_claudex 2>/dev/null || true)

    marker_repo=""
    marker_tag=""
    marker_asset=""
    if [ -f "$CLAUDEX_MARKER" ]; then
        marker_repo=$(marker_value "$CLAUDEX_MARKER" "repo" 2>/dev/null || true)
        marker_tag=$(marker_value "$CLAUDEX_MARKER" "tag" 2>/dev/null || true)
        marker_asset=$(marker_value "$CLAUDEX_MARKER" "asset" 2>/dev/null || true)
    fi

    if is_placeholder_repo "$CLAUDEX_REPO"; then
        if [ -n "$existing" ]; then
            info "ClaudeX repository is still a placeholder; keeping the existing launcher: $existing"
        else
            CLAUDEX_MISSING_PLACEHOLDER=1
            warn "ClaudeX repository is still a placeholder: $CLAUDEX_REPO"
            warn "After publishing, pass --claudex-repo owner/repo or set CLAUDEX_REPO; skipping the launcher download for now."
        fi
        return 0
    fi

    release_json="$WORK/claudex-release.json"
    selection="$WORK/claudex-selection.txt"

    if [ -n "$existing" ]; then
        if fetch_latest_release "$CLAUDEX_REPO" "$release_json"; then
            if ! select_asset_from_release "$release_json" "$CLAUDEX_ASSET_OVERRIDE" "$selection"; then
                warn "no ClaudeX package in the latest release; keeping the existing launcher."
                return 0
            fi
            if ! parse_selection "$selection"; then
                warn "cannot parse the ClaudeX release; keeping the existing launcher."
                return 0
            fi
            if [ -n "$CLAUDEX_ASSET_OVERRIDE" ] && [ "$ASSET_NAME" != "$CLAUDEX_ASSET_OVERRIDE" ]; then
                warn "release has no asset $CLAUDEX_ASSET_OVERRIDE; keeping the existing launcher."
                return 0
            fi

            if [ "$FORCE_UPDATE" -eq 0 ] && [ -n "$marker_tag" ] &&
                [ "$marker_repo" = "$CLAUDEX_REPO" ] &&
                [ "$marker_tag" = "$RELEASE_TAG" ] &&
                [ "$marker_asset" = "$ASSET_NAME" ]; then
                ok "ClaudeX is up to date ($RELEASE_TAG)"
                return 0
            fi

            if [ -z "$marker_tag" ] && [ "$FORCE_UPDATE" -eq 0 ]; then
                warn "found a ClaudeX not managed by this script: $existing"
                warn "latest is $RELEASE_TAG; keeping the existing file to avoid overwriting a local build. Run $0 --update to update."
                return 0
            fi

            if install_component_from_release "ClaudeX" "claudex" "$CLAUDEX_BIN" "$CLAUDEX_MARKER" "$CLAUDEX_REPO"; then
                return 0
            fi
            warn "ClaudeX update failed; keeping the existing launcher."
            return 0
        fi

        warn "cannot check for ClaudeX updates (network or GitHub API error); using the existing launcher."
        return 0
    fi

    if fetch_latest_release "$CLAUDEX_REPO" "$release_json"; then
        if ! select_asset_from_release "$release_json" "$CLAUDEX_ASSET_OVERRIDE" "$selection"; then
            HARD_FAIL=1
            err "no ClaudeX package found in the latest release."
            return 1
        fi
        if ! parse_selection "$selection"; then
            HARD_FAIL=1
            err "cannot parse the ClaudeX release."
            return 1
        fi
        if [ -n "$CLAUDEX_ASSET_OVERRIDE" ] && [ "$ASSET_NAME" != "$CLAUDEX_ASSET_OVERRIDE" ]; then
            HARD_FAIL=1
            err "release has no asset $CLAUDEX_ASSET_OVERRIDE."
            return 1
        fi

        if install_component_from_release "ClaudeX" "claudex" "$CLAUDEX_BIN" "$CLAUDEX_MARKER" "$CLAUDEX_REPO"; then
            return 0
        fi
        HARD_FAIL=1
        err "ClaudeX download/installation failed."
        return 1
    fi

    HARD_FAIL=1
    err "cannot fetch ClaudeX release info and no local launcher exists."
    return 1
}

# ---------------------------------------------------------------------------
# claudex-config.json
# ---------------------------------------------------------------------------

config_is_valid() {
    [ -f "$CONFIG_FILE" ] || return 1
    perl -MJSON::PP -e '
        local $/;
        open my $fh, "<:raw", $ARGV[0] or exit 1;
        my $raw = <$fh>;
        close $fh;
        $raw =~ s/^\xEF\xBB\xBF//;
        my $doc = eval { JSON::PP->new->utf8->decode($raw) };
        exit((ref($doc) eq "HASH") ? 0 : 1);
    ' "$CONFIG_FILE" 2>/dev/null
}

config_is_complete() {
    [ -f "$CONFIG_FILE" ] || return 1
    perl -MJSON::PP -e '
        local $/;
        open my $fh, "<:raw", $ARGV[0] or exit 1;
        my $raw = <$fh>;
        close $fh;
        $raw =~ s/^\xEF\xBB\xBF//;
        my $doc = eval { JSON::PP->new->utf8->decode($raw) };
        exit 1 unless $doc && ref($doc) eq "HASH";
        for my $key (qw(version theme claudePath claudeExclude launchCommand claudeConfigDir tempDir logFile tabOnlySectionSwitch projects)) {
            exit 1 unless exists $doc->{$key};
        }
        exit 0;
    ' "$CONFIG_FILE" 2>/dev/null
}

write_fallback_config() {
    tmp="$CONFIG_FILE.tmp.$$"
    cat >"$tmp" <<'EOF'
{
  "version": 1,
  "theme": "claudex-theme.json",
  "claudePath": ["claude*"],
  "claudeExclude": ["ClaudeX*"],
  "launchCommand": {
    "windows": "set \"CLAUDE_CONFIG_DIR={claudeConfigDir}\" && set \"TEMP={tempDir}\" && set \"TMP={tempDir}\" && set \"TMPDIR={tempDir}\" && {claude}",
    "posix": "CLAUDE_CONFIG_DIR='{claudeConfigDir}' TEMP='{tempDir}' TMP='{tempDir}' TMPDIR='{tempDir}' {claude}"
  },
  "claudeConfigDir": "data",
  "tempDir": "data/tmp",
  "logFile": "claudex.log",
  "tabOnlySectionSwitch": false,
  "projects": []
}
EOF
    rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        return 1
    }
    return 0
}

run_launcher_once() {
    [ -n "$LAUNCHER" ] || return 1
    [ -f "$LAUNCHER" ] || return 1

    if [ -f "$CONFIG_FILE" ] && ! config_is_valid; then
        backup="$CONFIG_FILE.invalid.$(date +%Y%m%d-%H%M%S)"
        if mv -f "$CONFIG_FILE" "$backup" 2>/dev/null; then
            warn "existing config cannot be parsed; backed up to $backup"
        else
            rm -f "$CONFIG_FILE" 2>/dev/null || true
        fi
    fi

    info "Running ClaudeX to generate/repair the configuration file (it will close automatically)..."
    log="$WORK/launcher.log"

    "$LAUNCHER" --config "$CONFIG_FILE" </dev/null >"$log" 2>&1 &
    LAUNCHER_PID=$!

    waited=0
    while [ "$waited" -lt "$LAUNCHER_TIMEOUT" ]; do
        if config_is_valid; then
            break
        fi
        if ! kill -0 "$LAUNCHER_PID" 2>/dev/null; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Give the just-written config file a moment to reach disk.
    if ! config_is_valid; then
        sleep 1
    fi

    stop_process "$LAUNCHER_PID"
    LAUNCHER_PID=""

    if config_is_valid; then
        ok "generated $CONFIG_NAME"
        return 0
    fi

    warn "ClaudeX did not generate a valid configuration file."
    if [ -s "$log" ]; then
        say "--- ClaudeX output (last 5 lines) ---" >&2
        tail -n 5 "$log" 2>/dev/null | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\r//g; s/\x00//g' >&2 || true
        say "-----------------------------" >&2
    fi
    return 1
}

apply_config() {
    if [ -f "$CONFIG_FILE" ]; then
        cp -p "$CONFIG_FILE" "$CONFIG_FILE.before-setup" 2>/dev/null ||
            warn "cannot back up the config to $CONFIG_FILE.before-setup"
    fi

    perl -MJSON::PP -e '
        use strict;
        use warnings;

        my ($path, $claude_path) = @ARGV;
        local $/;
        open my $fh, "<:raw", $path or die "cannot read config: $!\n";
        my $raw = <$fh>;
        close $fh;
        $raw =~ s/^\xEF\xBB\xBF//;

        my $doc = eval { JSON::PP->new->utf8->decode($raw) };
        die "config is not a valid JSON object\n" unless $doc && ref($doc) eq "HASH";

        $doc->{claudeConfigDir} = "data";
        $doc->{claudePath} = [ $claude_path ];

        my $out = JSON::PP->new->utf8
            ->canonical(1)
            ->indent
            ->indent_length(2)
            ->space_before(0)
            ->space_after(1)
            ->encode($doc);
        $out .= "\n" unless $out =~ /\n\z/;

        my $tmp = $path . ".tmp.$$";
        open my $ofh, ">:raw", $tmp or die "cannot write config: $!\n";
        print $ofh $out;
        close $ofh or die "cannot write config: $!\n";
        rename $tmp, $path or die "cannot replace config: $!\n";
    ' "$CONFIG_FILE" "$CLAUDE_PATH_CONFIG" || return 1

    return 0
}

verify_config_values() {
    perl -MJSON::PP -e '
        local $/;
        open my $fh, "<:raw", $ARGV[0] or exit 1;
        my $raw = <$fh>;
        close $fh;
        $raw =~ s/^\xEF\xBB\xBF//;
        my $doc = eval { JSON::PP->new->utf8->decode($raw) };
        exit 1 unless $doc && ref($doc) eq "HASH";

        exit 1 unless (($doc->{claudeConfigDir} // "") eq "data");

        my $path = $doc->{claudePath};
        if (ref($path) eq "ARRAY") {
            exit 1 unless @$path == 1 && ($path->[0] // "") eq $ARGV[1];
        } else {
            exit 1 unless ($path // "") eq $ARGV[1];
        }
        exit 0;
    ' "$CONFIG_FILE" "$CLAUDE_PATH_CONFIG" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

display_path() {
    if [ "$OS" = "windows" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1" 2>/dev/null || printf '%s' "$1"
    else
        printf '%s' "$1"
    fi
}

print_banner() {
    libc_suffix=""
    [ "$LIBC" = "musl" ] && libc_suffix=" (musl)"
    say "${BOLD}ClaudeX + Claude Code portable setup${RESET}"
    say "  Script directory: $(display_path "$ROOT")"
    say "  Detected:         $PLATFORM_LABEL $ARCH$libc_suffix"
    say ""
}

print_summary() {
    libc_suffix=""
    [ "$LIBC" = "musl" ] && libc_suffix=" (musl)"

    say ""
    say "${BOLD}================ Done ================${RESET}"
    say "  Platform:     $PLATFORM_LABEL $ARCH$libc_suffix"
    say "  Script dir:   $(display_path "$ROOT")"

    if [ -n "$LAUNCHER" ] && [ -f "$LAUNCHER" ]; then
        say "  ClaudeX:     $(display_path "$LAUNCHER")"
    else
        say "  ClaudeX:      not installed"
    fi

    if [ -f "$CLAUDE_BIN" ]; then
        say "  Claude Code: $(display_path "$CLAUDE_BIN")"
    else
        say "  Claude Code:  not installed"
    fi

    say "  Config file:  $(display_path "$CONFIG_FILE")"
    say "    claudeConfigDir = data"
    say "    claudePath      = $CLAUDE_PATH_CONFIG"

    if [ -n "$LAUNCHER" ] && [ -f "$LAUNCHER" ]; then
        if [ "$OS" = "$DETECTED_OS" ] && [ "$ARCH" = "$DETECTED_ARCH" ]; then
            say ""
            say "Launch: $(display_path "$LAUNCHER")"
        else
            say ""
            say "This is the $PLATFORM_LABEL $ARCH build; it cannot run on this host."
        fi
    else
        say ""
        say "Once ClaudeX is ready, run $CLAUDEX_EXE in the script folder."
    fi

    if [ "$CLAUDEX_MISSING_PLACEHOLDER" -eq 1 ]; then
        say ""
        say "${YELLOW}Note: the ClaudeX GitHub repository is still a placeholder.${RESET}"
        say "      Re-run this script after publishing, or use:"
        say "      $0 --claudex-repo <owner>/<repo>"
    fi

    if [ "$WARNINGS" -gt 0 ]; then
        say ""
        say "This run produced $WARNINGS warning(s); see the output above."
    fi
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

install_current_target() {
    apply_platform_vars
    select_claude_asset_name

    print_banner

    if [ "$DO_CLAUDEX" -eq 1 ]; then
        ensure_claudex || true
    else
        info "Skipping ClaudeX download/update (--no-claudex)"
    fi

    if [ "$DO_CLAUDE" -eq 1 ]; then
        ensure_claude || true
    else
        info "Skipping Claude Code download/update (--no-claude)"
    fi
}

configure_install() {
    LAUNCHER=$(find_existing_claudex 2>/dev/null || true)
    if [ -n "$LAUNCHER" ]; then
        chmod 755 "$LAUNCHER" 2>/dev/null || true
    fi

    native=0
    if [ "$OS" = "$DETECTED_OS" ] && [ "$ARCH" = "$DETECTED_ARCH" ]; then
        native=1
    fi

    if [ "$native" -eq 1 ] && [ -n "$LAUNCHER" ] && [ -f "$LAUNCHER" ]; then
        if ! config_is_valid || ! config_is_complete; then
            run_launcher_once || true
        fi
    fi

    if [ ! -f "$CONFIG_FILE" ] || ! config_is_valid; then
        if [ -f "$CONFIG_FILE" ]; then
            cp -p "$CONFIG_FILE" "$CONFIG_FILE.invalid" 2>/dev/null || true
        fi
        warn "Writing default config $CONFIG_NAME"
        write_fallback_config || die "cannot write $CONFIG_FILE"
    fi

    apply_config || die "cannot update $CONFIG_FILE"
    verify_config_values || die "config validation failed: $CONFIG_FILE"

    mkdir -p "$DATA_DIR" "$PORTABLE_TEMP_DIR" 2>/dev/null ||
        warn "cannot create data directory: $DATA_DIR"

    if [ -f "$CLAUDE_BIN" ]; then
        chmod 755 "$CLAUDE_BIN" 2>/dev/null || true
    else
        if [ "$DO_CLAUDE" -eq 1 ]; then
            err "Claude Code was not installed to $CLAUDE_BIN"
            HARD_FAIL=1
        else
            info "Claude Code not installed (download skipped)"
        fi
    fi

    if [ -z "$LAUNCHER" ] || [ ! -f "$LAUNCHER" ]; then
        if [ "$DO_CLAUDEX" -eq 0 ]; then
            info "ClaudeX not installed (download skipped)"
        elif [ "$CLAUDEX_MISSING_PLACEHOLDER" -eq 1 ]; then
            warn "ClaudeX is not installed yet: the repository is still a placeholder."
        else
            err "ClaudeX not installed"
            HARD_FAIL=1
        fi
    fi
}

print_multi_summary() {
    say ""
    say "${BOLD}================ Done ================${RESET}"
    say "  Install dir:  $(display_path "$BASE_ROOT")"
    say "  Targets:"
    for target in $MULTI_TARGETS; do
        platform=${target%-*}
        arch=${target#*-}
        exe="ClaudeX-$platform-$arch"
        [ "$platform" = "windows" ] && exe="$exe.exe"
        label=$(printf '%-14s' "$platform/$arch")
        if [ -f "$BASE_ROOT/$exe" ]; then
            say "    $label $(display_path "$BASE_ROOT/$exe")"
        else
            say "    $label not installed"
        fi
    done
    say ""
    say "  All launchers share this folder; Claude Code builds are under bin/<arch>/<platform>/."
}

main() {
    parse_args "$@"
    detect_platform
    prompt_platform_arch
    prompt_install_dir
    BASE_ROOT=$ROOT
    check_dependencies
    setup_work

    platforms=$OS
    [ "$ALL_TARGETS" -eq 1 ] && platforms="windows macos linux"
    arches=$ARCH
    [ "$ALL_ARCH" -eq 1 ] && arches="x64 arm64"

    MULTI_TARGETS=""
    for p in $platforms; do
        for a in $arches; do
            MULTI_TARGETS="$MULTI_TARGETS $p-$a"
        done
    done

    set -- $MULTI_TARGETS
    for target in "$@"; do
        OS=${target%-*}
        ARCH=${target#*-}
        ROOT=$BASE_ROOT
        install_current_target
    done

    # One shared config. Prefer the host target; otherwise use the first one.
    config_target=""
    for target in "$@"; do
        if [ "$target" = "$DETECTED_OS-$DETECTED_ARCH" ]; then
            config_target=$target
            break
        fi
    done
    [ -n "$config_target" ] || config_target=$1

    OS=${config_target%-*}
    ARCH=${config_target#*-}
    ROOT=$BASE_ROOT
    apply_platform_vars
    configure_install

    if [ "$#" -gt 1 ]; then
        print_multi_summary
    else
        print_summary
    fi

    if [ "$HARD_FAIL" -ne 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"
