#!/bin/sh
# ============================================================================
# setup-portable.sh - 一键部署便携版 ClaudeX + Claude Code
#
# 功能:
#   1. 自动识别当前操作系统与 CPU 架构
#      Windows / macOS / Linux，x64 / arm64（Linux 会自动识别 musl）
#   2. 从 GitHub Releases 下载最新版 ClaudeX 与 Claude Code，并自动解压
#      - ClaudeX 放在脚本所在目录 ./ClaudeX[.exe]
#      - Claude Code 放在 ./bin/<arch>/<platform>/claude[.exe]
#   3. 首次运行 ClaudeX 生成 claudex-config.json，随后立即关闭它
#   4. 把配置里的 claudeConfigDir 改为 data，把 claudePath 指向
#      bin/<arch>/<platform>/claude*
#
# 目录约定（全部相对于脚本所在目录）:
#   ./ClaudeX[.exe]                      ClaudeX 启动器
#   ./claudex-config.json                启动器配置
#   ./data/                              便携式 CLAUDE_CONFIG_DIR
#   ./data/tmp/                          便携式临时目录
#   ./bin/<arch>/<platform>/claude*      Claude Code 本体
#
# 三平台支持:
#   - Linux / macOS: 直接用系统自带的 POSIX sh 运行
#   - Windows:       通过 Git for Windows 提供的 Git Bash 运行
#                    （脚本会处理 .exe、zip、taskkill 等 Windows 细节）
#
# 依赖: POSIX sh、curl、tar、perl（JSON::PP 模块）、find/awk/sed/grep
#       Windows 解压 zip 还需要 unzip（Git Bash 自带），或 PowerShell 兜底。
#
# 注意: 本脚本不会修改 ClaudeX 的源代码，只下载 release 并修改运行时配置。
# ============================================================================

set -u
export LC_ALL=C

# ---------------------------------------------------------------------------
# 常量与可覆盖配置
# ---------------------------------------------------------------------------

# TODO: ClaudeX 发布到 GitHub 后，把下面的占位符换成真实的 owner/repo。
#       也可以运行时用 --claudex-repo owner/repo 或环境变量 CLAUDEX_REPO 覆盖。
#
# 建议的 ClaudeX release 资产命名（脚本会自动识别平台/架构标记）:
#   ClaudeX-windows-x64.zip       ClaudeX-windows-arm64.zip
#   ClaudeX-macos-x64.tar.gz      ClaudeX-macos-arm64.tar.gz
#   ClaudeX-linux-x64.tar.gz      ClaudeX-linux-arm64.tar.gz
# 也可以直接发布裸二进制，例如 ClaudeX.exe / ClaudeX-linux-x64。
# 压缩包内应包含名为 ClaudeX / ClaudeX.exe（大小写不敏感）的可执行文件；
# 如果压缩包内只有一个其它名字的可执行文件，脚本也会采用它。
CLAUDEX_REPO_PLACEHOLDER="JPTV-21/Claudex"
CLAUDEX_REPO=${CLAUDEX_REPO:-$CLAUDEX_REPO_PLACEHOLDER}
CLAUDE_REPO=${CLAUDE_REPO:-anthropics/claude-code}

API_BASE="https://api.github.com"
GITHUB_BASE="https://github.com"
USER_AGENT="claudex-portable-setup/1.0"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || {
    printf 'error: 无法确定脚本所在目录\n' >&2
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
# 输出辅助
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
    say "运行 '$0 --help' 查看用法。"
    exit 2
}

# ---------------------------------------------------------------------------
# 进程与临时目录清理
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
# 帮助
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
用法: sh $0 [选项]

一键部署便携版 ClaudeX + Claude Code。脚本会把 ClaudeX 放在脚本所在
目录，把 Claude Code 放在 bin/<arch>/<platform>/ 下，并自动生成/修改
claudex-config.json。

请把本脚本放在你希望作为便携根目录的文件夹中运行；脚本所在目录就是
ClaudeX、data/ 和 bin/ 的根目录。

选项:
  -u, --update             强制重新下载最新版 ClaudeX 与 Claude Code
      --no-claudex         跳过 ClaudeX 的下载/更新
      --no-claude          跳过 Claude Code 的下载/更新
      --platform OS        安装平台：windows/macos/linux/all（默认检测）
      --arch ARCH          CPU 架构：x64/arm64（默认检测）
      --all                下载全部 6 个平台/架构组合，每项一个子目录
      --install-dir DIR    安装目录（默认脚本所在目录）
  -y, --yes                使用默认值，不进行交互询问
      --claudex-repo REPO  指定 ClaudeX 仓库（owner/repo）
      --claudex-asset NAME 指定 ClaudeX release 中的资产文件名
      --claude-repo REPO   指定 Claude Code 仓库
                           （默认 anthropics/claude-code）
      --timeout SECONDS    等待 ClaudeX 生成配置文件的秒数（默认 20）
  -h, --help               显示本帮助

环境变量:
  GITHUB_TOKEN / GH_TOKEN  提高 GitHub API 速率限制
  CLAUDEX_REPO             覆盖 ClaudeX 仓库地址
  HTTPS_PROXY / HTTP_PROXY / NO_PROXY
                           由 curl 自动使用
  NO_COLOR                 禁用彩色输出

平台支持:
  Linux / macOS  使用系统 POSIX sh 直接运行
  Windows        使用 Git for Windows 提供的 Git Bash 运行，
                 例如: bash setup-portable.sh

示例:
  sh setup-portable.sh
  bash setup-portable.sh --update
  bash setup-portable.sh --install-dir /opt/claudex --yes
  bash setup-portable.sh --platform macos --arch arm64
  bash setup-portable.sh --all --install-dir /opt/claudex
  bash setup-portable.sh --claudex-repo owner/claudex
EOF
}

# ---------------------------------------------------------------------------
# 参数解析与校验
# ---------------------------------------------------------------------------

validate_repo() {
    repo=$1
    option=$2
    case "$repo" in
        */*)
            printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || {
                err "$option 需要 owner/repo 格式，收到：$repo"
                return 1
            }
            ;;
        *)
            err "$option 需要 owner/repo 格式，收到：$repo"
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
                ;;
            --platform)
                [ "$#" -ge 2 ] || usage_error "--platform 需要一个平台名"
                PLATFORM_OVERRIDE=$2
                shift
                ;;
            --platform=*)
                PLATFORM_OVERRIDE=${1#*=}
                ;;
            --arch)
                [ "$#" -ge 2 ] || usage_error "--arch 需要一个架构名"
                ARCH_OVERRIDE=$2
                shift
                ;;
            --arch=*)
                ARCH_OVERRIDE=${1#*=}
                ;;
            --install-dir)
                [ "$#" -ge 2 ] || usage_error "--install-dir 需要一个目录"
                INSTALL_DIR_OVERRIDE=$2
                shift
                ;;
            --install-dir=*)
                INSTALL_DIR_OVERRIDE=${1#*=}
                ;;
            --claudex-repo)
                [ "$#" -ge 2 ] || usage_error "--claudex-repo 需要一个 owner/repo 参数"
                CLAUDEX_REPO=$2
                shift
                ;;
            --claudex-repo=*)
                CLAUDEX_REPO=${1#*=}
                ;;
            --claudex-asset)
                [ "$#" -ge 2 ] || usage_error "--claudex-asset 需要一个资产文件名"
                CLAUDEX_ASSET_OVERRIDE=$2
                shift
                ;;
            --claudex-asset=*)
                CLAUDEX_ASSET_OVERRIDE=${1#*=}
                ;;
            --claude-repo)
                [ "$#" -ge 2 ] || usage_error "--claude-repo 需要一个 owner/repo 参数"
                CLAUDE_REPO=$2
                shift
                ;;
            --claude-repo=*)
                CLAUDE_REPO=${1#*=}
                ;;
            --timeout)
                [ "$#" -ge 2 ] || usage_error "--timeout 需要一个秒数"
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
                usage_error "未知选项：$1"
                ;;
        esac
        shift
    done

    case "$LAUNCHER_TIMEOUT" in
        ''|*[!0-9]*)
            usage_error "--timeout 必须是正整数"
            ;;
    esac

    case "$CLAUDEX_ASSET_OVERRIDE" in
        */*|*..*)
            usage_error "--claudex-asset 不能包含路径分隔符或 .."
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
# 平台检测
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
            die "不支持的操作系统：$sys"
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
            die "不支持的 CPU 架构：$raw_arch"
            ;;
    esac

    # Apple Silicon 上通过 Rosetta 运行 x86_64 shell 时，仍然下载原生 arm64 版本。
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
            CLAUDEX_EXE="ClaudeX.exe"
            ;;
        macos)
            PLATFORM_LABEL="macOS"
            CLAUDE_EXE="claude"
            CLAUDEX_EXE="ClaudeX"
            ;;
        linux)
            PLATFORM_LABEL="Linux"
            CLAUDE_EXE="claude"
            CLAUDEX_EXE="ClaudeX"
            ;;
    esac

    CLAUDE_DEST="$ROOT/bin/$ARCH/$OS"
    CLAUDE_BIN="$CLAUDE_DEST/$CLAUDE_EXE"
    CLAUDE_MARKER="$CLAUDE_DEST/.claude-version"
    CLAUDEX_BIN="$ROOT/$CLAUDEX_EXE"
    CLAUDEX_MARKER="$ROOT/.claudex-version"
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
    if [ "$ALL_TARGETS" -eq 0 ]; then
        [ -z "$ARCH_OVERRIDE" ] || ARCH=$ARCH_OVERRIDE
    fi

    if [ "$INTERACTIVE" -eq 1 ]; then
        printf '安装平台 [%s] (windows/macos/linux/all): ' "$OS"
        read answer || answer=""
        case "$answer" in
            "") ;;
            windows|macos|linux|all) OS=$answer ;;
            *) warn "无效平台：$answer，使用 $OS" ;;
        esac

        if [ "$OS" != "all" ]; then
            printf 'CPU 架构 [%s] (x64/arm64): ' "$ARCH"
            read answer || answer=""
            case "$answer" in
                "") ;;
                x64|arm64) ARCH=$answer ;;
                *) warn "无效架构：$answer，使用 $ARCH" ;;
            esac
        fi
    fi

    case "$OS" in
        windows|macos|linux) ;;
        all) ALL_TARGETS=1 ;;
        *) die "不支持的平台：$OS" ;;
    esac

    if [ "$ALL_TARGETS" -eq 1 ]; then
        info "将下载全部 6 个平台/架构组合，每项一个子目录。"
    else
        case "$ARCH" in
            x64|arm64) ;;
            *) die "不支持的架构：$ARCH" ;;
        esac
        if [ "$OS" != "$DETECTED_OS" ] || [ "$ARCH" != "$DETECTED_ARCH" ]; then
            info "将下载 $OS/$ARCH 版本（不会在本机运行）。"
        fi
    fi
}

prompt_install_dir() {
    if [ -n "$INSTALL_DIR_OVERRIDE" ]; then
        ROOT=$INSTALL_DIR_OVERRIDE
    elif [ "$INTERACTIVE" -eq 1 ]; then
        printf '安装目录 [%s]: ' "$ROOT"
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
            printf '目录不存在：%s\n是否创建？[Y/n]: ' "$ROOT"
            read answer || answer=""
            case "$answer" in
                n|N|no|NO) die "已取消。" ;;
            esac
        fi
        mkdir -p "$ROOT" || die "无法创建目录：$ROOT"
        ok "已创建目录：$ROOT"
    fi
    [ -w "$ROOT" ] || die "目录不可写：$ROOT"
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
            die "没有适用于 $OS/$ARCH/$LIBC 的 Claude Code 安装包"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 依赖与临时目录
# ---------------------------------------------------------------------------

check_dependencies() {
    command -v curl >/dev/null 2>&1 || die "缺少 curl。Windows 请使用 Git Bash，或安装 curl。"
    command -v tar >/dev/null 2>&1 || die "缺少 tar。"
    command -v perl >/dev/null 2>&1 || die "缺少 perl。"
    perl -MJSON::PP -e '1' >/dev/null 2>&1 || die "缺少 Perl 模块 JSON::PP。"
    command -v find >/dev/null 2>&1 || die "缺少 find。"
    command -v awk >/dev/null 2>&1 || die "缺少 awk。"
    command -v sed >/dev/null 2>&1 || die "缺少 sed。"
    command -v grep >/dev/null 2>&1 || die "缺少 grep。"
    command -v mkdir >/dev/null 2>&1 || die "缺少 mkdir。"
    command -v cp >/dev/null 2>&1 || die "缺少 cp。"
    command -v mv >/dev/null 2>&1 || die "缺少 mv。"
    command -v chmod >/dev/null 2>&1 || die "缺少 chmod。"
    command -v date >/dev/null 2>&1 || die "缺少 date。"

    CURL=$(command -v curl)

    if command -v sha256sum >/dev/null 2>&1; then
        SHA256_CMD="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        SHA256_CMD="shasum"
    else
        SHA256_CMD=""
        warn "未找到 sha256sum/shasum，将跳过 SHA-256 校验。"
    fi
}

setup_work() {
    if command -v mktemp >/dev/null 2>&1; then
        WORK=$(mktemp -d "${TMPDIR:-/tmp}/claudex-setup.XXXXXX" 2>/dev/null) || WORK=""
    fi
    if [ -z "$WORK" ]; then
        WORK="${TMPDIR:-/tmp}/claudex-setup.$$"
        (umask 077 && mkdir -p "$WORK") || die "无法创建临时目录：$WORK"
    fi
}

# ---------------------------------------------------------------------------
# 下载与 GitHub API
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
            warn "$dl_label 下载中断（尝试 $dl_attempt/$dl_max_attempts），2 秒后继续…"
            sleep 2
        fi
        dl_attempt=$((dl_attempt + 1))
    done

    rm -f "$dl_dest"
    dl_detail=$(tail -n 1 "$dl_err_file" 2>/dev/null | tr -d '\r')
    warn "$dl_label 下载失败${dl_detail:+：$dl_detail}"
    return 1
}

download_release_asset() {
    dl_label=$1
    dl_dest="$WORK/$ASSET_NAME"

    if [ -n "$ASSET_BROWSER_URL" ]; then
        if download_plain "$ASSET_BROWSER_URL" "$dl_dest" "$dl_label" 0; then
            return 0
        fi
        warn "$dl_label: 直链下载失败，改用 GitHub API 重试。"
    fi
    if [ -n "$ASSET_API_URL" ]; then
        if download_plain "$ASSET_API_URL" "$dl_dest" "$dl_label" 1; then
            return 0
        fi
    fi
    warn "$dl_label: 下载失败。"
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
            warn "GitHub API 速率受限（设置 GITHUB_TOKEN 可提高上限）：$detail"
            return 1
            ;;
        404)
            warn "GitHub 仓库不存在或没有 release：$repo"
            return 1
            ;;
        000)
            detail=$(tail -n 1 "$err_file" 2>/dev/null | tr -d '\r')
            warn "无法连接 GitHub API${detail:+：$detail}"
            return 1
            ;;
        *)
            detail=$(head -n 1 "$out" 2>/dev/null | cut -c1-240 | tr -d '\r')
            warn "GitHub API 返回 HTTP $status${detail:+：$detail}"
            return 1
            ;;
    esac
}

# 从 release JSON 中选择当前平台/架构的资产。
# 输出两行（TAB 分隔）:
#   TAG<TAB>标签
#   ASSET<TAB>文件名<TAB>browser_url<TAB>api_url
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
            print "ERROR\t无法读取 release JSON\n";
            exit 1;
        };
        my $raw = <$fh>;
        close $fh;
        $raw =~ s/^\xEF\xBB\xBF//;

        my $rel = eval { JSON::PP->new->utf8->decode($raw) };
        if (!$rel || ref($rel) ne "HASH" || !$rel->{tag_name}) {
            print "ERROR\trelease JSON 缺少 tag_name\n";
            exit 1;
        }

        my $tag = $rel->{tag_name};
        my @assets = @{ $rel->{assets} || [] };

        # 优先精确匹配预期资产名（Claude Code 的资产名是固定的）。
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

            # 校验文件、签名、安装器、源码包不参与自动选择。
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
            print "ERROR\t没有匹配 $os/$arch/$libc 的 release 资产\n";
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
            warn "解析 release 资产失败${detail:+：$detail}"
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
            warn "release 返回了非法的资产名：$ASSET_NAME"
            return 1
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# SHA-256 校验
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
        err "$label: 下载文件缺失或为空，安装已中止。"
        return 1
    fi

    if [ -z "$SHA256_CMD" ]; then
        warn "$label: 没有可用的 SHA-256 工具，跳过校验。"
        return 0
    fi

    shasums="$WORK/SHASUMS256.txt"
    if ! fetch_shasums "$repo" "$ref" "$shasums"; then
        warn "$label: 无法获取 SHASUMS256.txt，跳过校验。"
        return 0
    fi

    expected=$(awk -v n="$asset" '$2 == n || $2 == ("*" n) { print $1; exit }' "$shasums")
    if [ -z "$expected" ]; then
        warn "$label: SHASUMS256.txt 中没有 $asset，跳过校验。"
        return 0
    fi

    actual=$(sha256_of "$file") || {
        warn "$label: 无法计算 SHA-256，跳过校验。"
        return 0
    }

    if [ "$actual" != "$expected" ]; then
        err "$label: SHA-256 校验失败"
        err "  期望: $expected"
        err "  实际: $actual"
        return 1
    fi

    ok "$label: SHA-256 校验通过"
    return 0
}

# ---------------------------------------------------------------------------
# 解压与文件查找
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
        warn "无法读取 tar 包：$(tail -n 1 "$WORK/tar.err" 2>/dev/null | tr -d '\r')"
        return 1
    }
    if ! archive_list_safe "$list"; then
        warn "压缩包包含不安全的路径，已拒绝解压。"
        return 1
    fi
    # 拒绝符号链接和硬链接，避免解压时跳出临时目录。
    if tar -tvf "$archive" 2>/dev/null | awk 'substr($1, 1, 1) == "l" || substr($1, 1, 1) == "h" { bad = 1 } END { exit (bad ? 0 : 1) }'; then
        warn "压缩包包含符号链接或硬链接，已拒绝解压。"
        return 1
    fi

    tar -xf "$archive" -C "$outdir" || {
        warn "tar 解压失败。"
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
            warn "无法读取 zip 包。"
            return 1
        fi
        if ! archive_list_safe "$list"; then
            warn "压缩包包含不安全的路径，已拒绝解压。"
            return 1
        fi
        unzip -q "$archive" -d "$outdir"
        rc=$?
        # Info-ZIP 返回 1 表示“完成但有警告”（例如 Windows 生成的
        # 反斜杠路径），此时文件通常已经正确解压；2 以上才是错误。
        if [ "$rc" -gt 1 ]; then
            warn "zip 解压失败（unzip 返回 $rc）。"
            return 1
        fi
        if [ "$rc" -eq 1 ]; then
            warn "zip 解压完成，但 unzip 报告了警告（已继续）。"
        fi
        return 0
    fi

    # bsdtar 也能读取 zip（Windows 自带的 tar.exe、部分 macOS 环境）。
    if tar -tf "$archive" >"$list" 2>/dev/null; then
        if ! archive_list_safe "$list"; then
            warn "压缩包包含不安全的路径，已拒绝解压。"
            return 1
        fi
        tar -xf "$archive" -C "$outdir" || {
            warn "zip 解压失败。"
            return 1
        }
        return 0
    fi

    if [ "$OS" = "windows" ] && command -v powershell >/dev/null 2>&1; then
        ARCHIVE_PATH=$archive EXTRACT_PATH=$outdir powershell -NoProfile -ExecutionPolicy Bypass \
            -Command 'Expand-Archive -LiteralPath $env:ARCHIVE_PATH -DestinationPath $env:EXTRACT_PATH -Force' \
            >/dev/null 2>&1 || {
            warn "PowerShell 解压失败。"
            return 1
        }
        return 0
    fi

    warn "缺少 unzip，无法解压 zip 包。"
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
            # 裸二进制（例如直接发布的 ClaudeX.exe / claudex-linux-x64）。
            cp -f "$archive" "$outdir/$(basename "$name")" || {
                warn "无法复制裸二进制文件。"
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
            # 文件名不含 claudex 时，只有在压缩包里仅剩一个可执行候选时才采用，
            # 避免误把 README、DLL、脚本之类的东西当成启动器。
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
# 组件安装
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

    info "下载 $label $RELEASE_TAG（$ASSET_NAME）"
    download_release_asset "$label" || {
        err "$label: 下载失败，安装已中止。"
        return 1
    }

    verify_download "$label" "$VERIFY_REF" "$archive" "$ASSET_NAME" "$repo" || return 1

    extract_archive "$archive" "$extract_dir" "$ASSET_NAME" || return 1

    bin=$(find_component_binary "$extract_dir" "$kind") || {
        warn "$label: 压缩包中找不到可执行文件。"
        return 1
    }
    install_binary "$bin" "$install_dest" || {
        warn "$label: 安装到 $install_dest 失败。"
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
            "exe=$(basename "$dest")" || warn "$label: 无法写入版本标记。"
    else
        write_marker "$marker" \
            "repo=$repo" \
            "tag=$RELEASE_TAG" \
            "asset=$ASSET_NAME" \
            "sha256=$sha" || warn "$label: 无法写入版本标记。"
    fi

    ok "$label 已安装：$install_dest"
    return 0
}

# 尝试从 /releases/latest/download/... 的重定向链里解析真实 tag。
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
                warn "无法在最新 release 中匹配 Claude Code 安装包，保留现有版本。"
                return 0
            fi
            HARD_FAIL=1
            err "无法在最新 release 中匹配 Claude Code 安装包。"
            return 1
        fi

        parse_selection "$selection" || {
            if [ "$have" -eq 1 ]; then
                warn "无法解析 Claude Code release，保留现有版本。"
                return 0
            fi
            HARD_FAIL=1
            err "无法解析 Claude Code release。"
            return 1
        }

        if [ "$have" -eq 1 ] && [ "$FORCE_UPDATE" -eq 0 ] &&
            [ -n "$marker_tag" ] && [ "$marker_repo" = "$CLAUDE_REPO" ] &&
            [ "$marker_tag" = "$RELEASE_TAG" ] && [ "$marker_asset" = "$ASSET_NAME" ]; then
            ok "Claude Code 已是最新（$RELEASE_TAG）"
            return 0
        fi

        if [ "$have" -eq 1 ]; then
            if install_component_from_release "Claude Code" "claude" "$CLAUDE_BIN" "$CLAUDE_MARKER" "$CLAUDE_REPO"; then
                return 0
            fi
            warn "Claude Code 更新失败，保留现有版本。"
            return 0
        fi

        if install_component_from_release "Claude Code" "claude" "$CLAUDE_BIN" "$CLAUDE_MARKER" "$CLAUDE_REPO"; then
            return 0
        fi
        HARD_FAIL=1
        err "Claude Code 下载/安装失败。"
        return 1
    fi

    if [ "$have" -eq 1 ] && [ "$FORCE_UPDATE" -eq 0 ]; then
        warn "无法检查 Claude Code 更新（网络或 GitHub API 错误），继续使用现有版本。"
        return 0
    fi

    # API 不可用时，尝试 GitHub 的 latest 直链（首次安装或 --update 时）。
    warn "无法获取 Claude Code release 信息，尝试 latest 直链下载。"
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
        warn "Claude Code 更新失败，保留现有版本。"
        return 0
    fi

    HARD_FAIL=1
    err "Claude Code 下载失败，且本地没有可用的现有版本。"
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

    for candidate in \
        "$ROOT/$CLAUDEX_EXE" \
        "$ROOT/ClaudeX.exe" \
        "$ROOT/claudex.exe" \
        "$ROOT/ClaudeX" \
        "$ROOT/claudex"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
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
            info "ClaudeX 仓库地址仍是占位符，保留现有启动器：$existing"
        else
            CLAUDEX_MISSING_PLACEHOLDER=1
            warn "ClaudeX 仓库地址仍是占位符：$CLAUDEX_REPO"
            warn "项目发布后，请用 --claudex-repo owner/repo 或环境变量 CLAUDEX_REPO 指定；本次跳过启动器下载。"
        fi
        return 0
    fi

    release_json="$WORK/claudex-release.json"
    selection="$WORK/claudex-selection.txt"

    if [ -n "$existing" ]; then
        if fetch_latest_release "$CLAUDEX_REPO" "$release_json"; then
            if ! select_asset_from_release "$release_json" "$CLAUDEX_ASSET_OVERRIDE" "$selection"; then
                warn "无法在最新 release 中匹配 ClaudeX 安装包，保留现有启动器。"
                return 0
            fi
            if ! parse_selection "$selection"; then
                warn "无法解析 ClaudeX release，保留现有启动器。"
                return 0
            fi
            if [ -n "$CLAUDEX_ASSET_OVERRIDE" ] && [ "$ASSET_NAME" != "$CLAUDEX_ASSET_OVERRIDE" ]; then
                warn "release 中没有资产 $CLAUDEX_ASSET_OVERRIDE，保留现有启动器。"
                return 0
            fi

            if [ "$FORCE_UPDATE" -eq 0 ] && [ -n "$marker_tag" ] &&
                [ "$marker_repo" = "$CLAUDEX_REPO" ] &&
                [ "$marker_tag" = "$RELEASE_TAG" ] &&
                [ "$marker_asset" = "$ASSET_NAME" ]; then
                ok "ClaudeX 已是最新（$RELEASE_TAG）"
                return 0
            fi

            if [ -z "$marker_tag" ] && [ "$FORCE_UPDATE" -eq 0 ]; then
                warn "检测到未由本脚本管理的 ClaudeX：$existing"
                warn "最新版是 $RELEASE_TAG；为避免覆盖本地构建，保留现有文件。需要更新时运行：$0 --update"
                return 0
            fi

            if install_component_from_release "ClaudeX" "claudex" "$CLAUDEX_BIN" "$CLAUDEX_MARKER" "$CLAUDEX_REPO"; then
                return 0
            fi
            warn "ClaudeX 更新失败，保留现有启动器。"
            return 0
        fi

        warn "无法检查 ClaudeX 更新（网络或 GitHub API 错误），继续使用现有启动器。"
        return 0
    fi

    if fetch_latest_release "$CLAUDEX_REPO" "$release_json"; then
        if ! select_asset_from_release "$release_json" "$CLAUDEX_ASSET_OVERRIDE" "$selection"; then
            HARD_FAIL=1
            err "无法在最新 release 中匹配 ClaudeX 安装包。"
            return 1
        fi
        if ! parse_selection "$selection"; then
            HARD_FAIL=1
            err "无法解析 ClaudeX release。"
            return 1
        fi
        if [ -n "$CLAUDEX_ASSET_OVERRIDE" ] && [ "$ASSET_NAME" != "$CLAUDEX_ASSET_OVERRIDE" ]; then
            HARD_FAIL=1
            err "release 中没有资产 $CLAUDEX_ASSET_OVERRIDE。"
            return 1
        fi

        if install_component_from_release "ClaudeX" "claudex" "$CLAUDEX_BIN" "$CLAUDEX_MARKER" "$CLAUDEX_REPO"; then
            return 0
        fi
        HARD_FAIL=1
        err "ClaudeX 下载/安装失败。"
        return 1
    fi

    HARD_FAIL=1
    err "无法获取 ClaudeX release 信息，且本地没有启动器。"
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
            warn "现有配置无法解析，已备份到 $backup"
        else
            rm -f "$CONFIG_FILE" 2>/dev/null || true
        fi
    fi

    info "正在运行 ClaudeX 以生成/修复配置文件（完成后会自动关闭）..."
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

    # 给刚写完的配置文件一点落盘时间。
    if ! config_is_valid; then
        sleep 1
    fi

    stop_process "$LAUNCHER_PID"
    LAUNCHER_PID=""

    if config_is_valid; then
        ok "已生成 $CONFIG_NAME"
        return 0
    fi

    warn "ClaudeX 没有生成有效的配置文件。"
    if [ -s "$log" ]; then
        say "--- ClaudeX 输出（最后 5 行）---" >&2
        tail -n 5 "$log" 2>/dev/null | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\r//g; s/\x00//g' >&2 || true
        say "-----------------------------" >&2
    fi
    return 1
}

apply_config() {
    if [ -f "$CONFIG_FILE" ]; then
        cp -p "$CONFIG_FILE" "$CONFIG_FILE.before-setup" 2>/dev/null ||
            warn "无法备份配置到 $CONFIG_FILE.before-setup"
    fi

    perl -MJSON::PP -e '
        use strict;
        use warnings;

        my ($path, $claude_path) = @ARGV;
        local $/;
        open my $fh, "<:raw", $path or die "无法读取配置：$!\n";
        my $raw = <$fh>;
        close $fh;
        $raw =~ s/^\xEF\xBB\xBF//;

        my $doc = eval { JSON::PP->new->utf8->decode($raw) };
        die "配置文件不是有效的 JSON 对象\n" unless $doc && ref($doc) eq "HASH";

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
        open my $ofh, ">:raw", $tmp or die "无法写入配置：$!\n";
        print $ofh $out;
        close $ofh or die "无法写入配置：$!\n";
        rename $tmp, $path or die "无法替换配置：$!\n";
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
# 展示
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
    say "${BOLD}便携版 Claude Code 一键部署${RESET}"
    say "  脚本目录: $(display_path "$ROOT")"
    say "  检测到:   $PLATFORM_LABEL $ARCH$libc_suffix"
    say ""
}

print_summary() {
    libc_suffix=""
    [ "$LIBC" = "musl" ] && libc_suffix=" (musl)"

    say ""
    say "${BOLD}================ 完成 ================${RESET}"
    say "  平台:        $PLATFORM_LABEL $ARCH$libc_suffix"
    say "  脚本目录:    $(display_path "$ROOT")"

    if [ -n "$LAUNCHER" ] && [ -f "$LAUNCHER" ]; then
        say "  ClaudeX:     $(display_path "$LAUNCHER")"
    else
        say "  ClaudeX:     未安装"
    fi

    if [ -f "$CLAUDE_BIN" ]; then
        say "  Claude Code: $(display_path "$CLAUDE_BIN")"
    else
        say "  Claude Code: 未安装"
    fi

    say "  配置文件:    $(display_path "$CONFIG_FILE")"
    say "    claudeConfigDir = data"
    say "    claudePath      = $CLAUDE_PATH_CONFIG"

    if [ -n "$LAUNCHER" ] && [ -f "$LAUNCHER" ]; then
        if [ "$OS" = "$DETECTED_OS" ] && [ "$ARCH" = "$DETECTED_ARCH" ]; then
            say ""
            say "启动方式：$(display_path "$LAUNCHER")"
        else
            say ""
            say "这是 $PLATFORM_LABEL $ARCH 版本，不能在本机运行。"
        fi
    else
        say ""
        say "ClaudeX 就绪后，运行脚本目录中的 $CLAUDEX_EXE 即可。"
    fi

    if [ "$CLAUDEX_MISSING_PLACEHOLDER" -eq 1 ]; then
        say ""
        say "${YELLOW}注意: ClaudeX 的 GitHub 仓库地址仍是占位符。${RESET}"
        say "      项目发布后重新运行本脚本，或使用："
        say "      $0 --claudex-repo <owner>/<repo>"
    fi

    if [ "$WARNINGS" -gt 0 ]; then
        say ""
        say "本次运行有 $WARNINGS 条警告，详见上方输出。"
    fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

install_current_target() {
    apply_platform_vars
    select_claude_asset_name

    print_banner

    if [ "$DO_CLAUDEX" -eq 1 ]; then
        ensure_claudex || true
    else
        info "跳过 ClaudeX 下载/更新（--no-claudex）"
    fi

    LAUNCHER=$(find_existing_claudex 2>/dev/null || true)
    if [ -n "$LAUNCHER" ]; then
        chmod 755 "$LAUNCHER" 2>/dev/null || true
    fi

    if [ "$DO_CLAUDE" -eq 1 ]; then
        ensure_claude || true
    else
        info "跳过 Claude Code 下载/更新（--no-claude）"
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
        warn "写入默认配置 $CONFIG_NAME"
        write_fallback_config || die "无法写入 $CONFIG_FILE"
    fi

    apply_config || die "无法更新 $CONFIG_FILE"
    verify_config_values || die "配置文件校验失败：$CONFIG_FILE"

    mkdir -p "$DATA_DIR" "$PORTABLE_TEMP_DIR" 2>/dev/null ||
        warn "无法创建数据目录：$DATA_DIR"

    if [ -f "$CLAUDE_BIN" ]; then
        chmod 755 "$CLAUDE_BIN" 2>/dev/null || true
    else
        if [ "$DO_CLAUDE" -eq 1 ]; then
            err "Claude Code 未安装到 $CLAUDE_BIN"
            HARD_FAIL=1
        else
            info "Claude Code 未安装（已跳过下载）"
        fi
    fi

    if [ -z "$LAUNCHER" ] || [ ! -f "$LAUNCHER" ]; then
        if [ "$DO_CLAUDEX" -eq 0 ]; then
            info "ClaudeX 未安装（已跳过下载）"
        elif [ "$CLAUDEX_MISSING_PLACEHOLDER" -eq 1 ]; then
            warn "ClaudeX 尚未安装：仓库地址仍是占位符。"
        else
            err "ClaudeX 未安装"
            HARD_FAIL=1
        fi
    fi
}

print_multi_summary() {
    target_exe() {
        case "$1" in
            windows) printf 'ClaudeX.exe' ;;
            *) printf 'ClaudeX' ;;
        esac
    }

    say ""
    say "${BOLD}================ 完成 ================${RESET}"
    say "  安装目录: $(display_path "$BASE_ROOT")"
    say "  已安装目标:"
    for target in windows-x64 windows-arm64 macos-x64 macos-arm64 linux-x64 linux-arm64; do
        platform=${target%-*}
        arch=${target#*-}
        exe=$(target_exe "$platform")
        label=$(printf '%-14s' "$platform/$arch")
        if [ -f "$BASE_ROOT/$target/$exe" ]; then
            say "    $label $(display_path "$BASE_ROOT/$target/$exe")"
        else
            say "    $label 未安装"
        fi
    done
    say ""
    say "  每个目标目录都包含自己的 $CONFIG_NAME、data/ 和 bin/。"
}

main() {
    parse_args "$@"
    detect_platform
    prompt_platform_arch
    prompt_install_dir
    BASE_ROOT=$ROOT
    check_dependencies
    setup_work

    if [ "$ALL_TARGETS" -eq 1 ]; then
        for target in windows-x64 windows-arm64 macos-x64 macos-arm64 linux-x64 linux-arm64; do
            OS=${target%-*}
            ARCH=${target#*-}
            ROOT="$BASE_ROOT/$target"
            mkdir -p "$ROOT" || die "无法创建目录：$ROOT"
            install_current_target
        done
        print_multi_summary
    else
        install_current_target
        print_summary
    fi

    if [ "$HARD_FAIL" -ne 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"
