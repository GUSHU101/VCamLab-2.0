[CmdletBinding()]
param(
    [string]$RootPath = "",
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Stop-StandaloneVerification {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 70
}

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = Split-Path -Parent $PSScriptRoot
}
$root = [IO.Path]::GetFullPath($RootPath)

$requiredFiles = @(
    "VirtualCamPro-Windows控制中心.bat",
    "start-obs-vcam.bat",
    "start-stream.bat",
    "install-phone.bat",
    "standalone-self-test.bat",
    "obs-vcam-config.cmd",
    "WINDOWS_TOOLS.md",
    "DEPLOYMENT.md",
    "scripts\windows-vcam.ps1",
    "scripts\obs-websocket.ps1",
    "scripts\install-ios.ps1",
    "scripts\install-ios-gui.ps1",
    "scripts\verify-standalone.ps1"
)
foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $root $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Stop-StandaloneVerification -Message "Required companion-tool file is missing: $relativePath"
    }
}

$allowedConfigNames = @{
    VCAM_FFMPEG_PATH = $true
    VCAM_OBS_PATH = $true
    VCAM_OBS_SCENE = $true
    VCAM_ORIENTATION = $true
    VCAM_RESOLUTION = $true
    VCAM_FPS = $true
    VCAM_SCALE_MODE = $true
    VCAM_QUALITY = $true
    VCAM_BIND_ADDRESS = $true
    VCAM_PORT = $true
    VCAM_OBS_WAIT_SECONDS = $true
    VCAM_RESTART_ON_DISCONNECT = $true
    VCAM_RT_BUFFER_MB = $true
    VCAM_THREAD_QUEUE_SIZE = $true
    VCAM_ENCODER_THREADS = $true
    VCAM_OUTPUT_QUEUE_SIZE = $true
    VCAM_TCP_SEND_BUFFER_MB = $true
    VCAM_FFMPEG_LOG_LEVEL = $true
    VCAM_REQUIRE_OBS_MODE_MATCH = $true
    VCAM_AUTO_REFRESH_OBS_VIRTUAL_CAMERA = $true
    VCAM_DEVICE_NAME = $true
}
$configPath = Join-Path $root "obs-vcam-config.cmd"
foreach ($rawLine in Get-Content -LiteralPath $configPath -Encoding UTF8) {
    $line = $rawLine.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }
    if ($line -match '[&|<>^%!]') {
        Stop-StandaloneVerification -Message "Unsafe command metacharacter in mutable config: $line"
    }
    if ($line -match '^(?i:@?rem)(?:\s|$)') { continue }
    $match = [regex]::Match($line, '^set "(?<name>VCAM_[A-Z0-9_]+)=[^"\r\n]*"$')
    if (-not $match.Success -or -not $allowedConfigNames.ContainsKey($match.Groups["name"].Value)) {
        Stop-StandaloneVerification -Message "Unsafe mutable config line: $line"
    }
}

foreach ($relativePath in @(
        "scripts\windows-vcam.ps1",
        "scripts\obs-websocket.ps1",
        "scripts\install-ios.ps1",
        "scripts\install-ios-gui.ps1",
        "scripts\verify-standalone.ps1")) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root $relativePath),
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    if ($parseErrors.Count -gt 0) {
        Stop-StandaloneVerification -Message (
            "PowerShell syntax check failed for {0}: {1}" -f
            $relativePath, $parseErrors[0].Message
        )
    }
}

$manifestPath = Join-Path $root "standalone-manifest.json"
$manifest = $null
$manifestPaths = @{}
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $reparsePoint = @(
        Get-Item -LiteralPath $root -Force
        Get-ChildItem -LiteralPath $root -Force -Recurse
    ) | Where-Object {
        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    } | Select-Object -First 1
    if ($reparsePoint) {
        Stop-StandaloneVerification -Message (
            "Standalone directory must not contain links or reparse points: {0}" -f
            $reparsePoint.FullName
        )
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
    } catch {
        Stop-StandaloneVerification -Message "Manifest cannot be read: $($_.Exception.Message)"
    }
    if ([int]$manifest.schemaVersion -ne 1 -or -not $manifest.files) {
        Stop-StandaloneVerification -Message "Manifest schema is unsupported or incomplete."
    }
    $rootPrefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    foreach ($entry in $manifest.files) {
        $relativePath = [string]$entry.path
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
            [IO.Path]::IsPathRooted($relativePath) -or
            $relativePath.Split(@('\', '/')) -contains "..") {
            Stop-StandaloneVerification -Message "Manifest contains an unsafe path: $relativePath"
        }
        $fullPath = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
        if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-StandaloneVerification -Message "Manifest path escapes the tool directory: $relativePath"
        }
        $manifestPaths[$relativePath.ToLowerInvariant()] = $true
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            Stop-StandaloneVerification -Message "Manifest file is missing: $relativePath"
        }
        $mutableProperty = $entry.PSObject.Properties["mutable"]
        if ($mutableProperty -and [bool]$mutableProperty.Value) {
            continue
        }
        $file = Get-Item -LiteralPath $fullPath
        if ([long]$entry.bytes -ne $file.Length) {
            Stop-StandaloneVerification -Message "File size mismatch: $relativePath"
        }
        $actualHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
        if ($actualHash -ne [string]$entry.sha256) {
            Stop-StandaloneVerification -Message "SHA-256 mismatch: $relativePath"
        }
    }
}

$packages = @(Get-ChildItem -LiteralPath (Join-Path $root "packages") `
    -Filter "com.murkaska.virtualcampro_*_iphoneos-arm64.deb" `
    -File -ErrorAction SilentlyContinue)
$packageRequired = -not (Test-Path -LiteralPath (Join-Path $root ".git"))
if ($manifest -and $manifest.PSObject.Properties["packageIncluded"] -and
    -not [bool]$manifest.packageIncluded) {
    $packageRequired = $false
}
if ($packages.Count -eq 0 -and $packageRequired) {
    Stop-StandaloneVerification -Message "No deployable VirtualCamPro package was found."
}
if ($manifestPaths.Count -gt 0) {
    foreach ($package in $packages) {
        $relativePath = "packages\$($package.Name)"
        if (-not $manifestPaths.ContainsKey($relativePath.ToLowerInvariant())) {
            Stop-StandaloneVerification -Message (
                "Unmanifested deployment package found; regenerate the standalone tool: $relativePath"
            )
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File) {
        if ($file.FullName.Equals($manifestPath, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $relativePath = $file.FullName.Substring($root.Length).TrimStart(
            [char]'\', [char]'/'
        )
        if (-not $manifestPaths.ContainsKey($relativePath.ToLowerInvariant())) {
            Stop-StandaloneVerification -Message (
                "Unmanifested file found: $relativePath"
            )
        }
    }
}

if (-not $Quiet) {
    $mode = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        "manifest and tool integrity"
    } else {
        "source-tree structure and syntax"
    }
    Write-Host "[OK] VirtualCamPro $mode verification passed." -ForegroundColor Green
}
exit 0
