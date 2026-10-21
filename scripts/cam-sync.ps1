# Copies new recordings to the off-site box over SFTP. Runs every 5 min via Task Scheduler.
# Uses an inline rclone connection string (no rclone.conf) and bootstraps its own SSH key,
# so it works identically in the Task Scheduler context. Add the printed public key to the
# server's authorized_keys once (setup.ps1 shows it).
. "$PSScriptRoot\lib.ps1"
$cfg = Get-WatchpostConfig

if (-not $cfg.sync.sftpHost) { exit 0 }  # no backup host configured: backup is off, not failing

$key = $cfg.sync.keyFile
if (-not (Test-Path -LiteralPath $key)) {
  & "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -t ed25519 -f $key -N '""' -C watchpost-sync -q
}

# rclone only verifies the server's host key when known_hosts_file is set; without it the
# footage would go to whoever answers on that IP. Pin it via sync.knownHostsFile (ssh to the
# host once, or ssh-keyscan it, so the key lands in that file).
$pin = if ($cfg.sync.knownHostsFile) { ",known_hosts_file='$($cfg.sync.knownHostsFile)'" } else { '' }
$dest = ":sftp,host=$($cfg.sync.sftpHost),user=$($cfg.sync.sftpUser),key_file='$key'${pin}:$($cfg.sync.remotePath)"
& $cfg.sync.rcloneExe copy $cfg.sync.sourceDir $dest `
  --min-age $cfg.sync.minAge `
  --log-file (Join-Path (Get-StateDir) 'cam-sync.log') --log-level INFO
if ($LASTEXITCODE -ne 0) { Write-LastError 'sync-last-error.txt' "rclone exit $LASTEXITCODE (details in cam-sync.log)" }
else { Clear-LastError 'sync-last-error.txt' }
