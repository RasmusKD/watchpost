# One-time install. Interactive: prompts for every value, pairs with the Hue bridge,
# registers the scheduled tasks and puts the toggle shortcut on the desktop.
# Re-runnable: existing config.json values are offered as defaults.
# -TasksOnly registers just the scheduled tasks and skips every prompt: used by the elevated
# relaunch below, and by unattended installs that build config.json themselves (see AGENTS.md).
param([switch]$TasksOnly)
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

function Register-WatchpostTasks {
  $user = "$env:USERDOMAIN\$env:USERNAME"
  $principal = New-ScheduledTaskPrincipal -UserId $user -RunLevel Highest -LogonType Interactive
  foreach ($t in @(@{N='CamRigOn'; A='On'}, @{N='CamRigOff'; A='Off'})) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
      -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$repo\scripts\watchpost.ps1`" $($t.A)"
    Register-ScheduledTask -TaskName $t.N -Action $action -Principal $principal -Force | Out-Null
  }
  $every5 = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
  foreach ($t in @('cam-sync.ps1', 'hue-presence.ps1')) {
    $name = if ($t -eq 'cam-sync.ps1') { 'CamSyncDroplet' } else { 'HuePresence' }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$repo\scripts\$t`""
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $every5 -Force | Out-Null
    Disable-ScheduledTask -TaskName $name | Out-Null   # the toggle enables them
  }
  Write-Host 'Tasks registered: CamRigOn, CamRigOff, CamSyncDroplet, HuePresence (last two start disabled).'
}

if ($TasksOnly) { Register-WatchpostTasks; return }

function Ask([string]$question, [string]$default) {
  $suffix = if ($default) { " [$default]" } else { '' }
  $answer = Read-Host "$question$suffix"
  if ($answer) { $answer } else { $default }
}

# ---- Collect config ----
$existing = $null
if (Test-Path "$repo\config.json") { $existing = Get-Content "$repo\config.json" -Raw | ConvertFrom-Json }
$cfg = if ($existing) { $existing } else { Get-Content "$repo\config.example.json" -Raw | ConvertFrom-Json }

Write-Host "`n=== watchpost setup ===" -ForegroundColor Cyan
$cfg.liveUrl = Ask 'Tailscale live URL (https://<pc>.<tailnet>.ts.net)' $cfg.liveUrl
$cfg.discord.webhookUrl = Ask 'Discord webhook URL (empty = no alerts)' $cfg.discord.webhookUrl
$cfg.discord.mention = Ask 'Discord mention, e.g. <@123456789> (empty = none)' $cfg.discord.mention
$cfg.camera.serviceName = Ask 'Camera Windows service name' $cfg.camera.serviceName
$cfg.camera.configJson = Ask 'Camera config.json path' $cfg.camera.configJson
$cfg.proxy.caddyExe = Ask 'caddy.exe path' $cfg.proxy.caddyExe
$cfg.proxy.caddyDir = Ask 'Folder holding the Caddyfile (see caddy\Caddyfile.example)' $cfg.proxy.caddyDir
$cfg.sync.rcloneExe = Ask 'rclone.exe path' $cfg.sync.rcloneExe
$cfg.sync.sourceDir = Ask 'Recordings folder to back up' $cfg.sync.sourceDir
$cfg.sync.sftpHost = Ask 'Backup server (SFTP host, empty = no off-site backup)' $cfg.sync.sftpHost
$cfg.sync.sftpUser = Ask 'SFTP user' $cfg.sync.sftpUser
$cfg.sync.remotePath = Ask 'Remote path' $cfg.sync.remotePath

# ---- Hue pairing (optional) ----
$cfg.hue.bridgeIp = Ask 'Hue bridge IP (empty = no lights)' $cfg.hue.bridgeIp
if ($cfg.hue.bridgeIp -and -not $cfg.hue.apiKey) {
  Write-Host 'Press the LINK BUTTON on the Hue bridge now - polling for 60s...' -ForegroundColor Yellow
  for ($i = 0; $i -lt 30 -and -not $cfg.hue.apiKey; $i++) {
    # a mistyped IP or dropped connection throws under $ErrorActionPreference=Stop; it must not
    # abort setup and lose every answer collected above, so keep polling
    $r = $null
    try { $r = Invoke-RestMethod -Method Post -Uri "http://$($cfg.hue.bridgeIp)/api" -Body '{"devicetype":"watchpost#pc"}' -TimeoutSec 5 }
    catch { Write-Host "  bridge not answering ($($_.Exception.Message))" -ForegroundColor Yellow }
    if ($r.success.username) { $cfg.hue.apiKey = $r.success.username; Write-Host 'Paired.' -ForegroundColor Green }
    else { Start-Sleep 2 }
  }
  if (-not $cfg.hue.apiKey) { Write-Host 'No pairing - lights disabled until you rerun setup.' -ForegroundColor Yellow }
}
if ($cfg.hue.apiKey) {
  $cfg.hue.livingRoomGroupId = Ask 'Hue group id: living room' $cfg.hue.livingRoomGroupId
  $cfg.hue.bedroomGroupId = Ask 'Hue group id: bedroom' $cfg.hue.bedroomGroupId
  $cfg.hue.groupIds = @($cfg.hue.bedroomGroupId, $cfg.hue.livingRoomGroupId)
}

$cfg | ConvertTo-Json -Depth 8 | Set-Content "$repo\config.json" -Encoding UTF8
Write-Host 'config.json written.' -ForegroundColor Green

# ---- Caddyfile ----
# watchpost.ps1 runs `caddy start --config Caddyfile` in proxy.caddyDir, so the file must exist there
$caddyfile = Join-Path $cfg.proxy.caddyDir 'Caddyfile'
if (-not (Test-Path -LiteralPath $caddyfile)) {
  New-Item -ItemType Directory -Force $cfg.proxy.caddyDir | Out-Null
  Copy-Item "$repo\caddy\Caddyfile.example" $caddyfile
  Write-Host "Caddyfile created at $caddyfile (edit it if the camera web UI is not on port 8090)."
}

# ---- Scheduled tasks (RunLevel Highest so the toggle never shows UAC) ----
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Register-WatchpostTasks
} else {
  Write-Host 'Elevating to register scheduled tasks (accept the UAC prompt)...' -ForegroundColor Yellow
  Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -TasksOnly"
}

# ---- Toggle shortcut on the desktop ----
$toggle = "$repo\scripts\watchpost-toggle.cmd"
if ($cfg.camera.serviceName -ne 'Agent') {
  (Get-Content $toggle -Raw) -replace 'sc query \S+ \|', "sc query $($cfg.camera.serviceName) |" | Set-Content $toggle
}
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Watchpost.lnk'))
$lnk.TargetPath = $toggle
$lnk.IconLocation = '%SystemRoot%\System32\imageres.dll,101'
$lnk.Save()

# ---- Backup key ----
if ($cfg.sync.sftpHost) {
  if (-not (Test-Path $cfg.sync.keyFile)) {
    & "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -t ed25519 -f $cfg.sync.keyFile -N '""' -C watchpost-sync -q
  }
  Write-Host "`nAdd this public key to $($cfg.sync.sftpUser)@$($cfg.sync.sftpHost):~/.ssh/authorized_keys:" -ForegroundColor Cyan
  Get-Content "$($cfg.sync.keyFile).pub"
}

Write-Host "`nDone. Double-click 'Watchpost' on the desktop to arm/disarm." -ForegroundColor Green
