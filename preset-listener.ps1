param(
    [string]$SpeakerIp = "192.168.1.4"
)

# Remembered once a connection succeeds, so a later re-discovery scan (see
# Find-SpeakerBySubnetScan) knows WHICH device it's looking for, not just
# "any SoundTouch speaker" - matters if there's ever more than one on the LAN.
$script:KnownDeviceId = $null

function Get-SpeakerDeviceId {
    param([string]$Ip, [int]$TimeoutSec = 3)
    try {
        $resp = Invoke-WebRequest -Uri "http://${Ip}:8090/info" -TimeoutSec $TimeoutSec -UseBasicParsing
        [xml]$xml = $resp.Content
        return $xml.info.deviceID
    } catch {
        return $null
    }
}

function Test-PortOpen {
    param([string]$Ip, [int]$Port, [int]$TimeoutMs = 200)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $task = $tcp.ConnectAsync($Ip, $Port)
        $ok = $task.Wait($TimeoutMs) -and $tcp.Connected
        $tcp.Close()
        return $ok
    } catch {
        return $false
    }
}

# Sweeps this machine's own /24 for a SoundTouch device whose deviceID
# matches the one this script last successfully connected to - a pragmatic,
# single-home-network fix for DHCP re-leasing the speaker a new address,
# which otherwise leaves this script permanently stuck retrying a dead IP
# (confirmed via preset-listener.log: repeated "Unable to connect to the
# remote server" after the speaker's IP changed, with no recovery until
# manually restarted with the new address). A fast TCP-connect probe first
# (a couple hundred ms per address) keeps a full 254-address sweep well
# under a minute, only paying the slower HTTP /info GET for addresses that
# actually have port 8090 open.
#
# Returns a PSCustomObject{Ip, Id} rather than a bare IP string, since the
# no-known-DeviceId branch below needs to hand its caller a freshly-learned
# Id too - not just an Ip - or a second stale-IP episode right after this
# one would be back to square one with nothing to compare against.
function Find-SpeakerBySubnetScan {
    param([string]$DeviceId, [string]$CurrentIp)
    $prefix = ($CurrentIp -split '\.')[0..2] -join '.'
    # Write-Host, NOT Write-Output, for every message in this function - the
    # caller does `$found = Find-SpeakerBySubnetScan ...`, and PowerShell
    # captures EVERYTHING a function writes to the success/output stream
    # into that assignment, not just the final `return` value. Write-Output
    # here silently turned $found into a polluted array (log message(s) +
    # the real result object) instead of a clean single value - and, worse,
    # meant every one of this function's own status messages ("scanning...",
    # "Found speaker...", "Scan finished...") got swallowed into $found
    # instead of ever reaching the log file (confirmed: zero of them ever
    # appeared in preset-listener.log despite this function running on
    # every 3rd failure). Write-Host bypasses the success stream entirely,
    # so it's both a real log message again AND leaves $found clean.
    Write-Host "Speaker unreachable for a while - scanning $prefix.0/24 for a SoundTouch speaker..."
    $candidates = @()
    for ($i = 1; $i -le 254; $i++) {
        $candidate = "$prefix.$i"
        if ($candidate -eq $CurrentIp) { continue }
        if (-not (Test-PortOpen -Ip $candidate -Port 8090)) { continue }
        $id = Get-SpeakerDeviceId -Ip $candidate -TimeoutSec 2
        if ($id) { $candidates += [PSCustomObject]@{ Ip = $candidate; Id = $id } }
    }
    if ($DeviceId) {
        $match = $candidates | Where-Object { $_.Id -eq $DeviceId } | Select-Object -First 1
        if ($match) {
            Write-Host "Found speaker at $($match.Ip) (was $CurrentIp)"
            return $match
        }
    }
    # No known DeviceId yet (this process never had a single successful
    # connection to learn one from - e.g. it was started already pointed at
    # a stale IP) - a real, previously-unrecoverable case (confirmed via
    # preset-listener.log: 65 consecutive connection failures, never once
    # connected, because this exact branch used to just bail out with
    # "if (-not $DeviceId) { return $null }"). Exactly one SoundTouch device
    # on the subnet is the practical single-home-network signal that it's
    # the speaker, same reasoning as the rest of this function.
    if ($candidates.Count -eq 1) {
        Write-Host "Found speaker at $($candidates[0].Ip) (was $CurrentIp) - no prior deviceID to confirm against, but it's the only SoundTouch device on the subnet."
        return $candidates[0]
    }
    if ($candidates.Count -gt 1) {
        Write-Host "Scan finished - found $($candidates.Count) SoundTouch devices on $prefix.0/24 but none confirmed match - can't tell which is the right one."
    } else {
        Write-Host "Scan finished - no SoundTouch speaker found on $prefix.0/24."
    }
    return $null
}

function Invoke-SoapAction {
    param([string]$Action, [string]$Body)
    $req = [System.Net.WebRequest]::Create("http://${SpeakerIp}:8091/AVTransport/Control")
    $req.Method = "POST"
    $req.ContentType = 'text/xml; charset="utf-8"'
    $req.Headers.Add("SOAPACTION", "`"urn:schemas-upnp-org:service:AVTransport:1#$Action`"")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $req.ContentLength = $bytes.Length
    $req.Timeout = 8000
    $stream = $req.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    $resp = $req.GetResponse()
    $resp.Close()
}

function Start-StationPlayback {
    param([string]$StreamUrl)
    # Stop first - clears the transport out of whatever it was already doing
    # before handing it a new URI, instead of layering SetAVTransportURI on
    # top of a transition the device (or its own native preset-recall, which
    # starts at the same instant this notification arrives) may still be
    # mid-way through. This is the single most-cited mitigation in UPnP
    # AVTransport implementations for a device silently accepting a command
    # without actually applying it - a real, reproduced symptom against this
    # exact hardware (confirmed via manual SOAP testing, 2026-07-2x: the
    # device returned HTTP 200 for SetAVTransportURI+Play repeatedly without
    # its own /now_playing ever reflecting the change). Best-effort - if Stop
    # itself fails (e.g. nothing was playing yet), proceed anyway.
    try {
        $stopBody = @"
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
    </u:Stop>
  </s:Body>
</s:Envelope>
"@
        Invoke-SoapAction "Stop" $stopBody
    } catch {}

    $escapedUrl = [System.Security.SecurityElement]::Escape($StreamUrl)
    $setUriBody = @"
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <CurrentURI>$escapedUrl</CurrentURI>
      <CurrentURIMetaData></CurrentURIMetaData>
    </u:SetAVTransportURI>
  </s:Body>
</s:Envelope>
"@
    Invoke-SoapAction "SetAVTransportURI" $setUriBody

    $playBody = @"
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <InstanceID>0</InstanceID>
      <Speed>1</Speed>
    </u:Play>
  </s:Body>
</s:Envelope>
"@
    Invoke-SoapAction "Play" $playBody
}

function Connect-Listener {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.AddSubProtocol("gabbo")
    $ct = [System.Threading.CancellationToken]::None
    $ws.ConnectAsync([Uri]"ws://${SpeakerIp}:8080/", $ct).GetAwaiter().GetResult() | Out-Null
    Write-Host "Connected to speaker notification WebSocket ($SpeakerIp)."
    if (-not $script:KnownDeviceId) {
        $script:KnownDeviceId = Get-SpeakerDeviceId -Ip $SpeakerIp
    }
    return $ws
}

$buffer = New-Object byte[] 16384
$consecutiveFailures = 0
# Dedup guard: the SAME (presetId, location) pair processed again within this
# window is skipped rather than re-triggering a redundant SetAVTransportURI
# +Play - protects against duplicate/repeated notification frames for one
# physical press (observed: the speaker's own WebSocket can emit more than
# one nowSelectionUpdated for a single press), not against the underlying
# race with the device's own native recall (that one instance is
# unavoidable client-side - see Start-StationPlayback's Stop-first comment
# for the actual mitigation for that).
$lastPresetKey = $null
$lastPresetAt = [DateTime]::MinValue

while ($true) {
    try {
        $ws = Connect-Listener
        $consecutiveFailures = 0
        while ($ws.State -eq 'Open') {
            $ct = [System.Threading.CancellationToken]::None
            $result = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buffer), $ct).GetAwaiter().GetResult()
            if ($result.Count -eq 0) { continue }
            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)

            if ($text -match "nowSelectionUpdated") {
                try {
                    [xml]$xml = $text
                    $preset = $xml.updates.nowSelectionUpdated.preset
                    $presetId = $preset.id
                    $location = $preset.ContentItem.location
                    if ($location -and $location -ne "") {
                        $key = "$presetId|$location"
                        $now = Get-Date
                        if ($key -eq $lastPresetKey -and ($now - $lastPresetAt).TotalSeconds -lt 3) {
                            Write-Output "Preset $presetId pressed -> duplicate notification within 3s, skipping replay."
                        } else {
                            $lastPresetKey = $key
                            $lastPresetAt = $now
                            Write-Output "Preset $presetId pressed -> replaying: $location"
                            Start-StationPlayback $location
                        }
                    }
                } catch {
                    Write-Output "Parse error: $($_.Exception.Message)"
                }
            }
        }
        Write-Output "WebSocket closed. Reconnecting in 5s..."
    } catch {
        $consecutiveFailures++
        Write-Output "Listener error: $($_.Exception.Message). Retrying in 5s... (failure $consecutiveFailures)"
        # Every 3rd failure, not just the 3rd failure ever - a scan attempt
        # can itself come up empty (e.g. transient LAN hiccup, or no known
        # DeviceId yet and more than one SoundTouch-like device briefly
        # visible), and re-checking "-eq 3" would then never fire again for
        # the rest of the process's life, exactly the permanently-stuck
        # scenario this rescan exists to prevent.
        if ($consecutiveFailures -ge 3 -and ($consecutiveFailures % 3) -eq 0) {
            $found = Find-SpeakerBySubnetScan -DeviceId $script:KnownDeviceId -CurrentIp $SpeakerIp
            # Validating the shape of $found.Ip (not just truthiness) is a
            # deliberate extra guard, not redundant - a live production bug
            # (2026-07-23, confirmed via preset-listener.log: 1000+ repeated
            # cycles of "ws://:8080/" - a blank hostname - crashing every
            # reconnect attempt) traced back to this function's OWN Write-Host
            # calls previously being Write-Output, which PowerShell captures
            # into $found alongside the real return value on `$found = ...`.
            # That's fixed at the source now (see Find-SpeakerBySubnetScan),
            # but this check stays as a second line of defense against
            # $SpeakerIp ever again being assigned something that isn't
            # actually a usable IP string.
            if ($found -and $found.Ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                $SpeakerIp = $found.Ip
                $script:KnownDeviceId = $found.Id
                $consecutiveFailures = 0
            }
        }
    }
    Start-Sleep -Seconds 5
}
