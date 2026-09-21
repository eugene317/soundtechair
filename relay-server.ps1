param(
    [int]$ListenPort = 7000,
    [int]$AdminPort = 7001,
    [string]$SoundCloudClientId = "",
    [string]$SoundCloudOAuthToken = "",
    [string]$GeminiApiKey = ""
)

$ytDlpPath = Join-Path $PSScriptRoot "yt-dlp.exe"
$adminHtmlPath = Join-Path $PSScriptRoot "admin.html"
$tunnelStreamLogPath = Join-Path $PSScriptRoot "tunnel-stream.err.log"
$scriptRoot = $PSScriptRoot

# SoundCloud search needs a personal client_id (and optionally an
# oauth_token) extracted from a logged-in soundcloud.com browser session -
# see the "How to get your SoundCloud credentials" note wherever this repo's
# setup instructions live. Read from a local, gitignored config file so the
# credential never needs to be passed as a command-line arg (and never goes
# near the Flutter app/APK - it's a personal session credential, not
# something to ship to a device). The -SoundCloudClientId/-SoundCloudOAuthToken
# params above are a manual override/fallback if this file doesn't exist yet.
$soundcloudConfigPath = Join-Path $PSScriptRoot "soundcloud-config.json"
if ([string]::IsNullOrWhiteSpace($SoundCloudClientId) -and (Test-Path $soundcloudConfigPath)) {
    try {
        $scConfig = Get-Content $soundcloudConfigPath -Raw | ConvertFrom-Json
        if ($scConfig.clientId) { $SoundCloudClientId = $scConfig.clientId }
        if ($scConfig.oauthToken) { $SoundCloudOAuthToken = $scConfig.oauthToken }
    } catch {
        Write-Output "Warning: could not read soundcloud-config.json - $($_.Exception.Message)"
    }
}
if ([string]::IsNullOrWhiteSpace($SoundCloudClientId)) {
    Write-Output "Note: SoundCloud search not configured yet - create soundcloud-config.json (see soundcloud-config.example.json) with your client_id to enable it."
}

# AI chat assistant (Gemini) - same local-gitignored-config pattern as SoundCloud
# above, for the same reason (a personal API key, never shipped to the app).
$geminiConfigPath = Join-Path $PSScriptRoot "gemini-config.json"
if ([string]::IsNullOrWhiteSpace($GeminiApiKey) -and (Test-Path $geminiConfigPath)) {
    try {
        $gConfig = Get-Content $geminiConfigPath -Raw | ConvertFrom-Json
        if ($gConfig.apiKey) { $GeminiApiKey = $gConfig.apiKey }
    } catch {
        Write-Output "Warning: could not read gemini-config.json - $($_.Exception.Message)"
    }
}
if ([string]::IsNullOrWhiteSpace($GeminiApiKey)) {
    Write-Output "Note: AI chat assistant not configured yet - create gemini-config.json (see gemini-config.example.json) with your API key to enable it."
}

# Shared state across REST-handler runspaces. Real .NET reference types, so every
# runspace that receives the same object instance observes the same underlying data.
$activityLog = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
# Server-wide run/stop switch, toggled from the admin dashboard. A synchronized
# Hashtable (not a plain PS variable) so every runspace that receives this same
# instance observes flips to it immediately.
$serverState = [System.Collections.Hashtable]::Synchronized(@{ Running = $true })

# Rough "how many users/speakers are actually using this" signal, grouped by
# app-install id (see SettingsService.getOrCreateInstallId's doc comment -
# there's no account/login system yet, so an install id is the closest thing
# to a "user"). One install can hold several speakers (one phone can control
# more than one). Updated by the app's periodic /api/heartbeat call
# (piggybacked onto the same 5-minute timer that already refreshes the stream
# proxy URL - see SpeakerController._refreshStreamProxyUrlFromServer - plus
# fired immediately on connect and on any play/pause state change). An
# install with no owner still around to run the app just stops refreshing and
# ages out of "Online" in the admin dashboard on its own; Remove-StaleInstalls
# additionally prunes anything not heard from in 24h, so a one-off test ping
# or a user who's genuinely gone for good doesn't sit in this list forever.
$connectedInstalls = [System.Collections.Hashtable]::Synchronized(@{})

function Add-ActivityLogEntry {
    param($Queue, [string]$Code, [string]$Action, [string]$Status, [string]$Detail = "")
    $Queue.Enqueue([PSCustomObject]@{
        time   = (Get-Date).ToString("HH:mm:ss")
        code   = $Code
        action = $Action
        status = $Status
        detail = $Detail
    })
    $dummy = $null
    while ($Queue.Count -gt 300) { $Queue.TryDequeue([ref]$dummy) | Out-Null }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$ListenPort/")
$listener.Prefixes.Add("http://+:$AdminPort/")
$listener.Start()
Write-Output "Relay server (app) listening on http://+:$ListenPort/ - safe to expose/tunnel"
Write-Output "Admin dashboard listening on http://+:$AdminPort/ - keep this LAN-only, never tunnel it"

# --- REST handler body, run through a small bounded runspace pool (same proven
# pattern as stream-proxy.ps1's concurrency fix). Redefines its own copies of every
# helper function, since runspaces don't inherit the parent script's function scope.
#
# The Flutter app controls the speaker directly over LAN UPnP, so this server's only
# jobs now are: serving search results for the app, and the admin dashboard. The old
# WebSocket agent-relay and pairing-code-gated control routes (built for the PC-based
# "Local App" + the old browser web app, both superseded by the Flutter app) have
# been permanently removed. ---
$restHandlerScript = {
    param($Context, $ActivityLog, $ServerState, $YtDlpPath, $AdminHtmlPath, $ListenPort, $AdminPort, $SoundCloudClientId, $SoundCloudOAuthToken, $GeminiApiKey, $TunnelStreamLogPath, $ScriptRoot, $ConnectedInstalls)

    # Private/loopback/LAN addresses (localhost testing, or ngrok failing to
    # forward the real client IP) have no meaningful geolocation - skip the
    # lookup entirely rather than reporting a nonsense location for them.
    function Test-IsPrivateIp {
        param([string]$Ip)
        if ([string]::IsNullOrWhiteSpace($Ip)) { return $true }
        return $Ip -match '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|::1$|localhost$)'
    }

    # Free, no-API-key lookup (ip-api.com, ~45 req/min limit on the free
    # tier) - fine here since this only ever runs ONCE per install (cached on
    # the record below), not per heartbeat. Best-effort: any failure (rate
    # limited, offline, blocked) just leaves the install's location unknown
    # rather than breaking the heartbeat itself.
    function Get-IpLocation {
        param([string]$Ip)
        if (Test-IsPrivateIp $Ip) { return "Local network" }
        try {
            $resp = Invoke-RestMethod -Uri "http://ip-api.com/json/$Ip?fields=status,city,regionName,country" -TimeoutSec 3
            if ($resp.status -eq "success") {
                return (@($resp.city, $resp.regionName, $resp.country) | Where-Object { $_ }) -join ", "
            }
        } catch {}
        return "Unknown"
    }

    function Add-SpeakerLogEntry {
        param($Speaker, [string]$Event)
        $Speaker.log.Enqueue([PSCustomObject]@{ time = (Get-Date).ToString("MM/dd HH:mm:ss"); event = $Event })
        $dummy = $null
        while ($Speaker.log.Count -gt 30) { $Speaker.log.TryDequeue([ref]$dummy) | Out-Null }
    }

    # $ClientIp is the PHONE's public IP (for geolocation) - unrelated to
    # $SpeakerIp, which is the speaker's own LAN address (for display only,
    # e.g. "192.168.1.9" - meaningless for location since it's never routable
    # outside the user's own home network).
    function Set-ConnectedSpeaker {
        param($Installs, [string]$InstallId, [string]$DeviceId, [string]$SpeakerName, [string]$SpeakerIp, [bool]$IsPlaying, [string]$ClientIp)
        if ([string]::IsNullOrWhiteSpace($InstallId) -or [string]::IsNullOrWhiteSpace($DeviceId)) { return }
        $now = Get-Date
        $install = $Installs[$InstallId]
        if (-not $install) {
            $install = [PSCustomObject]@{
                installId = $InstallId
                firstSeen = $now
                lastSeen  = $now
                location  = Get-IpLocation $ClientIp
                speakers  = [System.Collections.Hashtable]::Synchronized(@{})
            }
            $Installs[$InstallId] = $install
        }
        $install.lastSeen = $now

        $speakers = $install.speakers
        $speaker = $speakers[$DeviceId]
        if (-not $speaker) {
            $speaker = [PSCustomObject]@{
                deviceId    = $DeviceId
                speakerName = $SpeakerName
                speakerIp   = $SpeakerIp
                firstSeen   = $now
                lastSeen    = $now
                isPlaying   = $IsPlaying
                log         = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
            }
            $speakers[$DeviceId] = $speaker
            Add-SpeakerLogEntry $speaker "Connected"
        } else {
            $speaker.speakerName = $SpeakerName
            $speaker.speakerIp = $SpeakerIp
            $speaker.lastSeen = $now
            if ($speaker.isPlaying -ne $IsPlaying) {
                Add-SpeakerLogEntry $speaker $(if ($IsPlaying) { "Started playing" } else { "Stopped playing" })
            }
            $speaker.isPlaying = $IsPlaying
        }
    }

    # Sweeps out anything not heard from in a full day - a one-off test ping
    # (curl'd by hand, a user who's genuinely gone for good) has no other way
    # to ever leave this list otherwise, since heartbeats only ever add/
    # update, never remove. 24h (not the 15-minute Online/Offline threshold
    # used elsewhere) so a real user who just didn't open the app today
    # doesn't get pruned mid-day.
    function Remove-StaleInstalls {
        param($Installs)
        $cutoff = (Get-Date).AddHours(-24)
        foreach ($key in @($Installs.Keys)) {
            if ($Installs[$key].lastSeen -lt $cutoff) { $Installs.Remove($key) }
        }
    }

    function Add-ActivityLogEntry {
        param($Queue, [string]$Code, [string]$Action, [string]$Status, [string]$Detail = "")
        $Queue.Enqueue([PSCustomObject]@{
            time   = (Get-Date).ToString("HH:mm:ss")
            code   = $Code
            action = $Action
            status = $Status
            detail = $Detail
        })
        $dummy = $null
        while ($Queue.Count -gt 300) { $Queue.TryDequeue([ref]$dummy) | Out-Null }
    }

    # Sibling backend scripts/tunnels (stream-proxy.ps1, preset-listener.ps1,
    # ngrok, cloudflared) are separate OS processes from this one - none of
    # them auto-restart on crash, and they've each been observed dying
    # silently during real use (2026-07-2x). Rather than requiring someone
    # to notice and restart them by hand from a terminal, the admin
    # dashboard can check-and-start each one itself - this relay server's
    # own process tends to outlive the others, so it doubles as the one
    # thing reachable to fix the rest FROM.
    function Test-NamedScriptRunning {
        param([string]$Pattern)
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -notmatch '-NonInteractive' -and $_.CommandLine -match $Pattern }
        return (@($procs)).Count -gt 0
    }

    function Test-ExeRunning {
        param([string]$ExeName)
        return $null -ne (Get-Process -Name $ExeName -ErrorAction SilentlyContinue)
    }

    # The speaker IP is hard-coded here (matches this household's actual
    # speaker) rather than exposed as a dashboard input - preset-listener.ps1
    # itself falls back to a subnet scan if this address ever goes stale
    # (see its own Find-SpeakerBySubnetScan), so a wrong/outdated value here
    # self-heals rather than needing to be kept in sync by hand.
    function Start-BackendProcess {
        param([string]$Name, [string]$Root)
        switch ($Name) {
            "stream-proxy" {
                Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root "stream-proxy.ps1")) `
                    -RedirectStandardOutput (Join-Path $Root "stream-proxy.log") -RedirectStandardError (Join-Path $Root "stream-proxy.err.log") -WindowStyle Hidden
            }
            "preset-listener" {
                Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root "preset-listener.ps1"), '-SpeakerIp', '192.168.1.9') `
                    -RedirectStandardOutput (Join-Path $Root "preset-listener.log") -RedirectStandardError (Join-Path $Root "preset-listener.err.log") -WindowStyle Hidden
            }
            "tunnel-search" {
                # Fixed ngrok static domain - see SettingsService.searchServerUrl's
                # doc comment in the Flutter app for why this exact URL is
                # permanent and hard-coded there too.
                Start-Process ngrok -ArgumentList @('http', '--url=https://slush-epileptic-dipper.ngrok-free.dev', '--host-header=rewrite', '7000', '--log=stdout') `
                    -RedirectStandardOutput (Join-Path $Root "ngrok-tunnel.log") -RedirectStandardError (Join-Path $Root "ngrok-tunnel.err.log") -WindowStyle Hidden
            }
            "tunnel-stream" {
                # --protocol http2 (TCP) instead of cloudflared's default quic
                # (UDP) - confirmed directly (2026-07-25) that on this network
                # the QUIC session gets silently killed by NAT/router every
                # ~40-90s ("failed to accept QUIC stream: timeout: no recent
                # network activity"), then cloudflared reconnects only to drop
                # again seconds later, in a continuous loop. Any speaker
                # playback that happens to straddle one of those drops loses
                # its audio connection mid-stream, which is what was causing
                # the "blinking then solid orange" symptom regardless of which
                # station was chosen. HTTP/2-over-TCP tolerates this router's
                # NAT/idle timeouts far better.
                Start-Process (Join-Path $Root "tools\cloudflared.exe") -ArgumentList @('tunnel', '--url', 'http://localhost:5001', '--protocol', 'http2') `
                    -RedirectStandardOutput (Join-Path $Root "tunnel-stream.log") -RedirectStandardError (Join-Path $Root "tunnel-stream.err.log") -WindowStyle Hidden
            }
        }
    }

    function Get-BackendProcessStatuses {
        @(
            [PSCustomObject]@{ name = "stream-proxy"; label = "Stream Proxy"; running = (Test-NamedScriptRunning "stream-proxy\.ps1") }
            [PSCustomObject]@{ name = "preset-listener"; label = "Preset Listener"; running = (Test-NamedScriptRunning "preset-listener\.ps1") }
            [PSCustomObject]@{ name = "tunnel-search"; label = "Search Tunnel (ngrok)"; running = (Test-ExeRunning "ngrok") }
            [PSCustomObject]@{ name = "tunnel-stream"; label = "Stream Tunnel (cloudflared)"; running = (Test-ExeRunning "cloudflared") }
        )
    }

    function Stop-BackendProcess {
        param([string]$Name)
        switch ($Name) {
            "stream-proxy" {
                Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -match 'stream-proxy\.ps1' } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            }
            "preset-listener" {
                Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -match 'preset-listener\.ps1' } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            }
            "tunnel-search" { Get-Process -Name "ngrok" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
            "tunnel-stream" { Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
        }
    }

    # Goes past "is the .exe/script still alive" (Get-BackendProcessStatuses
    # above) into "does it actually do its job right now" - added 2026-07-28
    # after a real incident where cloudflared sat alive for hours in a
    # continuous "Unauthorized: Tunnel not found" reconnect-fail loop (a real
    # process, so the dashboard's plain running-check kept showing it as
    # healthy the whole time) while every speaker playback silently failed -
    # nothing surfaced this until a user noticed the speaker just blinking.
    # A clean HTTP response (even a 404 - there's no route at "/") proves the
    # request reached the real server and back; a transport-level failure
    # (refused/timeout/DNS) or a >=500 edge error means whatever's supposed
    # to be answering isn't really there.
    function Test-BackendProcessHealth {
        param([string]$Name, [string]$Root)
        switch ($Name) {
            "stream-proxy" {
                if (-not (Test-NamedScriptRunning "stream-proxy\.ps1")) {
                    return [PSCustomObject]@{ running = $false; healthy = $false; detail = "Not running" }
                }
                try {
                    Invoke-WebRequest -Uri "http://localhost:5001/" -Method Head -TimeoutSec 4 -UseBasicParsing | Out-Null
                    return [PSCustomObject]@{ running = $true; healthy = $true; detail = "Responding on :5001" }
                } catch {
                    if ($_.Exception.Response) {
                        return [PSCustomObject]@{ running = $true; healthy = $true; detail = "Responding on :5001 (HTTP $([int]$_.Exception.Response.StatusCode))" }
                    }
                    return [PSCustomObject]@{ running = $true; healthy = $false; detail = "Not answering on :5001 - $($_.Exception.Message)" }
                }
            }
            "preset-listener" {
                # No cheap deep check available without touching the actual
                # speaker (which this process already self-heals toward via
                # its own subnet rescan - see its own doc comment) - treated
                # as healthy whenever the process itself is alive.
                $running = Test-NamedScriptRunning "preset-listener\.ps1"
                return [PSCustomObject]@{ running = $running; healthy = $running; detail = $(if ($running) { "Running" } else { "Not running" }) }
            }
            "tunnel-search" {
                if (-not (Test-ExeRunning "ngrok")) {
                    return [PSCustomObject]@{ running = $false; healthy = $false; detail = "Not running" }
                }
                try {
                    $tunnels = Invoke-RestMethod -Uri "http://localhost:4040/api/tunnels" -TimeoutSec 4
                    $ok = @($tunnels.tunnels).Count -gt 0
                    return [PSCustomObject]@{ running = $true; healthy = $ok; detail = $(if ($ok) { "Tunnel registered" } else { "No active tunnel registered" }) }
                } catch {
                    return [PSCustomObject]@{ running = $true; healthy = $false; detail = "ngrok local API (:4040) unreachable - $($_.Exception.Message)" }
                }
            }
            "tunnel-stream" {
                if (-not (Test-ExeRunning "cloudflared")) {
                    return [PSCustomObject]@{ running = $false; healthy = $false; detail = "Not running" }
                }
                $logPath = Join-Path $Root "tunnel-stream.err.log"
                $altLogPath = Join-Path $Root "tunnel-stream.log"
                $candidates = @($logPath, $altLogPath) | Where-Object { Test-Path $_ } | Sort-Object { (Get-Item $_).LastWriteTimeUtc } -Descending
                $hostUrl = $null
                foreach ($candidate in $candidates) {
                    $found = Select-String -Path $candidate -Pattern "https://[a-z0-9-]+\.trycloudflare\.com" -AllMatches
                    if ($found) { $hostUrl = $found[-1].Matches[-1].Value; break }
                }
                if (-not $hostUrl) {
                    return [PSCustomObject]@{ running = $true; healthy = $false; detail = "No tunnel URL found in logs yet" }
                }
                try {
                    $r = Invoke-WebRequest -Uri $hostUrl -Method Head -TimeoutSec 6 -UseBasicParsing
                    return [PSCustomObject]@{ running = $true; healthy = $true; detail = "Reachable ($hostUrl, HTTP $([int]$r.StatusCode))" }
                } catch {
                    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -lt 500) {
                        return [PSCustomObject]@{ running = $true; healthy = $true; detail = "Reachable ($hostUrl, HTTP $([int]$_.Exception.Response.StatusCode))" }
                    }
                    return [PSCustomObject]@{ running = $true; healthy = $false; detail = "$hostUrl not reachable - tunnel is likely dead ($($_.Exception.Message))" }
                }
            }
        }
    }

    # Shared by both the on-demand "Check & Fix All" button and the periodic
    # background self-heal loop (see near $restPool.Open() at the bottom of
    # this file for the latter) - one place for "what does fixing a given
    # process actually involve" so the two never drift apart.
    function Invoke-BackendHeal {
        param($ActivityLog, [string]$Root, [string]$Source = "admin dashboard")
        $names = @("stream-proxy", "preset-listener", "tunnel-search", "tunnel-stream")
        $results = @()
        foreach ($name in $names) {
            $health = Test-BackendProcessHealth $name $Root
            if ($health.healthy) {
                $results += [PSCustomObject]@{ name = $name; wasHealthy = $true; nowHealthy = $true; detail = $health.detail }
                continue
            }
            if ($health.running) { Stop-BackendProcess $name; Start-Sleep -Milliseconds 500 }
            Start-BackendProcess $name $Root
            Start-Sleep -Seconds 2
            $after = Test-BackendProcessHealth $name $Root
            Add-ActivityLogEntry $ActivityLog "-" "auto_heal" $(if ($after.healthy) { "ok" } else { "error" }) "$name was unhealthy ($($health.detail)) - restarted via $Source, now: $($after.detail)"
            $results += [PSCustomObject]@{ name = $name; wasHealthy = $false; nowHealthy = $after.healthy; detail = $after.detail }
        }
        return $results
    }

    function Search-YouTube {
        param([string]$Query, [int]$Count = 15)
        # Confirmed via direct test (2026-07-17): --flat-playlist DOES include
        # duration for YouTube search results (it's part of the search-results
        # page data, not a full per-video extraction), so this stays fast.
        $raw = & $YtDlpPath "ytsearch${Count}:$Query" --flat-playlist --print "%(title)s|||%(id)s|||%(duration)s" --no-warnings 2>$null
        $results = @()
        foreach ($line in $raw) {
            # Duration group is (.*) not ([^|]+) - live streams/premieres/etc.
            # report an EMPTY %(duration)s, and requiring 1+ chars there silently
            # dropped those results entirely instead of just showing them with an
            # unknown duration.
            if ($line -match "^(.*)\|\|\|([^|]+)\|\|\|(.*)$") {
                $durationSeconds = $null
                $parsedDuration = 0
                if ([int]::TryParse($matches[3], [ref]$parsedDuration)) { $durationSeconds = $parsedDuration }
                $results += [PSCustomObject]@{ title = $matches[1]; id = $matches[2]; durationSeconds = $durationSeconds }
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
                $results += [PSCustomObject]@{ name = $item.text; id = $item.guide_id; image = $item.image }
            }
        }
        return $results
    }

    function Search-SoundCloud {
        param([string]$Query, [string]$ClientId, [string]$OAuthToken, [int]$Count = 15)
        if ([string]::IsNullOrWhiteSpace($ClientId)) {
            throw "SoundCloud not configured - set clientId in soundcloud-config.json"
        }
        $url = "https://api-v2.soundcloud.com/search/tracks?q=" + [System.Uri]::EscapeDataString($Query) + "&client_id=$ClientId&limit=$Count"
        $headers = @{}
        if (-not [string]::IsNullOrWhiteSpace($OAuthToken)) {
            # SoundCloud's real web app sends this as "Authorization: OAuth <token>"
            # (confirmed via a real browser DevTools capture, 2026-07-22) - client_id
            # alone gets a 401 from search/tracks and other endpoints even though it
            # looks valid, since SoundCloud's API now requires the session's OAuth
            # token too. Prepend the scheme here so soundcloud-config.json can just
            # hold the bare token value without the user needing to know this.
            $token = $OAuthToken.Trim()
            if ($token -notmatch '^OAuth\s') { $token = "OAuth $token" }
            $headers["Authorization"] = $token
        }
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 10 -UseBasicParsing
        $data = $resp.Content | ConvertFrom-Json
        $results = @()
        foreach ($item in $data.collection) {
            # duration is milliseconds - confirmed against SoundCloud's own API shape.
            $durationSeconds = $null
            if ($item.duration) { $durationSeconds = [int]([math]::Round($item.duration / 1000)) }
            $results += [PSCustomObject]@{
                title           = $item.title
                artist          = $item.user.username
                id              = $item.permalink_url
                durationSeconds = $durationSeconds
                image           = $item.artwork_url
            }
        }
        return $results
    }

    function ConvertTo-JsonSafe { param($Data) return ($Data | ConvertTo-Json -Compress -Depth 5) }

    # Sends the user's free-text message to Gemini (gemini-flash-latest - the
    # free-tier-eligible alias, confirmed working: fixed model names like
    # gemini-2.0-flash/gemini-2.5-pro have had their free-tier quota zeroed
    # out, and the alias always routes to whichever current model still has
    # it) and forces a structured decision back via responseSchema: either
    # "play" (with a source + search query) or "none" (just a reply, no
    # music action) - so the caller never has to parse free-form text.
    #
    # Whether a decision actually carries the field(s) its own action needs -
    # weaker/lite models have been observed (2026-07-22, gemini-3.1-flash-lite)
    # to sometimes return action="play" with source/query left null or empty
    # despite the schema listing them - the schema only enforces TYPE/
    # presence-of-key, not that the value is meaningful, so this check exists
    # specifically to catch what the schema can't.
    # Confirmed live (2026-07-23, direct repeated testing against the real
    # Gemini API with this exact prompt/schema): given a request like "play
    # music from yt music gloc 9", gemini-3.1-flash-lite correctly chooses
    # action="play"/"search" and sets `source` roughly 100% of the time, but
    # leaves `query` genuinely blank (not even misplaced into trackQueries)
    # in a large fraction of calls - out of 5 repeated trials of the exact
    # same message, 3 failed this way across ALL THREE fallback models, not
    # just the first one. Schema property descriptions (see `query`'s
    # description above) and the trackQueries-misplacement recovery below
    # both help, but neither is reliable enough alone - a flat responseSchema
    # has no way to make a field conditionally required only for certain
    # action values, so the model is always free to just skip it. This
    # function is the actual safety net: if the model at least committed to
    # a source (real intent to play/search SOMETHING) but never isolated a
    # clean search term, fall back to the user's own raw message with only
    # the unambiguous command verbs/platform names stripped - a slightly
    # noisier search term beats the assistant claiming to play something and
    # silently doing nothing, which is what shipped before this existed.
    # Sets $Decision.query whether or not that key was even present in
    # Gemini's JSON in the first place - ConvertFrom-Json only creates
    # properties for keys that were actually in the payload, and a plain
    # `$Decision.query = ...` assignment THROWS ("property cannot be found")
    # when the key was fully absent (confirmed live: absent, not just an
    # empty string, on a real fraction of responses) rather than silently
    # creating it the way a hashtable would - Add-Member is the form that
    # works either way.
    function Set-DecisionQuery {
        param($Decision, [string]$Value)
        $Decision | Add-Member -NotePropertyName query -NotePropertyValue $Value -Force
    }

    function Set-DecisionAlarmDays {
        param($Decision, [string]$Value)
        $Decision | Add-Member -NotePropertyName alarmDays -NotePropertyValue $Value -Force
    }

    # Deterministic day-of-week extraction, kept entirely separate from the
    # freeform song/artist query rescue above - day names are a small closed
    # vocabulary (unlike a search phrase), so scanning the WHOLE conversation
    # so far for them is safe even when the days were actually named several
    # turns before the one that finally fires set_alarm (a real live-tested
    # case, 2026-07-24: user says "weekdays only" in one turn, doesn't repeat
    # it, then answers the wake-up-song question in a LATER turn - by the
    # time set_alarm actually fires, "weekdays" is nowhere in that turn's own
    # raw message, only earlier in the conversation). Returns $null (not "")
    # when nothing matches, so callers can tell "found nothing" apart from a
    # deliberately-empty one-time alarm.
    function Get-AlarmDaysFromText {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
        $t = $Text.ToLowerInvariant()
        if ($t -match '\b(every\s*day|araw-?araw|daily)\b') { return "mon,tue,wed,thu,fri,sat,sun" }
        if ($t -match '\bweekdays?\b' -or $t -match '\bmonday\s*(?:to|-|until)\s*friday\b' -or $t -match '\blunes\s*(?:hanggang|to|-)\s*biyernes\b') { return "mon,tue,wed,thu,fri" }
        if ($t -match '\bweekends?\b' -or $t -match '\bsaturday\s*(?:and|&)\s*sunday\b' -or $t -match '\bsabado\s*(?:at|and|&)\s*linggo\b') { return "sat,sun" }
        $dayMap = [ordered]@{
            'mon' = @('monday', 'lunes'); 'tue' = @('tuesday', 'martes')
            'wed' = @('wednesday', 'miyerkules', 'miyerkoles'); 'thu' = @('thursday', 'huwebes')
            'fri' = @('friday', 'biyernes'); 'sat' = @('saturday', 'sabado')
            'sun' = @('sunday', 'linggo')
        }
        $found = @()
        foreach ($code in $dayMap.Keys) {
            foreach ($name in $dayMap[$code]) {
                if ($t -match "\b$name\b") { $found += $code; break }
            }
        }
        if ($found.Count -gt 0) { return ($found -join ',') }
        return $null
    }

    # Extracts a search target the model itself already named in its OWN
    # reply text - e.g. "Coming right up, playing some upbeat pop hits for
    # you now." -> "upbeat pop hits". Exists specifically for the case
    # Repair-GeminiDecision's other fallbacks can't reach: the user just
    # confirms something GEMINI suggested a turn earlier ("sure, that one",
    # "yes please") - the real target was never in the user's own raw
    # message at all (the raw-message-strip fallback below would just leave
    # "sure, that one" nearly intact), but the assistant's reply on THIS
    # SAME turn almost always narrates what it's about to do, since that is
    # the natural thing to say back regardless of which field it forgot to
    # fill in. Confirmed live (2026-07-24): even with an explicit schema
    # description AND a dedicated prompt rule telling it to restate its own
    # earlier suggestion into `query`, gemini-3.1-flash-lite still left query
    # blank in 2 of 3 repeated trials of this exact scenario - the reply text
    # itself was the only thing that reliably carried the real target both
    # times. Returns $null (not a fallback string) when nothing matches, so
    # callers can tell "found nothing" apart from "found an empty string".
    function Get-ReplyImpliedQuery {
        param([string]$ReplyText)
        if ([string]::IsNullOrWhiteSpace($ReplyText)) { return $null }
        if ($ReplyText -match '(?i)\b(?:playing|play|put(?:ting)?\s+on|queu(?:e|ing)\s+up|start(?:ing)?|get(?:ting)?|pick(?:ing)?\s+out)\s+(?:this\s+|that\s+|those\s+|some\s+|the\s+)*(.+?)\s*(?:(?:playing|queuing|starting)\s+)?(?:for\s+you(?:\s+(?:right\s+)?now)?|right\s+now|now|going(?:\s+for\s+you)?)?[.!]?\s*$') {
            $extracted = $matches[1].Trim()
            if ($extracted) { return $extracted }
        }
        return $null
    }

    function Repair-GeminiDecision {
        param($Decision, [string]$OriginalMessage, [string]$ConversationText = "")
        if ($Decision.action -eq "set_alarm") {
            # The CURRENT message is the highest-confidence signal for "what
            # did the user just say about days" - if it names an unambiguous
            # pattern, that OVERRIDES whatever alarmDays the model itself
            # returned. Confirmed live (2026-07-24): the model can confidently
            # return an ACTIVELY WRONG alarmDays (all 7 days) when its OWN
            # previous turn asked a multi-choice question ("every day,
            # weekdays, or just once?") and the user picked a LATER option
            # ("weekdays only") - it sometimes anchors on the FIRST option it
            # itself listed rather than the one actually chosen, the same
            # anchoring failure as the play-action example bias fixed above,
            # just self-inflicted via its own prior question this time.
            $currentMessageDays = Get-AlarmDaysFromText $OriginalMessage
            if ($currentMessageDays) {
                Set-DecisionAlarmDays $Decision $currentMessageDays
            } elseif ([string]::IsNullOrWhiteSpace($Decision.alarmDays)) {
                # Nothing day-related in THIS turn's own message - only
                # rescue a genuinely BLANK field by scanning further back
                # (days named several turns ago - see Get-AlarmDaysFromText's
                # doc comment); never override an already-filled value based
                # on older, less-current context than what the model saw.
                $impliedDays = Get-AlarmDaysFromText $ConversationText
                if ($impliedDays) { Set-DecisionAlarmDays $Decision $impliedDays }
            }
        }
        if ($Decision.action -eq "play" -or $Decision.action -eq "search" -or $Decision.action -eq "set_alarm") {
            if ([string]::IsNullOrWhiteSpace($Decision.query) -and $Decision.trackQueries -and @($Decision.trackQueries).Count -ge 1) {
                # A single best guess, not a join of everything - a specific
                # misplaced title beats a garbled concatenation of several.
                # Same fix as below, for the same trackQueries/query mix-up -
                # confirmed live (2026-07-23) this happens for set_alarm's
                # optional wake-up song too, not just play/search.
                Set-DecisionQuery $Decision (@($Decision.trackQueries)[0])
            }
            if (($Decision.action -eq "play" -or $Decision.action -eq "search") -and
                [string]::IsNullOrWhiteSpace($Decision.query) -and -not [string]::IsNullOrWhiteSpace($Decision.source)) {
                # Try the model's own reply text FIRST - see Get-ReplyImpliedQuery's
                # doc comment for why this catches a real gap the raw-message
                # strip below cannot (a confirmed-earlier-suggestion has no
                # trace in the user's OWN current message at all).
                $impliedQuery = Get-ReplyImpliedQuery $Decision.reply
                if ($impliedQuery) {
                    Set-DecisionQuery $Decision $impliedQuery
                } else {
                    # Deliberately narrow strip list - only unambiguous command
                    # verbs and platform names, NOT common function words
                    # (sa/ng/mo/ko/na/mula) - those legitimately appear inside
                    # real Filipino song titles (e.g. "Sa Ngalan ng Pag-Ibig"),
                    # and this is a last resort already, not worth risking
                    # mangling a title that's otherwise fine as-is.
                    $stripped = $OriginalMessage `
                        -replace '(?i)\b(please|paki-?usap|i-?play|patugtugin|pakinggan|gusto\s+ko(ng)?\s+(marinig|pakinggan))\b', ' ' `
                        -replace '(?i)\bplay\b', ' ' `
                        -replace '(?i)\b(yt\s*music|youtube\s*music|youtube|soundcloud|tunein(\s*radio)?|radio)\b', ' ' `
                        -replace '(?i)\bmusic\b', ' ' `
                        -replace '\s{2,}', ' '
                    $stripped = $stripped.Trim()
                    Set-DecisionQuery $Decision $(if ($stripped) { $stripped } else { $OriginalMessage })
                }
            }
            # set_alarm's optional wake-up song gets the SAME reply-text
            # rescue (an alarm confirmation flow hits the exact same "sure,
            # that one" pattern as play/search), but deliberately NOT the
            # raw-message strip above - a missing song there is a perfectly
            # valid alarm (see Test-GeminiDecisionComplete), not a failure to
            # paper over with the user's own unrelated raw message.
            if ($Decision.action -eq "set_alarm" -and [string]::IsNullOrWhiteSpace($Decision.query) -and -not [string]::IsNullOrWhiteSpace($Decision.source)) {
                $impliedAlarmQuery = Get-ReplyImpliedQuery $Decision.reply
                if ($impliedAlarmQuery) { Set-DecisionQuery $Decision $impliedAlarmQuery }
            }
        }
        return $Decision
    }

    function Test-GeminiDecisionComplete {
        param($Decision)
        switch ($Decision.action) {
            "play"           { return (-not [string]::IsNullOrWhiteSpace($Decision.source)) -and (-not [string]::IsNullOrWhiteSpace($Decision.query)) }
            "search"         { return (-not [string]::IsNullOrWhiteSpace($Decision.source)) -and (-not [string]::IsNullOrWhiteSpace($Decision.query)) }
            "volume_set"     { return $null -ne $Decision.volumeLevel }
            "volume_adjust"  { return $null -ne $Decision.volumeDelta }
            "transport"      { return -not [string]::IsNullOrWhiteSpace($Decision.transportKey) }
            "preset"         { return -not [string]::IsNullOrWhiteSpace($Decision.presetNum) }
            "create_playlist" { return (-not [string]::IsNullOrWhiteSpace($Decision.playlistName)) -and $Decision.trackQueries -and @($Decision.trackQueries).Count -gt 0 }
            "set_alarm"      { return ($null -ne $Decision.alarmHour) -and ($null -ne $Decision.alarmMinute) }
            default          { return $true } # "none"/"toggle_source"/"play_playlist" need nothing extra.
        }
    }

    function Invoke-GeminiChat {
        param([string]$Message, [string]$ApiKey, [array]$History = @())
        # Personality + capability list, rewritten 2026-07-23 to (1) hold a real
        # conversation before ever touching playback/creating anything, (2)
        # cover every command the app can actually do, and (3) be honest about
        # what it can't do instead of staying vague or pretending. Kept as ONE
        # long string (not multiple systemInstruction parts) since the Gemini
        # API only reads parts[0].text in practice for a single-turn system
        # instruction - no behavioral reason to split it.
        $systemPrompt = 'You are the built-in voice/chat assistant for a Bose SoundTouch speaker control app - warm, friendly, and easy to talk to, like a good friend who happens to know a lot about music, not a stiff formal assistant. Genuinely enthusiastic and quick-witted, never robotic, never a wall of caveats, never cold or transactional even when just executing a simple command - a little warmth in every reply, not just the conversational ones. Proactively help rather than answering only literally - if someone sounds unsure, offer 2-3 concrete options by name; once they confirm something, just do it, no re-confirmation theater. ' +
            'CONVERSATION FIRST, COMMAND SECOND: hold a real back-and-forth before committing to anything that starts new audio or creates something. Discuss mood/genre/artist, ask follow-up questions, suggest specific songs/artists by name - all through action="none" or action="search" below. Only fire "play" once the user has clearly picked or confirmed one specific thing; only fire "create_playlist"/"set_alarm" once every question you yourself asked has actually been answered. Low-risk, instantly-reversible actions - volume, pause/resume/skip, presets, source toggle - do NOT need this back-and-forth; do those immediately when asked. ' +
            'TWO RULES THAT MATTER MORE THAN ANYTHING ELSE BELOW: ' +
            '(1) ALWAYS BUILD FROM THE WHOLE CONVERSATION, NEVER JUST THE LATEST MESSAGE ALONE. The newest message is very often just filling in ONE missing piece of a request that started several turns earlier - never treat it as the entire request by itself, and never search for it as a literal phrase/title. Worked example: user says "play music" with nothing else named -> you correctly ask what mood/genre/artist they want (action="none") -> user then replies with just a short answer like "something fun" or a bare genre name -> you now fire action="play" with a query that COMBINES the original intent (they want music playing) with that answer (turn a mood/vibe word into an actual concrete-sounding query, like upbeat feel-good songs of that vibe, or use the named genre/artist directly) - never search for the literal words "something fun" as if that were a real song title, and never fall back to naming some specific artist/song of your own that nobody actually asked for. This cuts both ways: if instead YOU offered 2-3 named options and the user just confirms one ("sure, that one", "yes please", "okay", "sige") without repeating its name, you must still fire action="play" with query set to that EXACT option you yourself just named a moment ago - never leave query blank just because the target was already spelled out earlier in the conversation instead of in this exact message. ' +
            '(2) NEVER FIRE AN ACTION WHILE ONE OF YOUR OWN QUESTIONS IS STILL UNANSWERED. If your last reply asked the user one or more specific questions (what time, which days, what to wake up to, what genre, etc.), every one of those stays OPEN until the user''s latest message actually addresses ALL of them - an explicit "wala"/"never mind"/"nothing" counts as answering it. Worked example for alarms: user says "set an alarm" -> you ask what time -> they answer the time -> you ask which days AND what they want to wake up to -> if their next reply only answers ONE of those two (say, just the days, or just a song), keep action="none" and ask again for whichever part is still missing - do NOT fire set_alarm just because you already technically have hour/minute; wait until every question you asked has a real answer. ' +
            'ACTIONS you can set on action: ' +
            '"none" - pure conversation: answering, brainstorming, suggesting things by name, asking a clarifying question, or explaining a limitation. No app effect. ' +
            '"play" (set source + query) - fires the instant the user gives a play verb/phrase ("play", "i-play", "patugtugin", "pakinggan natin", "gusto kong marinig") PLUS any named target - a specific song title, an artist name, a genre, a mood, or a station name are ALL specific enough on their own (naming just one artist, or just one genre, or just one mood word, is enough - pick your own best match yourself, never ask "which song" first). A bare request with NOTHING named at all ("play music", "gusto ko ng kanta", "laro ng kanta") is NOT enough on its own - see rule (1), ask what they are in the mood for instead of guessing, and never default to any specific artist/song you were not actually given. Also fires the instant the user confirms a specific option you already offered ("yes play the first one", "sige yun na", "gusto ko yung pangalawa"). source="youtube" for songs/artists/general music, "radio" for a station/genre-radio request, "soundcloud" for an explicit SoundCloud request. If the message contains a play instruction at all, ALWAYS choose "play" over "search" - never turn a direct "play X" into a menu of choices. ' +
            '"search" (set source + query) - the user is BROWSING/asking to see options, with NO play verb at all - a question or open request ("may chill ka ba", "anong meron", "pahanap ng 90s rock", "ano magandang OPM"). Shows up to 5 results as tappable cards and asks which one, but does NOT start playback. Reserve this for when the user is the one asking to see choices - not a fallback for "the target was broad." ' +
            '"volume_set" (set volumeLevel, 0-100) - an EXACT target level the user stated ("set volume to 30"). ' +
            '"volume_adjust" (set volumeDelta, e.g. -20 or +15) - a RELATIVE change ("lower it a bit", "medyo lakasan mo", "pababain ng 20%"). ' +
            '"transport" (set transportKey to PLAY, PAUSE, NEXT_TRACK, PREV_TRACK, or POWER) - resume/pause, skip a track, or power on/off. ' +
            '"toggle_source" - switch the input between AUX and Bluetooth (no extra fields). ' +
            '"preset" (set presetNum "1".."6") - recall a saved preset by number. ' +
            '"create_playlist" (set playlistName + trackQueries, an array of 3-8 concrete song/artist search phrases) - once the user has confirmed they want a playlist built; pick good concrete tracks yourself if they only named a vibe/genre. After this fires, ask in reply whether to play it now, sequential or shuffle, once or on repeat. ' +
            '"play_playlist" (optionally set playlistOrder: "sequential"|"shuffle" and playlistRepeat: "once"|"loop") - the user just confirmed they want the playlist you created played, and/or answered the shuffle/loop question. ' +
            '"set_alarm" (set alarmHour 0-23 + alarmMinute 0-59, optionally alarmDays for a repeating alarm, optionally source+query for a specific wake-up song/artist/genre) - once EVERY question you asked about it has actually been answered (see rule (2)). Ask what time, which days (every day / weekdays / specific days / just once), and what they want to wake up to (a specific song/artist/genre, or nothing - the alarm will just resume whatever the speaker was last playing) - all through action="none" first, exactly like any other multi-detail request. A song is genuinely optional (a clear "wala"/"never mind"/"just wake me up" answer settles that question without naming one), but it must actually be SETTLED through conversation, not silently skipped just because you already had enough fields to fire technically. The time is never optional. If any days were mentioned at all, alarmDays is NOT optional - always translate them into the array, never leave it empty when the user named days: "Lunes hanggang Biyernes"/"weekdays"/"Monday to Friday" -> ["mon","tue","wed","thu","fri"]; "everyday"/"araw-araw" -> all 7; "Saturday and Sunday"/"weekends" -> ["sat","sun"]; a single named day -> that one day only. Leave alarmDays empty ONLY when the user actually means just once (today/tomorrow, no repeat), e.g. "gising mo ako sa 6am bukas" with no day-of-week or "everyday" wording at all. ' +
            'WHAT YOU CANNOT DO FROM CHAT - say so plainly and point at the real control instead of pretending or staying vague: pairing/unpairing stereo speakers (that is the app''s "Pair speakers" menu, not chat), Spotify playback (Spotify login/browsing lives in its own "Spotify" tab, not this chat), anything on a speaker that is not currently connected, Bluetooth *pairing* itself (toggle_source only flips the input to an already-paired device), and anything outside this app entirely. ' +
            'Use the conversation history to resolve CLEAR references to something already discussed - "yung number 2", "sige, gawin mo yun", "oo tama", or a short answer to a question you just asked - into a concrete decision that COMBINES with what was already established (see rule (1)), never asking them to repeat what they already said. But do NOT use history to silently guess a brand-NEW vague request that has nothing to do with what you just asked - if the CURRENT message does not answer your last question AND does not name anything specific on its own, ask again rather than guessing. Only fire a command once the user has clearly committed and every question you asked has a real answer - if they are still asking questions, comparing options, or deliberating, keep action="none" and keep the conversation going. ' +
            'LANGUAGE: always reply in English, no matter what language the user wrote in - even if they write in Tagalog/Taglish, your reply text is English. Always set replyLanguage to "en". ' +
            'Keep reply short and speakable out loud (one to two sentences, no markdown, no bullet lists, no emoji) - it gets read aloud by text-to-speech.'

        $contents = @()
        # Plain concatenation of every turn's text (both sides) - fed to
        # Get-AlarmDaysFromText below so a day-of-week named several turns
        # before set_alarm actually fires still gets found, not just
        # whatever happens to be in the CURRENT message alone.
        $conversationText = ""
        foreach ($turn in $History) {
            $role = if ($turn.role -eq "model") { "model" } else { "user" }
            $contents += @{ role = $role; parts = @(@{ text = [string]$turn.text }) }
            $conversationText += " " + [string]$turn.text
        }
        $contents += @{ role = "user"; parts = @(@{ text = $Message }) }
        $conversationText += " " + $Message

        $body = @{
            contents          = $contents
            systemInstruction = @{ parts = @(@{ text = $systemPrompt }) }
            generationConfig  = @{
                responseMimeType = "application/json"
                responseSchema   = @{
                    type       = "OBJECT"
                    properties = @{
                        reply         = @{ type = "STRING" }
                        replyLanguage = @{ type = "STRING"; enum = @("en", "tl") }
                        action        = @{ type = "STRING"; enum = @("play", "search", "volume_set", "volume_adjust", "transport", "toggle_source", "preset", "create_playlist", "play_playlist", "set_alarm", "none") }
                        source        = @{ type = "STRING"; enum = @("youtube", "radio", "soundcloud"); description = "REQUIRED for action play/search." }
                        query         = @{ type = "STRING"; description = "REQUIRED for action play/search - the ONE song/artist/genre/mood/station to look up, as an actual concrete searchable phrase. Never leave this empty when action is play or search - not even when the user is just confirming something YOU suggested earlier in this conversation ('sure, that one', 'yes please', 'okay'): restate that exact suggestion here yourself, since this field is what actually gets searched and the user's own current message may not repeat it. Never put it in trackQueries instead - trackQueries is a completely different field, only for create_playlist." }
                        volumeLevel   = @{ type = "INTEGER" }
                        volumeDelta   = @{ type = "INTEGER" }
                        transportKey  = @{ type = "STRING"; enum = @("PLAY", "PAUSE", "NEXT_TRACK", "PREV_TRACK", "POWER") }
                        presetNum     = @{ type = "STRING"; enum = @("1", "2", "3", "4", "5", "6") }
                        playlistName  = @{ type = "STRING"; description = "ONLY for action create_playlist." }
                        trackQueries  = @{ type = "ARRAY"; items = @{ type = "STRING" }; description = "ONLY for action create_playlist - a list of SEVERAL different song search phrases to build a new playlist out of. Never used for action play/search - those use the single `query` field instead." }
                        playlistOrder = @{ type = "STRING"; enum = @("sequential", "shuffle") }
                        playlistRepeat = @{ type = "STRING"; enum = @("once", "loop") }
                        alarmHour     = @{ type = "INTEGER"; description = "ONLY for action set_alarm - 0-23, 24-hour, device-local time." }
                        alarmMinute   = @{ type = "INTEGER"; description = "ONLY for action set_alarm - 0-59." }
                        # Confirmed live (2026-07-23): a plain comma-separated STRING
                        # here is materially more reliable coming back from this
                        # app's lite Gemini models than an ARRAY-typed field was
                        # (still not 100% - the model can just omit an optional
                        # field regardless of shape - but noticeably better).
                        alarmDays     = @{ type = "STRING"; description = "ONLY for action set_alarm - a comma-separated list of which days it repeats on, using exactly these codes: mon,tue,wed,thu,fri,sat,sun - e.g. 'mon,tue,wed,thu,fri'. Empty/omitted means a one-time alarm." }
                    }
                    required   = @("reply", "action")
                }
            }
        } | ConvertTo-Json -Depth 10 -Compress
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

        # Deliberately NOT "gemini-flash-latest" - Google hot-swaps that alias
        # to whatever model is newest, and newest models get squeezed hardest
        # on the free tier (confirmed live, 2026-07-22: it currently points at
        # gemini-3.6-flash, launched THAT SAME DAY, with a free quota of only
        # 20 requests/day - exhausted almost immediately by normal use).
        # Each model name below tracks its OWN separate daily quota
        # (the metric is literally "...PerProjectPerModel..."), so trying
        # several in order - not just retrying the same one - means one
        # model's daily cap being hit doesn't take the assistant down; the
        # next name still has its full untouched allowance for today.
        $models = @("gemini-3.1-flash-lite", "gemini-flash-lite-latest", "gemini-3.5-flash-lite")
        $lastError = $null
        # A real response that came back missing the field(s) its own action
        # needs (weaker models observed doing this ~2/3 of the time even
        # though the schema was satisfied) - kept as a last-resort fallback
        # so a genuinely-answered-but-incomplete reply still reaches the user
        # (the app-side dispatch already no-ops safely on a null field) rather
        # than throwing away a perfectly good conversational reply just
        # because the action's own extra field didn't come through.
        $bestIncompleteDecision = $null
        # Changed 2026-07-23: this used to retry the SAME model up to twice
        # (3s/6s backoff sleep) before moving on, at a 20s-per-attempt
        # timeout - worst case (all 3 models rate-limited) was north of two
        # minutes of pure waiting, which is exactly the "matagal ang
        # pagrespond" the voice assistant was getting complained about for.
        # A 429 here is almost always a DAILY quota already at zero for that
        # model (see the $models comment above - each has its own separate
        # daily cap), not a transient blip a few seconds' wait would clear -
        # so there is no real benefit to retrying the same model at all;
        # falling straight through to the next model (its own untouched
        # quota) is both faster AND just as likely to succeed. One attempt
        # per model, shorter per-attempt timeout: worst case is now ~3
        # models x 10s = 30s instead of 129s+.
        foreach ($model in $models) {
            $url = "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=$ApiKey"
            try {
                $resp = Invoke-WebRequest -Uri $url -Method Post -Body $bodyBytes -ContentType "application/json; charset=utf-8" -TimeoutSec 10 -UseBasicParsing
                $data = $resp.Content | ConvertFrom-Json
                $decision = Repair-GeminiDecision ($data.candidates[0].content.parts[0].text | ConvertFrom-Json) $Message $conversationText
                if (Test-GeminiDecisionComplete $decision) { return $decision }
                $bestIncompleteDecision = $decision
            } catch {
                $lastError = $_
            }
        }
        if ($bestIncompleteDecision) { return $bestIncompleteDecision }
        throw $lastError
    }

    function Write-TextResponse {
        param($Response, [string]$Text, [string]$ContentType = "text/plain")
        $buf = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $Response.ContentType = "$ContentType; charset=utf-8"
        $Response.ContentLength64 = $buf.Length
        $Response.OutputStream.Write($buf, 0, $buf.Length)
    }

    $request = $Context.Request
    $response = $Context.Response
    try {
        $path = $request.Url.AbsolutePath
        $adminPaths = @("/admin", "/api/admin/status", "/api/admin/toggle", "/api/admin/processes", "/api/admin/start_process", "/api/admin/heal_now")
        $requestPort = $request.Url.Port
        $isAdminPort = ($requestPort -eq $AdminPort)

        if ($isAdminPort -and $adminPaths -notcontains $path) {
            # Admin port only ever serves admin routes - even if someone finds this
            # port, nothing app-related (search) is reachable on it.
            $response.StatusCode = 404
            Write-TextResponse $response "Not found"
        }
        elseif (-not $isAdminPort -and $adminPaths -contains $path) {
            # App port never serves admin routes - so tunneling/exposing only this
            # port (the intended setup) can never leak the admin dashboard.
            $response.StatusCode = 404
            Write-TextResponse $response "Not found"
        }
        elseif (-not $ServerState.Running -and $adminPaths -notcontains $path) {
            $response.StatusCode = 503
            Write-TextResponse $response "Server is stopped by admin. Visit the admin dashboard to restart it."
        }
        elseif ($path -eq "/api/yt_search") {
            $q = [System.Uri]::UnescapeDataString($request.QueryString["q"])
            Write-TextResponse $response (ConvertTo-JsonSafe (Search-YouTube $q)) "application/json"
        }
        elseif ($path -eq "/api/radio_search") {
            $q = [System.Uri]::UnescapeDataString($request.QueryString["q"])
            Write-TextResponse $response (ConvertTo-JsonSafe (Search-TuneIn $q)) "application/json"
        }
        elseif ($path -eq "/api/soundcloud_search") {
            $q = [System.Uri]::UnescapeDataString($request.QueryString["q"])
            Write-TextResponse $response (ConvertTo-JsonSafe (Search-SoundCloud $q $SoundCloudClientId $SoundCloudOAuthToken)) "application/json"
        }
        elseif ($path -eq "/api/heartbeat") {
            # Fire-and-forget "I'm still here" ping - see $connectedInstalls'
            # own doc comment for the installId/deviceId grouping. No extra
            # Running check needed here - the -not $ServerState.Running
            # branch above already 503s every non-admin path (this one
            # included) while the admin has the server stopped, same as
            # every other app route.
            $installId = [System.Uri]::UnescapeDataString($request.QueryString["installId"])
            $deviceId = [System.Uri]::UnescapeDataString($request.QueryString["deviceId"])
            $speakerName = [System.Uri]::UnescapeDataString($request.QueryString["name"])
            $speakerIp = [System.Uri]::UnescapeDataString($request.QueryString["ip"])
            $isPlaying = $request.QueryString["playing"] -eq "true"
            # X-Forwarded-For (added by ngrok) carries the PHONE's real public
            # IP - $request.RemoteEndPoint here would just be ngrok's own
            # local forwarding connection, not the actual client. A chain of
            # proxies would comma-separate multiple IPs; the first is the
            # original client, which is the one that matters for location.
            $clientIp = $request.Headers["X-Forwarded-For"]
            if ([string]::IsNullOrWhiteSpace($clientIp)) { $clientIp = $request.RemoteEndPoint.Address.ToString() }
            $clientIp = ($clientIp -split ',')[0].Trim()
            Set-ConnectedSpeaker $ConnectedInstalls $installId $deviceId $speakerName $speakerIp $isPlaying $clientIp
            Write-TextResponse $response (ConvertTo-JsonSafe @{ ok = $true }) "application/json"
        }
        elseif ($path -eq "/api/current_stream_url") {
            # This server's own address is now a permanent ngrok static
            # domain, but the STREAM proxy still sits behind a Cloudflare
            # quick tunnel (its plain-http:// answering is required - the
            # speaker's AVTransport rejects https:// CurrentURI values,
            # confirmed via a real UPnP fault against the hardware - and
            # ngrok's free static domain forces https-only, so it can't host
            # this half). Quick tunnels hand out a brand-new random hostname
            # on every restart, which is exactly what broke playback before
            # this endpoint existed (the app's saved Settings URL going
            # stale with no way to notice). Since THIS server's address is
            # now fixed, the app can always reach it to ask "what's the
            # CURRENT stream address" instead of a human re-typing it after
            # every cloudflared restart.
            $streamUrl = $null
            # Two different things start cloudflared with two different
            # redirection schemes, so the live banner can land in either
            # file depending which one launched it last: the admin
            # dashboard's Start-BackendProcess uses Start-Process's native
            # -RedirectStandardOutput/-RedirectStandardError (cloudflared's
            # own INF/ERR banner lines end up in tunnel-stream.err.log
            # there), while setup-autostart.ps1's Scheduled Task wraps it in
            # `*> tunnel-stream.log 2>&1`, merging everything into the
            # non-".err" file instead. Reading only one of them (as this
            # endpoint used to, hard-coded to .err.log) went stale and kept
            # serving an hours-dead hostname the moment the OTHER path was
            # the one that last started the tunnel - confirmed directly
            # 2026-07-25, the exact cause of the app being handed a dead
            # trycloudflare.com URL even after the tunnel itself was healthy
            # again. Checking both and trusting whichever file was actually
            # written to most recently is what actually stays correct
            # regardless of which of the two ever launches cloudflared next.
            $candidates = @($TunnelStreamLogPath, ($TunnelStreamLogPath -replace '\.err\.log$', '.log')) |
                Where-Object { Test-Path $_ } |
                Sort-Object { (Get-Item $_).LastWriteTimeUtc } -Descending
            foreach ($candidate in $candidates) {
                $found = Select-String -Path $candidate -Pattern "https://[a-z0-9-]+\.trycloudflare\.com" -AllMatches
                if ($found) {
                    $lastUrl = $found[-1].Matches[-1].Value
                    $streamUrl = $lastUrl -replace '^https://', 'http://'
                    break
                }
            }
            Write-TextResponse $response (ConvertTo-JsonSafe @{ streamProxyUrl = $streamUrl }) "application/json"
        }
        elseif ($path -eq "/api/ai_chat") {
            $q = [System.Uri]::UnescapeDataString($request.QueryString["q"])
            # Optional JSON array of prior turns ([{"role":"user"|"model","text":"..."}]) -
            # lets Gemini resolve references like "yung number 2" or "sige, patugtugin
            # mo na" back to whatever it suggested earlier in THIS conversation, instead
            # of every message being evaluated with no memory of what came before.
            $historyRaw = $request.QueryString["history"]
            $history = @()
            if (-not [string]::IsNullOrWhiteSpace($historyRaw)) {
                try {
                    $decodedHistory = [System.Uri]::UnescapeDataString($historyRaw) | ConvertFrom-Json
                    if ($decodedHistory) { $history = @($decodedHistory) }
                } catch {
                    # Malformed history from an old/mismatched client build - carry on
                    # with no history rather than failing the whole request over it.
                }
            }
            if ([string]::IsNullOrWhiteSpace($GeminiApiKey)) {
                Write-TextResponse $response (ConvertTo-JsonSafe @{ reply = "AI assistant hasn't been set up yet - add your Gemini API key to gemini-config.json on the server."; action = "none" }) "application/json"
            } else {
                try {
                    $decision = Invoke-GeminiChat $q $GeminiApiKey $history
                    $payload = @{
                        reply          = $decision.reply
                        replyLanguage  = $decision.replyLanguage
                        action         = $decision.action
                        source         = $null
                        result         = $null
                        results        = $null
                        volumeLevel    = $decision.volumeLevel
                        volumeDelta    = $decision.volumeDelta
                        transportKey   = $decision.transportKey
                        presetNum      = $decision.presetNum
                        playlistName   = $null
                        playlistTracks = $null
                        playlistOrder  = $decision.playlistOrder
                        playlistRepeat = $decision.playlistRepeat
                        alarmHour      = $decision.alarmHour
                        alarmMinute    = $decision.alarmMinute
                        alarmDays      = $decision.alarmDays
                    }
                    if (($decision.action -eq "play" -or $decision.action -eq "search") -and $decision.source -and $decision.query) {
                        # "play" only ever needs the single best hit; "search" shows a
                        # tappable shortlist instead of committing to anything - same
                        # underlying search call either way, just how many of its
                        # results actually reach the app.
                        $wantCount = if ($decision.action -eq "search") { 5 } else { 1 }
                        # Wrapped in @(...) - confirmed live (2026-07-23): PowerShell
                        # silently unwraps a 1-element array into a bare scalar object
                        # across a function-return/switch-output boundary, and a bare
                        # object has no .Count property at all, so the check right
                        # below was evaluating to false for EVERY successful "play"
                        # search (which always asks for exactly 1 result) - action
                        # "play" was silently self-downgrading to "none" with a fake
                        # "couldn't find a matching result" reply on every single
                        # request that actually found something. @(...) forces real
                        # array semantics regardless of how many elements come back.
                        $searchResults = @(switch ($decision.source) {
                            "youtube"    { Search-YouTube $decision.query $wantCount }
                            "radio"      { Search-TuneIn $decision.query }
                            "soundcloud" { Search-SoundCloud $decision.query $SoundCloudClientId $SoundCloudOAuthToken $wantCount }
                        })
                        if ($searchResults.Count -gt 0) {
                            $payload.source = $decision.source
                            if ($decision.action -eq "search") {
                                $payload.results = @($searchResults | Select-Object -First 5)
                            } else {
                                $payload.result = $searchResults[0]
                            }
                        } else {
                            # Gemini wanted to play/search but the actual lookup came up
                            # empty (e.g. SoundCloud not configured, or an odd query) -
                            # downgrade to a plain reply rather than telling the app to
                            # act on a result that doesn't exist.
                            $payload.action = "none"
                            $payload.reply = "$($decision.reply) (I couldn't find a matching result - try rephrasing that.)"
                        }
                    }
                    elseif ($decision.action -eq "create_playlist" -and $decision.playlistName -and $decision.trackQueries) {
                        # Gemini names concrete songs by search phrase, not real track
                        # IDs (it has no access to the actual catalog) - resolve each
                        # phrase to a real YouTube hit server-side, same as any other
                        # search, then hand the app a ready-to-save list. One track can
                        # legitimately fail to resolve (an odd/unavailable phrase) without
                        # sinking the whole playlist - just fewer tracks than asked for.
                        $resolvedTracks = @()
                        foreach ($trackQuery in @($decision.trackQueries)) {
                            # Same @(...)-wrap fix as the play/search branch above - a
                            # 1-result Search-YouTube call unwraps to a bare object
                            # otherwise, and $hit.Count silently reads as $null.
                            $hit = @(Search-YouTube $trackQuery 1)
                            if ($hit.Count -gt 0) { $resolvedTracks += $hit[0] }
                        }
                        if ($resolvedTracks.Count -gt 0) {
                            $payload.playlistName = $decision.playlistName
                            $payload.playlistTracks = $resolvedTracks
                        } else {
                            $payload.action = "none"
                            $payload.reply = "$($decision.reply) (I couldn't find any of those tracks - try naming a few differently.)"
                        }
                    }
                    elseif ($decision.action -eq "set_alarm" -and $null -ne $decision.alarmHour -and $null -ne $decision.alarmMinute) {
                        # The time/days fields are already copied onto $payload above
                        # unconditionally - this branch only needs to resolve an
                        # OPTIONAL wake-up song, exactly like the play/search branch,
                        # same @(...)-wrap fix for the same single-result unwrap issue.
                        # No song requested at all is a completely valid alarm (the
                        # app just resumes whatever was last playing), so a missing
                        # query here is not an error condition the way it is for play.
                        if ($decision.source -and $decision.query) {
                            $alarmSearchResults = @(switch ($decision.source) {
                                "youtube"    { Search-YouTube $decision.query 1 }
                                "radio"      { Search-TuneIn $decision.query }
                                "soundcloud" { Search-SoundCloud $decision.query $SoundCloudClientId $SoundCloudOAuthToken 1 }
                            })
                            if ($alarmSearchResults.Count -gt 0) {
                                $payload.source = $decision.source
                                $payload.result = $alarmSearchResults[0]
                            }
                            # No else/downgrade here unlike play/search - an alarm with
                            # an unresolvable song still sets a perfectly good alarm,
                            # just without a specific wake-up track.
                        }
                    }
                    # "play_playlist" needs no server-side lookup at all - playlistOrder/
                    # playlistRepeat (already copied onto $payload above) are the only
                    # fields it carries; the app resolves "which playlist" from its own
                    # locally-tracked "last one the AI created" state.
                    Write-TextResponse $response (ConvertTo-JsonSafe $payload) "application/json"
                } catch {
                    $response.StatusCode = 500
                    $errMsg = $_.Exception.Message
                    # A 429 survived Invoke-GeminiChat's own retries above - the free
                    # tier's per-minute quota is genuinely exhausted right now, not a
                    # real failure. Say that plainly instead of leaking the raw
                    # ".NET WebException" text, which reads like a broken feature
                    # rather than "wait a few seconds."
                    $friendlyReply = if ($errMsg -like "*429*" -or $errMsg -like "*Too Many Requests*") {
                        "I'm getting a lot of requests right now - give me about a minute and try again."
                    } else {
                        "Something went wrong talking to the AI assistant: $errMsg"
                    }
                    Write-TextResponse $response (ConvertTo-JsonSafe @{ reply = $friendlyReply; action = "none" }) "application/json"
                }
            }
        }
        elseif ($path -eq "/admin") {
            $html = [System.IO.File]::ReadAllText($AdminHtmlPath, [System.Text.Encoding]::UTF8)
            Write-TextResponse $response $html "text/html"
        }
        elseif ($path -eq "/api/admin/status") {
            $logEntries = $ActivityLog.ToArray()
            [Array]::Reverse($logEntries)
            Remove-StaleInstalls $ConnectedInstalls
            $now = Get-Date
            # 15 minutes = 3 missed heartbeats (the app pings every 5) before
            # a speaker flips to "Offline" here - long enough that one slow/
            # dropped request doesn't flicker it, short enough to still mean
            # something ("recently seen", not "seen at some point ever").
            $staleAfter = [TimeSpan]::FromMinutes(15)
            $installsList = @(
                $ConnectedInstalls.Values | Sort-Object lastSeen -Descending | ForEach-Object {
                    $inst = $_
                    $speakersList = @(
                        $inst.speakers.Values | Sort-Object lastSeen -Descending | ForEach-Object {
                            $online = ($now - $_.lastSeen) -lt $staleAfter
                            $logArr = @($_.log.ToArray())
                            [Array]::Reverse($logArr)
                            [PSCustomObject]@{
                                deviceId    = $_.deviceId
                                speakerName = $_.speakerName
                                speakerIp   = $_.speakerIp
                                firstSeen   = $_.firstSeen.ToString("MM/dd HH:mm")
                                isOnline    = $online
                                # Never "playing" once offline - a stale
                                # isPlaying=true from the last heartbeat
                                # before it went quiet would otherwise say
                                # "still playing" for up to 24h.
                                isPlaying   = ($online -and $_.isPlaying)
                                log         = $logArr
                            }
                        }
                    )
                    [PSCustomObject]@{
                        installId    = $inst.installId
                        location     = $inst.location
                        firstSeen    = $inst.firstSeen.ToString("MM/dd HH:mm")
                        speakerCount = $speakersList.Count
                        onlineCount  = @($speakersList | Where-Object { $_.isOnline }).Count
                        playingCount = @($speakersList | Where-Object { $_.isPlaying }).Count
                        speakers     = $speakersList
                    }
                }
            )
            $payload = @{ installs = $installsList; log = $logEntries; serverRunning = $ServerState.Running } | ConvertTo-Json -Compress -Depth 6
            Write-TextResponse $response $payload "application/json"
        }
        elseif ($path -eq "/api/admin/toggle") {
            $action = $request.QueryString["action"]
            if ($action -eq "start") {
                $ServerState.Running = $true
                Add-ActivityLogEntry $ActivityLog "-" "server_start" "ok" "Started via admin dashboard"
            } elseif ($action -eq "stop") {
                $ServerState.Running = $false
                Add-ActivityLogEntry $ActivityLog "-" "server_stop" "ok" "Stopped via admin dashboard"
            }
            Write-TextResponse $response (@{ serverRunning = $ServerState.Running } | ConvertTo-Json -Compress) "application/json"
        }
        elseif ($path -eq "/api/admin/processes") {
            $payload = @{ processes = @(Get-BackendProcessStatuses) } | ConvertTo-Json -Compress -Depth 5
            Write-TextResponse $response $payload "application/json"
        }
        elseif ($path -eq "/api/admin/start_process") {
            $procName = $request.QueryString["name"]
            $known = @("stream-proxy", "preset-listener", "tunnel-search", "tunnel-stream")
            if ($known -contains $procName) {
                Start-BackendProcess $procName $ScriptRoot
                Add-ActivityLogEntry $ActivityLog "-" "process_start" "ok" "Started $procName via admin dashboard"
                # Give the process a moment to actually bind/register before
                # reporting status back - immediately re-checking would almost
                # always still show "not running yet" and make the button look
                # like it did nothing.
                Start-Sleep -Milliseconds 1500
            }
            $payload = @{ processes = @(Get-BackendProcessStatuses) } | ConvertTo-Json -Compress -Depth 5
            Write-TextResponse $response $payload "application/json"
        }
        elseif ($path -eq "/api/admin/heal_now") {
            $results = @(Invoke-BackendHeal $ActivityLog $ScriptRoot "the Check & Fix All button")
            $payload = @{ results = $results; processes = @(Get-BackendProcessStatuses) } | ConvertTo-Json -Compress -Depth 6
            Write-TextResponse $response $payload "application/json"
        }
        else {
            $response.StatusCode = 404
            Write-TextResponse $response "Not found"
        }
    } catch {
        $response.StatusCode = 500
        try { Write-TextResponse $response ("ERROR: " + $_.Exception.Message) } catch {}
    } finally {
        try { $response.OutputStream.Close() } catch {}
    }
}

# Background self-heal loop - the "prevent it in the first place" half of
# 2026-07-28's cloudflared-stuck-alive incident (the on-demand /api/admin/heal_now
# button above is the "let me check right now" half; both call the exact same
# Invoke-BackendHeal so they can never drift apart). Runs in its own dedicated
# single-slot runspace pool, separate from $restPool below, so a burst of real
# HTTP traffic can never starve or delay it. Redefines the same health/heal
# functions as $restHandlerScript above - runspaces don't inherit the parent
# script's function scope, same reason every REST handler function is
# redefined inside that scriptblock too.
$healScript = {
    param($ActivityLog, $ScriptRoot)

    function Test-NamedScriptRunning {
        param([string]$Pattern)
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -notmatch '-NonInteractive' -and $_.CommandLine -match $Pattern }
        return (@($procs)).Count -gt 0
    }

    function Test-ExeRunning {
        param([string]$ExeName)
        return $null -ne (Get-Process -Name $ExeName -ErrorAction SilentlyContinue)
    }

    function Start-BackendProcess {
        param([string]$Name, [string]$Root)
        switch ($Name) {
            "stream-proxy" {
                Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root "stream-proxy.ps1")) `
                    -RedirectStandardOutput (Join-Path $Root "stream-proxy.log") -RedirectStandardError (Join-Path $Root "stream-proxy.err.log") -WindowStyle Hidden
            }
            "preset-listener" {
                Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root "preset-listener.ps1"), '-SpeakerIp', '192.168.1.9') `
                    -RedirectStandardOutput (Join-Path $Root "preset-listener.log") -RedirectStandardError (Join-Path $Root "preset-listener.err.log") -WindowStyle Hidden
            }
            "tunnel-search" {
                Start-Process ngrok -ArgumentList @('http', '--url=https://slush-epileptic-dipper.ngrok-free.dev', '--host-header=rewrite', '7000', '--log=stdout') `
                    -RedirectStandardOutput (Join-Path $Root "ngrok-tunnel.log") -RedirectStandardError (Join-Path $Root "ngrok-tunnel.err.log") -WindowStyle Hidden
            }
            "tunnel-stream" {
                Start-Process (Join-Path $Root "tools\cloudflared.exe") -ArgumentList @('tunnel', '--url', 'http://localhost:5001', '--protocol', 'http2') `
                    -RedirectStandardOutput (Join-Path $Root "tunnel-stream.log") -RedirectStandardError (Join-Path $Root "tunnel-stream.err.log") -WindowStyle Hidden
            }
        }
    }

    function Stop-BackendProcess {
        param([string]$Name)
        switch ($Name) {
            "stream-proxy" {
                Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -match 'stream-proxy\.ps1' } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            }
            "preset-listener" {
                Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -match 'preset-listener\.ps1' } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            }
            "tunnel-search" { Get-Process -Name "ngrok" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
            "tunnel-stream" { Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
        }
    }

    function Test-BackendProcessHealth {
        param([string]$Name, [string]$Root)
        switch ($Name) {
            "stream-proxy" {
                if (-not (Test-NamedScriptRunning "stream-proxy\.ps1")) {
                    return [PSCustomObject]@{ running = $false; healthy = $false; detail = "Not running" }
                }
                try {
                    Invoke-WebRequest -Uri "http://localhost:5001/" -Method Head -TimeoutSec 4 -UseBasicParsing | Out-Null
                    return [PSCustomObject]@{ running = $true; healthy = $true; detail = "Responding on :5001" }
                } catch {
                    if ($_.Exception.Response) {
                        return [PSCustomObject]@{ running = $true; healthy = $true; detail = "Responding on :5001 (HTTP $([int]$_.Exception.Response.StatusCode))" }
                    }
                    return [PSCustomObject]@{ running = $true; healthy = $false; detail = "Not answering on :5001 - $($_.Exception.Message)" }
                }
            }
            "preset-listener" {
                $running = Test-NamedScriptRunning "preset-listener\.ps1"
                return [PSCustomObject]@{ running = $running; healthy = $running; detail = $(if ($running) { "Running" } else { "Not running" }) }
            }
            "tunnel-search" {
                if (-not (Test-ExeRunning "ngrok")) {
                    return [PSCustomObject]@{ running = $false; healthy = $false; detail = "Not running" }
                }
                try {
                    $tunnels = Invoke-RestMethod -Uri "http://localhost:4040/api/tunnels" -TimeoutSec 4
                    $ok = @($tunnels.tunnels).Count -gt 0
                    return [PSCustomObject]@{ running = $true; healthy = $ok; detail = $(if ($ok) { "Tunnel registered" } else { "No active tunnel registered" }) }
                } catch {
                    return [PSCustomObject]@{ running = $true; healthy = $false; detail = "ngrok local API (:4040) unreachable - $($_.Exception.Message)" }
                }
            }
            "tunnel-stream" {
                if (-not (Test-ExeRunning "cloudflared")) {
                    return [PSCustomObject]@{ running = $false; healthy = $false; detail = "Not running" }
                }
                $logPath = Join-Path $Root "tunnel-stream.err.log"
                $altLogPath = Join-Path $Root "tunnel-stream.log"
                $candidates = @($logPath, $altLogPath) | Where-Object { Test-Path $_ } | Sort-Object { (Get-Item $_).LastWriteTimeUtc } -Descending
                $hostUrl = $null
                foreach ($candidate in $candidates) {
                    $found = Select-String -Path $candidate -Pattern "https://[a-z0-9-]+\.trycloudflare\.com" -AllMatches
                    if ($found) { $hostUrl = $found[-1].Matches[-1].Value; break }
                }
                if (-not $hostUrl) {
                    return [PSCustomObject]@{ running = $true; healthy = $false; detail = "No tunnel URL found in logs yet" }
                }
                try {
                    $r = Invoke-WebRequest -Uri $hostUrl -Method Head -TimeoutSec 6 -UseBasicParsing
                    return [PSCustomObject]@{ running = $true; healthy = $true; detail = "Reachable ($hostUrl, HTTP $([int]$r.StatusCode))" }
                } catch {
                    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -lt 500) {
                        return [PSCustomObject]@{ running = $true; healthy = $true; detail = "Reachable ($hostUrl, HTTP $([int]$_.Exception.Response.StatusCode))" }
                    }
                    return [PSCustomObject]@{ running = $true; healthy = $false; detail = "$hostUrl not reachable - tunnel is likely dead ($($_.Exception.Message))" }
                }
            }
        }
    }

    function Add-ActivityLogEntry {
        param($Queue, [string]$Code, [string]$Action, [string]$Status, [string]$Detail = "")
        $Queue.Enqueue([PSCustomObject]@{
            time   = (Get-Date).ToString("HH:mm:ss")
            code   = $Code
            action = $Action
            status = $Status
            detail = $Detail
        })
        $dummy = $null
        while ($Queue.Count -gt 300) { $Queue.TryDequeue([ref]$dummy) | Out-Null }
    }

    function Invoke-BackendHeal {
        param($ActivityLog, [string]$Root, [string]$Source = "background self-heal")
        $names = @("stream-proxy", "preset-listener", "tunnel-search", "tunnel-stream")
        foreach ($name in $names) {
            $health = Test-BackendProcessHealth $name $Root
            if ($health.healthy) { continue }
            if ($health.running) { Stop-BackendProcess $name; Start-Sleep -Milliseconds 500 }
            Start-BackendProcess $name $Root
            Start-Sleep -Seconds 2
            $after = Test-BackendProcessHealth $name $Root
            Add-ActivityLogEntry $ActivityLog "-" "auto_heal" $(if ($after.healthy) { "ok" } else { "error" }) "$name was unhealthy ($($health.detail)) - restarted via $Source, now: $($after.detail)"
        }
    }

    # 90s: frequent enough that a dead tunnel/proxy doesn't sit broken for
    # long unnoticed, but far enough apart that the deep checks (several
    # real HTTP round-trips per pass) never come close to competing with
    # real request traffic for anything. Each pass's own errors are
    # swallowed - a single bad tick (e.g. a transient network blip) must
    # never kill this loop, since there'd be nothing left to recover the
    # NEXT time something actually breaks.
    while ($true) {
        try { Invoke-BackendHeal $ActivityLog $ScriptRoot "background self-heal" } catch {}
        Start-Sleep -Seconds 90
    }
}
$healPool = [runspacefactory]::CreateRunspacePool(1, 1)
$healPool.Open()
$healPs = [powershell]::Create()
$healPs.RunspacePool = $healPool
[void]$healPs.AddScript($healScript).AddArgument($activityLog).AddArgument($scriptRoot)
$healHandle = $healPs.BeginInvoke()
Write-Output "Background self-heal loop started (checks every 90s)."

$restPool = [runspacefactory]::CreateRunspacePool(1, 8)
$restPool.Open()
$pendingRest = New-Object System.Collections.Generic.List[object]

while ($listener.IsListening) {
    $context = $listener.GetContext()

    $ps = [powershell]::Create()
    $ps.RunspacePool = $restPool
    [void]$ps.AddScript($restHandlerScript).AddArgument($context).AddArgument($activityLog).AddArgument($serverState).AddArgument($ytDlpPath).AddArgument($adminHtmlPath).AddArgument($ListenPort).AddArgument($AdminPort).AddArgument($SoundCloudClientId).AddArgument($SoundCloudOAuthToken).AddArgument($GeminiApiKey).AddArgument($tunnelStreamLogPath).AddArgument($scriptRoot).AddArgument($connectedInstalls)
    $outBuffer = New-Object System.Management.Automation.PSDataCollection[psobject]
    $handle = $ps.BeginInvoke($outBuffer, $outBuffer)
    $pendingRest.Add([PSCustomObject]@{ PS = $ps; Handle = $handle; Out = $outBuffer })

    for ($i = $pendingRest.Count - 1; $i -ge 0; $i--) {
        if ($pendingRest[$i].Handle.IsCompleted) {
            foreach ($line in $pendingRest[$i].Out) { Write-Output $line }
            try { $pendingRest[$i].PS.EndInvoke($pendingRest[$i].Handle) } catch {}
            $pendingRest[$i].PS.Dispose()
            $pendingRest.RemoveAt($i)
        }
    }
}
