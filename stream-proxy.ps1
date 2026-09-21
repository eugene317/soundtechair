param(
    [int]$ListenPort = 5001
)

$ytDlpPath = Join-Path $PSScriptRoot "yt-dlp.exe"
$ffmpegPath = Join-Path $PSScriptRoot "ffmpeg.exe"

# Fully-transcoded output cache (YouTube/SoundCloud only, never radio - see
# Send-TranscodedStream's doc comment for why). Confirmed by direct
# measurement (2026-07-22): a cold ffmpeg start takes 2-3+ seconds to produce
# a first byte, which is fine for the app's own patient play/poll loop but
# too slow for a real SoundTouch's PHYSICAL preset-recall flow - recalling a
# preset saved against a live-transcoded URL blinks white (device gives up)
# even though the exact same URL plays fine when tapped from the app. Presets
# by definition replay the SAME content repeatedly, so caching the finished
# file after the first successful play is what makes a physical recall fast
# enough afterward - not a workaround, the actual fix for that failure mode.
$streamCacheDir = Join-Path $PSScriptRoot "stream-cache"
if (-not (Test-Path $streamCacheDir)) { New-Item -ItemType Directory -Path $streamCacheDir | Out-Null }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$ListenPort/")
$listener.Start()
Write-Output "Stream proxy listening on http://+:$ListenPort/ (LAN-wide, concurrent, live MP3 transcode)"

$runspacePool = [runspacefactory]::CreateRunspacePool(1, 8)
$runspacePool.Open()
$pending = New-Object System.Collections.Generic.List[object]

# Resolved-URL cache, keyed by video id, shared across every request's own
# runspace via .Synchronized() (safe for concurrent reads/writes from
# multiple runspaces at once - a plain hashtable is not). Exists because
# yt-dlp's own resolution (a separate process invocation, several real HTTP
# round trips to YouTube) routinely takes multiple seconds - long enough
# that a SoundTouch speaker recalling a saved preset (which expects audio
# to start flowing almost immediately, unlike the app's own more patient
# retry/refresh loop) times out and gives up before ffmpeg ever gets to
# start. Re-playing/recalling the SAME video within the cache window skips
# yt-dlp entirely and goes straight to ffmpeg.
$urlCache = [hashtable]::Synchronized(@{})

# Same reasoning/shape as $urlCache above, but keyed by SoundCloud
# permalink_url instead of a video id - SoundCloud track resolution also
# goes through yt-dlp (a separate process spawn), so it's just as slow on a
# cache miss as the YouTube path is.
$soundcloudUrlCache = [hashtable]::Synchronized(@{})

# TuneIn's own resolution (a single HTTP call to opml.radiotime.com, plus an
# extra hop if the result is an .m3u/.pls playlist) is much lighter than
# yt-dlp's process-spawn approach, but was previously NOT cached at all -
# every single /radio/* request re-hit opml.radiotime.com from scratch. That
# meant a client-side prefetch (see the Flutter app's _prefetchUrl) would
# have resolved the URL and then thrown it straight away, since nothing
# stored it for the real play request to reuse - caching it the same way
# the other two sources already are is what makes prefetching TuneIn
# actually save time on the real request, not just add an extra API call.
$tuneinUrlCache = [hashtable]::Synchronized(@{})

$handlerScript = {
    param($context, $ytDlpPath, $ffmpegPath, $urlCache, $soundcloudUrlCache, $tuneinUrlCache, $streamCacheDir)

    function Resolve-YouTubeUrl {
        param([string]$VideoId, $UrlCache)
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($UrlCache.ContainsKey($VideoId)) {
            $cached = $UrlCache[$VideoId]
            # YouTube's signed direct-media URLs are themselves time-limited -
            # this window is a conservative margin well under their actual
            # expiry, so a stale/expired URL doesn't get reused and silently fail.
            if (($now - $cached.CachedAt) -lt 10800) {
                return $cached.Url
            }
        }
        $resolved = (& $ytDlpPath -f "18/best" --extractor-args "youtube:player_client=android" -g "https://www.youtube.com/watch?v=$VideoId" --no-warnings 2>$null | Select-Object -First 1)
        if ($resolved) {
            $UrlCache[$VideoId] = [PSCustomObject]@{ Url = $resolved; CachedAt = $now }
        }
        return $resolved
    }

    function Resolve-SoundCloudUrl {
        param([string]$PermalinkUrl, $UrlCache)
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($UrlCache.ContainsKey($PermalinkUrl)) {
            $cached = $UrlCache[$PermalinkUrl]
            if (($now - $cached.CachedAt) -lt 10800) {
                return $cached.Url
            }
        }
        # yt-dlp's scsearch: shortcut is currently broken (malformed URLs from
        # encoded colons), which is why search is done directly against
        # SoundCloud's own API in relay-server.ps1 instead - but resolving a
        # KNOWN track's permalink_url straight to a direct stream still works
        # fine, confirmed separately from the search shortcut's bug.
        $resolved = (& $ytDlpPath -f "best" -g "$PermalinkUrl" --no-warnings 2>$null | Select-Object -First 1)
        if ($resolved) {
            $UrlCache[$PermalinkUrl] = [PSCustomObject]@{ Url = $resolved; CachedAt = $now }
        }
        return $resolved
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
        param([string]$StationId, $UrlCache)
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($UrlCache.ContainsKey($StationId)) {
            $cached = $UrlCache[$StationId]
            if (($now - $cached.CachedAt) -lt 10800) {
                return $cached.Url
            }
        }
        try {
            $resp = Invoke-WebRequest -Uri "http://opml.radiotime.com/Tune.ashx?id=$StationId&render=json" -TimeoutSec 10 -UseBasicParsing
            $data = $resp.Content | ConvertFrom-Json
            $url = $data.body[0].url
            if ($null -eq $url -or $url -eq "") { return $null }
            if ($url -match "\.(m3u|pls)(\?|$)") {
                $url = Resolve-PlaylistUrl $url
            }
            if ($url) {
                $UrlCache[$StationId] = [PSCustomObject]@{ Url = $url; CachedAt = $now }
            }
            return $url
        } catch { return $null }
    }

    # Bose SoundTouch's PHYSICAL preset-recall path refuses/cancels a
    # "Transfer-Encoding: chunked" response outright (confirmed 2026-07-22
    # via direct hardware A/B: the exact same URL, same speaker, same
    # session - chunked -> recall fails into INVALID_SOURCE every time;
    # a declared Content-Length -> recall succeeds every time, including
    # for radio where the true length is infinite/unknown). Real Icecast/
    # Shoutcast servers hit this same problem for live streams and solve it
    # the same way: declare a large-but-finite fake Content-Length instead
    # of chunked, and just close the connection whenever the stream actually
    # ends (early, relative to the declared length) - verified against two
    # live third-party Icecast streams (ice2.somafm.com, stream.radioparadise.com)
    # that this exact pattern recalls reliably on this hardware. This is NOT
    # used for a real cache-hit below, which already has a true exact length.
    $fakeContentLength = [int64]10737418240  # 10 GiB - far beyond any realistic single play/listen session

    function Send-TranscodedStream {
        param($Response, [string]$SourceUrl, [string]$HttpMethod, [int]$StartSeconds = 0, [string]$CacheKey = $null, $CacheDir = $null)
        if ($null -eq $SourceUrl -or $SourceUrl -eq "") {
            $Response.StatusCode = 404
            return
        }
        $Response.ContentType = "audio/mpeg"

        if ($HttpMethod -eq "HEAD") {
            $cachePathForHead = $null
            if ($CacheKey -and $CacheDir -and $StartSeconds -eq 0) {
                $safeKeyForHead = $CacheKey -replace '[^a-zA-Z0-9_\-]', '_'
                $cachePathForHead = Join-Path $CacheDir "$safeKeyForHead.mp3"
            }
            $Response.SendChunked = $false
            if ($cachePathForHead -and (Test-Path $cachePathForHead)) {
                $Response.ContentLength64 = (Get-Item $cachePathForHead).Length
            } else {
                $Response.ContentLength64 = $fakeContentLength
            }
            return
        }

        # Only a from-the-beginning play of a finite track is cacheable - a
        # seek (StartSeconds > 0) produces a PARTIAL file starting mid-track,
        # and $CacheKey is null entirely for radio (Resolve-TuneInUrl's
        # source), since a live stream has no "finished file" to cache.
        $cachePath = $null
        if ($CacheKey -and $CacheDir -and $StartSeconds -eq 0) {
            $safeKey = $CacheKey -replace '[^a-zA-Z0-9_\-]', '_'
            $cachePath = Join-Path $CacheDir "$safeKey.mp3"
        }

        # Fast path: this exact track was already fully transcoded once
        # before - serve the finished file directly, no ffmpeg/network
        # round-trip at all. This is what keeps a repeat play (a preset
        # recall, by definition, IS a repeat play) fast enough for a real
        # SoundTouch's own physical-recall timeout - see this function's
        # doc comment on $streamCacheDir above for the measured numbers.
        #
        # Deliberately a real Content-Length here (SendChunked=false), NOT
        # the chunked/unknown-length response the live-transcode path below
        # has to use - confirmed live (2026-07-22, tunnel log) that the real
        # SoundTouch was actively CANCELING the connection mid-response even
        # against this exact cached file, consistent with a strict UPnP
        # client during a PHYSICAL preset recall (as opposed to the app's
        # own play command, which tolerates it fine) expecting a definite,
        # complete-file-sized response rather than an open-ended chunked
        # stream - and a cache hit is exactly a case where the true size is
        # already known upfront, so there's no reason to send it chunked.
        if ($cachePath -and (Test-Path $cachePath)) {
            $bytes = [System.IO.File]::ReadAllBytes($cachePath)
            $Response.SendChunked = $false
            $Response.ContentLength64 = $bytes.Length
            $Response.OutputStream.Write($bytes, 0, $bytes.Length)
            return
        }

        # Live transcode: true final size isn't known until ffmpeg finishes.
        # Chunked would be the "correct" HTTP answer, but see this function's
        # doc comment above $fakeContentLength - the real device's recall
        # path cancels/rejects chunked outright, so a declared-but-oversized
        # length (closing early once the source actually ends) is what
        # actually works on real hardware.
        $Response.SendChunked = $false
        $Response.ContentLength64 = $fakeContentLength

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ffmpegPath
        # -ss BEFORE -i does fast input seeking (ffmpeg jumps directly to
        # that offset in the source instead of decoding/discarding
        # everything before it) - this is what backs the app's "seek"
        # feature, which works by restarting the stream at a new offset
        # rather than seeking within an already-open connection (there's
        # no pre-existing indexed file to seek within - this is a live,
        # on-the-fly transcode).
        $seekArg = if ($StartSeconds -gt 0) { "-ss $StartSeconds " } else { "" }
        # -rw_timeout bounds how long ffmpeg will wait on a stalled/dead
        # network read (microseconds - 15s here) - without this, a dead
        # radio stream or an expired/edge-case source URL blocks this
        # worker slot indefinitely, and with only 8 total concurrent
        # slots (see $runspacePool below), a few hung requests silently
        # exhaust capacity for every OTHER stream request too - the
        # likely cause of intermittent "sometimes doesn't play".
        $psi.Arguments = "-loglevel error -rw_timeout 15000000 $seekArg-i `"$SourceUrl`" -vn -acodec libmp3lame -b:a 192k -f mp3 pipe:1"
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        # Writing to a per-request temp file (not the final cache path
        # directly) and only moving it into place once the WHOLE transcode
        # finished cleanly means a client disconnecting mid-track (skip/
        # stop/change-source) never leaves a truncated, silently-broken file
        # sitting at the real cache path for the next play to pick up.
        $tempPath = $null
        $tempStream = $null
        if ($cachePath) {
            $tempPath = "$cachePath.tmp-$([guid]::NewGuid().ToString('N'))"
            $tempStream = [System.IO.File]::Create($tempPath)
        }
        $completedFully = $false
        try {
            $buffer = New-Object byte[] 65536
            $srcStream = $proc.StandardOutput.BaseStream
            while (($read = $srcStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $Response.OutputStream.Write($buffer, 0, $read)
                if ($tempStream) { $tempStream.Write($buffer, 0, $read) }
            }
            $completedFully = $true
        } finally {
            if ($tempStream) {
                $tempStream.Close()
                if ($completedFully) {
                    try { Move-Item -Path $tempPath -Destination $cachePath -Force } catch {}
                } else {
                    try { Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
            # Always reached - whether the copy loop finished normally (track
            # ended) or threw (client disconnected mid-stream, e.g. skip/
            # stop/change-source). Previously this cleanup only ran on
            # the normal-return path, so a disconnect-triggered exception
            # here left ffmpeg orphaned: still running, blocked writing
            # to a pipe nobody's reading anymore, permanently occupying
            # one of only 8 worker slots until the OS eventually reaped
            # it (if ever) - the other likely contributor to
            # intermittent playback failures under load.
            try {
                $proc.WaitForExit(3000) | Out-Null
                if (-not $proc.HasExited) { $proc.Kill() }
            } catch {}
        }
    }

    $request = $context.Request
    $response = $context.Response
    try {
        $path = $request.Url.AbsolutePath
        Write-Output "[$($request.HttpMethod)] $path"
        if ($path -like "/stream/*") {
            $videoId = $path.Substring("/stream/".Length) -replace "\.\w+$", ""
            $startSeconds = 0
            $startParam = $request.QueryString["start"]
            if ($startParam) { [void][int]::TryParse($startParam, [ref]$startSeconds) }
            $realUrl = Resolve-YouTubeUrl $videoId $urlCache
            Send-TranscodedStream $response $realUrl $request.HttpMethod $startSeconds "yt-$videoId" $streamCacheDir
        }
        elseif ($path -like "/radio/*") {
            $stationId = $path.Substring("/radio/".Length) -replace "\.\w+$", ""
            $realUrl = Resolve-TuneInUrl $stationId $tuneinUrlCache
            # No CacheKey - a live radio stream has no "finished file" to
            # cache, see Send-TranscodedStream's doc comment.
            Send-TranscodedStream $response $realUrl $request.HttpMethod
        }
        elseif ($path -like "/soundcloud/*") {
            # $path (Url.AbsolutePath) decodes %2F to a literal slash and then
            # NORMALIZES consecutive slashes down to one - which corrupts an
            # embedded "https://..." track URL's own "//" into ":/", so the
            # unescape below would silently produce a broken URL (confirmed
            # via direct testing against a real request, 2026-07-22: logged
            # path was ".../soundcloud/https:/soundcloud.com/..." - one
            # slash, not two). RawUrl is the exact, unmodified wire text
            # instead, so the embedded URL's own encoding survives intact
            # until unescaped, once, right here.
            $rawAfterPrefix = $request.RawUrl.Substring($request.RawUrl.IndexOf("/soundcloud/") + "/soundcloud/".Length)
            $rawAfterPrefix = $rawAfterPrefix -replace "\?.*$", ""
            $encodedTrackUrl = $rawAfterPrefix -replace "\.\w+$", ""
            $trackUrl = [Uri]::UnescapeDataString($encodedTrackUrl)
            $realUrl = Resolve-SoundCloudUrl $trackUrl $soundcloudUrlCache
            Send-TranscodedStream $response $realUrl $request.HttpMethod 0 "sc-$trackUrl" $streamCacheDir
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
    [void]$ps.AddScript($handlerScript).AddArgument($context).AddArgument($ytDlpPath).AddArgument($ffmpegPath).AddArgument($urlCache).AddArgument($soundcloudUrlCache).AddArgument($tuneinUrlCache).AddArgument($streamCacheDir)
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
