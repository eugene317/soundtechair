param(
    [int]$ListenPort = 7000,
    [int]$AdminPort = 7001,
    [string]$OnlineServerIp = "192.168.1.8",
    [int]$StreamProxyPort = 5001
)

$ytDlpPath = Join-Path $PSScriptRoot "yt-dlp.exe"
$htmlPath = Join-Path $PSScriptRoot "index.html"
$panelImgPath = Join-Path $PSScriptRoot "panel.png"
$adminHtmlPath = Join-Path $PSScriptRoot "admin.html"

# Shared state across all runspaces spawned below. These are real .NET reference
# types, so every runspace that receives the same object instance observes the
# same underlying data - this is what lets REST-handler runspaces and per-agent
# reader runspaces coordinate without fighting over PowerShell scope rules.
$agentRegistry = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
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

# --- Per-agent WebSocket reader: one dedicated runspace per connected Local App. ---
# Deliberately NOT part of the bounded REST pool below - a read loop blocks its
# thread for the agent's whole connection lifetime, and mixing that with the pool
# used for quick REST handlers would starve REST handling once a few agents connect.
$agentReaderScript = {
    param($WsContext, $Code, $SpeakerIp, $SpeakerName, $AgentRegistry, $ActivityLog)

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

    $entry = [PSCustomObject]@{
        WebSocket   = $WsContext.WebSocket
        SendLock    = New-Object System.Object
        Replies     = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
        SpeakerIp   = $SpeakerIp
        SpeakerName = $SpeakerName
        ConnectedAt = Get-Date
        IsOnline    = $true
    }
    # Overwrite (not remove-then-add) so a reconnecting agent replaces its own stale
    # entry in place; entries are never removed here, only flipped offline, so the
    # admin dashboard can keep showing an agent's last-known info after it disconnects.
    $AgentRegistry[$Code] = $entry
    Add-ActivityLogEntry $ActivityLog $Code "connect" "ok" "$SpeakerName ($SpeakerIp)"

    $buffer = New-Object byte[] 65536
    try {
        while ($entry.WebSocket.State -eq 'Open') {
            $ct = [System.Threading.CancellationToken]::None
            $result = $entry.WebSocket.ReceiveAsync([System.ArraySegment[byte]]::new($buffer), $ct).GetAwaiter().GetResult()
            if ($result.Count -eq 0) { continue }
            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
            try {
                $reply = $text | ConvertFrom-Json
                $entry.Replies[$reply.id] = $reply
            } catch {}
        }
    } catch {
    } finally {
        # Only flip our own entry offline - if a newer connection for this code has
        # already replaced it (reconnect raced with this loop noticing its own close),
        # leave that newer entry alone.
        $current = $null
        if ($AgentRegistry.TryGetValue($Code, [ref]$current) -and [object]::ReferenceEquals($current, $entry)) {
            $entry.IsOnline = $false
        }
        Add-ActivityLogEntry $ActivityLog $Code "disconnect" "info" ""
    }
}

# --- REST handler body, run through a small bounded runspace pool (same proven
# pattern as stream-proxy.ps1's concurrency fix). Redefines its own copies of every
# helper function, since runspaces don't inherit the parent script's function scope. ---
$restHandlerScript = {
    param($Context, $AgentRegistry, $ActivityLog, $ServerState, $YtDlpPath, $HtmlPath, $PanelImgPath, $AdminHtmlPath, $OnlineServerIp, $StreamProxyPort, $ListenPort, $AdminPort)

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
        $raw = & $YtDlpPath "ytsearch${Count}:$Query" --flat-playlist --print "%(title)s|||%(id)s" --no-warnings 2>$null
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

    function Send-AgentCommand {
        param($AgentEntry, [string]$Code, $ActivityLog, [string]$Action, $Params, [int]$TimeoutMs = 8000)
        $id = [guid]::NewGuid().ToString()
        $msg = @{ id = $id; action = $Action; params = $Params } | ConvertTo-Json -Compress -Depth 5
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
        $seg = [System.ArraySegment[byte]]::new($bytes)
        $ct = [System.Threading.CancellationToken]::None

        [System.Threading.Monitor]::Enter($AgentEntry.SendLock)
        try {
            $AgentEntry.WebSocket.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).GetAwaiter().GetResult() | Out-Null
        } finally {
            [System.Threading.Monitor]::Exit($AgentEntry.SendLock)
        }

        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        $reply = $null
        while ((Get-Date) -lt $deadline) {
            if ($AgentEntry.Replies.TryRemove($id, [ref]$reply)) {
                if ($reply.ok -eq $false) {
                    Add-ActivityLogEntry $ActivityLog $Code $Action "error" $reply.error
                } else {
                    Add-ActivityLogEntry $ActivityLog $Code $Action "ok" ($Params | ConvertTo-Json -Compress)
                }
                return $reply
            }
            Start-Sleep -Milliseconds 25
        }
        $AgentEntry.Replies.TryRemove($id, [ref]$reply) | Out-Null
        Add-ActivityLogEntry $ActivityLog $Code $Action "timeout" ""
        throw "TIMEOUT waiting for agent reply"
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
            # port, nothing app-related (search, play, presets) is reachable on it.
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
        elseif ($path -eq "/") {
            $html = [System.IO.File]::ReadAllText($HtmlPath, [System.Text.Encoding]::UTF8)
            Write-TextResponse $response $html "text/html"
        }
        elseif ($path -eq "/panel.png") {
            $bytes = [System.IO.File]::ReadAllBytes($PanelImgPath)
            $response.ContentType = "image/png"
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
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
            $agents = @()
            foreach ($kv in $AgentRegistry.GetEnumerator()) {
                $agents += [PSCustomObject]@{
                    code        = $kv.Key
                    speakerName = $kv.Value.SpeakerName
                    speakerIp   = $kv.Value.SpeakerIp
                    connectedAt = $kv.Value.ConnectedAt.ToString("yyyy-MM-dd HH:mm:ss")
                    isOnline    = $kv.Value.IsOnline
                }
            }
            $logEntries = $ActivityLog.ToArray()
            [Array]::Reverse($logEntries)
            $payload = @{ agents = $agents; log = $logEntries; serverRunning = $ServerState.Running } | ConvertTo-Json -Compress -Depth 5
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
            $code = $request.Headers["X-Pairing-Code"]
            $agentEntry = $null
            if (-not $code -or -not $AgentRegistry.TryGetValue($code, [ref]$agentEntry)) {
                $response.StatusCode = 401
                Write-TextResponse $response "Unauthorized: missing or unknown pairing code"
            } elseif (-not $agentEntry.IsOnline) {
                $response.StatusCode = 503
                Write-TextResponse $response "Local App is offline"
            } else {
                try {
                    $result = $null
                    if ($path -eq "/api/key") {
                        $result = Send-AgentCommand $agentEntry $code $ActivityLog "key" @{ cmd = $request.QueryString["cmd"] }
                    }
                    elseif ($path -eq "/api/volume") {
                        $result = Send-AgentCommand $agentEntry $code $ActivityLog "volume" @{ level = $request.QueryString["level"] }
                    }
                    elseif ($path -eq "/api/now_playing") {
                        $result = Send-AgentCommand $agentEntry $code $ActivityLog "now_playing" @{}
                    }
                    elseif ($path -eq "/api/volume_status") {
                        $result = Send-AgentCommand $agentEntry $code $ActivityLog "volume_status" @{}
                    }
                    elseif ($path -eq "/api/presets_list") {
                        $result = Send-AgentCommand $agentEntry $code $ActivityLog "presets_list" @{}
                    }
                    elseif ($path -eq "/api/play") {
                        $url = [System.Uri]::UnescapeDataString($request.QueryString["url"])
                        $result = Send-AgentCommand $agentEntry $code $ActivityLog "play" @{ url = $url }
                    }
                    elseif ($path -eq "/api/stop") {
                        $result = Send-AgentCommand $agentEntry $code $ActivityLog "stop" @{}
                    }
                    elseif ($path -eq "/api/save_preset") {
                        $result = Send-AgentCommand $agentEntry $code $ActivityLog "save_preset" @{ num = $request.QueryString["num"] } -TimeoutMs 12000
                    }
                    elseif ($path -eq "/api/preset_play") {
                        $result = Send-AgentCommand $agentEntry $code $ActivityLog "preset_play" @{ num = $request.QueryString["num"] }
                    }
                    elseif ($path -eq "/api/select_source") {
                        $result = Send-AgentCommand $agentEntry $code $ActivityLog "select_source" @{ source = $request.QueryString["source"] }
                    }
                    elseif ($path -eq "/api/yt_play") {
                        $id = $request.QueryString["id"]
                        $url = "http://${OnlineServerIp}:${StreamProxyPort}/stream/$id.mp3"
                        $result = Send-AgentCommand $agentEntry $code $ActivityLog "play" @{ url = $url }
                    }
                    elseif ($path -eq "/api/radio_play") {
                        $id = $request.QueryString["id"]
                        $url = "http://${OnlineServerIp}:${StreamProxyPort}/radio/$id.mp3"
                        $result = Send-AgentCommand $agentEntry $code $ActivityLog "play" @{ url = $url }
                    }
                    else {
                        $response.StatusCode = 404
                        $result = "not found"
                    }

                    if ($result -is [string]) {
                        Write-TextResponse $response $result "text/xml"
                    } elseif ($null -ne $result -and $result.ok -eq $false) {
                        $response.StatusCode = 502
                        Write-TextResponse $response ("ERROR: " + $result.error)
                    } elseif ($null -ne $result -and $null -ne $result.result) {
                        Write-TextResponse $response ($result.result | Out-String) "text/xml"
                    } else {
                        Write-TextResponse $response "OK"
                    }
                } catch {
                    $response.StatusCode = 502
                    Write-TextResponse $response ("ERROR: " + $_.Exception.Message)
                }
            }
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

    if ($context.Request.IsWebSocketRequest -and $context.Request.Url.AbsolutePath -eq "/agent-ws") {
        if ($context.Request.Url.Port -eq $AdminPort) {
            $context.Response.StatusCode = 404
            $context.Response.OutputStream.Close()
            Write-Output "Rejected agent connection attempt on admin port"
        } elseif (-not $serverState.Running) {
            $context.Response.StatusCode = 503
            $context.Response.OutputStream.Close()
            Write-Output "Rejected agent connection attempt - server is stopped"
        } else {
        $code = $context.Request.QueryString["code"]
        $speakerIp = $context.Request.QueryString["speakerIp"]
        $speakerName = $context.Request.QueryString["speakerName"]
        try {
            $wsContext = $context.AcceptWebSocketAsync([NullString]::Value).GetAwaiter().GetResult()
            $rs = [runspacefactory]::CreateRunspace()
            $rs.Open()
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript($agentReaderScript).AddArgument($wsContext).AddArgument($code).AddArgument($speakerIp).AddArgument($speakerName).AddArgument($agentRegistry).AddArgument($activityLog)
            [void]$ps.BeginInvoke()
            Write-Output "Agent connected: $code ($speakerName / $speakerIp)"
        } catch {
            Write-Output "WebSocket accept failed: $($_.Exception.Message)"
        }
        }
    }
    else {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $restPool
        [void]$ps.AddScript($restHandlerScript).AddArgument($context).AddArgument($agentRegistry).AddArgument($activityLog).AddArgument($serverState).AddArgument($ytDlpPath).AddArgument($htmlPath).AddArgument($panelImgPath).AddArgument($adminHtmlPath).AddArgument($OnlineServerIp).AddArgument($StreamProxyPort).AddArgument($ListenPort).AddArgument($AdminPort)
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
}
