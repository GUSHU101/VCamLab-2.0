[CmdletBinding()]
param(
    [string]$RootPath = "",
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = Split-Path -Parent $PSScriptRoot
}
$root = [IO.Path]::GetFullPath($RootPath)
$script:FailureCount = 0
$script:WarningCount = 0
$script:PassCount = 0

function Write-DeepResult {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("PASS", "WARN", "FAIL", "INFO")][string]$Level,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )
    switch ($Level) {
        "PASS" { $script:PassCount++; $color = "Green" }
        "WARN" { $script:WarningCount++; $color = "Yellow" }
        "FAIL" { $script:FailureCount++; $color = "Red" }
        default { $color = "Cyan" }
    }
    if (-not $Quiet -or $Level -in @("WARN", "FAIL")) {
        Write-Host ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
    }
}

function Get-ChildPowerShellPath {
    $candidate = Join-Path $PSHOME "powershell.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return ""
}

function Invoke-ChildPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 30,
        [switch]$STA,
        [hashtable]$EnvironmentOverrides = @{}
    )
    $powershell = Get-ChildPowerShellPath
    if ([string]::IsNullOrWhiteSpace($powershell)) {
        return [pscustomobject]@{ ExitCode = 9001; Output = "powershell.exe not found"; TimedOut = $false }
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershell
    $argumentList = New-Object Collections.Generic.List[string]
    foreach ($value in @("-NoLogo", "-NoProfile")) { $argumentList.Add($value) }
    if ($STA) { $argumentList.Add("-STA") }
    foreach ($value in @("-ExecutionPolicy", "Bypass", "-File", ('"{0}"' -f $ScriptPath))) {
        $argumentList.Add($value)
    }
    foreach ($argument in $Arguments) {
        if ($argument -match '[\r\n]') { throw "Child process argument contains a newline." }
        if ($argument -match '[\s"]') {
            $argumentList.Add(('"{0}"' -f $argument.Replace('"', '\"')))
        } else {
            $argumentList.Add($argument)
        }
    }
    $startInfo.Arguments = $argumentList -join " "
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($environmentName in $EnvironmentOverrides.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$environmentName)) { continue }
        $startInfo.EnvironmentVariables[[string]$environmentName] = [string]$EnvironmentOverrides[$environmentName]
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            return [pscustomobject]@{ ExitCode = 9002; Output = "process start returned false"; TimedOut = $false }
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            try { [void]$process.WaitForExit(3000) } catch {}
            try { $stdoutTask.Wait(3000) } catch {}
            try { $stderrTask.Wait(3000) } catch {}
            $stdout = if ($stdoutTask.IsCompleted) { [string]$stdoutTask.Result } else { "[stdout did not finish before timeout]" }
            $stderr = if ($stderrTask.IsCompleted) { [string]$stderrTask.Result } else { "[stderr did not finish before timeout]" }
            $output = (($stdout + [Environment]::NewLine + $stderr).Trim())
            return [pscustomobject]@{ ExitCode = 9003; Output = $output; TimedOut = $true }
        }
        $stdoutTask.Wait()
        $stderrTask.Wait()
        $output = (($stdoutTask.Result + [Environment]::NewLine + $stderrTask.Result).Trim())
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output; TimedOut = $false }
    } finally {
        $process.Dispose()
    }
}

function Get-ConfigValues {
    param([Parameter(Mandatory = $true)][string]$Path)
    $values = @{}
    foreach ($rawLine in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $rawLine.Trim()
        $match = [regex]::Match($line, '^set "(?<name>VCAM_[A-Z0-9_]+)=(?<value>[^"\r\n]*)"$')
        if ($match.Success) {
            $values[$match.Groups["name"].Value] = $match.Groups["value"].Value
        }
    }
    return $values
}

function Test-IntegerSetting {
    param(
        [hashtable]$Values,
        [string]$Name,
        [int]$Minimum,
        [int]$Maximum
    )
    if (-not $Values.ContainsKey($Name)) { Write-DeepResult -Level "FAIL" -Message "Config setting is missing: $Name"; return $null }
    $parsed = 0
    if (-not [int]::TryParse([string]$Values[$Name], [ref]$parsed) -or $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        Write-DeepResult -Level "FAIL" -Message "$Name must be an integer from $Minimum through $Maximum; current value '$($Values[$Name])'."
        return $null
    }
    return $parsed
}

function Test-DecimalSetting {
    param(
        [hashtable]$Values,
        [string]$Name,
        [double]$Minimum,
        [double]$Maximum
    )
    if (-not $Values.ContainsKey($Name)) { Write-DeepResult -Level "FAIL" -Message "Config setting is missing: $Name"; return $null }
    $parsed = 0.0
    if (-not [double]::TryParse([string]$Values[$Name], [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -or
        [double]::IsNaN($parsed) -or [double]::IsInfinity($parsed) -or
        $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        Write-DeepResult -Level "FAIL" -Message "$Name must be from $Minimum through $Maximum; current value '$($Values[$Name])'."
        return $null
    }
    return $parsed
}

function Test-BooleanSetting {
    param([hashtable]$Values, [string]$Name)
    if (-not $Values.ContainsKey($Name)) { Write-DeepResult -Level "FAIL" -Message "Config setting is missing: $Name"; return }
    if (([string]$Values[$Name]).Trim().ToLowerInvariant() -notin @("1", "0", "true", "false", "yes", "no", "on", "off")) {
        Write-DeepResult -Level "FAIL" -Message "$Name is not a valid boolean value: '$($Values[$Name])'."
    }
}

function Get-FreeLoopbackPort {
    $listener = New-Object Net.Sockets.TcpListener -ArgumentList @([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Wait-TcpPort {
    param([int]$Port, [int]$TimeoutMilliseconds = 5000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync("127.0.0.1", $Port)
            if ($task.Wait(250) -and $client.Connected) { return $true }
        } catch {
        } finally {
            $client.Dispose()
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Invoke-HttpProbe {
    param(
        [Parameter(Mandatory = $true)][string]$URL,
        [ValidateSet("GET", "HEAD", "OPTIONS", "POST")][string]$Method = "GET",
        [int]$RangeStart = -1,
        [int]$RangeEnd = -1
    )
    $request = [Net.HttpWebRequest]::Create($URL)
    $request.Method = $Method
    $request.Timeout = 5000
    $request.ReadWriteTimeout = 5000
    $request.AllowAutoRedirect = $false
    if ($RangeStart -ge 0 -and $RangeEnd -ge $RangeStart) {
        $request.AddRange($RangeStart, $RangeEnd)
    }
    $response = $null
    try {
        $response = [Net.HttpWebResponse]$request.GetResponse()
    } catch [Net.WebException] {
        if ($_.Exception.Response) {
            $response = [Net.HttpWebResponse]$_.Exception.Response
        } else {
            throw
        }
    }
    try {
        $body = New-Object byte[] 0
        if ($Method -ne "HEAD") {
            $stream = $null
            $memory = $null
            try {
                $stream = $response.GetResponseStream()
                $memory = New-Object IO.MemoryStream
                try {
                    $stream.CopyTo($memory)
                    $body = $memory.ToArray()
                } finally {
                    $memory.Dispose()
                }
            } finally {
                if ($stream) { $stream.Dispose() }
            }
        }
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            ContentType = [string]$response.ContentType
            ContentLength = [long]$response.ContentLength
            AllowOrigin = [string]$response.Headers["Access-Control-Allow-Origin"]
            ContentRange = [string]$response.Headers["Content-Range"]
            CacheControl = [string]$response.Headers["Cache-Control"]
            ContentTypeOptions = [string]$response.Headers["X-Content-Type-Options"]
            Body = $body
        }
    } finally {
        $response.Dispose()
    }
}

function Test-HlsServerRuntime {
    $serverScript = Join-Path $root "scripts\hls-server.ps1"
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("VirtualCamPro-deep-test-" + [Guid]::NewGuid().ToString("N"))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $programTime = "2026-01-01T00:00:00.000Z"
    $playlistLines = New-Object Collections.Generic.List[string]
    foreach ($line in @("#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:1", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-PROGRAM-DATE-TIME:$programTime")) {
        $playlistLines.Add($line)
    }
    for ($index = 0; $index -lt 6; $index++) {
        $playlistLines.Add("#EXTINF:0.25,")
        $playlistLines.Add(("segment_{0:D6}.ts" -f $index))
    }
    $playlist = ($playlistLines -join "`n") + "`n"
    [IO.File]::WriteAllText((Join-Path $tempRoot "live.m3u8"), $playlist, (New-Object Text.UTF8Encoding($false)))
    for ($index = 0; $index -lt 6; $index++) {
        [IO.File]::WriteAllBytes(
            (Join-Path $tempRoot ("segment_{0:D6}.ts" -f $index)),
            [byte[]](0, 1, 2, 3, 4, 5, 6, 7))
    }
    $port = Get-FreeLoopbackPort
    $powershell = Get-ChildPowerShellPath
    if ([string]::IsNullOrWhiteSpace($powershell)) { throw "powershell.exe not found" }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershell
    $startInfo.Arguments = ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -RootPath "{1}" -BindAddress 127.0.0.1 -Port {2} -PlaylistName live.m3u8' -f
        $serverScript, $tempRoot, $port)
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $server = $null
    try {
        $server = [Diagnostics.Process]::Start($startInfo)
        if (-not $server) { throw "HLS server process could not be started." }
        if (-not (Wait-TcpPort -Port $port)) {
            $server.Refresh()
            if ($server.HasExited) { throw "HLS server exited with code $($server.ExitCode)." }
            throw "HLS server did not listen within 5 seconds."
        }
        $base = "http://127.0.0.1:$port"
        $playlistResult = Invoke-HttpProbe -URL "$base/live.m3u8"
        if ($playlistResult.StatusCode -ne 200 -or
            $playlistResult.ContentType -notlike "application/vnd.apple.mpegurl*" -or
            $playlistResult.AllowOrigin -ne "*" -or
            $playlistResult.CacheControl -notlike "*no-store*" -or
            $playlistResult.ContentTypeOptions -ne "nosniff") {
            throw "HLS playlist GET response is invalid."
        }
        $playlistText = [Text.Encoding]::UTF8.GetString($playlistResult.Body)
        $listedSegments = ([regex]::Matches($playlistText, '(?m)^segment_[0-9]{6}[.]ts$')).Count
        if ($listedSegments -lt 6 -or
            $playlistText -notlike "*#EXT-X-INDEPENDENT-SEGMENTS*" -or
            $playlistText -notlike "*#EXT-X-PROGRAM-DATE-TIME:*") {
            throw "HLS playlist is missing the six-segment/PDT/independent-segment contract."
        }

        $headResult = Invoke-HttpProbe -URL "$base/segment_000000.ts" -Method HEAD
        if ($headResult.StatusCode -ne 200 -or $headResult.ContentLength -ne 8 -or
            $headResult.ContentType -notlike "video/mp2t*") {
            throw "HLS segment HEAD response is invalid."
        }

        $rangeResult = Invoke-HttpProbe -URL "$base/segment_000000.ts" -RangeStart 1 -RangeEnd 3
        if ($rangeResult.StatusCode -ne 206 -or $rangeResult.Body.Length -ne 3 -or
            $rangeResult.Body[0] -ne 1 -or $rangeResult.Body[2] -ne 3 -or
            $rangeResult.ContentRange -ne "bytes 1-3/8") {
            throw "HLS byte-range response is invalid."
        }

        $invalidRangeResult = Invoke-HttpProbe -URL "$base/segment_000000.ts" -RangeStart 20 -RangeEnd 25
        if ($invalidRangeResult.StatusCode -ne 416 -or
            $invalidRangeResult.ContentRange -ne "bytes */8") {
            throw "HLS invalid-range response is not RFC-compatible."
        }

        $missingResult = Invoke-HttpProbe -URL "$base/%2e%2e/control"
        if ($missingResult.StatusCode -notin @(403, 404)) {
            throw "HLS path allow-list rejected an unsafe path with an unexpected status."
        }

        $methodResult = Invoke-HttpProbe -URL "$base/live.m3u8" -Method POST
        if ($methodResult.StatusCode -ne 405) {
            throw "HLS unsupported-method response is invalid."
        }

        $optionsResult = Invoke-HttpProbe -URL "$base/live.m3u8" -Method OPTIONS
        if ($optionsResult.StatusCode -ne 204 -or $optionsResult.AllowOrigin -ne "*") {
            throw "HLS OPTIONS/CORS response is invalid."
        }
    } finally {
        if ($server) {
            try {
                $server.Refresh()
                if (-not $server.HasExited) {
                    $server.Kill()
                    [void]$server.WaitForExit(3000)
                }
            } catch {}
            $server.Dispose()
        }
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-FfmpegMjpegRuntime {
    param([Parameter(Mandatory = $true)][string]$FfmpegPath)
    $port = Get-FreeLoopbackPort
    $process = $null
    $stdoutTask = $null
    $stderrTask = $null
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $FfmpegPath
        $startInfo.WorkingDirectory = $root
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.Arguments = (
            '-hide_banner -loglevel error -re -f lavfi -i "testsrc2=size=160x120:rate=10" ' +
            '-map 0:v:0 -an -c:v mjpeg -threads 2 -pix_fmt yuvj420p -q:v 5 ' +
            '-f fifo -fifo_format mpjpeg -queue_size 20 -drop_pkts_on_overflow 1 ' +
            '-format_opts "listen=1:flush_packets=1:content_type=multipart/x-mixed-replace;boundary=ffmpeg" ' +
            ('http://127.0.0.1:{0}/live.mjpg' -f $port)
        )
        $process = [Diagnostics.Process]::Start($startInfo)
        if (-not $process) { throw "FFmpeg MJPEG smoke process did not start." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $deadline = [DateTime]::UtcNow.AddSeconds(6)
        $lastError = ""
        $response = $null
        while ([DateTime]::UtcNow -lt $deadline -and -not $response) {
            try {
                $request = [Net.HttpWebRequest]::Create("http://127.0.0.1:$port/live.mjpg")
                $request.Method = "GET"
                $request.Timeout = 1200
                $request.ReadWriteTimeout = 1200
                $request.AllowAutoRedirect = $false
                $response = [Net.HttpWebResponse]$request.GetResponse()
            } catch {
                $lastError = $_.Exception.Message
                if ($process.HasExited) { break }
                Start-Sleep -Milliseconds 150
            }
        }
        if (-not $response) {
            $detail = if ([string]::IsNullOrWhiteSpace($lastError)) { "listener never became reachable" } else { $lastError }
            throw "FFmpeg MJPEG HTTP listener did not become usable: $detail"
        }
        try {
            if ([int]$response.StatusCode -ne 200) { throw "MJPEG HTTP status was $([int]$response.StatusCode)." }
            if ([string]$response.ContentType -notlike "multipart/x-mixed-replace*") {
                throw "MJPEG Content-Type was '$($response.ContentType)' instead of multipart/x-mixed-replace."
            }
            $stream = $response.GetResponseStream()
            try {
                $buffer = New-Object byte[] 4096
                $sampleBuilder = New-Object Text.StringBuilder
                while ($sampleBuilder.Length -lt 65536) {
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    [void]$sampleBuilder.Append([Text.Encoding]::ASCII.GetString($buffer, 0, $read))
                    $candidateText = $sampleBuilder.ToString()
                    if ($candidateText -match '(?is)--ffmpeg.*?content-type\s*:\s*image/jpeg') { break }
                }
                $sample = $sampleBuilder.ToString()
                if ($sample.Length -eq 0) { throw "MJPEG listener returned no body bytes." }
                if ($sample -notmatch '(?is)--ffmpeg.*?content-type\s*:\s*image/jpeg') {
                    throw "MJPEG multipart boundary or JPEG part header was not found."
                }
            } finally {
                if ($stream) { $stream.Dispose() }
            }
        } finally {
            $response.Dispose()
        }
    } finally {
        if ($process) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                    [void]$process.WaitForExit(3000)
                }
            } catch {}
            try { if ($stdoutTask -and -not $stdoutTask.IsCompleted) { [void]$stdoutTask.Wait(1000) } } catch {}
            try { if ($stderrTask -and -not $stderrTask.IsCompleted) { [void]$stderrTask.Wait(1000) } } catch {}
            $process.Dispose()
        }
    }
}

Write-DeepResult -Level "INFO" -Message "VirtualCamPro 2.17.0 deep self-test started."
Write-DeepResult -Level "INFO" -Message "Root: $root"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-DeepResult -Level "FAIL" -Message "Windows PowerShell 5.1 or newer is required; current version is $($PSVersionTable.PSVersion)."
} else {
    Write-DeepResult -Level "PASS" -Message "PowerShell runtime: $($PSVersionTable.PSVersion)."
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    Write-DeepResult -Level "WARN" -Message "Current PowerShell is not STA. GUI launchers force -STA automatically."
} else {
    Write-DeepResult -Level "PASS" -Message "STA apartment state is available for WinForms."
}

$requiredScripts = @(
    "scripts\windows-vcam.ps1",
    "scripts\hls-server.ps1",
    "scripts\obs-websocket.ps1",
    "scripts\install-ios.ps1",
    "scripts\install-ios-gui.ps1",
    "scripts\launch-control-center.ps1",
    "scripts\verify-standalone.ps1",
    "scripts\deep-self-test.ps1"
)
foreach ($relativePath in $requiredScripts) {
    $path = Join-Path $root $relativePath
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        Write-DeepResult -Level "FAIL" -Message ("PowerShell parser rejected {0}: {1}" -f $relativePath, $parseErrors[0].Message)
    } else {
        Write-DeepResult -Level "PASS" -Message "PowerShell parser: $relativePath"
    }
}

try {
    $guiPath = Join-Path $root "scripts\install-ios-gui.ps1"
    $tokens = $null
    $parseErrors = $null
    $guiAst = [Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$tokens, [ref]$parseErrors)
    $labelFunction = $guiAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "New-GuiLabel" }, $true)
    if (-not $labelFunction -or -not $labelFunction.Body.ParamBlock) { throw "New-GuiLabel function was not found." }
    $textParameter = $labelFunction.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Text" } | Select-Object -First 1
    if (-not $textParameter) { throw "New-GuiLabel -Text parameter was not found." }
    $attributeNames = @($textParameter.Attributes | ForEach-Object { $_.TypeName.Name })
    if ($attributeNames -notcontains "AllowEmptyString") {
        throw "New-GuiLabel -Text must allow empty strings so dynamic labels cannot crash startup."
    }
    Write-DeepResult -Level "PASS" -Message "GUI dynamic-label parameter contract is safe."
} catch {
    Write-DeepResult -Level "FAIL" -Message "GUI parameter-contract check failed: $($_.Exception.Message)"
}

try {
    $configPath = Join-Path $root "obs-vcam-config.cmd"
    $config = Get-ConfigValues -Path $configPath
    $transport = ([string]$config["VCAM_TRANSPORT"]).Trim().ToLowerInvariant()
    if ($transport -notin @("mjpeg", "hls")) { Write-DeepResult -Level "FAIL" -Message "VCAM_TRANSPORT must be mjpeg or hls." }
    else { Write-DeepResult -Level "PASS" -Message "Transport config: $transport" }
    foreach ($requiredTextName in @("VCAM_DEVICE_NAME", "VCAM_FFMPEG_LOG_LEVEL")) {
        if (-not $config.ContainsKey($requiredTextName) -or [string]::IsNullOrWhiteSpace([string]$config[$requiredTextName])) {
            Write-DeepResult -Level "FAIL" -Message "$requiredTextName must not be blank."
        }
    }
    if ($config.ContainsKey("VCAM_FFMPEG_LOG_LEVEL") -and
        ([string]$config["VCAM_FFMPEG_LOG_LEVEL"]).Trim().ToLowerInvariant() -notin @("quiet", "panic", "fatal", "error", "warning", "info", "verbose", "debug", "trace")) {
        Write-DeepResult -Level "FAIL" -Message "VCAM_FFMPEG_LOG_LEVEL is invalid."
    }
    foreach ($pathSetting in @("VCAM_FFMPEG_PATH", "VCAM_OBS_PATH")) {
        if ($config.ContainsKey($pathSetting) -and -not [string]::IsNullOrWhiteSpace([string]$config[$pathSetting])) {
            $expandedConfiguredPath = [Environment]::ExpandEnvironmentVariables(([string]$config[$pathSetting]).Trim().Trim('"'))
            if (-not (Test-Path -LiteralPath $expandedConfiguredPath -PathType Leaf)) {
                Write-DeepResult -Level "WARN" -Message "$pathSetting points to a file that does not currently exist: $expandedConfiguredPath"
            }
        }
    }
    if (([string]$config["VCAM_ORIENTATION"]).Trim().ToLowerInvariant() -notin @("landscape", "portrait")) {
        Write-DeepResult -Level "FAIL" -Message "VCAM_ORIENTATION must be landscape or portrait."
    }
    if (([string]$config["VCAM_RESOLUTION"]).Trim().ToLowerInvariant() -notin @("auto", "720p", "1080p", "1440p", "2160p")) {
        Write-DeepResult -Level "FAIL" -Message "VCAM_RESOLUTION is invalid."
    }
    if (([string]$config["VCAM_SCALE_MODE"]).Trim().ToLowerInvariant() -notin @("fill", "fit", "stretch")) {
        Write-DeepResult -Level "FAIL" -Message "VCAM_SCALE_MODE is invalid."
    }
    [void](Test-IntegerSetting -Values $config -Name "VCAM_QUALITY" -Minimum 1 -Maximum 31)
    [void](Test-DecimalSetting -Values $config -Name "VCAM_HLS_SEGMENT_SECONDS" -Minimum 0.2 -Maximum 10)
    $hlsListSize = Test-IntegerSetting -Values $config -Name "VCAM_HLS_LIST_SIZE" -Minimum 6 -Maximum 30
    if ($null -ne $hlsListSize -and $hlsListSize -lt 6) {
        Write-DeepResult -Level "FAIL" -Message "Apple-compatible live HLS playlists require at least six segments."
    }
    $hlsTarget = Test-IntegerSetting -Values $config -Name "VCAM_HLS_VIDEO_BITRATE_KBPS" -Minimum 500 -Maximum 100000
    $hlsMax = Test-IntegerSetting -Values $config -Name "VCAM_HLS_MAXRATE_KBPS" -Minimum 500 -Maximum 120000
    [void](Test-IntegerSetting -Values $config -Name "VCAM_HLS_BUFSIZE_KBPS" -Minimum 500 -Maximum 200000)
    if ($null -ne $hlsTarget -and $null -ne $hlsMax -and $hlsMax -lt $hlsTarget) {
        Write-DeepResult -Level "FAIL" -Message "VCAM_HLS_MAXRATE_KBPS must be >= VCAM_HLS_VIDEO_BITRATE_KBPS."
    }
    if (([string]$config["VCAM_HLS_PRESET"]).Trim().ToLowerInvariant() -notin @("ultrafast", "superfast", "veryfast", "faster", "fast", "medium")) {
        Write-DeepResult -Level "FAIL" -Message "VCAM_HLS_PRESET is invalid."
    }
    [void](Test-IntegerSetting -Values $config -Name "VCAM_PORT" -Minimum 1024 -Maximum 65535)
    [void](Test-IntegerSetting -Values $config -Name "VCAM_OBS_WAIT_SECONDS" -Minimum 1 -Maximum 120)
    [void](Test-IntegerSetting -Values $config -Name "VCAM_RT_BUFFER_MB" -Minimum 16 -Maximum 1024)
    [void](Test-IntegerSetting -Values $config -Name "VCAM_THREAD_QUEUE_SIZE" -Minimum 1 -Maximum 256)
    [void](Test-IntegerSetting -Values $config -Name "VCAM_ENCODER_THREADS" -Minimum 1 -Maximum 16)
    [void](Test-IntegerSetting -Values $config -Name "VCAM_OUTPUT_QUEUE_SIZE" -Minimum 1 -Maximum 600)
    [void](Test-IntegerSetting -Values $config -Name "VCAM_TCP_SEND_BUFFER_MB" -Minimum 1 -Maximum 16)
    foreach ($booleanName in @("VCAM_RESTART_ON_DISCONNECT", "VCAM_REQUIRE_OBS_MODE_MATCH", "VCAM_AUTO_REFRESH_OBS_VIRTUAL_CAMERA")) {
        Test-BooleanSetting -Values $config -Name $booleanName
    }
    $bindAddress = $null
    if (-not [Net.IPAddress]::TryParse([string]$config["VCAM_BIND_ADDRESS"], [ref]$bindAddress) -or
        $bindAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        Write-DeepResult -Level "FAIL" -Message "VCAM_BIND_ADDRESS must be an IPv4 literal."
    }
    $fpsText = ([string]$config["VCAM_FPS"]).Trim().ToLowerInvariant()
    if ($fpsText -ne "auto") {
        $fpsParsed = 0.0
        $fpsValid = [double]::TryParse($fpsText, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$fpsParsed)
        if (-not $fpsValid -and $fpsText -match '^(?<n>[0-9.]+)/(?<d>[0-9.]+)$') {
            $n = 0.0; $d = 0.0
            if ([double]::TryParse($Matches.n, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and
                [double]::TryParse($Matches.d, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -gt 0) {
                $fpsParsed = $n / $d; $fpsValid = $true
            }
        }
        if (-not $fpsValid -or $fpsParsed -lt 1 -or $fpsParsed -gt 240) {
            Write-DeepResult -Level "FAIL" -Message "VCAM_FPS is invalid: '$fpsText'."
        }
    }
    Write-DeepResult -Level "PASS" -Message "Mutable configuration values were semantically checked."
} catch {
    Write-DeepResult -Level "FAIL" -Message "Configuration semantic check failed: $($_.Exception.Message)"
}

foreach ($test in @(
        @{ Name = "Windows streaming core self-test"; Script = "scripts\windows-vcam.ps1"; Args = @("-Mode", "SelfTest"); STA = $false; Timeout = 30 },
        @{ Name = "iPhone installer self-test"; Script = "scripts\install-ios.ps1"; Args = @("-Mode", "SelfTest"); STA = $false; Timeout = 30 },
        @{ Name = "Control-center function self-test"; Script = "scripts\launch-control-center.ps1"; Args = @("-SelfTest", "-DebugConsole"); STA = $true; Timeout = 30 },
        @{ Name = "Control-center WinForms smoke test"; Script = "scripts\launch-control-center.ps1"; Args = @("-SmokeTest", "-DebugConsole"); STA = $true; Timeout = 45 }
    )) {
    $path = Join-Path $root $test.Script
    $result = Invoke-ChildPowerShell -ScriptPath $path -Arguments $test.Args -TimeoutSeconds $test.Timeout -STA:$test.STA
    if ($result.ExitCode -eq 0) {
        Write-DeepResult -Level "PASS" -Message $test.Name
    } else {
        $detail = if ([string]::IsNullOrWhiteSpace($result.Output)) { "no diagnostic output" } else { $result.Output }
        Write-DeepResult -Level "FAIL" -Message ("{0} failed (exit {1}): {2}" -f $test.Name, $result.ExitCode, $detail)
    }
}

$legacySettingsRoot = Join-Path ([IO.Path]::GetTempPath()) ("VirtualCamPro-legacy-settings-" + [Guid]::NewGuid().ToString("N"))
try {
    $legacySettingsDirectory = Join-Path $legacySettingsRoot "VirtualCamPro"
    [IO.Directory]::CreateDirectory($legacySettingsDirectory) | Out-Null
    $legacyJson = @'
{
  "phoneHost": "-oProxyCommand=bad",
  "phonePort": "not-a-number",
  "phoneFPS": 999999,
  "transport": "unknown-old-value",
  "packagePath": "Z:\\does-not-exist\\old.deb",
  "startBridgeAfterDeploy": "not-a-boolean"
}
'@
    [IO.File]::WriteAllText((Join-Path $legacySettingsDirectory "deploy-gui.json"), $legacyJson, (New-Object Text.UTF8Encoding($false)))
    $legacySmoke = Invoke-ChildPowerShell -ScriptPath (Join-Path $root "scripts\launch-control-center.ps1") `
        -Arguments @("-SmokeTest", "-DebugConsole") -TimeoutSeconds 45 -STA `
        -EnvironmentOverrides @{ LOCALAPPDATA = $legacySettingsRoot }
    if ($legacySmoke.ExitCode -eq 0) {
        Write-DeepResult -Level "PASS" -Message "GUI survived malformed/legacy deploy-gui.json values."
    } else {
        $legacyDetail = if ([string]::IsNullOrWhiteSpace($legacySmoke.Output)) { "no diagnostic output" } else { $legacySmoke.Output }
        Write-DeepResult -Level "FAIL" -Message "GUI legacy-settings smoke test failed (exit $($legacySmoke.ExitCode)): $legacyDetail"
    }
} catch {
    Write-DeepResult -Level "FAIL" -Message "GUI legacy-settings smoke test could not run: $($_.Exception.Message)"
} finally {
    Remove-Item -LiteralPath $legacySettingsRoot -Recurse -Force -ErrorAction SilentlyContinue
}

try {
    Test-HlsServerRuntime
    Write-DeepResult -Level "PASS" -Message "HLS HTTP runtime test passed: six-segment playlist, PDT, GET/HEAD, 206/416, method/path guards and CORS."
} catch {
    Write-DeepResult -Level "FAIL" -Message "HLS HTTP runtime test failed: $($_.Exception.Message)"
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Write-DeepResult -Level "PASS" -Message "WinForms and System.Drawing assemblies load successfully."
} catch {
    Write-DeepResult -Level "FAIL" -Message "WinForms runtime is unavailable: $($_.Exception.Message)"
}

$configForEnvironment = $null
try { $configForEnvironment = Get-ConfigValues -Path (Join-Path $root "obs-vcam-config.cmd") } catch {}
$ffmpegPath = ""
if ($configForEnvironment -and -not [string]::IsNullOrWhiteSpace([string]$configForEnvironment["VCAM_FFMPEG_PATH"])) {
    $candidate = [Environment]::ExpandEnvironmentVariables(([string]$configForEnvironment["VCAM_FFMPEG_PATH"]).Trim().Trim('"'))
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $ffmpegPath = (Resolve-Path -LiteralPath $candidate).Path }
    else { Write-DeepResult -Level "WARN" -Message "Configured FFmpeg path does not exist: $candidate" }
}
if ([string]::IsNullOrWhiteSpace($ffmpegPath)) {
    $ffmpegCommand = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($ffmpegCommand) { $ffmpegPath = $ffmpegCommand.Source }
}
if ([string]::IsNullOrWhiteSpace($ffmpegPath)) {
    Write-DeepResult -Level "WARN" -Message "FFmpeg was not found in the configured path or PATH; streaming cannot start until it is available."
} else {
    Write-DeepResult -Level "PASS" -Message "FFmpeg executable: $ffmpegPath"
    try {
        $encoderText = (& $ffmpegPath -hide_banner -encoders 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
        $hasMjpeg = $encoderText -match '(?im)^\s*V\S*\s+mjpeg\s'
        $hasX264 = $encoderText -match '(?im)^\s*V\S*\s+libx264\s'
        if ($hasMjpeg) {
            Write-DeepResult -Level "PASS" -Message "FFmpeg MJPEG encoder is available."
        } else {
            Write-DeepResult -Level "WARN" -Message "Current FFmpeg does not report the MJPEG encoder; MJPEG mode will not start."
        }
        if ($hasX264) {
            Write-DeepResult -Level "PASS" -Message "FFmpeg libx264 encoder is available for HLS."
        } else {
            Write-DeepResult -Level "WARN" -Message "Current FFmpeg does not report libx264; HLS mode will not start."
        }

        if ($hasMjpeg) {
            try {
                Test-FfmpegMjpegRuntime -FfmpegPath $ffmpegPath
                Write-DeepResult -Level "PASS" -Message "FFmpeg MJPEG HTTP runtime test passed, including multipart Content-Type."
            } catch {
                Write-DeepResult -Level "WARN" -Message "FFmpeg MJPEG runtime smoke test failed: $($_.Exception.Message)"
            }
        }

        if ($hasX264) {
            $ffmpegSmokeRoot = Join-Path ([IO.Path]::GetTempPath()) ("VirtualCamPro-ffmpeg-hls-" + [Guid]::NewGuid().ToString("N"))
            [IO.Directory]::CreateDirectory($ffmpegSmokeRoot) | Out-Null
            try {
                $smokePlaylist = Join-Path $ffmpegSmokeRoot "live.m3u8"
                $smokeSegmentPattern = Join-Path $ffmpegSmokeRoot "segment_%06d.ts"
                $smokeOutput = (& $ffmpegPath -hide_banner -loglevel error -f lavfi -i "testsrc2=size=320x240:rate=30" `
                    -t 2 -an -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p `
                    -g 8 -keyint_min 8 -sc_threshold 0 -force_key_frames "expr:gte(t,n_forced*0.25)" `
                    -f hls -hls_time 0.25 -hls_list_size 6 -hls_flags independent_segments+program_date_time+temp_file `
                    -hls_segment_filename $smokeSegmentPattern $smokePlaylist 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
                $ffmpegSmokeExit = $LASTEXITCODE
                $segmentCount = @(Get-ChildItem -LiteralPath $ffmpegSmokeRoot -Filter "segment_*.ts" -File -ErrorAction SilentlyContinue).Count
                if ($ffmpegSmokeExit -eq 0 -and (Test-Path -LiteralPath $smokePlaylist -PathType Leaf) -and $segmentCount -gt 0) {
                    $smokeText = [IO.File]::ReadAllText($smokePlaylist)
                    if ($smokeText -like "*#EXTM3U*" -and $smokeText -like "*segment_*" -and
                        $smokeText -like "*#EXT-X-INDEPENDENT-SEGMENTS*" -and
                        $smokeText -like "*#EXT-X-PROGRAM-DATE-TIME:*") {
                        Write-DeepResult -Level "PASS" -Message "FFmpeg generated H.264 HLS with independent segments and program date/time."
                    } else {
                        Write-DeepResult -Level "WARN" -Message "FFmpeg HLS smoke output was generated but the playlist content was unexpected."
                    }
                } else {
                    $detail = if ([string]::IsNullOrWhiteSpace($smokeOutput)) { "no FFmpeg diagnostic output" } else { $smokeOutput }
                    Write-DeepResult -Level "WARN" -Message "FFmpeg HLS generation smoke test failed (exit $ffmpegSmokeExit): $detail"
                }
            } finally {
                Remove-Item -LiteralPath $ffmpegSmokeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-DeepResult -Level "WARN" -Message "Could not query/test FFmpeg encoders: $($_.Exception.Message)"
    }
}

$obsFound = ""
if ($configForEnvironment -and -not [string]::IsNullOrWhiteSpace([string]$configForEnvironment["VCAM_OBS_PATH"])) {
    $configuredObs = [Environment]::ExpandEnvironmentVariables(([string]$configForEnvironment["VCAM_OBS_PATH"]).Trim().Trim('"'))
    if (Test-Path -LiteralPath $configuredObs -PathType Leaf) { $obsFound = (Resolve-Path -LiteralPath $configuredObs).Path }
}
if ([string]::IsNullOrWhiteSpace($obsFound)) {
    $obsCommand = Get-Command obs64.exe -ErrorAction SilentlyContinue
    if (-not $obsCommand) {
        $obsCandidates = New-Object Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            $obsCandidates.Add((Join-Path $env:ProgramFiles "obs-studio\bin\64bit\obs64.exe"))
        }
        if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
            $obsCandidates.Add((Join-Path ${env:ProgramFiles(x86)} "obs-studio\bin\64bit\obs64.exe"))
        }
        if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $obsCandidates.Add((Join-Path $env:LOCALAPPDATA "Programs\obs-studio\bin\64bit\obs64.exe"))
        }
        $obsFound = $obsCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    } else { $obsFound = $obsCommand.Source }
}
if ($obsFound) { Write-DeepResult -Level "PASS" -Message "OBS executable: $obsFound" }
else { Write-DeepResult -Level "WARN" -Message "OBS Studio was not found in the configured path, standard locations or PATH." }

$ffprobePath = ""
if (-not [string]::IsNullOrWhiteSpace($ffmpegPath)) {
    $ffprobeCandidate = Join-Path (Split-Path -Parent $ffmpegPath) "ffprobe.exe"
    if (Test-Path -LiteralPath $ffprobeCandidate -PathType Leaf) { $ffprobePath = $ffprobeCandidate }
}
if ([string]::IsNullOrWhiteSpace($ffprobePath)) {
    $ffprobeCommand = Get-Command ffprobe.exe -ErrorAction SilentlyContinue
    if ($ffprobeCommand) { $ffprobePath = $ffprobeCommand.Source }
}
if ($ffprobePath) { Write-DeepResult -Level "PASS" -Message "FFprobe executable: $ffprobePath" }
else { Write-DeepResult -Level "WARN" -Message "FFprobe was not found; local-file source validation will be unavailable." }

foreach ($toolName in @("ssh.exe", "scp.exe")) {
    $tool = Get-Command $toolName -ErrorAction SilentlyContinue
    if ($tool) { Write-DeepResult -Level "PASS" -Message "$toolName is available." }
    else { Write-DeepResult -Level "WARN" -Message "$toolName is not available; phone deployment requires Windows OpenSSH Client." }
}

Write-Host ""
Write-Host ("Deep self-test summary: {0} passed, {1} warning(s), {2} failure(s)." -f
    $script:PassCount, $script:WarningCount, $script:FailureCount) -ForegroundColor $(if ($script:FailureCount -gt 0) { "Red" } elseif ($script:WarningCount -gt 0) { "Yellow" } else { "Green" })
if ($script:FailureCount -gt 0) { exit 70 }
exit 0
