Set-StrictMode -Version 2.0

function Get-VcamObsWebSocketConfig {
    $configPath = Join-Path $env:APPDATA "obs-studio\plugin_config\obs-websocket\config.json"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return [pscustomobject]@{
            Configured = $false
            Enabled = $false
            AuthRequired = $false
            Port = 4455
            Password = ""
            Reason = "OBS WebSocket configuration was not found."
            ConfigPath = $configPath
        }
    }
    try {
        $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $port = 4455
        if ($config.PSObject.Properties["server_port"]) {
            $candidatePort = 0
            if ([int]::TryParse([string]$config.server_port, [ref]$candidatePort) -and
                $candidatePort -ge 1 -and $candidatePort -le 65535) {
                $port = $candidatePort
            }
        }
        $enabled = $config.PSObject.Properties["server_enabled"] -and
            [bool]$config.server_enabled
        $authRequired = $config.PSObject.Properties["auth_required"] -and
            [bool]$config.auth_required
        $password = if ($config.PSObject.Properties["server_password"]) {
            [string]$config.server_password
        } else { "" }
        $reason = if ($enabled) { "" } else {
            "OBS WebSocket is disabled. Enable Tools > WebSocket Server Settings > Enable WebSocket server once."
        }
        return [pscustomobject]@{
            Configured = $true
            Enabled = [bool]$enabled
            AuthRequired = [bool]$authRequired
            Port = $port
            Password = $password
            Reason = $reason
            ConfigPath = $configPath
        }
    } catch {
        return [pscustomobject]@{
            Configured = $true
            Enabled = $false
            AuthRequired = $false
            Port = 4455
            Password = ""
            Reason = "OBS WebSocket configuration could not be read: $($_.Exception.Message)"
            ConfigPath = $configPath
        }
    }
}

function ConvertTo-VcamObsWebSocketAuthentication {
    param(
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Salt,
        [Parameter(Mandatory = $true)][string]$Challenge
    )
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $secretBytes = [Text.Encoding]::UTF8.GetBytes($Password + $Salt)
        $secret = [Convert]::ToBase64String($sha.ComputeHash($secretBytes))
        $authenticationBytes = [Text.Encoding]::UTF8.GetBytes($secret + $Challenge)
        return [Convert]::ToBase64String($sha.ComputeHash($authenticationBytes))
    } finally {
        $sha.Dispose()
    }
}

function Send-VcamObsWebSocketMessage {
    param(
        [Parameter(Mandatory = $true)][Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory = $true)][object]$Payload,
        [Parameter(Mandatory = $true)][Threading.CancellationToken]$CancellationToken
    )
    $json = $Payload | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $segment = [ArraySegment[byte]]::new($bytes)
    $Socket.SendAsync(
        $segment,
        [Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        $CancellationToken
    ).GetAwaiter().GetResult()
}

function Receive-VcamObsWebSocketMessage {
    param(
        [Parameter(Mandatory = $true)][Net.WebSockets.ClientWebSocket]$Socket,
        [Parameter(Mandatory = $true)][Threading.CancellationToken]$CancellationToken
    )
    $buffer = New-Object byte[] 8192
    $segment = [ArraySegment[byte]]::new($buffer)
    $stream = New-Object IO.MemoryStream
    try {
        do {
            $result = $Socket.ReceiveAsync($segment, $CancellationToken).GetAwaiter().GetResult()
            if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                throw "OBS closed the WebSocket connection before completing the request."
            }
            if ($result.Count -gt 0) {
                $stream.Write($buffer, 0, $result.Count)
            }
            if ($stream.Length -gt 1024 * 1024) {
                throw "OBS WebSocket response exceeded the 1 MiB safety limit."
            }
        } while (-not $result.EndOfMessage)
        $json = [Text.Encoding]::UTF8.GetString($stream.ToArray())
        return ($json | ConvertFrom-Json)
    } finally {
        $stream.Dispose()
    }
}

function Invoke-VcamObsWebSocketRequests {
    param(
        [Parameter(Mandatory = $true)][string[]]$RequestTypes,
        [int]$TimeoutSeconds = 5
    )
    $config = Get-VcamObsWebSocketConfig
    if (-not $config.Enabled) {
        return [pscustomobject]@{
            Available = $false
            Success = $false
            Reason = $config.Reason
            Responses = @{}
        }
    }
    if ($config.AuthRequired -and [string]::IsNullOrEmpty($config.Password)) {
        return [pscustomobject]@{
            Available = $false
            Success = $false
            Reason = "OBS WebSocket authentication is enabled but its configured password is empty."
            Responses = @{}
        }
    }

    $socket = New-Object Net.WebSockets.ClientWebSocket
    $cancellation = New-Object Threading.CancellationTokenSource
    $cancellation.CancelAfter([Math]::Max(1, $TimeoutSeconds) * 1000)
    $responses = @{}
    try {
        $socket.Options.AddSubProtocol("obswebsocket.json")
        $uri = [Uri]("ws://127.0.0.1:{0}" -f $config.Port)
        $socket.ConnectAsync($uri, $cancellation.Token).GetAwaiter().GetResult()

        $hello = Receive-VcamObsWebSocketMessage -Socket $socket `
            -CancellationToken $cancellation.Token
        if (-not $hello.PSObject.Properties["op"] -or [int]$hello.op -ne 0 -or
            -not $hello.PSObject.Properties["d"]) {
            throw "OBS WebSocket did not send a valid Hello message."
        }
        $rpcVersion = if ($hello.d.PSObject.Properties["rpcVersion"]) {
            [int]$hello.d.rpcVersion
        } else { 1 }
        $identifyData = [ordered]@{
            rpcVersion = [Math]::Min(1, $rpcVersion)
            eventSubscriptions = 0
        }
        $authenticationProperty = $hello.d.PSObject.Properties["authentication"]
        if ($authenticationProperty) {
            $authentication = $authenticationProperty.Value
            if (-not $authentication.PSObject.Properties["salt"] -or
                -not $authentication.PSObject.Properties["challenge"]) {
                throw "OBS WebSocket sent an incomplete authentication challenge."
            }
            $identifyData.authentication = ConvertTo-VcamObsWebSocketAuthentication `
                -Password $config.Password `
                -Salt ([string]$authentication.salt) `
                -Challenge ([string]$authentication.challenge)
        }
        Send-VcamObsWebSocketMessage -Socket $socket `
            -Payload ([ordered]@{ op = 1; d = $identifyData }) `
            -CancellationToken $cancellation.Token
        $identified = Receive-VcamObsWebSocketMessage -Socket $socket `
            -CancellationToken $cancellation.Token
        if (-not $identified.PSObject.Properties["op"] -or [int]$identified.op -ne 2) {
            throw "OBS WebSocket authentication or identification failed."
        }

        foreach ($requestType in $RequestTypes) {
            $requestId = [Guid]::NewGuid().ToString("N")
            Send-VcamObsWebSocketMessage -Socket $socket `
                -Payload ([ordered]@{
                    op = 6
                    d = [ordered]@{
                        requestType = $requestType
                        requestId = $requestId
                    }
                }) `
                -CancellationToken $cancellation.Token
            do {
                $response = Receive-VcamObsWebSocketMessage -Socket $socket `
                    -CancellationToken $cancellation.Token
            } while ([int]$response.op -ne 7 -or
                [string]$response.d.requestId -ne $requestId)
            $status = $response.d.requestStatus
            if (-not $status -or -not [bool]$status.result) {
                $comment = if ($status -and $status.PSObject.Properties["comment"]) {
                    [string]$status.comment
                } else { "OBS rejected the request." }
                return [pscustomobject]@{
                    Available = $true
                    Success = $false
                    Reason = "${requestType}: $comment"
                    Responses = $responses
                }
            }
            $responses[$requestType] = $response.d
        }
        return [pscustomobject]@{
            Available = $true
            Success = $true
            Reason = ""
            Responses = $responses
        }
    } catch {
        return [pscustomobject]@{
            Available = $true
            Success = $false
            Reason = "OBS WebSocket control failed: $($_.Exception.Message)"
            Responses = $responses
        }
    } finally {
        $cancellation.Dispose()
        $socket.Dispose()
    }
}

function Invoke-VcamObsVirtualCameraControl {
    param(
        [switch]$Restart,
        [int]$TimeoutSeconds = 5
    )
    $statusResult = Invoke-VcamObsWebSocketRequests `
        -RequestTypes @("GetVirtualCamStatus") -TimeoutSeconds $TimeoutSeconds
    if (-not $statusResult.Success) { return $statusResult }

    $statusResponse = $statusResult.Responses["GetVirtualCamStatus"]
    $responseDataProperty = $statusResponse.PSObject.Properties["responseData"]
    $outputActive = $responseDataProperty -and
        $responseDataProperty.Value.PSObject.Properties["outputActive"] -and
        [bool]$responseDataProperty.Value.outputActive
    $requests = New-Object Collections.Generic.List[string]
    if ($Restart -and $outputActive) { $requests.Add("StopVirtualCam") }
    if ($Restart -or -not $outputActive) { $requests.Add("StartVirtualCam") }
    if ($requests.Count -eq 0) {
        return [pscustomobject]@{
            Available = $true
            Success = $true
            Reason = ""
            Responses = $statusResult.Responses
        }
    }
    return (Invoke-VcamObsWebSocketRequests -RequestTypes $requests.ToArray() `
        -TimeoutSeconds $TimeoutSeconds)
}

function Test-VcamObsWebSocketAuthentication {
    $actual = ConvertTo-VcamObsWebSocketAuthentication `
        -Password "password" -Salt "salt" -Challenge "challenge"
    return $actual -eq "zTM5ki6L2vVvBQiTG9ckH1Lh64AbnCf6XZ226UmnkIA="
}
