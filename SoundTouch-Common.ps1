# Shared SoundTouch control functions, dot-sourced by local-app.ps1 (and any
# other process that needs to talk directly to a speaker's local API).
# Every function takes $SpeakerIp explicitly rather than relying on a script-scope
# variable, since this file is shared across processes/runspaces with no common scope.

function Invoke-SoapAction {
    param([string]$SpeakerIp, [string]$Action, [string]$Body)
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
    param([string]$SpeakerIp, [string]$StreamUrl)
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
    Invoke-SoapAction $SpeakerIp "SetAVTransportURI" $setUriBody

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
    Invoke-SoapAction $SpeakerIp "Play" $playBody
}

function Stop-StationPlayback {
    param([string]$SpeakerIp)
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
    Invoke-SoapAction $SpeakerIp "Stop" $stopBody
}

function Send-SoundTouchKey {
    param([string]$SpeakerIp, [string]$Key)
    foreach ($state in @("press", "release")) {
        $body = "<key state=`"$state`" sender=`"Gabbo`">$Key</key>"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $req = [System.Net.WebRequest]::Create("http://${SpeakerIp}:8090/key")
        $req.Method = "POST"
        $req.ContentType = "text/xml"
        $req.ContentLength = $bytes.Length
        $req.Timeout = 5000
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        $resp = $req.GetResponse()
        $resp.Close()
    }
}

function Set-SoundTouchVolume {
    param([string]$SpeakerIp, [string]$Level)
    $body = "<volume>$Level</volume>"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $req = [System.Net.WebRequest]::Create("http://${SpeakerIp}:8090/volume")
    $req.Method = "POST"
    $req.ContentType = "text/xml"
    $req.ContentLength = $bytes.Length
    $req.Timeout = 5000
    $stream = $req.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    $resp = $req.GetResponse()
    $resp.Close()
}

function Get-SoundTouchEndpoint {
    param([string]$SpeakerIp, [string]$Path)
    $req = [System.Net.WebRequest]::Create("http://${SpeakerIp}:8090$Path")
    $req.Method = "GET"
    $req.Timeout = 5000
    $resp = $req.GetResponse()
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $content = $reader.ReadToEnd()
    $reader.Close()
    $resp.Close()
    return $content
}

function Save-CurrentToPreset {
    param([string]$SpeakerIp, [string]$PresetNum)
    $key = "PRESET_$PresetNum"
    $pressBody = "<key state=`"press`" sender=`"Gabbo`">$key</key>"
    $releaseBody = "<key state=`"release`" sender=`"Gabbo`">$key</key>"

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pressBody)
    $req = [System.Net.WebRequest]::Create("http://${SpeakerIp}:8090/key")
    $req.Method = "POST"; $req.ContentType = "text/xml"; $req.ContentLength = $bytes.Length; $req.Timeout = 5000
    $stream = $req.GetRequestStream(); $stream.Write($bytes, 0, $bytes.Length); $stream.Close()
    $resp = $req.GetResponse(); $resp.Close()

    Start-Sleep -Seconds 3

    $bytes2 = [System.Text.Encoding]::UTF8.GetBytes($releaseBody)
    $req2 = [System.Net.WebRequest]::Create("http://${SpeakerIp}:8090/key")
    $req2.Method = "POST"; $req2.ContentType = "text/xml"; $req2.ContentLength = $bytes2.Length; $req2.Timeout = 5000
    $stream2 = $req2.GetRequestStream(); $stream2.Write($bytes2, 0, $bytes2.Length); $stream2.Close()
    $resp2 = $req2.GetResponse(); $resp2.Close()
}

function Select-Source {
    param([string]$SpeakerIp, [string]$Source)
    if ($Source -eq "BLUETOOTH") {
        $body = '<ContentItem source="BLUETOOTH" sourceAccount="" isPresetable="false"><itemName>Bluetooth</itemName></ContentItem>'
    } else {
        $body = '<ContentItem source="AUX" sourceAccount="AUX" isPresetable="false"><itemName>AUX IN</itemName></ContentItem>'
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $req = [System.Net.WebRequest]::Create("http://${SpeakerIp}:8090/select")
    $req.Method = "POST"
    $req.ContentType = "text/xml"
    $req.ContentLength = $bytes.Length
    $req.Timeout = 5000
    $stream = $req.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    $resp = $req.GetResponse()
    $resp.Close()
}

function Get-PresetUrl {
    param([string]$SpeakerIp, [string]$Num)
    [xml]$presetsXml = Get-SoundTouchEndpoint $SpeakerIp "/presets"
    $preset = $presetsXml.presets.preset | Where-Object { $_.id -eq $Num }
    if ($null -eq $preset) { return $null }
    return $preset.ContentItem.location
}

function Find-SoundTouchSpeaker {
    param([int]$Port = 8090, [int]$TimeoutMs = 400)

    $config = Get-NetIPConfiguration | Where-Object {
        $_.IPv4Address -and $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway
    } | Select-Object -First 1

    if (-not $config) { return $null }

    $prefixLength = $config.IPv4Address.PrefixLength
    $ipBytes = [System.Net.IPAddress]::Parse($config.IPv4Address.IPAddress).GetAddressBytes()
    [Array]::Reverse($ipBytes)
    $ipInt = [BitConverter]::ToUInt32($ipBytes, 0)

    $maskInt = if ($prefixLength -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $prefixLength)) }
    $networkInt = $ipInt -band $maskInt
    $hostCount = [Math]::Min(([Math]::Pow(2, (32 - $prefixLength)) - 2), 1022)

    function ConvertTo-IpString {
        param([uint32]$Value)
        $bytes = [BitConverter]::GetBytes($Value)
        [Array]::Reverse($bytes)
        return ([System.Net.IPAddress]$bytes).ToString()
    }

    $clients = New-Object System.Collections.Generic.List[object]
    for ($i = 1; $i -le $hostCount; $i++) {
        $candidateIp = ConvertTo-IpString ($networkInt + [uint32]$i)
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $client.BeginConnect($candidateIp, $Port, $null, $null)
            $clients.Add([PSCustomObject]@{ IP = $candidateIp; Client = $client; Result = $ar })
        } catch {}
    }

    Start-Sleep -Milliseconds $TimeoutMs

    $candidates = @()
    foreach ($c in $clients) {
        if ($c.Result.IsCompleted -and $c.Client.Connected) { $candidates += $c.IP }
        $c.Client.Close()
    }

    foreach ($ip in $candidates) {
        try {
            $info = Invoke-WebRequest -Uri "http://${ip}:8090/info" -TimeoutSec 3 -UseBasicParsing
            if ($info.Content -match '<info deviceID=') {
                return $ip
            }
        } catch {}
    }
    return $null
}
