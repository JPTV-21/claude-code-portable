#requires -Version 5.1
<#
.SYNOPSIS
    ClaudeX portable one-step setup (native Windows PowerShell)

.DESCRIPTION
    Downloads and installs ClaudeX and Claude Code into the script folder and writes a portable config.
    Does not require Git Bash, perl, curl, or external extraction tools; it uses only Windows' built-in
    PowerShell and the system tar.exe when handling cross-platform tar.gz archives.

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
    [ValidateSet('auto', 'x64', 'arm64', 'all')][string]$Architecture = 'auto',
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
Usage: powershell -ExecutionPolicy Bypass -File setup-portable.ps1 [options]

One-step portable setup for ClaudeX + Claude Code into the script folder.
This version uses native Windows PowerShell and does not need Git Bash.

Options:
  -Update               force re-download of ClaudeX and Claude Code
  -NoClaudex            skip the ClaudeX download/update
  -NoClaude             skip the Claude Code download/update
  -Platform PLATFORM    install platform: windows/macos/linux/all (default: detected)
  -Architecture ARCH    CPU architecture: x64/arm64/all (default: detected)
  -All                  download all six platform/arch combinations into one folder
  -InstallDir DIR       install directory (default: script folder)
  -Yes                  use defaults without interactive prompts
  -NoProgress           do not show the download progress meter
  -Repo OWNER/REPO      ClaudeX repository (default: JPTV-21/Claudex)
  -ClaudeRepo OWNER/REPO
                        Claude Code repository (default: anthropics/claude-code)
  -Help                 show this help

Examples:
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
        Write-Warn "Enter one of: $($Choices -join ' / ')"
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
            $answer = Read-Host "Directory does not exist: $Dir`nCreate it? [Y/n]"
            if ($answer -match '^(n|no)$') { throw 'Cancelled.' }
        }
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        Write-Ok "Created directory: $Dir"
    }
    return $Dir
}

function Get-SourceLauncherExeName {
    if ($script:TargetPlatform -eq 'windows') { return 'ClaudeX.exe' }
    return 'ClaudeX'
}

# Every build gets a platform/arch suffix, including the local one, so all
# launchers can share the install root without overwriting each other.
function Get-LauncherFileName {
    param([string]$Platform, [string]$Arch)

    $base = "ClaudeX-$Platform-$Arch"
    if ($Platform -eq 'windows') { return "$base.exe" }
    return $base
}

function Get-ClaudeExeName {
    if ($script:TargetPlatform -eq 'windows') { return 'claude.exe' }
    return 'claude'
}

# Release assets use x64/arm64, but ClaudeX resolves {arch} to x86_64/arm64.
# Folders under bin/ follow the ClaudeX names so the {arch} template matches.
function Get-ClaudeArchName {
    param([string]$Arch)
    if ($Arch -eq 'x64') { return 'x86_64' }
    return $Arch
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
            if (-not $tar) { throw 'Extracting .tar.gz requires tar.exe (built into Windows 10).' }
            $tarPath = $tar.Source
        }
        & $tarPath -xzf $Path -C $Destination
        if ($LASTEXITCODE -ne 0) { throw "Extraction failed: $Path" }
        return
    }
    throw "Unsupported archive format: $Path"
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
        'X86'   { throw '32-bit Windows is not supported; ClaudeX only provides x64 and arm64 builds.' }
        default { throw "Unrecognized CPU architecture: $raw" }
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
                Write-Warn "$Label download interrupted (attempt $attempt/$Attempts); resuming in 2 seconds..."
                Start-Sleep -Seconds 2
            }
        } finally {
            if ($file) { $file.Dispose() }
            if ($stream) { $stream.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }

    throw "$Label download failed: $Url"
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

    if (-not $Asset) { throw "${Label}: asset not found in the release." }

    # Prefer the API endpoint: it redirects straight to the asset host and
    # works even when github.com itself is unreachable.
    if ($Asset.url) {
        try {
            Invoke-DownloadWithRetry -Url $Asset.url -Destination $Destination -Label $Label `
                -Headers @{ 'Accept' = 'application/octet-stream' }
            return
        } catch {
            Write-Warn "${Label}: API download failed; trying the direct URL."
        }
    }

    if ($Asset.browser_download_url) {
        Invoke-DownloadWithRetry -Url $Asset.browser_download_url -Destination $Destination -Label $Label
        return
    }

    throw "${Label}: no download URL is available."
}

function Test-AssetHash {
    param(
        $SumsAsset,
        [string]$Asset,
        [string]$Path
    )

    if (-not $SumsAsset) {
        Write-Warn "${Asset}: the release has no SHASUMS256.txt; skipping verification."
        return
    }

    $sumFile = Join-Path $script:WorkDir 'SHASUMS256.txt'
    try {
        Save-ReleaseAsset -Asset $SumsAsset -Destination $sumFile -Label "$Asset checksum file"
    } catch {
        Write-Warn "${Asset}: cannot fetch SHASUMS256.txt; skipping verification."
        return
    }

    $line = Get-Content -LiteralPath $sumFile |
        Where-Object { $_ -match "\s\*?$([regex]::Escape($Asset))\s*$" } |
        Select-Object -First 1
    if (-not $line) {
        Write-Warn "${Asset}: SHASUMS256.txt does not list it; skipping verification."
        return
    }

    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "$Asset SHA-256 verification failed`n  expected: $expected`n  actual:   $actual"
    }
    Write-Ok "${Asset}: SHA-256 verified"
}

function Install-ClaudeX {
    param([Parameter(Mandatory = $true)][string]$LauncherName)

    $target = Join-Path $script:Root $LauncherName

    if ((Test-Path -LiteralPath $target) -and -not $Update) {
        Write-Ok "ClaudeX already exists; skipping download (use -Update to force an update)"
        return $target
    }

    $release = Get-ReleaseInfo -Repository $Repo
    $assetName = Get-ClaudexAssetName
    $asset = Get-ReleaseAsset -Release $release -Name $assetName
    if (-not $asset) { throw "release does not contain $assetName." }

    $zip = Join-Path $script:WorkDir $assetName
    # A fresh directory per target avoids handles left by antivirus scanners.
    $extractDir = Join-Path $script:WorkDir ("claudex-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

    Write-Step "Downloading ClaudeX $($release.tag_name) ($assetName)"
    Save-ReleaseAsset -Asset $asset -Destination $zip -Label 'ClaudeX'
    if (-not (Test-Path -LiteralPath $zip)) { throw 'ClaudeX download file is missing.' }
    Test-AssetHash -SumsAsset (Get-ReleaseAsset -Release $release -Name 'SHASUMS256.txt') `
        -Asset $assetName -Path $zip

    Expand-ReleaseArchive -Path $zip -Destination $extractDir

    $sourceExeName = Get-SourceLauncherExeName
    $exe = Get-ChildItem -LiteralPath $extractDir -Recurse -File |
        Where-Object { $_.Name -ieq $sourceExeName } |
        Select-Object -First 1
    if (-not $exe) { throw "Cannot find $sourceExeName in the ClaudeX archive." }

    Copy-Item -LiteralPath $exe.FullName -Destination $target -Force
    Write-Ok "ClaudeX installed: $target"
    return $target
}

function Install-ClaudeCode {
    $exeName = Get-ClaudeExeName
    $claudeArch = Get-ClaudeArchName -Arch $script:TargetArch
    $destDir = Join-Path $script:Root ("bin\" + $claudeArch + "\" + $script:TargetPlatform)
    $dest = Join-Path $destDir $exeName

    if ((Test-Path -LiteralPath $dest) -and -not $Update) {
        Write-Ok "Claude Code already exists; skipping download (use -Update to force an update)"
        return
    }

    $claudeAssetName = Get-ClaudeAssetName
    $release = Get-ReleaseInfo -Repository $ClaudeRepo
    $asset = Get-ReleaseAsset -Release $release -Name $claudeAssetName
    if (-not $asset) { throw "release does not contain $claudeAssetName." }

    $zip = Join-Path $script:WorkDir $claudeAssetName
    $extractDir = Join-Path $script:WorkDir ("claude-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

    Write-Step "Downloading Claude Code $($release.tag_name) ($claudeAssetName)"
    Save-ReleaseAsset -Asset $asset -Destination $zip -Label 'Claude Code'
    if (-not (Test-Path -LiteralPath $zip)) { throw 'Claude Code download file is missing.' }
    Test-AssetHash -SumsAsset (Get-ReleaseAsset -Release $release -Name 'SHASUMS256.txt') `
        -Asset $claudeAssetName -Path $zip

    Expand-ReleaseArchive -Path $zip -Destination $extractDir

    $exe = Get-ChildItem -LiteralPath $extractDir -Recurse -File |
        Where-Object { $_.Name -ieq $exeName } |
        Select-Object -First 1
    if (-not $exe) { throw "Cannot find $exeName in the Claude Code archive." }

    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    Copy-Item -LiteralPath $exe.FullName -Destination $dest -Force
    Write-Ok "Claude Code installed: $dest"
}

function Write-LauncherConfig {
    $configPath = Join-Path $script:Root 'claudex-config.json'
    # Let ClaudeX expand {arch}/{platform} so a folder prepared on one machine
    # still resolves correctly when it is moved to the target machine.
    $claudePath = 'bin/{arch}/{platform}/claude*'

    $cfg = $null
    if (Test-Path -LiteralPath $configPath) {
        try {
            $cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $backup = "$configPath.invalid.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item -LiteralPath $configPath -Destination $backup -Force
            Write-Warn "Existing config cannot be parsed; backed up to $backup"
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
    Write-Ok "Config written: $configPath"
}

function Show-Summary {
    param([string]$BaseRoot, [switch]$Multi)

    if ($Multi) {
        Write-Host ''
        Write-Host '================ Done ================' -ForegroundColor Green
        Write-Host "  Install directory: $BaseRoot"
        Write-Host '  Installed targets:'
        foreach ($item in $script:InstalledTargets) {
            $state = if ($item.Launcher -and (Test-Path -LiteralPath $item.Launcher)) {
                $item.Launcher
            } else {
                'not installed'
            }
            Write-Host ("    {0,-14} {1}" -f "$($item.Platform)/$($item.Arch)", $state)
        }
        Write-Host ''
        Write-Host '  All launchers share this folder; Claude Code builds are under bin/<arch>/<platform>/.'
        return
    }

    $launcher = Join-Path $script:Root (Get-LauncherFileName -Platform $script:TargetPlatform -Arch $script:TargetArch)
    $claudeArch = Get-ClaudeArchName -Arch $script:TargetArch
    $claude = Join-Path $script:Root ("bin\" + $claudeArch + "\" + $script:TargetPlatform + "\" + (Get-ClaudeExeName))
    $config = Join-Path $script:Root 'claudex-config.json'

    Write-Host ''
    Write-Host '================ Done ================' -ForegroundColor Green
    Write-Host "  Platform:     $script:TargetPlatform $script:TargetArch"
    Write-Host "  Install dir:  $script:Root"
    Write-Host ('  ClaudeX:      ' + $(if (Test-Path -LiteralPath $launcher) { $launcher } else { 'not installed' }))
    Write-Host ('  Claude Code:  ' + $(if (Test-Path -LiteralPath $claude) { $claude } else { 'not installed' }))
    Write-Host "  Config file:  $config"
    Write-Host "    claudeConfigDir = data"
    Write-Host '    claudePath      = bin/{arch}/{platform}/claude*'
    if ($script:TargetPlatform -ne 'windows') {
        Write-Host ''
        Write-Warn "This is the $script:TargetPlatform $script:TargetArch build; it cannot run on this Windows host."
        return
    }
    if (Test-Path -LiteralPath $launcher) {
        Write-Host ''
        Write-Host "Launch: $launcher"
    }
}

$script:Root = $null
$script:TargetArch = $null
$script:TargetPlatform = $null
$script:DetectedArch = $null
$script:DetectedPlatform = $null
$script:MultiTarget = $false
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
    $script:DetectedArch = Get-NormalizedArch
    $script:TargetArch = $script:DetectedArch
    $script:DetectedPlatform = 'windows'
    $script:TargetPlatform = 'windows'
    $script:AssumeYes = [bool]$Yes

    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }
    $script:ShowProgress = (-not $NoProgress) -and (-not $redirected)

    $script:WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("claudex-setup-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null

    $interactive = (-not $Yes) -and [Environment]::UserInteractive

    $platformAll = $All -or ($Platform -eq 'all')
    $archAll = $All -or ($Architecture -eq 'all')

    if ($Platform -ne 'auto') {
        $script:TargetPlatform = $Platform
    } elseif ($interactive) {
        $script:TargetPlatform = Read-Choice -Prompt 'Install platform' -Default $script:TargetPlatform `
            -Choices @('windows', 'macos', 'linux', 'all')
    }
    if ($script:TargetPlatform -eq 'all') { $platformAll = $true }

    $defaultArch = if ($platformAll) { 'all' } else { $script:TargetArch }
    if ($Architecture -ne 'auto') {
        $script:TargetArch = $Architecture
    } elseif ($interactive) {
        $script:TargetArch = Read-Choice -Prompt 'CPU architecture' -Default $defaultArch `
            -Choices @('x64', 'arm64', 'all')
    } elseif ($platformAll) {
        $script:TargetArch = 'all'
    }
    if ($script:TargetArch -eq 'all') { $archAll = $true }

    if ($interactive -and [string]::IsNullOrWhiteSpace($InstallDir)) {
        $answer = Read-Host "Install directory [$script:Root]"
        if (-not [string]::IsNullOrWhiteSpace($answer)) { $InstallDir = $answer }
    }
    $baseRoot = Resolve-InstallDir -Dir $InstallDir

    $platforms = if ($platformAll) { @('windows', 'macos', 'linux') } else { @($script:TargetPlatform) }
    $arches = if ($archAll) { @('x64', 'arm64') } else { @($script:TargetArch) }
    $targets = @()
    foreach ($p in $platforms) {
        foreach ($a in $arches) {
            $targets += [pscustomobject]@{ Platform = $p; Arch = $a }
        }
    }
    $multiTarget = $targets.Count -gt 1
    $script:MultiTarget = $multiTarget

    Write-Host 'ClaudeX + Claude Code portable setup (PowerShell)' -ForegroundColor White
    Write-Host "  Install directory: $baseRoot"
    if ($multiTarget) {
        Write-Host "  Targets: $($targets.Count) combinations in one folder"
    } else {
        Write-Host "  Target:   $script:TargetPlatform $script:TargetArch"
        if ($script:TargetPlatform -ne 'windows') {
            Write-Warn 'Downloading binaries for another platform; they cannot run on this Windows host.'
        }
    }
    Write-Host ''

    $script:InstalledTargets = @()
    foreach ($target in $targets) {
        $script:TargetPlatform = $target.Platform
        $script:TargetArch = $target.Arch
        $script:Root = $baseRoot

        $launcherName = Get-LauncherFileName -Platform $target.Platform -Arch $target.Arch
        Write-Step "Installing $($target.Platform)/$($target.Arch) ($launcherName)"

        $launcherPath = $null
        if (-not $NoClaudex) {
            $launcherPath = Install-ClaudeX -LauncherName $launcherName
        }
        if (-not $NoClaude) { Install-ClaudeCode }

        $script:InstalledTargets += [pscustomobject]@{
            Platform = $target.Platform
            Arch     = $target.Arch
            Root     = $script:Root
            Launcher = $launcherPath
        }
    }

    # A single config is shared by every target. Prefer the host target;
    # otherwise fall back to the first target in the list.
    $configTarget = $targets | Where-Object {
        $_.Platform -eq $script:DetectedPlatform -and $_.Arch -eq $script:DetectedArch
    } | Select-Object -First 1
    if (-not $configTarget) { $configTarget = $targets[0] }

    $script:TargetPlatform = $configTarget.Platform
    $script:TargetArch = $configTarget.Arch
    $script:Root = $baseRoot
    Write-LauncherConfig

    Show-Summary -BaseRoot $baseRoot -Multi:$multiTarget
} catch {
    Write-Err $_.Exception.Message
    exit 1
} finally {
    if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir)) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
