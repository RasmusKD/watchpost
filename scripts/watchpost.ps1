param([ValidateSet('On','Off')][string]$Mode)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\lib.ps1"
$cfg = Get-WatchpostConfig

# Everything below needs admin (the camera service + its config under Program Files) - self-elevates with UAC
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $Mode"
  exit
}

$svcName = $cfg.camera.serviceName
if (-not $Mode) {
  # Only a fully stopped service means "off": StartPending/StopPending are a rig mid-flip,
  # and answering On during the slow Off drain would re-arm everything mid-teardown
  $Mode = if ((Get-Service $svcName).Status -eq 'Stopped') { 'On' } else { 'Off' }
}

$ts       = $cfg.tailscale.exe
$caddyExe = $cfg.proxy.caddyExe
$startup  = Join-Path ([Environment]::GetFolderPath('Startup')) 'watchpost-proxy.cmd'

function Start-Proxy {
  # Startup entry so Caddy survives a reboot+login; generated from config, no loose file to maintain
  $lines = "@echo off`r`ncd /d `"$($cfg.proxy.caddyDir)`"`r`n`"$caddyExe`" start --config Caddyfile`r`n"
  Set-Content -LiteralPath $startup -Value $lines -Encoding Ascii
  if (-not (Get-Process caddy -ErrorAction SilentlyContinue)) {
    # Fire-and-poll, never wait on the launcher: `& ... | Out-Null` blocks on the console pipe the
    # detached caddy inherits, and Start-Process -Wait (PS 5.1) waits on descendants, i.e. caddy itself
    Start-Process -FilePath $startup -WindowStyle Hidden
    for ($i = 0; $i -lt 10 -and -not (Get-Process caddy -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
  }
}

if ($Mode -eq 'On') {
  Write-Host ''
  Write-Host '=== TAENDER OVERVAAGNING ===' -ForegroundColor Green

  # The alarm only fires when the camera software is ARMED with the alerting profile; fixed while the service is stopped
  if ((Get-Service $svcName).Status -ne 'Running') {
    # ReadAllText/WriteAllText keep the file's UTF-8 intact: Get/Set-Content on PS 5.1 re-encode
    # a BOM-less file to the ANSI code page and garble non-ASCII camera names
    $raw = [IO.File]::ReadAllText($cfg.camera.configJson)
    $fixed = $raw -replace '"Armed":\s*false', '"Armed": true' -replace '"LastProfileID":\s*\d+', '"LastProfileID": 0'
    if ($fixed -ne $raw) { [IO.File]::WriteAllText($cfg.camera.configJson, $fixed); Write-Host 'camera config: re-armed + profile reset' }
  }
  Remove-Item (Get-SuppressFile) -ErrorAction SilentlyContinue

  Set-Service $svcName -StartupType Automatic
  Start-Service $svcName
  Enable-ScheduledTask -TaskName CamSyncDroplet | Out-Null
  Enable-ScheduledTask -TaskName HuePresence   | Out-Null
  Start-ScheduledTask  -TaskName HuePresence   # run now; freshly enabled tasks can skip their first slot

  Start-Proxy

  # serve is refused in every backend state except Running: Stopped needs 'up', and NoState
  # means the user-session GUI has not connected the profile yet (typical after a reboot),
  # so the GUI gets started too; NeedsLogin cannot be fixed headless and times out to FEJL
  $deadline = (Get-Date).AddSeconds(40)
  do {
    $state = 'unknown'
    try { $state = (& $ts status --json 2>$null | ConvertFrom-Json).BackendState } catch { $state = 'unknown' }
    if ($state -eq 'Running') { break }
    if ($state -eq 'Stopped') { & $ts up 2>&1 | Out-Null }
    elseif (-not (Get-Process tailscale-ipn -ErrorAction SilentlyContinue)) {
      Start-Process (Join-Path (Split-Path $ts) 'tailscale-ipn.exe')
    }
    Start-Sleep 2
  } while ((Get-Date) -lt $deadline)
  & $ts serve --bg $cfg.tailscale.servePort
}
else {
  Write-Host ''
  Write-Host '=== SLUKKER OVERVAAGNING ===' -ForegroundColor Yellow

  # Ask the camera service to stop, then tear the rest down while it drains:
  # flushing open recordings is the slow part of Off, so it never gets waited on up front
  $svc = Get-Service $svcName
  if ($svc.Status -ne 'Stopped') {
    $svc.Stop()
    Write-Host 'Kamera-tjenesten lukker ned i baggrunden (skriver optagelser faerdig)...'
  }
  Set-Service $svcName -StartupType Manual
  Disable-ScheduledTask -TaskName CamSyncDroplet -ErrorAction SilentlyContinue | Out-Null
  Disable-ScheduledTask -TaskName HuePresence   -ErrorAction SilentlyContinue | Out-Null
  & $caddyExe stop 2>$null
  Remove-Item -LiteralPath $startup -ErrorAction SilentlyContinue
  # reset clears every serve mapping on the machine: fine here, the rig owns tailscale serve on this box
  & $ts serve reset 2>$null
  Remove-Item (Get-SuppressFile) -ErrorAction SilentlyContinue
  try { $svc.WaitForStatus('Stopped', '00:00:45') } catch [System.ServiceProcess.TimeoutException] {
    Write-Host 'Kamera-tjenesten er usaedvanligt laenge om at stoppe' -ForegroundColor Yellow
  }
}

# ---- Status report ----
Start-Sleep 2
$svc   = (Get-Service $svcName).Status
$sync  = (Get-ScheduledTask CamSyncDroplet -ErrorAction SilentlyContinue).State
$hue   = (Get-ScheduledTask HuePresence -ErrorAction SilentlyContinue).State
$prx   = if (Get-Process caddy -ErrorAction SilentlyContinue) { 'koerer' } else { 'stoppet' }
$serve = (& $ts serve status 2>&1 | Out-String).Trim()
# match OUR mapping, not any proxy: a stale serve entry for another port must not read as live
$live  = if ($serve -match "127\.0\.0\.1:$($cfg.tailscale.servePort)") { 'TIL' } else { 'FRA' }

Write-Host ''
Write-Host "Kamera:            $svc"
Write-Host "Synk (backup):     $sync"
Write-Host "Lys-simulation:    $hue"
Write-Host "Proxy (Caddy):     $prx"
Write-Host "Live-link:         $live"
Write-Host ''

if ($Mode -eq 'On') {
  # Arming only happens while the service is stopped (the camera software overwrites config edits
  # made while it runs), so a service that was ALREADY running may still be disarmed: read the
  # config back instead of assuming, and let the receipt say so
  $armed = $false
  try { $armed = ([IO.File]::ReadAllText($cfg.camera.configJson) -notmatch '"Armed":\s*false') } catch {}
  if (-not $armed) { Write-Host 'Kameraet er IKKE armed - sluk og taend igen' -ForegroundColor Red }
  # a missing task reads as $null, which 'not Disabled' would count as healthy
  $ok = ($svc -eq 'Running' -and $armed -and $sync -in 'Ready','Running' -and $hue -in 'Ready','Running' -and $prx -eq 'koerer' -and $live -eq 'TIL')
  if ($ok) {
    Write-Host 'ALT KOERER - god tur!' -ForegroundColor Green
    Send-Discord $cfg (Expand-Message $cfg $cfg.messages.on)
  } else {
    Write-Host 'NOGET FEJLEDE - se status ovenfor!' -ForegroundColor Red
    Send-Discord $cfg "$($cfg.messages.onFailed) Status: kamera=$svc armed=$armed synk=$sync lys=$hue proxy=$prx live=$live"
  }
} else {
  Write-Host 'Overvaagning er slukket.' -ForegroundColor Yellow
  Send-Discord $cfg (Expand-Message $cfg $cfg.messages.off)
}

Start-Sleep 6
