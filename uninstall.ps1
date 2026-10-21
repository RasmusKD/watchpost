# Removes the scheduled tasks, desktop shortcut and Startup entry. Deliberately kept: the repo
# folder, config.json, recordings, the SSH key pair, the Hue app key on the bridge, and the
# camera service (left set to Manual by the Off run below).
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  return
}

& "$PSScriptRoot\scripts\watchpost.ps1" Off

foreach ($t in 'CamRigOn','CamRigOff','CamSyncDroplet','HuePresence') {
  Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Watchpost.lnk') -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'watchpost-proxy.cmd') -ErrorAction SilentlyContinue
Write-Host 'watchpost removed (tasks, shortcut, startup entry).'
Write-Host 'Kept: repo, config.json, recordings, the SSH key pair, the Hue app key on the bridge,'
Write-Host 'and the camera service (now set to Manual start).'
