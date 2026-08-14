[CmdletBinding()]
param(
    [string]$Mode = "Install",
    [string]$PhoneHost = "",
    [string]$PhonePort = "",
    [string]$PhoneUser = "",
    [string]$PackagePath = "",
    [string]$StreamURL = "",
    [string]$Transport = "",
    [string]$PreferredFPS = "",
    [string]$LogPath = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:PhoneLogPath = ""

function Initialize-PhoneLog {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $parent = Split-Path -Parent $fullPath
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            [IO.Directory]::CreateDirectory($parent) | Out-Null
        }
        [IO.File]::WriteAllText($fullPath, "", (New-Object Text.UTF8Encoding($true)))
        $script:PhoneLogPath = $fullPath
    } catch {
        Write-Host "[WARN] Could not initialize the optional GUI log: $($_.Exception.Message)" `
            -ForegroundColor Yellow
    }
}

function Write-PhoneLog {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ([string]::IsNullOrWhiteSpace($script:PhoneLogPath)) { return }
    try {
        $line = "{0} [{1}] {2}{3}" -f (Get-Date -Format "HH:mm:ss"), $Level, `
            $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($script:PhoneLogPath, $line, (New-Object Text.UTF8Encoding($true)))
    } catch {
        # Logging is best-effort and must never interrupt installation or password prompts.
    }
}

function Write-PhoneDetail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host $Message
    Write-PhoneLog -Level "INFO" -Message $Message
}

function Write-PhoneStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $color = switch ($Level) {
        "OK" { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
    Write-PhoneLog -Level $Level -Message $Message
}

function Stop-PhoneTool {
    param(
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Write-PhoneStatus -Level "ERROR" -Message $Message
    exit $ExitCode
}

function Get-PhoneSetting {
    param(
        [AllowEmptyString()][string]$ExplicitValue,
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [AllowEmptyString()][Parameter(Mandatory = $true)][string]$DefaultValue
    )
    if (-not [string]::IsNullOrWhiteSpace($ExplicitValue)) {
        return $ExplicitValue.Trim()
    }
    $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
        return $environmentValue.Trim()
    }
    return $DefaultValue
}

function ConvertTo-PhonePort {
    param([Parameter(Mandatory = $true)][string]$Value)
    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) {
        Stop-PhoneTool -ExitCode 64 -Message "SSH port must be an integer from 1 through 65535; received '$Value'."
    }
    return $parsed
}

function ConvertTo-PhoneFPS {
    param([Parameter(Mandatory = $true)][string]$Value)
    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 240) {
        Stop-PhoneTool -ExitCode 64 -Message "Phone FPS must be an integer from 1 through 240; received '$Value'."
    }
    return $parsed
}

function ConvertTo-PhoneTransport {
    param([Parameter(Mandatory = $true)][string]$Value)
    $normalized = $Value.Trim().ToLowerInvariant()
    if ($normalized -notin @("mjpeg", "hls")) {
        Stop-PhoneTool -ExitCode 64 -Message "Transport must be mjpeg or hls; received '$Value'."
    }
    return $normalized
}

function Test-PhoneHostValue {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 253) { return $false }
    if ($Value.StartsWith("-") -or $Value.Contains("..")) { return $false }
    return $Value -match '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$'
}

function Test-PhoneUserValue {
    param([AllowEmptyString()][string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value -match '^[a-z_][a-z0-9_-]{0,31}$'
}

function Test-PhonePackageName {
    param([AllowEmptyString()][string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value -match '^com\.murkaska\.virtualcampro_[0-9A-Za-z.+~_-]+_iphoneos-arm64\.deb$'
}

function Test-PhoneStreamURL {
    param([AllowEmptyString()][string]$Value)
    $uri = $null
    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt 4096 -or $Value -match '\s' -or
        -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return $uri.Scheme -in @("http", "https") -and
        -not [string]::IsNullOrWhiteSpace($uri.Host) -and
        [string]::IsNullOrEmpty($uri.UserInfo) -and
        [string]::IsNullOrEmpty($uri.Fragment) -and
        $Value.IndexOfAny(@([char]"'", [char]'"', [char]"`r", [char]"`n")) -lt 0
}

function Test-PhoneStreamTransportMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$TransportName
    )
    if (-not (Test-PhoneStreamURL -Value $Value)) { return $false }
    $uri = [Uri]$Value
    $isHlsURL = $uri.AbsolutePath.EndsWith(".m3u8", [StringComparison]::OrdinalIgnoreCase)
    if ($TransportName -eq "hls") { return $isHlsURL }
    return -not $isHlsURL
}

function Format-PhoneStreamURLForDisplay {
    param([Parameter(Mandatory = $true)][string]$Value)
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        return "(invalid URL)"
    }
    # Query strings can contain access tokens. Keep them out of the GUI log.
    return $uri.GetLeftPart([UriPartial]::Path)
}

function Resolve-PhoneLocalIPv4 {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port
    )
    $client = New-Object Net.Sockets.UdpClient
    try {
        $client.Connect($Address, $Port)
        $endpoint = [Net.IPEndPoint]$client.Client.LocalEndPoint
        if ($endpoint -and
            $endpoint.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
            -not $endpoint.Address.ToString().StartsWith("127.")) {
            return $endpoint.Address.ToString()
        }
    } catch {
        return ""
    } finally {
        $client.Dispose()
    }
    return ""
}

function Resolve-PhoneExecutable {
    param([Parameter(Mandatory = $true)][string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        Stop-PhoneTool -ExitCode 3 -Message (
            "$Name was not found. Install the Windows OpenSSH Client optional feature."
        )
    }
    return $command.Source
}

function Resolve-PhonePackage {
    param([AllowEmptyString()][string]$ConfiguredPath)
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        if (-not (Test-Path -LiteralPath $ConfiguredPath -PathType Leaf)) {
            Stop-PhoneTool -ExitCode 2 -Message "Package does not exist: $ConfiguredPath"
        }
        $resolved = (Resolve-Path -LiteralPath $ConfiguredPath).Path
    } else {
        $projectRoot = Split-Path -Parent $PSScriptRoot
        $candidates = New-Object Collections.Generic.List[IO.FileInfo]
        foreach ($directoryName in @("packages", "artifacts")) {
            $directory = Join-Path $projectRoot $directoryName
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
            Get-ChildItem -LiteralPath $directory -Filter "com.murkaska.virtualcampro_*_iphoneos-arm64.deb" `
                -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $candidates.Add($_) }
        }
        $selected = $candidates | Sort-Object LastWriteTimeUtc, FullName -Descending | Select-Object -First 1
        if (-not $selected) {
            Stop-PhoneTool -ExitCode 2 -Message (
                "No VirtualCamPro .deb was found under packages or artifacts. " +
                "Pass the package path as the second argument."
            )
        }
        $resolved = $selected.FullName
    }

    $file = Get-Item -LiteralPath $resolved
    if (-not (Test-PhonePackageName -Value $file.Name)) {
        Stop-PhoneTool -ExitCode 64 -Message "Unexpected package filename: $($file.Name)"
    }
    if ($file.Length -lt 1024) {
        Stop-PhoneTool -ExitCode 2 -Message "Package is unexpectedly small: $($file.FullName)"
    }
    return $file
}

function Test-PhoneTcpPort {
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMilliseconds = 5000
    )
    $client = New-Object Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Address, $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function New-PhoneCheckCommand {
    return (@(
        'set -eu'
        'printf ''VirtualCamPro remote preflight\n'''
        'printf ''iOS: '''
        'sw_vers -productVersion 2>/dev/null || uname -r'
        'id'
        'test -d /var/jb || { echo ''ERROR: /var/jb is missing; activate a rootless jailbreak.'' >&2; exit 20; }'
        'sudo_path="$(command -v sudo)" || { echo ''ERROR: sudo is missing.'' >&2; exit 21; }'
        'dpkg_path="$(command -v dpkg)" || { echo ''ERROR: dpkg is missing.'' >&2; exit 22; }'
        'dpkg_deb_path="$(command -v dpkg-deb)" || { echo ''ERROR: dpkg-deb is missing.'' >&2; exit 23; }'
        'command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1 || { echo ''ERROR: a SHA-256 utility is missing.'' >&2; exit 36; }'
        'ls -l "$sudo_path"'
        '"$sudo_path" -v'
        '"$sudo_path" id'
        '"$dpkg_path" -s com.murkaska.virtualcampro 2>/dev/null | grep -E ''^(Status|Version|Architecture):'' || true'
    ) -join '; ')
}

function New-PhoneInstallCommand {
    param(
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][long]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$ExpectedSHA256
    )
    if (-not (Test-PhonePackageName -Value $PackageName)) {
        throw "Unsafe package filename: $PackageName"
    }
    if ($ExpectedSHA256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "Unsafe package SHA-256: $ExpectedSHA256"
    }
    $remotePackage = "/var/mobile/$PackageName"
    return (@(
        'set -eu'
        'test -d /var/jb || { echo ''ERROR: /var/jb is missing; activate a rootless jailbreak.'' >&2; exit 20; }'
        'sudo_path="$(command -v sudo)" || { echo ''ERROR: sudo is missing.'' >&2; exit 21; }'
        'dpkg_path="$(command -v dpkg)" || { echo ''ERROR: dpkg is missing.'' >&2; exit 22; }'
        'dpkg_deb_path="$(command -v dpkg-deb)" || { echo ''ERROR: dpkg-deb is missing.'' >&2; exit 23; }'
        ('test -f ''' + $remotePackage + ''' || { echo ''ERROR: uploaded package is missing.'' >&2; exit 24; }')
        ('remote_package=''' + $remotePackage + '''')
        ('expected_bytes=''' + [string]$ExpectedBytes + '''')
        ('expected_sha256=''' + $ExpectedSHA256.ToUpperInvariant() + '''')
        'cleanup_upload() { rm -f "$remote_package"; }'
        'trap cleanup_upload EXIT HUP INT TERM'
        'actual_bytes="$(wc -c < "$remote_package" | tr -d ''[:space:]'')"'
        'test "$actual_bytes" = "$expected_bytes" || { echo "ERROR: uploaded package size mismatch: $actual_bytes != $expected_bytes" >&2; exit 27; }'
        'if command -v sha256sum >/dev/null 2>&1; then actual_sha256="$(sha256sum "$remote_package" | awk ''{print $1}'')"; elif command -v shasum >/dev/null 2>&1; then actual_sha256="$(shasum -a 256 "$remote_package" | awk ''{print $1}'')"; elif command -v openssl >/dev/null 2>&1; then actual_sha256="$(openssl dgst -sha256 "$remote_package" | awk ''{print $NF}'')"; else echo ''ERROR: a SHA-256 utility is missing.'' >&2; exit 36; fi'
        'actual_sha256="$(printf ''%s'' "$actual_sha256" | tr ''[:lower:]'' ''[:upper:]'')"'
        'test "$actual_sha256" = "$expected_sha256" || { echo ''ERROR: uploaded package SHA-256 mismatch.'' >&2; exit 37; }'
        'package_id="$("$dpkg_deb_path" -f "$remote_package" Package)"'
        'package_version="$("$dpkg_deb_path" -f "$remote_package" Version)"'
        'package_arch="$("$dpkg_deb_path" -f "$remote_package" Architecture)"'
        'test "$package_id" = ''com.murkaska.virtualcampro'' || { echo "ERROR: unexpected package ID: $package_id" >&2; exit 25; }'
        'test "$package_arch" = ''iphoneos-arm64'' || { echo "ERROR: unexpected package architecture: $package_arch" >&2; exit 26; }'
        'printf ''Verified package: %s %s %s\n'' "$package_id" "$package_version" "$package_arch"'
        '"$sudo_path" -v'
        '"$sudo_path" "$dpkg_path" -i "$remote_package"'
        'installed_version="$("$dpkg_path" -s com.murkaska.virtualcampro | sed -n ''s/^Version: //p'' | head -n 1)"'
        'test "$installed_version" = "$package_version" || { echo "ERROR: installed version $installed_version does not match package $package_version" >&2; exit 28; }'
        '"$dpkg_path" -s com.murkaska.virtualcampro | grep -E ''^(Status|Version|Architecture):'''
        'rm -f "$remote_package"'
        'trap - EXIT HUP INT TERM'
        'printf ''Removed verified upload: %s\n'' "$remote_package"'
    ) -join '; ')
}

function New-PhoneSetupCommand {
    param(
        [Parameter(Mandatory = $true)][string]$URL,
        [Parameter(Mandatory = $true)][int]$FPS
    )
    if (-not (Test-PhoneStreamURL -Value $URL)) {
        throw "Unsafe stream URL: $URL"
    }
    if ($FPS -lt 1 -or $FPS -gt 240) { throw "Unsafe phone FPS: $FPS" }
    return (@(
        'set -eu'
        'config_path="$(command -v virtualcampro-config 2>/dev/null || true)"'
        'if [ -z "$config_path" ] && [ -x /var/jb/usr/bin/virtualcampro-config ]; then config_path=/var/jb/usr/bin/virtualcampro-config; fi'
        'test -n "$config_path" && test -x "$config_path" || { echo ''ERROR: virtualcampro-config is missing from the installed package.'' >&2; exit 29; }'
        ('"$config_path" ''' + $URL + ''' ''' + [string]$FPS + '''')
        'printf ''Configured stream URL successfully\n'''
    ) -join '; ')
}

function New-PhoneVerifyCommand {
    return (@(
        'set -eu'
        'dpkg_path="$(command -v dpkg)" || { echo ''ERROR: dpkg is missing.'' >&2; exit 22; }'
        '"$dpkg_path" -s com.murkaska.virtualcampro >/dev/null 2>&1 || { echo ''ERROR: VirtualCamPro is not installed.'' >&2; exit 30; }'
        # "status" is a read-only special parameter in zsh (the default iOS shell).
        'package_status="$("$dpkg_path" -s com.murkaska.virtualcampro | sed -n ''s/^Status: //p'' | head -n 1)"'
        'version="$("$dpkg_path" -s com.murkaska.virtualcampro | sed -n ''s/^Version: //p'' | head -n 1)"'
        'arch="$("$dpkg_path" -s com.murkaska.virtualcampro | sed -n ''s/^Architecture: //p'' | head -n 1)"'
        'test "$package_status" = ''install ok installed'' || { echo "ERROR: package status is $package_status" >&2; exit 31; }'
        'test "$arch" = ''iphoneos-arm64'' || { echo "ERROR: package architecture is $arch" >&2; exit 32; }'
        'test -f /var/jb/Library/MobileSubstrate/DynamicLibraries/AVFCameraSupport.dylib || { echo ''ERROR: application hook is missing.'' >&2; exit 33; }'
        'test -f /var/jb/Library/MobileSubstrate/DynamicLibraries/VCMediaServer.dylib || { echo ''ERROR: media-server hook is missing.'' >&2; exit 34; }'
        'test -x /var/jb/usr/bin/virtualcampro-config || { echo ''ERROR: configuration utility is missing.'' >&2; exit 35; }'
        'printf ''Status: %s\nVersion: %s\nArchitecture: %s\nRuntime files: verified\n'' "$package_status" "$version" "$arch"'
    ) -join '; ')
}

function Invoke-PhoneNativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    # Native stdout is success-stream data in PowerShell. Send it to the host so
    # callers capture only the integer exit code; stderr and password prompts
    # remain attached to the interactive console.
    & $Executable @Arguments | ForEach-Object {
        $nativeLine = [string]$_
        $nativeLine | Out-Host
        Write-PhoneLog -Level "REMOTE" -Message $nativeLine
    }
    $exitCode = $LASTEXITCODE
    return [int]$exitCode
}

function Invoke-PhoneSSH {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$RemoteCommand
    )
    $arguments = @(
        "-t",
        "-p", [string]$Port,
        "-o", "ConnectTimeout=8",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=2",
        ("{0}@{1}" -f $User, $Address),
        $RemoteCommand
    )
    return (Invoke-PhoneNativeCommand -Executable $Executable -Arguments $arguments)
}

function Invoke-PhoneSCP {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string]$Address,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][IO.FileInfo]$Package
    )
    $destination = "{0}@{1}:/var/mobile/{2}" -f $User, $Address, $Package.Name
    $arguments = @(
        "-P", [string]$Port,
        "-o", "ConnectTimeout=8",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=2",
        $Package.FullName,
        $destination
    )
    return (Invoke-PhoneNativeCommand -Executable $Executable -Arguments $arguments)
}

function Invoke-PhoneSelfTest {
    if ((ConvertTo-PhoneFPS -Value "240") -ne 240) {
        Stop-PhoneTool -ExitCode 70 -Message "High frame-rate validation self-test failed."
    }
    if (-not (Test-PhoneHostValue -Value "192.168.0.103") -or
        -not (Test-PhoneHostValue -Value "iphone.local") -or
        (Test-PhoneHostValue -Value "-oProxyCommand=bad") -or
        (Test-PhoneHostValue -Value "iphone..local")) {
        Stop-PhoneTool -ExitCode 70 -Message "Phone host validation self-test failed."
    }
    if (-not (Test-PhoneUserValue -Value "mobile") -or
        (Test-PhoneUserValue -Value "mobile@bad")) {
        Stop-PhoneTool -ExitCode 70 -Message "Phone user validation self-test failed."
    }
    $packageName = "com.murkaska.virtualcampro_2.21.0_iphoneos-arm64.deb"
    if (-not (Test-PhonePackageName -Value $packageName) -or
        (Test-PhonePackageName -Value "bad;touch_iphoneos-arm64.deb")) {
        Stop-PhoneTool -ExitCode 70 -Message "Package name validation self-test failed."
    }
    $checkCommand = New-PhoneCheckCommand
    $testHash = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
    $installCommand = New-PhoneInstallCommand -PackageName $packageName `
        -ExpectedBytes 65536 -ExpectedSHA256 $testHash
    $setupCommand = New-PhoneSetupCommand `
        -URL "http://192.168.1.10:8888/live.mjpg" -FPS 30
    $hlsSetupCommand = New-PhoneSetupCommand `
        -URL "http://192.168.1.10:8888/live.m3u8" -FPS 48
    $verifyCommand = New-PhoneVerifyCommand
    if ($checkCommand -notlike '*"$sudo_path" -v*' -or
        $checkCommand -notlike '*SHA-256 utility*' -or
        $installCommand -notlike "*dpkg-deb*" -or
        $installCommand -notlike "*$packageName*" -or
        $installCommand -notlike '*expected_bytes=''65536''*' -or
        $installCommand -notlike "*expected_sha256='$testHash'*" -or
        $installCommand -notlike '*sha256sum*shasum*' -or
        $installCommand -notlike '*trap cleanup_upload EXIT HUP INT TERM*' -or
        $installCommand -notlike '*installed_version*' -or
        $installCommand -notlike '*rm -f "$remote_package"*' -or
        $installCommand -notlike '*"$sudo_path" "$dpkg_path" -i "$remote_package"*' -or
        $setupCommand -notlike '*virtualcampro-config*' -or
        $setupCommand -notlike '*http://192.168.1.10:8888/live.mjpg*' -or
        $hlsSetupCommand -notlike '*virtualcampro-config*' -or
        $hlsSetupCommand -notlike '*http://192.168.1.10:8888/live.m3u8*' -or
        $hlsSetupCommand -notlike '*48*' -or
        $verifyCommand -notlike '*Runtime files: verified*' -or
        $verifyCommand -notlike '*package_status=*' -or
        $verifyCommand -match '(^|; )status=' -or
        $verifyCommand -notlike '*VCMediaServer.dylib*') {
        Stop-PhoneTool -ExitCode 70 -Message "Remote command construction self-test failed."
    }
    if (-not (Test-PhoneStreamURL -Value "http://192.168.1.10:8888/live.mjpg") -or
        -not (Test-PhoneStreamURL -Value "http://192.168.1.10:8888/live.m3u8") -or
        (Test-PhoneStreamURL -Value "file:///var/mobile/test") -or
        (Test-PhoneStreamURL -Value "http://user:password@192.168.1.10/live.mjpg")) {
        Stop-PhoneTool -ExitCode 70 -Message "Stream URL validation self-test failed."
    }
    if ((ConvertTo-PhoneTransport -Value "mjpeg") -ne "mjpeg" -or
        (ConvertTo-PhoneTransport -Value "HLS") -ne "hls" -or
        -not (Test-PhoneStreamTransportMatch -Value "http://192.168.1.10:8888/live.mjpg" -TransportName "mjpeg") -or
        -not (Test-PhoneStreamTransportMatch -Value "http://192.168.1.10:8888/live.m3u8" -TransportName "hls") -or
        (Test-PhoneStreamTransportMatch -Value "http://192.168.1.10:8888/live.mjpg" -TransportName "hls") -or
        (Test-PhoneStreamTransportMatch -Value "http://192.168.1.10:8888/live.m3u8" -TransportName "mjpeg")) {
        Stop-PhoneTool -ExitCode 70 -Message "Transport validation self-test failed."
    }
    $nativeResult = Invoke-PhoneNativeCommand -Executable $env:ComSpec `
        -Arguments @("/d", "/c", "echo Native output forwarding passed. & exit /b 7")
    if (@($nativeResult).Count -ne 1 -or $nativeResult -ne 7) {
        Stop-PhoneTool -ExitCode 70 -Message "Native exit-code forwarding self-test failed."
    }
    Write-PhoneStatus -Level "OK" -Message "iPhone installer self-test passed."
    exit 0
}

$normalizedMode = $Mode.Trim().ToLowerInvariant()
Initialize-PhoneLog -Path $LogPath
Write-PhoneLog -Level "INFO" -Message "VirtualCamPro phone operation started in $normalizedMode mode."
if ($normalizedMode -eq "selftest") { Invoke-PhoneSelfTest }
if ($normalizedMode -notin @("install", "setup", "check", "verify")) {
    Stop-PhoneTool -ExitCode 64 -Message "Mode must be Install, Setup, Check, Verify, or SelfTest."
}

$effectiveHost = Get-PhoneSetting -ExplicitValue $PhoneHost `
    -EnvironmentName "VCAM_PHONE_HOST" -DefaultValue ""
$effectivePort = ConvertTo-PhonePort -Value (Get-PhoneSetting -ExplicitValue $PhonePort `
    -EnvironmentName "VCAM_PHONE_PORT" -DefaultValue "22")
$effectiveUser = (Get-PhoneSetting -ExplicitValue $PhoneUser `
    -EnvironmentName "VCAM_PHONE_USER" -DefaultValue "mobile").ToLowerInvariant()
$effectivePackagePath = Get-PhoneSetting -ExplicitValue $PackagePath `
    -EnvironmentName "VCAM_DEB_PATH" -DefaultValue ""
$effectivePreferredFPS = ConvertTo-PhoneFPS -Value (Get-PhoneSetting `
    -ExplicitValue $PreferredFPS -EnvironmentName "VCAM_PHONE_FPS" -DefaultValue "60")
$effectiveTransport = ConvertTo-PhoneTransport -Value (Get-PhoneSetting `
    -ExplicitValue $Transport -EnvironmentName "VCAM_TRANSPORT" -DefaultValue "mjpeg")

if (-not (Test-PhoneHostValue -Value $effectiveHost)) {
    Stop-PhoneTool -ExitCode 64 -Message (
        "A valid phone IPv4 address or hostname is required. Example: " +
        "install-phone.bat --check 192.168.0.103"
    )
}
if (-not (Test-PhoneUserValue -Value $effectiveUser)) {
    Stop-PhoneTool -ExitCode 64 -Message "Invalid SSH user: $effectiveUser"
}

$ssh = Resolve-PhoneExecutable -Name "ssh.exe"
if (-not (Test-PhoneTcpPort -Address $effectiveHost -Port $effectivePort)) {
    Stop-PhoneTool -ExitCode 4 -Message (
        "Cannot reach SSH at ${effectiveHost}:$effectivePort. Confirm Wi-Fi, the phone IP, " +
        "OpenSSH, and the active jailbreak."
    )
}
Write-PhoneStatus -Level "OK" -Message "SSH is reachable at ${effectiveHost}:$effectivePort."

if ($normalizedMode -eq "check") {
    Write-PhoneDetail -Message "The SSH and sudo password prompts are handled directly by OpenSSH."
    $checkExitCode = Invoke-PhoneSSH -Executable $ssh -Address $effectiveHost `
        -Port $effectivePort -User $effectiveUser -RemoteCommand (New-PhoneCheckCommand)
    if ($checkExitCode -ne 0) {
        Stop-PhoneTool -ExitCode 5 -Message (
            "Remote preflight failed. If sudo reports an ineffective user ID or nosuid, " +
            "fully reboot and reactivate the same rootless jailbreak before retrying."
        )
    }
    Write-PhoneStatus -Level "OK" -Message "The phone rootless environment and sudo elevation are ready."
    exit 0
}

if ($normalizedMode -eq "verify") {
    Write-PhoneDetail -Message "The SSH password prompt is handled directly by OpenSSH."
    $verifyExitCode = Invoke-PhoneSSH -Executable $ssh -Address $effectiveHost `
        -Port $effectivePort -User $effectiveUser -RemoteCommand (New-PhoneVerifyCommand)
    if ($verifyExitCode -ne 0) {
        Stop-PhoneTool -ExitCode 9 -Message "Installed package verification failed."
    }
    Write-PhoneStatus -Level "OK" -Message "VirtualCamPro package and runtime files are installed correctly."
    exit 0
}

$package = Resolve-PhonePackage -ConfiguredPath $effectivePackagePath
$scp = Resolve-PhoneExecutable -Name "scp.exe"
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $package.FullName).Hash
Write-PhoneStatus -Level "OK" -Message "Package: $($package.FullName)"
Write-PhoneDetail -Message "SHA-256: $hash"
Write-PhoneDetail -Message "Passwords are requested directly by OpenSSH and are never accepted or stored by this tool."

$copyExitCode = Invoke-PhoneSCP -Executable $scp -Address $effectiveHost -Port $effectivePort `
    -User $effectiveUser -Package $package
if ($copyExitCode -ne 0) {
    Stop-PhoneTool -ExitCode 6 -Message "Package transfer failed with scp exit code $copyExitCode."
}
Write-PhoneStatus -Level "OK" -Message "Package copied to /var/mobile/$($package.Name)."

$installExitCode = Invoke-PhoneSSH -Executable $ssh -Address $effectiveHost `
    -Port $effectivePort -User $effectiveUser `
    -RemoteCommand (New-PhoneInstallCommand -PackageName $package.Name `
        -ExpectedBytes $package.Length -ExpectedSHA256 $hash)
if ($installExitCode -ne 0) {
    Stop-PhoneTool -ExitCode 7 -Message (
        "Remote installation failed. Do not force dependencies. If sudo mentions nosuid, " +
        "reactivate the rootless jailbreak and run --check first."
    )
}

Write-PhoneStatus -Level "OK" -Message (
    "VirtualCamPro installation, version verification, and upload cleanup completed."
)

if ($normalizedMode -eq "setup") {
    $effectiveStreamURL = Get-PhoneSetting -ExplicitValue $StreamURL `
        -EnvironmentName "VCAM_STREAM_URL" -DefaultValue ""
    if ([string]::IsNullOrWhiteSpace($effectiveStreamURL)) {
        $localAddress = Resolve-PhoneLocalIPv4 -Address $effectiveHost -Port $effectivePort
        if ([string]::IsNullOrWhiteSpace($localAddress)) {
            Stop-PhoneTool -ExitCode 8 -Message (
                "Could not determine the computer IPv4 address used to reach the phone. " +
                "Set VCAM_STREAM_URL and run --setup again."
            )
        }
        $streamPort = ConvertTo-PhonePort -Value (Get-PhoneSetting -ExplicitValue "" `
            -EnvironmentName "VCAM_PORT" -DefaultValue "8888")
        $streamLeaf = if ($effectiveTransport -eq "hls") { "live.m3u8" } else { "live.mjpg" }
        $effectiveStreamURL = "http://${localAddress}:$streamPort/$streamLeaf"
    }
    if (-not (Test-PhoneStreamURL -Value $effectiveStreamURL)) {
        Stop-PhoneTool -ExitCode 64 -Message "Invalid setup stream URL: $effectiveStreamURL"
    }
    if (-not (Test-PhoneStreamTransportMatch -Value $effectiveStreamURL `
            -TransportName $effectiveTransport)) {
        Stop-PhoneTool -ExitCode 64 -Message (
            "Stream URL does not match transport '$effectiveTransport'. " +
            "Use a .m3u8 URL for HLS, or a non-.m3u8 MJPEG endpoint for MJPEG."
        )
    }
    $displayStreamURL = Format-PhoneStreamURLForDisplay -Value $effectiveStreamURL
    Write-PhoneStatus -Level "INFO" -Message (
        "Configuring $displayStreamURL; local-file FPS limit is $effectivePreferredFPS (network FPS remains sender-controlled)..."
    )
    $setupExitCode = Invoke-PhoneSSH -Executable $ssh -Address $effectiveHost `
        -Port $effectivePort -User $effectiveUser `
        -RemoteCommand (New-PhoneSetupCommand -URL $effectiveStreamURL `
            -FPS $effectivePreferredFPS)
    if ($setupExitCode -ne 0) {
        Stop-PhoneTool -ExitCode 8 -Message (
            "The package was installed, but automatic stream configuration failed. " +
            "Open VirtualCamPro settings and enter the displayed URL manually."
        )
    }
    Write-PhoneStatus -Level "OK" -Message (
        "Phone configuration completed. Start the Windows bridge, then use the new in-phone stream test."
    )
}
