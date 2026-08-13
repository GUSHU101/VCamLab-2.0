[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$SmokeTest,
    [switch]$DebugConsole
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $PSScriptRoot "install-ios-gui.ps1"
$baseState = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($baseState)) { $baseState = $env:TEMP }
if ([string]::IsNullOrWhiteSpace($baseState)) { $baseState = $projectRoot }
$logDirectory = Join-Path $baseState "VirtualCamPro\logs"
$logPath = Join-Path $logDirectory "control-center-startup.log"

function Write-StartupFailure {
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    try { [IO.Directory]::CreateDirectory($logDirectory) | Out-Null } catch {}
    $details = @(
        "VirtualCamPro Control Center startup failure",
        "Time: $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))",
        "PowerShell: $($PSVersionTable.PSVersion)",
        "OS: $([Environment]::OSVersion.VersionString)",
        "Project: $projectRoot",
        "Script: $guiPath",
        "Exception: $($ErrorRecord.Exception.Message)",
        "Category: $($ErrorRecord.CategoryInfo)",
        "Position: $($ErrorRecord.InvocationInfo.PositionMessage)",
        "Stack: $($ErrorRecord.ScriptStackTrace)",
        "Full error:",
        ($ErrorRecord | Out-String)
    ) -join [Environment]::NewLine
    try {
        [IO.File]::WriteAllText($logPath, $details, (New-Object Text.UTF8Encoding($true)))
    } catch {}

    try {
        Add-Type -AssemblyName System.Windows.Forms
        $message = "VirtualCamPro 控制中心启动失败。`r`n`r`n$($ErrorRecord.Exception.Message)`r`n`r`n错误日志：`r`n$logPath`r`n`r`n可双击 BAT 后加 --debug 查看控制台诊断。"
        [Windows.Forms.MessageBox]::Show(
            $message,
            "VirtualCamPro 启动失败",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {
        Write-Host $details -ForegroundColor Red
    }
}

try {
    if (-not (Test-Path -LiteralPath $guiPath -PathType Leaf)) {
        throw "GUI script is missing: $guiPath"
    }
    if ($SelfTest) {
        & $guiPath -SelfTest
    } elseif ($SmokeTest) {
        & $guiPath -SmokeTest
    } else {
        & $guiPath
    }
    exit 0
} catch {
    Write-StartupFailure -ErrorRecord $_
    if ($DebugConsole) {
        Write-Host ""
        Write-Host "Startup failed. Log: $logPath" -ForegroundColor Yellow
    }
    exit 1
}
