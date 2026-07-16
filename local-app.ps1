param(
    [string]$RelayServerIp = "192.168.1.8",
    [int]$RelayServerPort = 7000
)

$commonPath = Join-Path $PSScriptRoot "SoundTouch-Common.ps1"
. $commonPath

$pairingCodePath = Join-Path $PSScriptRoot "pairing-code.txt"

function Get-OrCreatePairingCode {
    param([string]$Path)
    if (Test-Path $Path) {
        return (Get-Content $Path -Raw).Trim()
    }
    $chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    $bytes = New-Object byte[] 8
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $code = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    Set-Content -Path $Path -Value $code -NoNewline
    return $code
}

$pairingCode = Get-OrCreatePairingCode $pairingCodePath
Write-Output "=========================================="
Write-Output " Pairing code: $pairingCode"
Write-Output "=========================================="

Write-Output "Discovering SoundTouch speaker on this network..."
$SpeakerIp = Find-SoundTouchSpeaker
while (-not $SpeakerIp) {
    Write-Output "No SoundTouch speaker found. Retrying in 10s..."
    Start-Sleep -Seconds 10
    $SpeakerIp = Find-SoundTouchSpeaker
}
Write-Output "Found speaker at $SpeakerIp"

$SpeakerName = "Bose SoundTouch"
try {
    [xml]$infoXml = Get-SoundTouchEndpoint $SpeakerIp "/info"
    if ($infoXml.info.name) { $SpeakerName = $infoXml.info.name }
} catch {}
Write-Output "Speaker name: $SpeakerName"

# --- Background runspace: physical preset-button listener (same logic as preset-listener.ps1) ---
$presetListenerScript = {
    param($SpeakerIp, $CommonPath)
    . $CommonPath

    function Connect-SpeakerNotifyWs {
        param($SpeakerIp)
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ws.Options.AddSubProtocol("gabbo")
        $ct = [System.Threading.CancellationToken]::None
        $ws.ConnectAsync([Uri]"ws://${SpeakerIp}:8080/", $ct).GetAwaiter().GetResult() | Out-Null
        return $ws
    }

    $buffer = New-Object byte[] 16384
    while ($true) {
        try {
            $ws = Connect-SpeakerNotifyWs $SpeakerIp
            Write-Output "[preset-listener] Connected to speaker notification WebSocket."
            while ($ws.State -eq 'Open') {
                $ct = [System.Threading.CancellationToken]::None
                $result = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buffer), $ct).GetAwaiter().GetResult()
                if ($result.Count -eq 0) { continue }
                $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
                if ($text -match "nowSelectionUpdated") {
                    try {
                        [xml]$xml = $text
                        $preset = $xml.updates.nowSelectionUpdated.preset
                        $location = $preset.ContentItem.location
                        if ($location -and $location -ne "") {
                            Write-Output "[preset-listener] Preset $($preset.id) pressed -> replaying: $location"
                            Start-StationPlayback $SpeakerIp $location
                        }
                    } catch {
                        Write-Output "[preset-listener] Parse error: $($_.Exception.Message)"
                    }
                }
            }
        } catch {
            Write-Output "[preset-listener] Error: $($_.Exception.Message). Reconnecting in 5s..."
        }
        Start-Sleep -Seconds 5
    }
}

$presetRunspace = [runspacefactory]::CreateRunspace()
$presetRunspace.Open()
$presetPs = [powershell]::Create()
$presetPs.Runspace = $presetRunspace
[void]$presetPs.AddScript($presetListenerScript).AddArgument($SpeakerIp).AddArgument($commonPath)
$presetOutBuffer = New-Object System.Management.Automation.PSDataCollection[psobject]
[void]$presetPs.BeginInvoke($presetOutBuffer, $presetOutBuffer)

Write-Output "Preset-button listener started in background."

function Invoke-AgentAction {
    param([string]$SpeakerIp, [string]$Action, $Params)
    switch ($Action) {
        "key"            { Send-SoundTouchKey $SpeakerIp $Params.cmd; return $null }
        "volume"         { Set-SoundTouchVolume $SpeakerIp $Params.level; return $null }
        "now_playing"    { return Get-SoundTouchEndpoint $SpeakerIp "/now_playing" }
        "volume_status"  { return Get-SoundTouchEndpoint $SpeakerIp "/volume" }
        "presets_list"   { return Get-SoundTouchEndpoint $SpeakerIp "/presets" }
        "play"           { Start-StationPlayback $SpeakerIp $Params.url; return $null }
        "stop"           { Stop-StationPlayback $SpeakerIp; return $null }
        "save_preset"    { Save-CurrentToPreset $SpeakerIp $Params.num; return $null }
        "preset_play"    {
            $url = Get-PresetUrl $SpeakerIp $Params.num
            if (-not $url) { throw "EMPTY_PRESET" }
            Start-StationPlayback $SpeakerIp $url
            return $null
        }
        "select_source"  { Select-Source $SpeakerIp $Params.source; return $null }
        default          { throw "UNKNOWN_ACTION: $Action" }
    }
}

$buffer = New-Object byte[] 65536
while ($true) {
    try {
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $encodedName = [System.Uri]::EscapeDataString($SpeakerName)
        $uri = "ws://${RelayServerIp}:${RelayServerPort}/agent-ws?code=$pairingCode&speakerIp=$SpeakerIp&speakerName=$encodedName"
        $ct = [System.Threading.CancellationToken]::None
        $ws.ConnectAsync([Uri]$uri, $ct).GetAwaiter().GetResult() | Out-Null
        Write-Output "Connected to relay server at ${RelayServerIp}:${RelayServerPort}"

        while ($ws.State -eq 'Open') {
            $result = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buffer), $ct).GetAwaiter().GetResult()
            if ($result.Count -eq 0) { continue }
            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
            try {
                $msg = $text | ConvertFrom-Json
                try {
                    $res = Invoke-AgentAction $SpeakerIp $msg.action $msg.params
                    $reply = @{ id = $msg.id; ok = $true; result = $res } | ConvertTo-Json -Compress -Depth 5
                } catch {
                    $reply = @{ id = $msg.id; ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                }
                $replyBytes = [System.Text.Encoding]::UTF8.GetBytes($reply)
                $seg = [System.ArraySegment[byte]]::new($replyBytes)
                $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).GetAwaiter().GetResult() | Out-Null
            } catch {
                Write-Output "Bad message from relay: $text ($($_.Exception.Message))"
            }
        }
    } catch {
        Write-Output "Relay connection error: $($_.Exception.Message). Retrying in 5s..."
    }
    Start-Sleep -Seconds 5
}
