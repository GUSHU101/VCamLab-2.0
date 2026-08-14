[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$SmokeTest,
    [string]$RenderPath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:InstallerPath = Join-Path $PSScriptRoot "install-ios.ps1"
$script:BridgePath = Join-Path $script:ProjectRoot "start-obs-vcam.bat"
$script:DeepTestPath = Join-Path $script:ProjectRoot "standalone-self-test.bat"
$script:VerifierPath = Join-Path $PSScriptRoot "verify-standalone.ps1"
$script:StateBase = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($script:StateBase)) { $script:StateBase = $env:TEMP }
if ([string]::IsNullOrWhiteSpace($script:StateBase)) { $script:StateBase = $script:ProjectRoot }
$script:SettingsDirectory = Join-Path $script:StateBase "VirtualCamPro"
$script:SettingsPath = Join-Path $script:SettingsDirectory "deploy-gui.json"
$script:LogDirectory = Join-Path $script:SettingsDirectory "logs"
$script:CurrentProcess = $null
$script:BridgeProcess = $null
$script:TransportBox = $null
$script:TransportHint = $null
$script:LogBox = $null
$script:CurrentMode = ""
$script:CurrentLogPath = ""
$script:LastLogText = ""

function Get-GuiLatestPackage {
    $candidates = New-Object Collections.Generic.List[IO.FileInfo]
    foreach ($directoryName in @("packages", "artifacts")) {
        $directory = Join-Path $script:ProjectRoot $directoryName
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $directory `
            -Filter "com.murkaska.virtualcampro_*_iphoneos-arm64.deb" `
            -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $candidates.Add($_)
            }
    }
    return ($candidates | Sort-Object LastWriteTimeUtc, FullName -Descending |
        Select-Object -First 1)
}

function Test-GuiPhoneHost {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 253) { return $false }
    if ($Value.StartsWith("-") -or $Value.Contains("..")) { return $false }
    return $Value -match '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$'
}

function Test-GuiStreamURL {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    $uri = $null
    if ($Value.Length -gt 4096 -or $Value -match '\s' -or
        -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return $uri.Scheme -in @("http", "https") -and
        -not [string]::IsNullOrWhiteSpace($uri.Host) -and
        [string]::IsNullOrEmpty($uri.UserInfo) -and
        [string]::IsNullOrEmpty($uri.Fragment)
}

function Get-GuiSelectedTransport {
    if ($script:TransportBox -and $script:TransportBox.SelectedIndex -eq 1) {
        return "hls"
    }
    return "mjpeg"
}

function Update-GuiTransportHint {
    if (-not $script:TransportHint) { return }
    if ((Get-GuiSelectedTransport) -eq "hls") {
        $script:TransportHint.Text = "自动 URL: /live.m3u8 · H.264/HLS"
    } else {
        $script:TransportHint.Text = "自动 URL: /live.mjpg · 最低延迟"
    }
}

function ConvertTo-GuiQuotedPowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.IndexOfAny(@([char]"`r", [char]"`n")) -ge 0) {
        throw "A child-process argument contains a newline."
    }
    return "'" + $Value.Replace("'", "''") + "'"
}

function New-GuiInstallerCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$FPS,
        [Parameter(Mandatory = $true)][string]$Transport,
        [AllowEmptyString()][string]$PackagePath,
        [AllowEmptyString()][string]$StreamURL,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    $parts = @(
        "& " + (ConvertTo-GuiQuotedPowerShellLiteral -Value $script:InstallerPath),
        "-Mode " + (ConvertTo-GuiQuotedPowerShellLiteral -Value $Mode),
        "-PhoneHost " + (ConvertTo-GuiQuotedPowerShellLiteral -Value $HostName),
        "-PhonePort " + (ConvertTo-GuiQuotedPowerShellLiteral -Value ([string]$Port)),
        "-PreferredFPS " + (ConvertTo-GuiQuotedPowerShellLiteral -Value ([string]$FPS)),
        "-Transport " + (ConvertTo-GuiQuotedPowerShellLiteral -Value $Transport),
        "-LogPath " + (ConvertTo-GuiQuotedPowerShellLiteral -Value $LogPath)
    )
    if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
        $parts += "-PackagePath " + (ConvertTo-GuiQuotedPowerShellLiteral -Value $PackagePath)
    }
    if (-not [string]::IsNullOrWhiteSpace($StreamURL)) {
        $parts += "-StreamURL " + (ConvertTo-GuiQuotedPowerShellLiteral -Value $StreamURL)
    }
    return ($parts -join " ")
}

function ConvertTo-GuiEncodedCommand {
    param([Parameter(Mandatory = $true)][string]$Command)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

function Get-GuiCommandProcessor {
    if (-not [string]::IsNullOrWhiteSpace($env:ComSpec) -and
        (Test-Path -LiteralPath $env:ComSpec -PathType Leaf)) {
        return $env:ComSpec
    }
    $cmd = Get-Command cmd.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "Windows command processor cmd.exe was not found."
}

function ConvertTo-GuiSavedBoundedInt {
    param(
        $Value,
        [Parameter(Mandatory = $true)][int]$Minimum,
        [Parameter(Mandatory = $true)][int]$Maximum,
        [Parameter(Mandatory = $true)][int]$DefaultValue
    )
    if ($null -eq $Value) { return $DefaultValue }
    $parsed = 0
    if (-not [int]::TryParse([string]$Value, [ref]$parsed)) { return $DefaultValue }
    return [Math]::Min($Maximum, [Math]::Max($Minimum, $parsed))
}

function ConvertTo-GuiSavedBoolean {
    param($Value, [Parameter(Mandatory = $true)][bool]$DefaultValue)
    if ($null -eq $Value) { return $DefaultValue }
    if ($Value -is [bool]) { return [bool]$Value }
    switch (([string]$Value).Trim().ToLowerInvariant()) {
        { $_ -in @("1", "true", "yes", "on") } { return $true }
        { $_ -in @("0", "false", "no", "off") } { return $false }
        default { return $DefaultValue }
    }
}

function Invoke-GuiSelfTest {
    foreach ($requiredPath in @($script:InstallerPath, $script:BridgePath, $script:DeepTestPath, $script:VerifierPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required project tool is missing: $requiredPath"
        }
    }
    if (-not (Test-GuiPhoneHost -Value "192.168.0.103") -or
        (Test-GuiPhoneHost -Value "-oProxyCommand=bad") -or
        -not (Test-GuiStreamURL -Value "http://192.168.0.10:8888/live.mjpg") -or
        -not (Test-GuiStreamURL -Value "http://192.168.0.10:8888/live.m3u8") -or
        (Test-GuiStreamURL -Value "http://user:password@192.168.0.10/live.mjpg") -or
        (Test-GuiStreamURL -Value "file:///var/mobile/test")) {
        throw "GUI input validation self-test failed."
    }
    $testCommand = New-GuiInstallerCommand -Mode "Setup" -HostName "192.168.0.103" `
        -Port 22 -FPS 60 -Transport "hls" `
        -PackagePath "C:\build\com.murkaska.virtualcampro_2.18.0_iphoneos-arm64.deb" `
        -StreamURL "" -LogPath "C:\logs\deploy.log"
    foreach ($fragment in @("-Mode 'Setup'", "-PhoneHost '192.168.0.103'", "-PreferredFPS '60'",
            "-Transport 'hls'", "-LogPath 'C:\logs\deploy.log'")) {
        if ($testCommand -notlike "*$fragment*") {
            throw "GUI command construction self-test failed: $fragment"
        }
    }
    if ($testCommand -match '(?i)password') {
        throw "GUI command must never contain password parameters."
    }
    if ((ConvertTo-GuiSavedBoundedInt -Value "not-a-number" -Minimum 1 -Maximum 65535 -DefaultValue 22) -ne 22 -or
        (ConvertTo-GuiSavedBoundedInt -Value "999999" -Minimum 1 -Maximum 65535 -DefaultValue 22) -ne 65535 -or
        (ConvertTo-GuiSavedBoundedInt -Value "-5" -Minimum 1 -Maximum 240 -DefaultValue 48) -ne 1) {
        throw "GUI legacy numeric-settings migration self-test failed."
    }
    if ((ConvertTo-GuiSavedBoolean -Value "true" -DefaultValue $false) -ne $true -or
        (ConvertTo-GuiSavedBoolean -Value "garbage" -DefaultValue $true) -ne $true) {
        throw "GUI legacy boolean-settings migration self-test failed."
    }
    Write-Host "VirtualCamPro deployment GUI self-test passed." -ForegroundColor Green
    exit 0
}

function Test-GuiStandaloneIntegrity {
    if (-not (Test-Path -LiteralPath $script:VerifierPath -PathType Leaf)) {
        return [pscustomobject]@{ Success = $false; Message = "独立工具校验脚本缺失。" }
    }
    $process = $null
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = "powershell.exe"
        $startInfo.Arguments = ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -RootPath "{1}" -Quiet' -f
            $script:VerifierPath, $script:ProjectRoot)
        $startInfo.WorkingDirectory = $script:ProjectRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.RedirectStandardOutput = $true
        $process = [Diagnostics.Process]::Start($startInfo)
        if (-not $process) { throw "无法启动完整性校验。" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            try { $process.Kill() } catch {}
            try { [void]$process.WaitForExit(3000) } catch {}
            throw "完整性校验超时。"
        }
        $stdoutTask.Wait()
        $stderrTask.Wait()
        $message = ($stdoutTask.Result + [Environment]::NewLine + $stderrTask.Result).Trim()
        return [pscustomobject]@{
            Success = $process.ExitCode -eq 0
            Message = $message
        }
    } catch {
        return [pscustomobject]@{ Success = $false; Message = $_.Exception.Message }
    } finally {
        if ($process) { try { $process.Dispose() } catch {} }
    }
}

if ($SelfTest) { Invoke-GuiSelfTest }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$colorBackground = [Drawing.Color]::FromArgb(15, 23, 42)
$colorCard = [Drawing.Color]::FromArgb(30, 41, 59)
$colorInput = [Drawing.Color]::FromArgb(17, 24, 39)
$colorText = [Drawing.Color]::FromArgb(241, 245, 249)
$colorMuted = [Drawing.Color]::FromArgb(148, 163, 184)
$colorBlue = [Drawing.Color]::FromArgb(59, 130, 246)
$colorGreen = [Drawing.Color]::FromArgb(34, 197, 94)
$colorSlate = [Drawing.Color]::FromArgb(71, 85, 105)
$colorAmber = [Drawing.Color]::FromArgb(245, 158, 11)
$fontNormal = New-Object Drawing.Font("Segoe UI", 9.5)
$fontSmall = New-Object Drawing.Font("Segoe UI", 8.5)
$fontTitle = New-Object Drawing.Font("Segoe UI Semibold", 21)
$fontSection = New-Object Drawing.Font("Segoe UI Semibold", 11)

function New-GuiLabel {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [Parameter(Mandatory = $true)][int]$Width,
        [int]$Height = 24,
        [Drawing.Font]$Font = $fontNormal,
        [Drawing.Color]$Color = $colorText
    )
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object Drawing.Point($X, $Y)
    $label.Size = New-Object Drawing.Size($Width, $Height)
    $label.Font = $Font
    $label.ForeColor = $Color
    $label.BackColor = [Drawing.Color]::Transparent
    return $label
}

function Set-GuiFlatButtonStyle {
    param(
        [Parameter(Mandatory = $true)][Windows.Forms.Button]$Button,
        [Parameter(Mandatory = $true)][Drawing.Color]$Color
    )
    $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 0
    $Button.BackColor = $Color
    $Button.ForeColor = [Drawing.Color]::White
    $Button.Font = New-Object Drawing.Font("Segoe UI Semibold", 10)
    $Button.Cursor = [Windows.Forms.Cursors]::Hand
}

function Set-GuiTextBoxStyle {
    param([Parameter(Mandatory = $true)][Windows.Forms.TextBox]$TextBox)
    $TextBox.BackColor = $colorInput
    $TextBox.ForeColor = $colorText
    $TextBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
    $TextBox.Font = $fontNormal
}

function Add-GuiLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = "{0}  {1}{2}" -f (Get-Date -Format "HH:mm:ss"), $Message, [Environment]::NewLine
    $script:LogBox.AppendText($line)
    $script:LogBox.SelectionStart = $script:LogBox.TextLength
    $script:LogBox.ScrollToCaret()
}

function Get-GuiSavedSettings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf)) { return $null }
    try {
        return ([IO.File]::ReadAllText($script:SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-GuiSavedValue {
    param(
        $Settings,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue = $null
    )
    if ($null -eq $Settings) { return $DefaultValue }
    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Save-GuiSettings {
    try {
        [IO.Directory]::CreateDirectory($script:SettingsDirectory) | Out-Null
        $settings = [PSCustomObject]@{
            phoneHost = $script:HostBox.Text.Trim()
            phonePort = [int]$script:PortBox.Value
            phoneFPS = [int]$script:FpsBox.Value
            transport = Get-GuiSelectedTransport
            packagePath = $script:PackageBox.Text.Trim()
            startBridgeAfterDeploy = $script:AutoBridgeCheck.Checked
        }
        [IO.File]::WriteAllText($script:SettingsPath, ($settings | ConvertTo-Json), `
            (New-Object Text.UTF8Encoding($true)))
    } catch {
        Add-GuiLog -Message "无法保存非敏感界面设置：$($_.Exception.Message)"
    }
}

function Update-GuiPackageSummary {
    $path = $script:PackageBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($path) -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $script:PackageSummary.Text = "尚未选择有效的安装包"
        $script:PackageSummary.ForeColor = $colorAmber
        return
    }
    $file = Get-Item -LiteralPath $path
    $version = "未知版本"
    if ($file.Name -match '^com\.murkaska\.virtualcampro_([^_]+)_iphoneos-arm64\.deb$') {
        $version = $Matches[1]
    }
    $script:PackageSummary.Text = "VirtualCamPro $version  ·  $([Math]::Round($file.Length / 1KB, 1)) KiB"
    $script:PackageSummary.ForeColor = $colorGreen
}

function Set-GuiBusy {
    param(
        [Parameter(Mandatory = $true)][bool]$Busy,
        [AllowEmptyString()][string]$StatusText = ""
    )
    foreach ($control in @($script:CheckButton, $script:DeployButton, $script:VerifyButton,
            $script:BrowseButton, $script:HostBox, $script:PortBox, $script:FpsBox,
            $script:TransportBox, $script:PackageBox, $script:StreamBox)) {
        $control.Enabled = -not $Busy
    }
    if ($Busy) {
        $script:Progress.Style = [Windows.Forms.ProgressBarStyle]::Marquee
        $script:Progress.MarqueeAnimationSpeed = 24
        $script:StatusLabel.ForeColor = $colorBlue
    } else {
        $script:Progress.Style = [Windows.Forms.ProgressBarStyle]::Continuous
        $script:Progress.Value = 100
    }
    if (-not [string]::IsNullOrWhiteSpace($StatusText)) {
        $script:StatusLabel.Text = $StatusText
    }
}

function Test-GuiOperationInputs {
    param([Parameter(Mandatory = $true)][bool]$NeedsPackage)
    $hostName = $script:HostBox.Text.Trim()
    if (-not (Test-GuiPhoneHost -Value $hostName)) {
        [Windows.Forms.MessageBox]::Show("请输入有效的手机 IP 或主机名。", "参数错误",
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        $script:HostBox.Focus()
        return $false
    }
    if ($NeedsPackage) {
        $packagePath = $script:PackageBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($packagePath) -or
            -not (Test-Path -LiteralPath $packagePath -PathType Leaf) -or
            [IO.Path]::GetFileName($packagePath) -notmatch '^com\.murkaska\.virtualcampro_[0-9A-Za-z.+~_-]+_iphoneos-arm64\.deb$') {
            [Windows.Forms.MessageBox]::Show("请选择有效的 VirtualCamPro iphoneos-arm64 安装包。", "安装包错误",
                [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return $false
        }
    }
    $streamURL = $script:StreamBox.Text.Trim()
    if (-not (Test-GuiStreamURL -Value $streamURL)) {
        [Windows.Forms.MessageBox]::Show("流地址必须为空，或者是有效的 HTTP/HTTPS 地址。", "流地址错误",
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($streamURL)) {
        $uri = [Uri]$streamURL
        $isHlsURL = $uri.AbsolutePath.EndsWith(".m3u8", [StringComparison]::OrdinalIgnoreCase)
        $transport = Get-GuiSelectedTransport
        if (($transport -eq "hls" -and -not $isHlsURL) -or
            ($transport -eq "mjpeg" -and $isHlsURL)) {
            [Windows.Forms.MessageBox]::Show(
                "当前流地址与所选传输协议不一致。HLS 请使用 .m3u8；MJPEG 请使用非 .m3u8 的 MJPEG 地址。",
                "协议与地址不匹配", [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return $false
        }
    }
    return $true
}

function Start-GuiPhoneOperation {
    param([Parameter(Mandatory = $true)][string]$Mode)
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) { return }
    $needsPackage = $Mode -in @("Install", "Setup")
    if (-not (Test-GuiOperationInputs -NeedsPackage $needsPackage)) { return }
    Save-GuiSettings
    try {
        [IO.Directory]::CreateDirectory($script:LogDirectory) | Out-Null
        $script:CurrentLogPath = Join-Path $script:LogDirectory `
            ("phone-{0}-{1}.log" -f $Mode.ToLowerInvariant(), (Get-Date -Format "yyyyMMdd-HHmmss"))
        $script:LastLogText = ""
        $script:LogBox.Clear()
        Add-GuiLog -Message "正在启动 $Mode；密码只在随后出现的安全终端中输入。"
        $command = New-GuiInstallerCommand -Mode $Mode `
            -HostName $script:HostBox.Text.Trim() -Port ([int]$script:PortBox.Value) `
            -FPS ([int]$script:FpsBox.Value) -Transport (Get-GuiSelectedTransport) `
            -PackagePath $script:PackageBox.Text.Trim() `
            -StreamURL $script:StreamBox.Text.Trim() -LogPath $script:CurrentLogPath
        $encoded = ConvertTo-GuiEncodedCommand -Command $command
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = "powershell.exe"
        $startInfo.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $startInfo.WorkingDirectory = $script:ProjectRoot
        $startInfo.UseShellExecute = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
        $script:CurrentProcess = [Diagnostics.Process]::Start($startInfo)
        if (-not $script:CurrentProcess) { throw "无法启动安装进程。" }
        $script:CurrentMode = $Mode
        Set-GuiBusy -Busy $true -StatusText "$Mode 正在执行，请在安全终端输入 SSH/sudo 密码…"
    } catch {
        $script:CurrentProcess = $null
        Set-GuiBusy -Busy $false -StatusText "启动失败"
        $script:StatusLabel.ForeColor = [Drawing.Color]::FromArgb(248, 113, 113)
        Add-GuiLog -Message "启动失败：$($_.Exception.Message)"
    }
}

function Start-GuiBridge {
    if (-not (Test-Path -LiteralPath $script:BridgePath -PathType Leaf)) {
        [Windows.Forms.MessageBox]::Show("找不到 start-obs-vcam.bat。", "桥接工具缺失",
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    if ($script:BridgeProcess) {
        try {
            $script:BridgeProcess.Refresh()
            if (-not $script:BridgeProcess.HasExited) {
                Add-GuiLog -Message "OBS 桥接已经在运行；如需切换协议，请先关闭现有桥接窗口。"
                return
            }
            $script:BridgeProcess.Dispose()
        } catch {}
        $script:BridgeProcess = $null
    }
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = Get-GuiCommandProcessor
        $transport = Get-GuiSelectedTransport
        $startInfo.Arguments = ('/d /c ""{0}" --transport {1} --gui"' -f
            $script:BridgePath, $transport)
        $startInfo.WorkingDirectory = $script:ProjectRoot
        $startInfo.UseShellExecute = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
        $script:BridgeProcess = [Diagnostics.Process]::Start($startInfo)
        if (-not $script:BridgeProcess) { throw "桥接进程未能启动。" }
        Add-GuiLog -Message ("OBS 虚拟相机桥接正在启动：{0}；它会自动读取 OBS 保存的分辨率和 FPS。" -f
            $transport.ToUpperInvariant())
        $script:BridgeStatus.Text = ("桥接运行中：{0}" -f $transport.ToUpperInvariant())
        $script:BridgeStatus.ForeColor = $colorGreen
    } catch {
        $script:BridgeProcess = $null
        Add-GuiLog -Message "OBS 桥接启动失败：$($_.Exception.Message)"
        $script:BridgeStatus.Text = "桥接启动失败"
        $script:BridgeStatus.ForeColor = [Drawing.Color]::FromArgb(248, 113, 113)
    }
}

function Start-GuiBridgeCheck {
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = Get-GuiCommandProcessor
        $transport = Get-GuiSelectedTransport
        $startInfo.Arguments = ('/d /c ""{0}" --transport {1} --check & echo. & pause"' -f
            $script:BridgePath, $transport)
        $startInfo.WorkingDirectory = $script:ProjectRoot
        $startInfo.UseShellExecute = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
        [Diagnostics.Process]::Start($startInfo) | Out-Null
        Add-GuiLog -Message "已打开 OBS 桥接诊断窗口。"
    } catch {
        Add-GuiLog -Message "无法打开桥接诊断：$($_.Exception.Message)"
    }
}

function Start-GuiDeepSelfTest {
    if (-not (Test-Path -LiteralPath $script:DeepTestPath -PathType Leaf)) {
        [Windows.Forms.MessageBox]::Show("找不到 standalone-self-test.bat。", "自检工具缺失",
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = Get-GuiCommandProcessor
        $startInfo.Arguments = ('/d /c ""{0}""' -f $script:DeepTestPath)
        $startInfo.WorkingDirectory = $script:ProjectRoot
        $startInfo.UseShellExecute = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
        [Diagnostics.Process]::Start($startInfo) | Out-Null
        Add-GuiLog -Message "已打开深度自检窗口；会实际测试 GUI、核心脚本和 HLS HTTP 运行时。"
    } catch {
        Add-GuiLog -Message "无法启动深度自检：$($_.Exception.Message)"
    }
}

$form = New-Object Windows.Forms.Form
$form.Text = "VirtualCamPro Windows 控制中心 2.18.0"
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = New-Object Drawing.Size(1000, 790)
$form.MinimumSize = New-Object Drawing.Size(1000, 790)
$form.MaximumSize = New-Object Drawing.Size(1000, 790)
$form.BackColor = $colorBackground
$form.ForeColor = $colorText
$form.Font = $fontNormal
$form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
$form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false

$form.Controls.Add((New-GuiLabel -Text "VirtualCamPro 控制中心" -X 24 -Y 18 -Width 500 -Height 42 -Font $fontTitle))
$form.Controls.Add((New-GuiLabel -Text "一键部署 iPhone 插件，并启动 OBS 虚拟相机网络桥接" -X 27 -Y 61 -Width 650 -Height 24 -Color $colorMuted))
$securityLabel = New-GuiLabel -Text "密码不保存" -X 830 -Y 30 -Width 120 -Height 30 -Font $fontSection -Color $colorGreen
$securityLabel.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$form.Controls.Add($securityLabel)

$configPanel = New-Object Windows.Forms.Panel
$configPanel.Location = New-Object Drawing.Point(24, 100)
$configPanel.Size = New-Object Drawing.Size(610, 350)
$configPanel.BackColor = $colorCard
$form.Controls.Add($configPanel)
$configPanel.Controls.Add((New-GuiLabel -Text "手机部署设置" -X 20 -Y 14 -Width 220 -Height 28 -Font $fontSection))

$configPanel.Controls.Add((New-GuiLabel -Text "手机 IP / 主机名" -X 20 -Y 54 -Width 190 -Height 21 -Color $colorMuted))
$script:HostBox = New-Object Windows.Forms.TextBox
$script:HostBox.Location = New-Object Drawing.Point(20, 77)
$script:HostBox.Size = New-Object Drawing.Size(420, 28)
Set-GuiTextBoxStyle -TextBox $script:HostBox
$configPanel.Controls.Add($script:HostBox)
$configPanel.Controls.Add((New-GuiLabel -Text "SSH 端口" -X 460 -Y 54 -Width 110 -Height 21 -Color $colorMuted))
$script:PortBox = New-Object Windows.Forms.NumericUpDown
$script:PortBox.Location = New-Object Drawing.Point(460, 77)
$script:PortBox.Size = New-Object Drawing.Size(125, 28)
$script:PortBox.Minimum = 1
$script:PortBox.Maximum = 65535
$script:PortBox.Value = 22
$script:PortBox.BackColor = $colorInput
$script:PortBox.ForeColor = $colorText
$script:PortBox.Font = $fontNormal
$configPanel.Controls.Add($script:PortBox)

$configPanel.Controls.Add((New-GuiLabel -Text "插件安装包" -X 20 -Y 116 -Width 180 -Height 21 -Color $colorMuted))
$script:PackageBox = New-Object Windows.Forms.TextBox
$script:PackageBox.Location = New-Object Drawing.Point(20, 139)
$script:PackageBox.Size = New-Object Drawing.Size(474, 28)
Set-GuiTextBoxStyle -TextBox $script:PackageBox
$configPanel.Controls.Add($script:PackageBox)
$script:BrowseButton = New-Object Windows.Forms.Button
$script:BrowseButton.Text = "浏览…"
$script:BrowseButton.Location = New-Object Drawing.Point(505, 137)
$script:BrowseButton.Size = New-Object Drawing.Size(80, 31)
Set-GuiFlatButtonStyle -Button $script:BrowseButton -Color $colorSlate
$configPanel.Controls.Add($script:BrowseButton)
$script:PackageSummary = New-GuiLabel -Text "正在查找安装包…" -X 20 -Y 171 -Width 565 -Height 23 -Font $fontSmall -Color $colorMuted
$configPanel.Controls.Add($script:PackageSummary)

$configPanel.Controls.Add((New-GuiLabel -Text "手机本地视频最高 FPS" -X 20 -Y 202 -Width 200 -Height 21 -Color $colorMuted))
$script:FpsBox = New-Object Windows.Forms.NumericUpDown
$script:FpsBox.Location = New-Object Drawing.Point(20, 225)
$script:FpsBox.Size = New-Object Drawing.Size(125, 28)
$script:FpsBox.Minimum = 1
$script:FpsBox.Maximum = 240
$script:FpsBox.Value = 60
$script:FpsBox.BackColor = $colorInput
$script:FpsBox.ForeColor = $colorText
$script:FpsBox.Font = $fontNormal
$configPanel.Controls.Add($script:FpsBox)

$configPanel.Controls.Add((New-GuiLabel -Text "传输协议" -X 170 -Y 202 -Width 120 -Height 21 -Color $colorMuted))
$script:TransportBox = New-Object Windows.Forms.ComboBox
$script:TransportBox.Location = New-Object Drawing.Point(170, 224)
$script:TransportBox.Size = New-Object Drawing.Size(155, 30)
$script:TransportBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
$script:TransportBox.BackColor = $colorInput
$script:TransportBox.ForeColor = $colorText
$script:TransportBox.Font = $fontNormal
[void]$script:TransportBox.Items.Add("MJPEG")
[void]$script:TransportBox.Items.Add("HLS / H.264")
$script:TransportBox.SelectedIndex = 0
$configPanel.Controls.Add($script:TransportBox)
$script:TransportHint = New-GuiLabel -Text "自动 URL: /live.mjpg · 最低延迟" -X 340 -Y 228 -Width 245 -Height 22 -Font $fontSmall -Color $colorMuted
$configPanel.Controls.Add($script:TransportHint)

$configPanel.Controls.Add((New-GuiLabel -Text "网络流地址（留空自动生成）" -X 20 -Y 265 -Width 250 -Height 21 -Color $colorMuted))
$script:StreamBox = New-Object Windows.Forms.TextBox
$script:StreamBox.Location = New-Object Drawing.Point(20, 288)
$script:StreamBox.Size = New-Object Drawing.Size(565, 28)
Set-GuiTextBoxStyle -TextBox $script:StreamBox
$configPanel.Controls.Add($script:StreamBox)
$script:AutoBridgeCheck = New-Object Windows.Forms.CheckBox
$script:AutoBridgeCheck.Text = "部署成功后自动启动 OBS 桥接"
$script:AutoBridgeCheck.Location = New-Object Drawing.Point(20, 321)
$script:AutoBridgeCheck.Size = New-Object Drawing.Size(310, 24)
$script:AutoBridgeCheck.ForeColor = $colorText
$script:AutoBridgeCheck.BackColor = [Drawing.Color]::Transparent
$configPanel.Controls.Add($script:AutoBridgeCheck)

$actionPanel = New-Object Windows.Forms.Panel
$actionPanel.Location = New-Object Drawing.Point(650, 100)
$actionPanel.Size = New-Object Drawing.Size(320, 350)
$actionPanel.BackColor = $colorCard
$form.Controls.Add($actionPanel)
$actionPanel.Controls.Add((New-GuiLabel -Text "一键工作流" -X 20 -Y 14 -Width 200 -Height 28 -Font $fontSection))
$actionPanel.Controls.Add((New-GuiLabel -Text "1  检查 SSH、rootless 与 sudo" -X 20 -Y 48 -Width 280 -Height 22 -Color $colorMuted))
$actionPanel.Controls.Add((New-GuiLabel -Text "2  上传、校验、安装并自动配置" -X 20 -Y 72 -Width 280 -Height 22 -Color $colorMuted))
$actionPanel.Controls.Add((New-GuiLabel -Text "3  验证包状态与运行文件" -X 20 -Y 96 -Width 280 -Height 22 -Color $colorMuted))

$script:CheckButton = New-Object Windows.Forms.Button
$script:CheckButton.Text = "环境预检"
$script:CheckButton.Location = New-Object Drawing.Point(20, 128)
$script:CheckButton.Size = New-Object Drawing.Size(135, 42)
Set-GuiFlatButtonStyle -Button $script:CheckButton -Color $colorBlue
$actionPanel.Controls.Add($script:CheckButton)
$script:VerifyButton = New-Object Windows.Forms.Button
$script:VerifyButton.Text = "验证安装"
$script:VerifyButton.Location = New-Object Drawing.Point(165, 128)
$script:VerifyButton.Size = New-Object Drawing.Size(135, 42)
Set-GuiFlatButtonStyle -Button $script:VerifyButton -Color $colorSlate
$actionPanel.Controls.Add($script:VerifyButton)
$script:DeployButton = New-Object Windows.Forms.Button
$script:DeployButton.Text = "一键部署到手机"
$script:DeployButton.Location = New-Object Drawing.Point(20, 180)
$script:DeployButton.Size = New-Object Drawing.Size(280, 50)
Set-GuiFlatButtonStyle -Button $script:DeployButton -Color $colorGreen
$actionPanel.Controls.Add($script:DeployButton)

$actionPanel.Controls.Add((New-GuiLabel -Text "OBS 虚拟相机桥接" -X 20 -Y 247 -Width 220 -Height 24 -Font $fontSection))
$script:BridgeButton = New-Object Windows.Forms.Button
$script:BridgeButton.Text = "启动桥接"
$script:BridgeButton.Location = New-Object Drawing.Point(20, 277)
$script:BridgeButton.Size = New-Object Drawing.Size(88, 38)
Set-GuiFlatButtonStyle -Button $script:BridgeButton -Color $colorBlue
$actionPanel.Controls.Add($script:BridgeButton)
$script:BridgeCheckButton = New-Object Windows.Forms.Button
$script:BridgeCheckButton.Text = "桥接诊断"
$script:BridgeCheckButton.Location = New-Object Drawing.Point(116, 277)
$script:BridgeCheckButton.Size = New-Object Drawing.Size(88, 38)
Set-GuiFlatButtonStyle -Button $script:BridgeCheckButton -Color $colorSlate
$actionPanel.Controls.Add($script:BridgeCheckButton)
$script:DeepTestButton = New-Object Windows.Forms.Button
$script:DeepTestButton.Text = "深度自检"
$script:DeepTestButton.Location = New-Object Drawing.Point(212, 277)
$script:DeepTestButton.Size = New-Object Drawing.Size(88, 38)
Set-GuiFlatButtonStyle -Button $script:DeepTestButton -Color $colorSlate
$actionPanel.Controls.Add($script:DeepTestButton)
$script:BridgeStatus = New-GuiLabel -Text "未启动" -X 20 -Y 319 -Width 280 -Height 22 -Font $fontSmall -Color $colorMuted
$actionPanel.Controls.Add($script:BridgeStatus)

$statusPanel = New-Object Windows.Forms.Panel
$statusPanel.Location = New-Object Drawing.Point(24, 466)
$statusPanel.Size = New-Object Drawing.Size(946, 60)
$statusPanel.BackColor = $colorCard
$form.Controls.Add($statusPanel)
$script:StatusLabel = New-GuiLabel -Text "准备就绪" -X 18 -Y 9 -Width 900 -Height 23 -Font $fontSection -Color $colorGreen
$statusPanel.Controls.Add($script:StatusLabel)
$script:Progress = New-Object Windows.Forms.ProgressBar
$script:Progress.Location = New-Object Drawing.Point(18, 37)
$script:Progress.Size = New-Object Drawing.Size(910, 8)
$script:Progress.Style = [Windows.Forms.ProgressBarStyle]::Continuous
$script:Progress.Value = 0
$statusPanel.Controls.Add($script:Progress)

$form.Controls.Add((New-GuiLabel -Text "运行日志" -X 26 -Y 539 -Width 150 -Height 25 -Font $fontSection))
$form.Controls.Add((New-GuiLabel -Text "SSH 与 sudo 密码只在独立终端中输入，不会出现在日志里" -X 490 -Y 541 -Width 470 -Height 22 -Font $fontSmall -Color $colorMuted))
$script:LogBox = New-Object Windows.Forms.RichTextBox
$script:LogBox.Location = New-Object Drawing.Point(24, 566)
$script:LogBox.Size = New-Object Drawing.Size(946, 155)
$script:LogBox.BackColor = [Drawing.Color]::FromArgb(3, 7, 18)
$script:LogBox.ForeColor = [Drawing.Color]::FromArgb(203, 213, 225)
$script:LogBox.BorderStyle = [Windows.Forms.BorderStyle]::None
$script:LogBox.Font = New-Object Drawing.Font("Consolas", 9)
$script:LogBox.ReadOnly = $true
$form.Controls.Add($script:LogBox)

$saved = Get-GuiSavedSettings
$defaultHost = [Environment]::GetEnvironmentVariable("VCAM_PHONE_HOST")
if ([string]::IsNullOrWhiteSpace($defaultHost)) { $defaultHost = "192.168.0.103" }
$script:HostBox.Text = $defaultHost
if ($saved) {
    $savedHost = Get-GuiSavedValue -Settings $saved -Name "phoneHost" -DefaultValue $null
    $savedPort = Get-GuiSavedValue -Settings $saved -Name "phonePort" -DefaultValue $null
    $savedFPS = Get-GuiSavedValue -Settings $saved -Name "phoneFPS" -DefaultValue $null
    $savedTransport = Get-GuiSavedValue -Settings $saved -Name "transport" -DefaultValue "mjpeg"
    $savedAutoBridge = Get-GuiSavedValue -Settings $saved -Name "startBridgeAfterDeploy" -DefaultValue $null
    if (-not [string]::IsNullOrWhiteSpace([string]$savedHost) -and
        (Test-GuiPhoneHost -Value ([string]$savedHost))) {
        $script:HostBox.Text = [string]$savedHost
    }
    $script:PortBox.Value = ConvertTo-GuiSavedBoundedInt -Value $savedPort -Minimum 1 -Maximum 65535 -DefaultValue ([int]$script:PortBox.Value)
    $script:FpsBox.Value = ConvertTo-GuiSavedBoundedInt -Value $savedFPS -Minimum 1 -Maximum 240 -DefaultValue ([int]$script:FpsBox.Value)
    if (([string]$savedTransport).Trim().ToLowerInvariant() -eq "hls") { $script:TransportBox.SelectedIndex = 1 }
    elseif (([string]$savedTransport).Trim().ToLowerInvariant() -notin @("", "mjpeg")) {
        Add-GuiLog -Message "已忽略旧设置中的未知传输协议：$savedTransport"
    }
    $script:AutoBridgeCheck.Checked = ConvertTo-GuiSavedBoolean -Value $savedAutoBridge -DefaultValue $script:AutoBridgeCheck.Checked
}
Update-GuiTransportHint
$latestPackage = Get-GuiLatestPackage
$savedPackage = $null
$savedPackagePath = Get-GuiSavedValue -Settings $saved -Name "packagePath" -DefaultValue $null
if (-not [string]::IsNullOrWhiteSpace([string]$savedPackagePath) -and
    (Test-Path -LiteralPath ([string]$savedPackagePath) -PathType Leaf)) {
    $savedPackage = Get-Item -LiteralPath ([string]$savedPackagePath)
}
if ($latestPackage -and (-not $savedPackage -or
        $latestPackage.LastWriteTimeUtc -gt $savedPackage.LastWriteTimeUtc)) {
    $script:PackageBox.Text = $latestPackage.FullName
} elseif ($savedPackage) {
    $script:PackageBox.Text = $savedPackage.FullName
}
Update-GuiPackageSummary
Add-GuiLog -Message "控制中心已就绪。建议首次部署先运行「环境预检」。"
if ($latestPackage) { Add-GuiLog -Message "已自动发现安装包：$($latestPackage.Name)" }

# Show the window before the full integrity verification. Previous builds ran the
# verification first while PowerShell was hidden, which looked like a silent crash.
if (-not $SmokeTest -and [string]::IsNullOrWhiteSpace($RenderPath)) {
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    Add-GuiLog -Message "正在执行启动完整性检查，请稍候…"
}

$integrityResult = Test-GuiStandaloneIntegrity
if ($integrityResult.Success) {
    Add-GuiLog -Message "独立工具结构、脚本语法与文件完整性检查通过。"
} else {
    foreach ($control in @($script:CheckButton, $script:DeployButton, $script:VerifyButton,
            $script:BridgeButton, $script:BridgeCheckButton)) {
        $control.Enabled = $false
    }
    $script:StatusLabel.Text = "独立工具完整性检查失败，操作已锁定"
    $script:StatusLabel.ForeColor = [Drawing.Color]::FromArgb(248, 113, 113)
    Add-GuiLog -Message "完整性检查失败：$($integrityResult.Message)"
}

$script:BrowseButton.Add_Click({
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Title = "选择 VirtualCamPro 安装包"
    $dialog.Filter = "VirtualCamPro 安装包 (*.deb)|*.deb|所有文件 (*.*)|*.*"
    if (-not [string]::IsNullOrWhiteSpace($script:PackageBox.Text)) {
        $candidateDirectory = Split-Path -Parent $script:PackageBox.Text
        if (Test-Path -LiteralPath $candidateDirectory -PathType Container) {
            $dialog.InitialDirectory = $candidateDirectory
        }
    }
    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $script:PackageBox.Text = $dialog.FileName
        Update-GuiPackageSummary
    }
    $dialog.Dispose()
})
$script:PackageBox.Add_TextChanged({ Update-GuiPackageSummary })
$script:TransportBox.Add_SelectedIndexChanged({
    Update-GuiTransportHint
    $script:BridgeStatus.Text = "未启动"
    $script:BridgeStatus.ForeColor = $colorMuted
})
$script:CheckButton.Add_Click({ Start-GuiPhoneOperation -Mode "Check" })
$script:DeployButton.Add_Click({ Start-GuiPhoneOperation -Mode "Setup" })
$script:VerifyButton.Add_Click({ Start-GuiPhoneOperation -Mode "Verify" })
$script:BridgeButton.Add_Click({ Start-GuiBridge })
$script:BridgeCheckButton.Add_Click({ Start-GuiBridgeCheck })
$script:DeepTestButton.Add_Click({ Start-GuiDeepSelfTest })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 350
$timer.Add_Tick({
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentLogPath) -and
        (Test-Path -LiteralPath $script:CurrentLogPath -PathType Leaf)) {
        try {
            $logText = [IO.File]::ReadAllText($script:CurrentLogPath, [Text.Encoding]::UTF8)
            if ($logText -ne $script:LastLogText) {
                $script:LastLogText = $logText
                $script:LogBox.Text = $logText
                $script:LogBox.SelectionStart = $script:LogBox.TextLength
                $script:LogBox.ScrollToCaret()
            }
        } catch {
            # The installer can briefly hold the append handle; the next tick retries.
        }
    }
    if ($script:BridgeProcess) {
        try {
            $script:BridgeProcess.Refresh()
            if ($script:BridgeProcess.HasExited) {
                $bridgeExitCode = $script:BridgeProcess.ExitCode
                $script:BridgeProcess.Dispose()
                $script:BridgeProcess = $null
                if ($bridgeExitCode -eq 0) {
                    $script:BridgeStatus.Text = "桥接已停止"
                    $script:BridgeStatus.ForeColor = $colorMuted
                    Add-GuiLog -Message "OBS 桥接已停止。"
                } else {
                    $script:BridgeStatus.Text = "桥接异常退出：$bridgeExitCode"
                    $script:BridgeStatus.ForeColor = [Drawing.Color]::FromArgb(248, 113, 113)
                    Add-GuiLog -Message "OBS 桥接异常退出，退出码 $bridgeExitCode。可点击「桥接诊断」查看原因。"
                }
            }
        } catch {
            $script:BridgeProcess = $null
        }
    }
    if ($script:CurrentProcess -and $script:CurrentProcess.HasExited) {
        $exitCode = $script:CurrentProcess.ExitCode
        $finishedMode = $script:CurrentMode
        $script:CurrentProcess.Dispose()
        $script:CurrentProcess = $null
        Set-GuiBusy -Busy $false
        if ($exitCode -eq 0) {
            $script:StatusLabel.Text = "$finishedMode 已成功完成"
            $script:StatusLabel.ForeColor = $colorGreen
            Add-GuiLog -Message "$finishedMode 成功完成。"
            if ($finishedMode -eq "Setup" -and $script:AutoBridgeCheck.Checked) {
                Start-GuiBridge
            }
        } else {
            $script:StatusLabel.Text = "$finishedMode 失败，退出码 $exitCode"
            $script:StatusLabel.ForeColor = [Drawing.Color]::FromArgb(248, 113, 113)
            Add-GuiLog -Message "$finishedMode 未完成，退出码 $exitCode。请根据上方 ERROR 检查。"
        }
    }
})
$timer.Start()

$form.Add_FormClosing({
    Save-GuiSettings
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        $result = [Windows.Forms.MessageBox]::Show(
            "手机操作仍在运行。关闭控制中心不会终止独立安装终端，是否继续关闭？",
            "操作仍在运行", [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Warning)
        if ($result -ne [Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
            return
        }
    }
    if ($script:BridgeProcess) {
        try { $script:BridgeProcess.Dispose() } catch {}
        $script:BridgeProcess = $null
    }
})

if (-not [string]::IsNullOrWhiteSpace($RenderPath)) {
    $renderFullPath = [IO.Path]::GetFullPath($RenderPath)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $renderFullPath)) | Out-Null
    $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object Drawing.Point(-20000, -20000)
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bitmap.Save($renderFullPath, [Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $form.Hide()
}

if ($SmokeTest) {
    Write-Host "VirtualCamPro deployment GUI WinForms smoke test passed." -ForegroundColor Green
    $timer.Dispose()
    $form.Dispose()
    exit 0
}

[Windows.Forms.Application]::Run($form)
$timer.Dispose()
$form.Dispose()
