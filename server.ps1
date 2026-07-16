param(
    [string]$SpeakerIp = "192.168.1.4",
    [string]$AppIp = "192.168.1.8",
    [int]$ListenPort = 5000
)

$htmlPath = Join-Path $PSScriptRoot "index.html"
$ytDlpPath = Join-Path $PSScriptRoot "yt-dlp.exe"
$panelImgPath = Join-Path $PSScriptRoot "panel.png"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$ListenPort/")
$listener.Start()
Write-Output "Listening on http://localhost:$ListenPort/ (speaker: $SpeakerIp)"

function Send-SoundTouchKey {
    param([string]$Key)
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
    param([string]$Level)
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
    param([string]$Path)
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

function Stop-StationPlayback {
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
}

function Save-CurrentToPreset {
    param([string]$PresetNum)
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
    param([string]$Source)
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
    param([string]$Num)
    [xml]$presetsXml = Get-SoundTouchEndpoint "/presets"
    $preset = $presetsXml.presets.preset | Where-Object { $_.id -eq $Num }
    if ($null -eq $preset) { return $null }
    return $preset.ContentItem.location
}

function Search-YouTube {
    param([string]$Query, [int]$Count = 8)
    $raw = & $ytDlpPath "ytsearch${Count}:$Query" --flat-playlist --print "%(title)s|||%(id)s" --no-warnings 2>$null
    $results = @()
    foreach ($line in $raw) {
        if ($line -match "^(.*)\|\|\|(.+)$") {
            $results += [PSCustomObject]@{ title = $matches[1]; id = $matches[2] }
        }
    }
    return $results
}

function Search-TuneIn {
    param([string]$Query)
    $url = "http://opml.radiotime.com/Search.ashx?query=" + [System.Uri]::EscapeDataString($Query) + "&render=json"
    $resp = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing
    $data = $resp.Content | ConvertFrom-Json
    $results = @()
    foreach ($item in $data.body) {
        if ($item.type -eq "audio" -and $item.item -eq "station") {
            $results += [PSCustomObject]@{
                name  = $item.text
                id    = $item.guide_id
                image = $item.image
            }
        }
    }
    return $results
}

function ConvertTo-JsonSafe {
    param($Data)
    return ($Data | ConvertTo-Json -Compress)
}

function Write-TextResponse {
    param($Response, [string]$Text, [string]$ContentType = "text/plain")
    $buf = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Response.ContentType = "$ContentType; charset=utf-8"
    $Response.ContentLength64 = $buf.Length
    $Response.OutputStream.Write($buf, 0, $buf.Length)
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    try {
        $path = $request.Url.AbsolutePath
        if ($path -eq "/") {
            $html = [System.IO.File]::ReadAllText($htmlPath, [System.Text.Encoding]::UTF8)
            Write-TextResponse $response $html "text/html"
        }
        elseif ($path -eq "/panel.png") {
            $bytes = [System.IO.File]::ReadAllBytes($panelImgPath)
            $response.ContentType = "image/png"
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        elseif ($path -eq "/api/key") {
            $cmd = $request.QueryString["cmd"]
            Send-SoundTouchKey $cmd
            Write-TextResponse $response "OK"
        }
        elseif ($path -eq "/api/volume") {
            $level = $request.QueryString["level"]
            Set-SoundTouchVolume $level
            Write-TextResponse $response "OK"
        }
        elseif ($path -eq "/api/now_playing") {
            $xml = Get-SoundTouchEndpoint "/now_playing"
            Write-TextResponse $response $xml "text/xml"
        }
        elseif ($path -eq "/api/volume_status") {
            $xml = Get-SoundTouchEndpoint "/volume"
            Write-TextResponse $response $xml "text/xml"
        }
        elseif ($path -eq "/api/play") {
            $url = [System.Uri]::UnescapeDataString($request.QueryString["url"])
            Start-StationPlayback $url
            Write-TextResponse $response "OK"
        }
        elseif ($path -eq "/api/stop") {
            Stop-StationPlayback
            Write-TextResponse $response "OK"
        }
        elseif ($path -eq "/api/save_preset") {
            $num = $request.QueryString["num"]
            Save-CurrentToPreset $num
            Write-TextResponse $response "OK"
        }
        elseif ($path -eq "/api/preset_play") {
            $num = $request.QueryString["num"]
            $url = Get-PresetUrl $num
            if ($null -eq $url -or $url -eq "") {
                $response.StatusCode = 404
                Write-TextResponse $response "Walang laman ang preset na ito"
            } else {
                Start-StationPlayback $url
                Write-TextResponse $response "OK"
            }
        }
        elseif ($path -eq "/api/select_source") {
            $src = $request.QueryString["source"]
            Select-Source $src
            Write-TextResponse $response "OK"
        }
        elseif ($path -eq "/api/presets_list") {
            $xml = Get-SoundTouchEndpoint "/presets"
            Write-TextResponse $response $xml "text/xml"
        }
        elseif ($path -eq "/api/yt_search") {
            $q = [System.Uri]::UnescapeDataString($request.QueryString["q"])
            $results = Search-YouTube $q
            Write-TextResponse $response (ConvertTo-JsonSafe $results) "application/json"
        }
        elseif ($path -eq "/api/yt_play") {
            $id = $request.QueryString["id"]
            $shortUrl = "http://${AppIp}:5001/stream/$id.mp3"
            Start-StationPlayback $shortUrl
            Write-TextResponse $response "OK"
        }
        elseif ($path -eq "/api/radio_search") {
            $q = [System.Uri]::UnescapeDataString($request.QueryString["q"])
            $results = Search-TuneIn $q
            Write-TextResponse $response (ConvertTo-JsonSafe $results) "application/json"
        }
        elseif ($path -eq "/api/radio_play") {
            $id = $request.QueryString["id"]
            $shortUrl = "http://${AppIp}:5001/radio/$id.mp3"
            Start-StationPlayback $shortUrl
            Write-TextResponse $response "OK"
        }
        else {
            $response.StatusCode = 404
        }
    } catch {
        $response.StatusCode = 500
        Write-TextResponse $response ("ERROR: " + $_.Exception.Message)
    } finally {
        $response.OutputStream.Close()
    }
}
