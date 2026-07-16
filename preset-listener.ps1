param(
    [string]$SpeakerIp = "192.168.1.4"
)

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
    Write-Host "Connected to speaker notification WebSocket."
    return $ws
}

$buffer = New-Object byte[] 16384

while ($true) {
    try {
        $ws = Connect-Listener
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
                        Write-Output "Preset $presetId pressed -> replaying: $location"
                        Start-StationPlayback $location
                    }
                } catch {
                    Write-Output "Parse error: $($_.Exception.Message)"
                }
            }
        }
        Write-Output "WebSocket closed. Reconnecting in 5s..."
    } catch {
        Write-Output "Listener error: $($_.Exception.Message). Retrying in 5s..."
    }
    Start-Sleep -Seconds 5
}
