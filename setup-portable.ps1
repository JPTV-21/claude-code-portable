#requires -Version 5.1
<#
.SYNOPSIS
    ClaudeX 便携版一键部署（Windows 原生 PowerShell 版）

.DESCRIPTION
    下载并安装 ClaudeX 与 Claude Code 到本脚本所在目录，生成便携配置。
    不依赖 Git Bash、perl、curl 或外部解压工具；只使用 Windows 自带的
    PowerShell 和（处理跨平台 tar.gz 时的）系统 tar.exe。

.EXAMPLE
    .\setup-portable.ps1

.EXAMPLE
    .\setup-portable.ps1 -NoClaude

.EXAMPLE
    .\setup-portable.ps1 -Update
#>
[CmdletBinding()]
param(
    [switch]$Update,
    [switch]$NoClaudex,
    [switch]$NoClaude,
    [ValidateSet('auto', 'windows', 'macos', 'linux', 'all')][string]$Platform = 'auto',
    [ValidateSet('auto', 'x64', 'arm64')][string]$Architecture = 'auto',
    [string]$InstallDir = '',
    [switch]$All,
    [switch]$Yes,
    [switch]$NoProgress,
    [string]$Repo = 'JPTV-21/Claudex',
    [string]$ClaudeRepo = 'anthropics/claude-code',
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 may still negotiate TLS 1.0 by default.
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "  ok $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "warning: $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "error: $Message" -ForegroundColor Red }

function Show-Usage {
    @'
用法: powershell -ExecutionPolicy Bypass -File setup-portable.ps1 [选项]

一键部署便携版 ClaudeX + Claude Code 到本脚本所在目录。
本版本使用 Windows 原生 PowerShell，不需要 Git Bash。

选项:
  -Update               强制重新下载 ClaudeX 与 Claude Code
  -NoClaudex            跳过 ClaudeX 的下载/更新
  -NoClaude             跳过 Claude Code 的下载/更新
  -Platform PLATFORM    安装平台：windows/macos/linux/all（默认检测当前系统）
  -Architecture ARCH    CPU 架构：x64/arm64（默认检测当前系统）
  -All                  下载全部 6 个平台/架构组合，每项放入独立子目录
  -InstallDir DIR       安装目录（默认脚本所在目录）
  -Yes                  使用默认值，不进行交互询问
  -NoProgress           不显示下载进度表
  -Repo OWNER/REPO      指定 ClaudeX 仓库（默认 JPTV-21/Claudex）
  -ClaudeRepo OWNER/REPO
                        指定 Claude Code 仓库（默认 anthropics/claude-code）
  -Help                 显示本帮助

示例:
  .\setup-portable.ps1
  .\setup-portable.ps1 -InstallDir D:\ClaudexPortable
  .\setup-portable.ps1 -Platform macos -Architecture arm64
  .\setup-portable.ps1 -All -InstallDir D:\ClaudexAll
  .\setup-portable.ps1 -NoClaude -Update -Yes
'@ | Write-Host
}

function Read-Choice {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$Default,
        [Parameter(Mandatory = $true)][string[]]$Choices
    )

    while ($true) {
        $answer = Read-Host "$Prompt [$Default] ($($Choices -join '/'))"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        foreach ($choice in $Choices) {
            if ($choice -ieq $answer.Trim()) { return $choice }
        }
        Write-Warn "请输入：$($Choices -join ' / ')"
    }
}

function Resolve-InstallDir {
    param([string]$Dir)

    if ([string]::IsNullOrWhiteSpace($Dir)) {
        $Dir = $script:Root
    } else {
        $Dir = [Environment]::ExpandEnvironmentVariables($Dir)
        if ($Dir -eq '~') {
            $Dir = $HOME
        } elseif ($Dir.StartsWith('~\') -or $Dir.StartsWith('~/')) {
            $Dir = Join-Path $HOME $Dir.Substring(2)
        }
        if (-not [System.IO.Path]::IsPathRooted($Dir)) {
            $Dir = Join-Path (Get-Location).Path $Dir
        }
    }

    $Dir = [System.IO.Path]::GetFullPath($Dir)
    if (-not (Test-Path -LiteralPath $Dir)) {
        if (-not $script:AssumeYes) {
            $answer = Read-Host "目录不存在：$Dir`n是否创建？[Y/n]"
            if ($answer -match '^(n|no)$') { throw '已取消。' }
        }
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        Write-Ok "已创建目录：$Dir"
    }
    return $Dir
}

function Get-LauncherExeName {
    if ($script:TargetPlatform -eq 'windows') { return 'ClaudeX.exe' }
    return 'ClaudeX'
}

function Get-ClaudeExeName {
    if ($script:TargetPlatform -eq 'windows') { return 'claude.exe' }
    return 'claude'
}

function Get-ClaudexAssetName {
    switch ($script:TargetPlatform) {
        'windows' { return "ClaudeX-windows-$script:TargetArch.zip" }
        'macos'   { return "ClaudeX-macos-$script:TargetArch.tar.gz" }
        'linux'   { return "ClaudeX-linux-$script:TargetArch.tar.gz" }
    }
}

function Get-ClaudeAssetName {
    switch ($script:TargetPlatform) {
        'windows' {
            if ($script:TargetArch -eq 'arm64') { return 'claude-win32-arm64.zip' }
            return 'claude-win32-x64.zip'
        }
        'macos' { return "claude-darwin-$script:TargetArch.tar.gz" }
        'linux' { return "claude-linux-$script:TargetArch.tar.gz" }
    }
}

function Expand-ReleaseArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    if ($Path -match '\.zip$') {
        Expand-Archive -LiteralPath $Path -DestinationPath $Destination -Force
        return
    }
    if ($Path -match '\.(tar\.gz|tgz)$') {
        # Prefer Windows' bundled bsdtar. A GNU tar from Git/MSYS treats
        # "E:\path" as a remote host and fails.
        $tarPath = Join-Path $env:SystemRoot 'System32\tar.exe'
        if (-not (Test-Path -LiteralPath $tarPath)) {
            $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
            if (-not $tar) { throw '解压 .tar.gz 需要 tar.exe（Windows 10 自带）。' }
            $tarPath = $tar.Source
        }
        & $tarPath -xzf $Path -C $Destination
        if ($LASTEXITCODE -ne 0) { throw "解压失败：$Path" }
        return
    }
    throw "不支持的压缩格式：$Path"
}

function Get-NormalizedArch {
    $raw = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }

    switch ($raw.ToUpperInvariant()) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        'X86'   { throw '不支持 32 位 Windows；ClaudeX 只提供 x64 和 arm64 版本。' }
        default { throw "无法识别的 CPU 架构：$raw" }
    }
}

function Write-TransferProgress {
    param(
        [long]$Downloaded,
        [long]$Total,
        [double]$Speed,
        [string]$Label,
        [switch]$Done
    )

    if (-not $script:ShowProgress) { return }

    $mb = 1048576.0
    $downMb = $Downloaded / $mb
    $speedMb = $Speed / $mb
    if ($Total -gt 0) {
        $pct = [math]::Min(100, [math]::Floor($Downloaded * 100.0 / $Total))
        $text = "{0}: {1,3}%  {2:N1}/{3:N1} MB  {4:N1} MB/s" -f `
            $Label, $pct, $downMb, ($Total / $mb), $speedMb
    } else {
        $text = "{0}: {1:N1} MB  {2:N1} MB/s" -f $Label, $downMb, $speedMb
    }

    Write-Host "`r  $text" -NoNewline
    if ($Done) { Write-Host '' }
}

# Downloads with retry, byte-range resume, and a live speed/size meter.
# Uses only System.Net from .NET Framework; no curl or other executables.
function Invoke-DownloadWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Label,
        [hashtable]$Headers = @{},
        [int]$Attempts = 3,
        [switch]$Quiet
    )

    $showProgress = $script:ShowProgress -and (-not $Quiet)

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $response = $null
        $stream = $null
        $file = $null
        try {
            $request = [System.Net.HttpWebRequest]::Create($Url)
            $request.UserAgent = 'claudex-setup'
            $request.AllowAutoRedirect = $true
            $request.Timeout = 30000
            $request.ReadWriteTimeout = 120000
            if ($env:CLAUDEX_PROXY) {
                $request.Proxy = New-Object System.Net.WebProxy($env:CLAUDEX_PROXY)
            } else {
                $request.Proxy = $null
            }

            foreach ($key in $Headers.Keys) {
                switch ($key.ToLowerInvariant()) {
                    'user-agent' { $request.UserAgent = $Headers[$key] }
                    'accept' { $request.Accept = $Headers[$key] }
                    'authorization' { $request.Headers['Authorization'] = $Headers[$key] }
                    default { $request.Headers[$key] = $Headers[$key] }
                }
            }

            $existing = 0
            if (Test-Path -LiteralPath $Destination) {
                $existing = (Get-Item -LiteralPath $Destination).Length
            }
            if ($existing -gt 0) { $request.AddRange($existing) }

            $response = $request.GetResponse()
            $status = [int]$response.StatusCode
            $total = $response.ContentLength
            if ($status -eq 206) {
                if ($total -gt 0) { $total += $existing }
            } else {
                # The server ignored the range; overwrite instead of appending.
                $existing = 0
            }

            $mode = if ($existing -gt 0) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
            $file = New-Object System.IO.FileStream($Destination, $mode, [System.IO.FileAccess]::Write)
            $stream = $response.GetResponseStream()
            $buffer = New-Object byte[] 131072
            $downloaded = [long]$existing
            $lastTime = Get-Date
            $lastBytes = $downloaded
            $speed = 0.0

            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $file.Write($buffer, 0, $read)
                $downloaded += $read
                $now = Get-Date
                $elapsed = ($now - $lastTime).TotalSeconds
                if ($elapsed -ge 0.5) {
                    $speed = ($downloaded - $lastBytes) / $elapsed
                    $lastTime = $now
                    $lastBytes = $downloaded
                    if ($showProgress) {
                        Write-TransferProgress -Downloaded $downloaded -Total $total -Speed $speed -Label $Label
                    }
                }
            }

            if ($showProgress) {
                Write-TransferProgress -Downloaded $downloaded -Total $total -Speed $speed -Label $Label -Done
            }
            return
        } catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            # 416: the partial file is already complete; restart cleanly.
            if ($statusCode -eq 416 -and (Test-Path -LiteralPath $Destination)) {
                Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            }
            if ($attempt -lt $Attempts) {
                Write-Warn "$Label 下载中断（尝试 $attempt/$Attempts），2 秒后继续…"
                Start-Sleep -Seconds 2
            }
        } finally {
            if ($file) { $file.Dispose() }
            if ($stream) { $stream.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }

    throw "$Label 下载失败：$Url"
}

function Get-ReleaseInfo {
    param([string]$Repository)

    if ($script:ReleaseCache.ContainsKey($Repository)) {
        return $script:ReleaseCache[$Repository]
    }

    $out = Join-Path $script:WorkDir ("release-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    $url = "https://api.github.com/repos/$Repository/releases/latest"
    $token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_TOKEN }

    $headers = @{
        'Accept'     = 'application/vnd.github+json'
        'User-Agent' = 'claudex-setup'
    }
    if ($token) { $headers['Authorization'] = "Bearer $token" }

    Invoke-DownloadWithRetry -Url $url -Destination $out -Label "$Repository release" `
        -Headers $headers -Quiet

    $release = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:ReleaseCache[$Repository] = $release
    return $release
}

function Get-ReleaseAsset {
    param($Release, [string]$Name)

    if (-not $Release -or -not $Release.assets) { return $null }
    return $Release.assets |
        Where-Object { $_.name -ieq $Name } |
        Select-Object -First 1
}

function Save-ReleaseAsset {
    param($Asset, [string]$Destination, [string]$Label)

    if (-not $Asset) { throw "$Label：release 中找不到该资产。" }

    # Prefer the API endpoint: it redirects straight to the asset host and
    # works even when github.com itself is unreachable.
    if ($Asset.url) {
        try {
            Invoke-DownloadWithRetry -Url $Asset.url -Destination $Destination -Label $Label `
                -Headers @{ 'Accept' = 'application/octet-stream' }
            return
        } catch {
            Write-Warn "$Label：API 下载失败，尝试直链。"
        }
    }

    if ($Asset.browser_download_url) {
        Invoke-DownloadWithRetry -Url $Asset.browser_download_url -Destination $Destination -Label $Label
        return
    }

    throw "$Label：没有可用的下载地址。"
}

function Test-AssetHash {
    param(
        $SumsAsset,
        [string]$Asset,
        [string]$Path
    )

    if (-not $SumsAsset) {
        Write-Warn "$Asset：release 中没有 SHASUMS256.txt，跳过校验。"
        return
    }

    $sumFile = Join-Path $script:WorkDir 'SHASUMS256.txt'
    try {
        Save-ReleaseAsset -Asset $SumsAsset -Destination $sumFile -Label "$Asset 的校验文件"
    } catch {
        Write-Warn "$Asset：无法获取 SHASUMS256.txt，跳过校验。"
        return
    }

    $line = Get-Content -LiteralPath $sumFile |
        Where-Object { $_ -match "\s\*?$([regex]::Escape($Asset))\s*$" } |
        Select-Object -First 1
    if (-not $line) {
        Write-Warn "$Asset：SHASUMS256.txt 中没有该文件，跳过校验。"
        return
    }

    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "$Asset SHA-256 校验失败`n  期望: $expected`n  实际: $actual"
    }
    Write-Ok "$Asset：SHA-256 校验通过"
}

function Install-ClaudeX {
    $exeName = Get-LauncherExeName
    $target = Join-Path $script:Root $exeName

    if ((Test-Path -LiteralPath $target) -and -not $Update) {
        Write-Ok "ClaudeX 已存在，跳过下载（使用 -Update 强制更新）"
        return
    }

    $release = Get-ReleaseInfo -Repository $Repo
    $assetName = Get-ClaudexAssetName
    $asset = Get-ReleaseAsset -Release $release -Name $assetName
    if (-not $asset) { throw "release 中没有 $assetName。" }

    $zip = Join-Path $script:WorkDir $assetName
    # A fresh directory per target avoids handles left by antivirus scanners.
    $extractDir = Join-Path $script:WorkDir ("claudex-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

    Write-Step "下载 ClaudeX $($release.tag_name)（$assetName）"
    Save-ReleaseAsset -Asset $asset -Destination $zip -Label 'ClaudeX'
    if (-not (Test-Path -LiteralPath $zip)) { throw 'ClaudeX 下载文件不存在。' }
    Test-AssetHash -SumsAsset (Get-ReleaseAsset -Release $release -Name 'SHASUMS256.txt') `
        -Asset $assetName -Path $zip

    Expand-ReleaseArchive -Path $zip -Destination $extractDir

    $exe = Get-ChildItem -LiteralPath $extractDir -Recurse -File |
        Where-Object { $_.Name -ieq $exeName } |
        Select-Object -First 1
    if (-not $exe) { throw "ClaudeX 压缩包中找不到 $exeName。" }

    Copy-Item -LiteralPath $exe.FullName -Destination $target -Force
    Write-Ok "ClaudeX 已安装：$target"
}

function Install-ClaudeCode {
    $exeName = Get-ClaudeExeName
    $destDir = Join-Path $script:Root ("bin\" + $script:TargetArch + "\" + $script:TargetPlatform)
    $dest = Join-Path $destDir $exeName

    if ((Test-Path -LiteralPath $dest) -and -not $Update) {
        Write-Ok "Claude Code 已存在，跳过下载（使用 -Update 强制更新）"
        return
    }

    $claudeAssetName = Get-ClaudeAssetName
    $release = Get-ReleaseInfo -Repository $ClaudeRepo
    $asset = Get-ReleaseAsset -Release $release -Name $claudeAssetName
    if (-not $asset) { throw "release 中没有 $claudeAssetName。" }

    $zip = Join-Path $script:WorkDir $claudeAssetName
    $extractDir = Join-Path $script:WorkDir ("claude-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

    Write-Step "下载 Claude Code $($release.tag_name)（$claudeAssetName）"
    Save-ReleaseAsset -Asset $asset -Destination $zip -Label 'Claude Code'
    if (-not (Test-Path -LiteralPath $zip)) { throw 'Claude Code 下载文件不存在。' }
    Test-AssetHash -SumsAsset (Get-ReleaseAsset -Release $release -Name 'SHASUMS256.txt') `
        -Asset $claudeAssetName -Path $zip

    Expand-ReleaseArchive -Path $zip -Destination $extractDir

    $exe = Get-ChildItem -LiteralPath $extractDir -Recurse -File |
        Where-Object { $_.Name -ieq $exeName } |
        Select-Object -First 1
    if (-not $exe) { throw "Claude Code 压缩包中找不到 $exeName。" }

    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Copy-Item -LiteralPath $exe.FullName -Destination $dest -Force
    Write-Ok "Claude Code 已安装：$dest"
}

function Write-LauncherConfig {
    $configPath = Join-Path $script:Root 'claudex-config.json'
    $claudePath = "bin/$script:TargetArch/$script:TargetPlatform/claude*"

    $cfg = $null
    if (Test-Path -LiteralPath $configPath) {
        try {
            $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $backup = "$configPath.invalid.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item -LiteralPath $configPath -Destination $backup -Force
            Write-Warn "现有配置无法解析，已备份到 $backup"
            $cfg = $null
        }
    }

    if (-not $cfg) {
        $cfg = [pscustomobject]@{
            version              = 1
            theme                = 'claudex-theme.json'
            claudePath           = $claudePath
            claudeExclude        = @('ClaudeX*')
            launchCommand        = [pscustomobject]@{
                windows = 'set "CLAUDE_CONFIG_DIR={claudeConfigDir}" && set "TEMP={tempDir}" && set "TMP={tempDir}" && set "TMPDIR={tempDir}" && {claude}'
                posix   = "CLAUDE_CONFIG_DIR='{claudeConfigDir}' TEMP='{tempDir}' TMP='{tempDir}' TMPDIR='{tempDir}' {claude}"
            }
            claudeConfigDir      = 'data'
            tempDir              = 'data/tmp'
            logFile              = 'claudex.log'
            tabOnlySectionSwitch = $false
            projects             = @()
        }
    } else {
        Copy-Item -LiteralPath $configPath -Destination "$configPath.before-setup" -Force
        $cfg | Add-Member -NotePropertyName claudePath -NotePropertyValue $claudePath -Force
        $cfg | Add-Member -NotePropertyName claudeConfigDir -NotePropertyValue 'data' -Force
        $cfg | Add-Member -NotePropertyName tempDir -NotePropertyValue 'data/tmp' -Force
    }

    $json = $cfg | ConvertTo-Json -Depth 20
    # nlohmann/json rejects a UTF-8 BOM, so write without one.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($configPath, $json, $utf8NoBom)
    Write-Ok "配置已写入：$configPath"
}

function Show-Summary {
    param([string]$BaseRoot, [switch]$Multi)

    if ($Multi) {
        Write-Host ''
        Write-Host '================ 完成 ================' -ForegroundColor Green
        Write-Host "  安装目录:    $BaseRoot"
        Write-Host '  已安装目标:'
        foreach ($item in $script:InstalledTargets) {
            $exeName = if ($item.Platform -eq 'windows') { 'ClaudeX.exe' } else { 'ClaudeX' }
            $launcher = Join-Path $item.Root $exeName
            $state = if (Test-Path -LiteralPath $launcher) { $launcher } else { '未安装' }
            Write-Host ("    {0,-14} {1}" -f "$($item.Platform)/$($item.Arch)", $state)
        }
        Write-Host ''
        Write-Host '每个目标目录都包含自己的 claudex-config.json、data/ 和 bin/。'
        return
    }

    $launcher = Join-Path $script:Root (Get-LauncherExeName)
    $claude = Join-Path $script:Root ("bin\" + $script:TargetArch + "\" + $script:TargetPlatform + "\" + (Get-ClaudeExeName))
    $config = Join-Path $script:Root 'claudex-config.json'

    Write-Host ''
    Write-Host '================ 完成 ================' -ForegroundColor Green
    Write-Host "  平台:        $script:TargetPlatform $script:TargetArch"
    Write-Host "  安装目录:    $script:Root"
    Write-Host ('  ClaudeX:     ' + $(if (Test-Path -LiteralPath $launcher) { $launcher } else { '未安装' }))
    Write-Host ('  Claude Code: ' + $(if (Test-Path -LiteralPath $claude) { $claude } else { '未安装' }))
    Write-Host "  配置文件:    $config"
    Write-Host "    claudeConfigDir = data"
    Write-Host "    claudePath      = bin/$script:TargetArch/$script:TargetPlatform/claude*"
    if ($script:TargetPlatform -ne 'windows') {
        Write-Host ''
        Write-Warn "这是 $script:TargetPlatform $script:TargetArch 版本，不能在本机 Windows 上运行。"
        return
    }
    if (Test-Path -LiteralPath $launcher) {
        Write-Host ''
        Write-Host "启动方式：$launcher"
    }
}

$script:Root = $null
$script:TargetArch = $null
$script:TargetPlatform = $null
$script:WorkDir = $null
$script:AssumeYes = $false
$script:ShowProgress = $false
$script:ReleaseCache = @{}
$script:InstalledTargets = @()

try {
    if ($Help) {
        Show-Usage
        exit 0
    }

    $script:Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $script:TargetArch = Get-NormalizedArch
    $script:TargetPlatform = 'windows'
    $script:AssumeYes = [bool]$Yes

    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }
    $script:ShowProgress = (-not $NoProgress) -and (-not $redirected)

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("claudex-setup-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null

    $interactive = (-not $Yes) -and [Environment]::UserInteractive

    $allTargets = $All -or ($Platform -eq 'all')

    if ($Platform -ne 'auto') {
        $script:TargetPlatform = $Platform
    } elseif ($interactive) {
        $script:TargetPlatform = Read-Choice -Prompt '安装平台' -Default $script:TargetPlatform `
            -Choices @('windows', 'macos', 'linux', 'all')
    }
    if ($script:TargetPlatform -eq 'all') { $allTargets = $true }

    if (-not $allTargets) {
        if ($Architecture -ne 'auto') {
            $script:TargetArch = $Architecture
        } elseif ($interactive) {
            $script:TargetArch = Read-Choice -Prompt 'CPU 架构' -Default $script:TargetArch `
                -Choices @('x64', 'arm64')
        }
    }

    if ($interactive -and [string]::IsNullOrWhiteSpace($InstallDir)) {
        $answer = Read-Host "安装目录 [$script:Root]"
        if (-not [string]::IsNullOrWhiteSpace($answer)) { $InstallDir = $answer }
    }
    $baseRoot = Resolve-InstallDir -Dir $InstallDir

    Write-Host '便携版 Claude Code 一键部署（PowerShell）' -ForegroundColor White
    Write-Host "  安装目录: $baseRoot"
    if ($allTargets) {
        Write-Host '  目标平台: 全部（每项一个子目录）'
    } else {
        Write-Host "  目标平台: $script:TargetPlatform $script:TargetArch"
        if ($script:TargetPlatform -ne 'windows') {
            Write-Warn '将下载其他平台的二进制文件；它们不能在本机 Windows 上运行。'
        }
    }
    Write-Host ''

    if ($allTargets) {
        $targets = @(
            [pscustomobject]@{ Platform = 'windows'; Arch = 'x64' },
            [pscustomobject]@{ Platform = 'windows'; Arch = 'arm64' },
            [pscustomobject]@{ Platform = 'macos';   Arch = 'x64' },
            [pscustomobject]@{ Platform = 'macos';   Arch = 'arm64' },
            [pscustomobject]@{ Platform = 'linux';   Arch = 'x64' },
            [pscustomobject]@{ Platform = 'linux';   Arch = 'arm64' }
        )
    } else {
        $targets = @([pscustomobject]@{ Platform = $script:TargetPlatform; Arch = $script:TargetArch })
    }

    $script:InstalledTargets = @()
    foreach ($target in $targets) {
        $script:TargetPlatform = $target.Platform
        $script:TargetArch = $target.Arch

        if ($allTargets) {
            $script:Root = Join-Path $baseRoot ("$($target.Platform)-$($target.Arch)")
            New-Item -ItemType Directory -Force -Path $script:Root | Out-Null
            Write-Step "安装 $($target.Platform)/$($target.Arch) → $script:Root"
        } else {
            $script:Root = $baseRoot
        }

        if (-not $NoClaudex) { Install-ClaudeX }
        if (-not $NoClaude) { Install-ClaudeCode }
        Write-LauncherConfig

        $script:InstalledTargets += [pscustomobject]@{
            Platform = $target.Platform
            Arch     = $target.Arch
            Root     = $script:Root
        }
    }

    Show-Summary -BaseRoot $baseRoot -Multi:$allTargets
} catch {
    Write-Err $_.Exception.Message
    exit 1
} finally {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
