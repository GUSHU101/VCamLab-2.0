[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [string]$BindAddress = "0.0.0.0",
    [int]$Port = 8888,
    [string]$PlaylistName = "live.m3u8"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Write-HttpResponseHeader {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )
    $builder = New-Object Text.StringBuilder
    [void]$builder.AppendFormat("HTTP/1.1 {0} {1}`r`n", $StatusCode, $Reason)
    foreach ($key in $Headers.Keys) {
        [void]$builder.AppendFormat("{0}: {1}`r`n", $key, $Headers[$key])
    }
    [void]$builder.Append("`r`n")
    $bytes = [Text.Encoding]::ASCII.GetBytes($builder.ToString())
    $Stream.Write($bytes, 0, $bytes.Length)
}

function Send-SimpleResponse {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][string]$Reason,
        [AllowEmptyString()][string]$Body = ""
    )
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($Body)
    Write-HttpResponseHeader -Stream $Stream -StatusCode $StatusCode -Reason $Reason -Headers @{
        "Content-Type" = "text/plain; charset=utf-8"
        "Content-Length" = [string]$bodyBytes.Length
        "Cache-Control" = "no-store"
        "Access-Control-Allow-Origin" = "*"
        "X-Content-Type-Options" = "nosniff"
        "Connection" = "close"
    }
    if ($bodyBytes.Length -gt 0) {
        $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
}

function Get-RequestHeaders {
    param([Parameter(Mandatory = $true)][IO.TextReader]$Reader)
    $headers = @{}
    $lineCount = 0
    $totalCharacters = 0
    while ($true) {
        $line = $Reader.ReadLine()
        if ($null -eq $line -or $line.Length -eq 0) { break }
        $lineCount++
        $totalCharacters += $line.Length
        if ($lineCount -gt 100 -or $totalCharacters -gt 65536 -or $line.Length -gt 8192) {
            throw "HTTP request headers exceed the safety limit."
        }
        $separator = $line.IndexOf(':')
        if ($separator -le 0) { continue }
        $name = $line.Substring(0, $separator).Trim().ToLowerInvariant()
        $value = $line.Substring($separator + 1).Trim()
        if ($name.Length -eq 0 -or $name.Length -gt 256) { continue }
        $headers[$name] = $value
    }
    return $headers
}

$root = [IO.Path]::GetFullPath($RootPath)
[IO.Directory]::CreateDirectory($root) | Out-Null
$rootPrefix = $root.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) +
    [IO.Path]::DirectorySeparatorChar

$bindIP = $null
if (-not [Net.IPAddress]::TryParse($BindAddress, [ref]$bindIP) -or
    $bindIP.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw "BindAddress must be an IPv4 literal."
}
if ($Port -lt 1024 -or $Port -gt 65535) {
    throw "Port must be from 1024 through 65535."
}
if ([string]::IsNullOrWhiteSpace($PlaylistName) -or
    [IO.Path]::GetFileName($PlaylistName) -ne $PlaylistName -or
    $PlaylistName -notmatch '^[A-Za-z0-9._-]+[.]m3u8$') {
    throw "PlaylistName must be a simple .m3u8 file name."
}

$listener = New-Object Net.Sockets.TcpListener -ArgumentList $bindIP, $Port
$listener.Server.NoDelay = $true
$listener.Start(64)

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $null
        $reader = $null
        try {
            $client.NoDelay = $true
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 15000
            $stream = $client.GetStream()
            $reader = New-Object IO.StreamReader -ArgumentList @($stream, [Text.Encoding]::ASCII, $false, 8192, $true)
            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) {
                continue
            }
            if ($requestLine.Length -gt 8192) {
                Send-SimpleResponse -Stream $stream -StatusCode 414 -Reason "URI Too Long" -Body "URI Too Long"
                continue
            }
            $parts = $requestLine.Split(' ')
            if ($parts.Count -lt 2) {
                Send-SimpleResponse -Stream $stream -StatusCode 400 -Reason "Bad Request" -Body "Bad Request"
                continue
            }
            $method = $parts[0].ToUpperInvariant()
            $target = $parts[1]
            if ($target.Length -gt 4096) {
                Send-SimpleResponse -Stream $stream -StatusCode 414 -Reason "URI Too Long" -Body "URI Too Long"
                continue
            }
            $headers = Get-RequestHeaders -Reader $reader

            if ($method -eq "OPTIONS") {
                Write-HttpResponseHeader -Stream $stream -StatusCode 204 -Reason "No Content" -Headers @{
                    "Content-Length" = "0"
                    "Access-Control-Allow-Origin" = "*"
                    "Access-Control-Allow-Methods" = "GET, HEAD, OPTIONS"
                    "Access-Control-Allow-Headers" = "Range"
                    "Connection" = "close"
                }
                continue
            }
            if ($method -notin @("GET", "HEAD")) {
                Send-SimpleResponse -Stream $stream -StatusCode 405 -Reason "Method Not Allowed" -Body "Method Not Allowed"
                continue
            }

            $rawPath = ($target -split '[?]', 2)[0]
            try { $requestPath = [Uri]::UnescapeDataString($rawPath) } catch { $requestPath = "" }
            if ($requestPath -eq "/") { $requestPath = "/$PlaylistName" }
            $relativePath = $requestPath.TrimStart('/')
            $allowed = $relativePath -eq $PlaylistName -or $relativePath -match '^segment_[0-9]{6,12}[.]ts$'
            if (-not $allowed) {
                Send-SimpleResponse -Stream $stream -StatusCode 404 -Reason "Not Found" -Body "Not Found"
                continue
            }

            $fullPath = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
            if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Send-SimpleResponse -Stream $stream -StatusCode 403 -Reason "Forbidden" -Body "Forbidden"
                continue
            }
            if ($relativePath -eq $PlaylistName -and
                -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                # The HTTP listener starts just before FFmpeg. Give the first HLS
                # playlist request a short grace period instead of returning a
                # startup-race 404 that some players treat as fatal.
                for ($attempt = 0; $attempt -lt 20; $attempt++) {
                    Start-Sleep -Milliseconds 100
                    if (Test-Path -LiteralPath $fullPath -PathType Leaf) { break }
                }
            }
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                Send-SimpleResponse -Stream $stream -StatusCode 404 -Reason "Not Found" -Body "Not Found"
                continue
            }

            $share = [IO.FileShare]([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            $file = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
            try {
                $length = [long]$file.Length
                $start = [long]0
                $end = [long]([Math]::Max(0, $length - 1))
                $partial = $false
                if ($headers.ContainsKey("range")) {
                    $match = [regex]::Match([string]$headers["range"], '^bytes=(?<start>[0-9]*)-(?<end>[0-9]*)$')
                    if ($match.Success -and $length -gt 0) {
                        $startText = $match.Groups["start"].Value
                        $endText = $match.Groups["end"].Value
                        if ($startText.Length -eq 0 -and $endText.Length -gt 0) {
                            $suffixLength = [long]$endText
                            if ($suffixLength -gt 0) {
                                $start = [Math]::Max([long]0, $length - $suffixLength)
                                $end = $length - 1
                            }
                            else {
                                $end = -1
                            }
                        }
                        else {
                            if ($startText.Length -gt 0) {
                                $start = [long]$startText
                            }
                            if ($endText.Length -gt 0) {
                                $end = [Math]::Min([long]$endText, $length - 1)
                            }
                        }
                        if ($start -ge 0 -and $start -lt $length -and $end -ge $start) {
                            $partial = $true
                        } else {
                            Write-HttpResponseHeader -Stream $stream -StatusCode 416 -Reason "Range Not Satisfiable" -Headers @{
                                "Content-Range" = "bytes */$length"
                                "Content-Length" = "0"
                                "Connection" = "close"
                            }
                            continue
                        }
                    }
                }
                $count = if ($length -eq 0) { [long]0 } else { [long]($end - $start + 1) }
                $contentType = if ($relativePath.EndsWith(".m3u8", [StringComparison]::OrdinalIgnoreCase)) {
                    "application/vnd.apple.mpegurl"
                } else {
                    "video/mp2t"
                }
                $responseHeaders = @{
                    "Content-Type" = $contentType
                    "Content-Length" = [string]$count
                    "Accept-Ranges" = "bytes"
                    "Access-Control-Allow-Origin" = "*"
                    "Access-Control-Expose-Headers" = "Content-Length, Content-Range, Accept-Ranges"
                    "X-Content-Type-Options" = "nosniff"
                    "Connection" = "close"
                    "Cache-Control" = $(if ($contentType -eq "application/vnd.apple.mpegurl") {
                        "no-cache, no-store, must-revalidate"
                    } else {
                        "public, max-age=30"
                    })
                }
                if ($partial) {
                    $responseHeaders["Content-Range"] = "bytes $start-$end/$length"
                    Write-HttpResponseHeader -Stream $stream -StatusCode 206 -Reason "Partial Content" -Headers $responseHeaders
                } else {
                    Write-HttpResponseHeader -Stream $stream -StatusCode 200 -Reason "OK" -Headers $responseHeaders
                }
                if ($method -eq "HEAD" -or $count -eq 0) { continue }

                $file.Position = $start
                $buffer = New-Object byte[] 65536
                $remaining = $count
                while ($remaining -gt 0) {
                    $toRead = [int][Math]::Min([long]$buffer.Length, $remaining)
                    $read = $file.Read($buffer, 0, $toRead)
                    if ($read -le 0) { break }
                    $stream.Write($buffer, 0, $read)
                    $remaining -= $read
                }
            } finally {
                $file.Dispose()
            }
        } catch {
            try {
                if ($client.Connected) {
                    Send-SimpleResponse -Stream $client.GetStream() -StatusCode 500 -Reason "Internal Server Error" -Body "Internal Server Error"
                }
            } catch {}
        } finally {
            if ($reader) { try { $reader.Dispose() } catch {} }
            if ($stream) { try { $stream.Dispose() } catch {} }
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
}
