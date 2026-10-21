# watchpost — agent setup guide

Instructions for an AI agent (or anyone scripting) installing watchpost unattended.
The interactive path for humans is `setup.ps1`; everything it does can be done
non-interactively as below. All scripts target **Windows PowerShell 5.1**
(`powershell.exe`), run them with `-NoProfile -ExecutionPolicy Bypass`.

Ground rules:

- `config.json` holds secrets (webhook URL, Hue API key). It is gitignored; never
  commit it, print its values, or send them anywhere.
- Registering the scheduled tasks requires an **elevated** shell once. Everything
  else, including daily arm/disarm, runs without elevation.
- The user owns the machine: ask before installing the dependencies if you were
  not already told to.

## 1. Dependencies

```powershell
winget install --id Tailscale.Tailscale -e --accept-package-agreements --accept-source-agreements
winget install --id CaddyServer.Caddy   -e --accept-package-agreements --accept-source-agreements
winget install --id Rclone.Rclone       -e --accept-package-agreements --accept-source-agreements
```

Agent DVR has no winget package: download it from <https://www.ispyconnect.com/>
and install it **as a Windows service** (default service name `Agent`). Two
manual facts you need from it: the service name, and the path of its
`config.json` (default `C:\Program Files\Agent\Media\XML\config.json`).

Tailscale: `tailscale up` once so the machine joins a tailnet (this opens a
browser login the user must complete), and HTTPS certificates must be enabled in
the tailnet's admin console (<https://login.tailscale.com/admin/dns>). The
phone needs the Tailscale app on the same tailnet to open the live view.

## 2. Config

```powershell
Copy-Item config.example.json config.json
```

Fill `config.json` (every field is documented by its example value). Derivable
values, so do not ask the user for them:

```powershell
# liveUrl: the machine's tailnet DNS name
$dns = (& "$env:ProgramFiles\Tailscale\tailscale.exe" status --json | ConvertFrom-Json).Self.DNSName.TrimEnd('.')
# -> "liveUrl": "https://$dns"

# tool paths
(Get-Command caddy).Source   # -> proxy.caddyExe
(Get-Command rclone).Source  # -> sync.rcloneExe
```

Ask the user for: the Discord webhook URL (optional), the recordings folder
Agent DVR writes to (`sync.sourceDir`), and the backup host (optional).

## 3. Caddy

```powershell
New-Item -ItemType Directory -Force $env:USERPROFILE\caddy | Out-Null
Copy-Item caddy\Caddyfile.example $env:USERPROFILE\caddy\Caddyfile
# -> "proxy": { "caddyDir": "C:\\Users\\<user>\\caddy", ... }
```

The Caddyfile's two ports live only in the Caddyfile itself: 9090 must match
`tailscale.servePort` in config.json, 8090 is Agent DVR's default web UI port.
(Interactive `setup.ps1` does this copy too; doing it here keeps the unattended
path complete.)

## 4. Hue (optional — skip by leaving `hue.bridgeIp` empty)

Have the user press the bridge's link button, then within 30 s:

```powershell
$ip = '<bridge ip>'
(Invoke-RestMethod -Method Post -Uri "http://$ip/api" -Body '{"devicetype":"watchpost#pc"}').success.username  # -> hue.apiKey
Invoke-RestMethod "http://$ip/api/<apiKey>/groups"   # pick group ids -> livingRoomGroupId, bedroomGroupId, groupIds
```

## 5. Scheduled tasks (the one elevated step)

From an elevated PowerShell in the repo root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1 -TasksOnly
```

Registers `CamRigOn`/`CamRigOff` (RunLevel Highest, so the toggle never shows
UAC) and the 5-minute workers `CamSyncDroplet`/`HuePresence` (created disabled;
arming enables them). If the camera service is not named `Agent`, also patch the
service name in `scripts\watchpost-toggle.cmd` (setup.ps1's interactive path does this
with a one-line `-replace`).

## 6. Backup key (optional — only with a backup host)

```powershell
& "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -t ed25519 -f "$env:USERPROFILE\.ssh\cam_sync_key" -N '""' -C watchpost-sync -q
Get-Content "$env:USERPROFILE\.ssh\cam_sync_key.pub"
```

Give the public key to the user to append to `authorized_keys` on the backup
host (or do it yourself if you have access), and set `sync.keyFile`. Pin the
server's host key by pointing `sync.knownHostsFile` at a known_hosts file that
contains it (`ssh-keyscan <host> >> <file>`, verified out of band); without it
rclone skips host-key verification and the footage would go to whoever answers
on that IP.

## 7. Wire the alarm inside Agent DVR

In Agent DVR's web UI (`http://localhost:8090`): camera -> Actions -> add an
action on **Alert** (sustained motion, ~10 s) that executes:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<repo>\scripts\cam-alert.ps1"
```

Arming is otherwise automatic: `watchpost.ps1 On` re-arms Agent DVR and resets its
profile in the camera `config.json` whenever the service is stopped.

## 8. Verify

```powershell
schtasks /Run /TN CamRigOn     # arm; a Discord "ON" receipt arrives if a webhook is set
curl.exe -sk -o NUL -w "%{http_code}" <liveUrl>   # expect 200 (from any tailnet device)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\cam-alert.ps1   # test alarm: lights + ping
schtasks /Run /TN CamRigOff    # disarm; "OFF" receipt
```

`schtasks /Query /TN CamRigOn /V /FO LIST` shows the last result (`0` = clean
run; `267009` / `0x41301` = still running). Light/bridge failures land in
`state\hue-last-error.txt`.

## Daily driving (headless)

- Arm: `schtasks /Run /TN CamRigOn` - Disarm: `schtasks /Run /TN CamRigOff`
- State: `sc query Agent` (`RUNNING` = armed), or double-click the
  `scripts\watchpost-toggle.cmd` shortcut, which flips based on that state.
- The PC must stay powered and logged in (locking and screen-off are fine);
  after a reboot an armed rig resumes by itself once the user logs in (the
  service auto-starts, the Startup entry restarts the proxy) - do not toggle.
