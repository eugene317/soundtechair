param(
    [int]$ListenPort = 7000,
    [int]$AdminPort = 7001
)

$ytDlpPath = Join-Path $PSScriptRoot "yt-dlp.exe"
$adminHtmlPath = Join-Path $PSScriptRoot "admin.html"

# Shared state across REST-handler runspaces. Real .NET reference types, so every
# runspace that receives the same object instance observes the same underlying data.
$activityLog = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
# Server-wide run/stop switch, toggled from the admin dashboard. A synchronized
# Hashtable (not a plain PS variable) so every runspace that receives this same
# instance observes flips to it immediately.
$serverState = [System.Collections.Hashtable]::Synchronized(@{ Running = $true })

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
    param($Context, $ActivityLog, $ServerState, $YtDlpPath, $AdminHtmlPath, $ListenPort, $AdminPort)

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

    function Search-YouTube {
        param([string]$Query, [int]$Count = 8)
        # Confirmed via direct test (2026-07-17): --flat-playlist DOES include
        # duration for YouTube search results (it's part of the search-results
        # page data, not a full per-video extraction), so this stays fast.
        $raw = & $YtDlpPath "ytsearch${Count}:$Query" --flat-playlist --print "%(title)s|||%(id)s|||%(duration)s" --no-warnings 2>$null
        $results = @()
        foreach ($line in $raw) {
            if ($line -match "^(.*)\|\|\|([^|]+)\|\|\|([^|]+)$") {
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

    function ConvertTo-JsonSafe { param($Data) return ($Data | ConvertTo-Json -Compress) }

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
        $adminPaths = @("/admin", "/api/admin/status", "/api/admin/toggle")
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
        elseif ($path -eq "/admin") {
            $html = [System.IO.File]::ReadAllText($AdminHtmlPath, [System.Text.Encoding]::UTF8)
            Write-TextResponse $response $html "text/html"
        }
        elseif ($path -eq "/api/admin/status") {
            $logEntries = $ActivityLog.ToArray()
            [Array]::Reverse($logEntries)
            # "agents" is kept in the payload shape (always empty) purely so the
            # existing admin.html - left untouched for now, per plan to enhance its
            # UI later - doesn't need changes to keep rendering without errors.
            $payload = @{ agents = @(); log = $logEntries; serverRunning = $ServerState.Running } | ConvertTo-Json -Compress -Depth 5
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

$restPool = [runspacefactory]::CreateRunspacePool(1, 8)
$restPool.Open()
$pendingRest = New-Object System.Collections.Generic.List[object]

while ($listener.IsListening) {
    $context = $listener.GetContext()

    $ps = [powershell]::Create()
    $ps.RunspacePool = $restPool
    [void]$ps.AddScript($restHandlerScript).AddArgument($context).AddArgument($activityLog).AddArgument($serverState).AddArgument($ytDlpPath).AddArgument($adminHtmlPath).AddArgument($ListenPort).AddArgument($AdminPort)
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
