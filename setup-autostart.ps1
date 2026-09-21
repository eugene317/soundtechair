<#
Registers Windows Scheduled Tasks so every backend process this project
needs (relay-server, stream-proxy, preset-listener, and both tunnels)
starts automatically the moment you log into Windows - no manual restart
needed after a PC reboot.

Self-healing during a session (not just at login) comes from giving each
task a SECOND trigger that repeats every 5 minutes forever, combined with
MultipleInstances = IgnoreNew: if the process is still alive, the repeat
trigger is simply skipped (Task Scheduler sees the task "already running"
and no-ops); if it died, the next 5-minute tick starts a fresh one. No
separate supervisor process needed - Task Scheduler's own primitives do
the whole job.

Run this ONCE from an ELEVATED PowerShell ("Run as Administrator") - on
this machine, Register-ScheduledTask itself denies access from a plain,
non-elevated session (confirmed directly, 2026-07-2x), even though the
tasks it creates run the backend scripts as your normal (non-admin) user
- those already work fine unelevated, same as they always have. Re-running
this is safe - each task is re-registered with -Force.
#>

$isElevated = $null -ne (([Security.Principal.WindowsIdentity]::GetCurrent()).Groups | Where-Object { $_.Value -eq 'S-1-5-32-544' })
if (-not $isElevated) {
    Write-Output "This needs to run as Administrator - right-click PowerShell and choose 'Run as Administrator', then run this script again."
    exit 1
}

$root = $PSScriptRoot
$ngrokCmd = Get-Command ngrok -ErrorAction SilentlyContinue
$ngrokPath = if ($ngrokCmd) { $ngrokCmd.Source } else { "ngrok" }

function Register-AutoStartTask {
    param(
        [string]$TaskName,
        [string]$TargetPath,
        [string]$TargetArgs,
        [string]$LogFile
    )
    # Wrapped in a -Command string (built here, in real PowerShell syntax,
    # not passed through any other shell) so log redirection works exactly
    # like every manual `... > log 2>&1` invocation used throughout this
    # project's development - same log files, same shape, just started by
    # Windows instead of a person.
    $inner = "& '$TargetPath' $TargetArgs *> '$LogFile' 2>&1"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$inner`"" `
        -WorkingDirectory $root

    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn
    # -Once + RepetitionInterval/Duration (not -Daily, whose trigger object's
    # .Repetition sub-properties turned out to be read-only/unset here) is
    # the combination that actually produces a working repeating trigger -
    # confirmed directly, 2026-07-2x. [TimeSpan]::MaxValue as the duration
    # was tried first on the theory that Task Scheduler would just cap it to
    # some huge-but-finite value - it doesn't; confirmed directly (2026-07-25)
    # Register-ScheduledTask instead REJECTS it outright ("task XML contains
    # a value which is incorrectly formatted or out of range", the ISO8601
    # duration it serializes to - P99999999DT23H59M59S - exceeds whatever
    # Task Scheduler's XML schema actually allows) - and since that's a
    # non-terminating CimException, the script kept going and printed
    # "Registered: X" for every task regardless, even though NONE of them
    # actually got created. 10 years is comfortably within the schema's real
    # range and, same as the MaxValue attempt, is "forever" for any purpose
    # this project has - nothing here needs to run unattended for a decade
    # without anyone ever re-running this script anyway.
    $healTrigger = New-ScheduledTaskTrigger -Once -At "00:00" `
        -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)

    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

    # -ErrorAction Stop turns Register-ScheduledTask's own non-terminating
    # CimException into one this try/catch actually sees - without it, the
    # exact silent-failure-reported-as-success bug this fixes would still be
    # possible for any OTHER future registration problem, not just the
    # RepetitionDuration one above.
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($logonTrigger, $healTrigger) `
            -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
        Write-Output "Registered: $TaskName"
    } catch {
        Write-Output "FAILED to register $TaskName - $($_.Exception.Message)"
    }
}

Register-AutoStartTask -TaskName "SoundTouch-RelayServer" `
    -TargetPath "$root\relay-server.ps1" -TargetArgs "" -LogFile "$root\relay-server.log"

Register-AutoStartTask -TaskName "SoundTouch-StreamProxy" `
    -TargetPath "$root\stream-proxy.ps1" -TargetArgs "" -LogFile "$root\stream-proxy.log"

Register-AutoStartTask -TaskName "SoundTouch-PresetListener" `
    -TargetPath "$root\preset-listener.ps1" -TargetArgs "-SpeakerIp 192.168.1.9" -LogFile "$root\preset-listener.log"

Register-AutoStartTask -TaskName "SoundTouch-TunnelSearch" `
    -TargetPath $ngrokPath -TargetArgs "http --url=https://slush-epileptic-dipper.ngrok-free.dev --host-header=rewrite 7000 --log=stdout" `
    -LogFile "$root\ngrok-tunnel.log"

Register-AutoStartTask -TaskName "SoundTouch-TunnelStream" `
    -TargetPath "$root\tools\cloudflared.exe" -TargetArgs "tunnel --url http://localhost:5001 --protocol http2" `
    -LogFile "$root\tunnel-stream.log"

Write-Output ""
Write-Output "Done. All 5 will start automatically at your next Windows login,"
Write-Output "and self-heal within 5 minutes if any of them ever crash mid-session."
