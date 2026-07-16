param(
    [int]$ListenPort = 5001
)

$ytDlpPath = Join-Path $PSScriptRoot "yt-dlp.exe"
$ffmpegPath = Join-Path $PSScriptRoot "ffmpeg.exe"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$ListenPort/")
$listener.Start()
Write-Output "Stream proxy listening on http://+:$ListenPort/ (LAN-wide, concurrent, live MP3 transcode)"

$runspacePool = [runspacefactory]::CreateRunspacePool(1, 8)
$runspacePool.Open()
$pending = New-Object System.Collections.Generic.List[object]

$handlerScript = {
    param($context, $ytDlpPath, $ffmpegPath)

    function Resolve-YouTubeUrl {
        param([string]$VideoId)
        return (& $ytDlpPath -f "18/best" --extractor-args "youtube:player_client=android" -g "https://www.youtube.com/watch?v=$VideoId" --no-warnings 2>$null | Select-Object -First 1)
    }

    function Resolve-PlaylistUrl {
        param([string]$Url)
        try {
            $playlistResp = Invoke-WebRequest -Uri $Url -TimeoutSec 10 -UseBasicParsing
            $rawContent = $playlistResp.Content
            if ($rawContent -is [byte[]]) {
                $text = [System.Text.Encoding]::UTF8.GetString($rawContent)
            } else {
                $text = [string]$rawContent
            }
            $lines = $text -split "`r?`n"
            foreach ($line in $lines) {
                if ($line -match "^File\d*=(http.+)$") { return $matches[1].Trim() }
                if ($line -match "^\s*(https?://\S+)") { return $matches[1].Trim() }
            }
            return $null
        } catch { return $null }
    }

    function Resolve-TuneInUrl {
        param([string]$StationId)
        try {
            $resp = Invoke-WebRequest -Uri "http://opml.radiotime.com/Tune.ashx?id=$StationId&render=json" -TimeoutSec 10 -UseBasicParsing
            $data = $resp.Content | ConvertFrom-Json
            $url = $data.body[0].url
            if ($null -eq $url -or $url -eq "") { return $null }
            if ($url -match "\.(m3u|pls)(\?|$)") {
                return Resolve-PlaylistUrl $url
            }
            return $url
        } catch { return $null }
    }

    function Send-TranscodedStream {
        param($Response, [string]$SourceUrl, [string]$HttpMethod)
        if ($null -eq $SourceUrl -or $SourceUrl -eq "") {
            $Response.StatusCode = 404
            return
        }
        $Response.ContentType = "audio/mpeg"
        $Response.SendChunked = $true

        if ($HttpMethod -ne "HEAD") {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $ffmpegPath
            $psi.Arguments = "-loglevel error -i `"$SourceUrl`" -vn -acodec libmp3lame -b:a 192k -f mp3 pipe:1"
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            $proc.StandardOutput.BaseStream.CopyTo($Response.OutputStream)
            $proc.WaitForExit(3000) | Out-Null
            if (-not $proc.HasExited) { $proc.Kill() }
        }
    }

    $request = $context.Request
    $response = $context.Response
    try {
        $path = $request.Url.AbsolutePath
        Write-Output "[$($request.HttpMethod)] $path"
        if ($path -like "/stream/*") {
            $videoId = $path.Substring("/stream/".Length) -replace "\.\w+$", ""
            $realUrl = Resolve-YouTubeUrl $videoId
            Send-TranscodedStream $response $realUrl $request.HttpMethod
        }
        elseif ($path -like "/radio/*") {
            $stationId = $path.Substring("/radio/".Length) -replace "\.\w+$", ""
            $realUrl = Resolve-TuneInUrl $stationId
            Send-TranscodedStream $response $realUrl $request.HttpMethod
        }
        else {
            $response.StatusCode = 404
        }
    } catch {
        try { $response.StatusCode = 500 } catch {}
    } finally {
        try { $response.OutputStream.Close() } catch {}
    }
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $ps = [powershell]::Create()
    $ps.RunspacePool = $runspacePool
    [void]$ps.AddScript($handlerScript).AddArgument($context).AddArgument($ytDlpPath).AddArgument($ffmpegPath)
    $outBuffer = New-Object System.Management.Automation.PSDataCollection[psobject]
    $handle = $ps.BeginInvoke($outBuffer, $outBuffer)
    $pending.Add([PSCustomObject]@{ PS = $ps; Handle = $handle; Out = $outBuffer })

    for ($i = $pending.Count - 1; $i -ge 0; $i--) {
        if ($pending[$i].Handle.IsCompleted) {
            foreach ($line in $pending[$i].Out) { Write-Output $line }
            try { $pending[$i].PS.EndInvoke($pending[$i].Handle) } catch {}
            $pending[$i].PS.Dispose()
            $pending.RemoveAt($i)
        }
    }
}
