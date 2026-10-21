# watchpost

Turn a Windows PC and the webcam plugged into it into a one-click vacation security system:

- **One desktop icon** arms or disarms everything (no UAC prompt, no terminal)
- **Motion recording with audio**, viewable **live from your phone** from anywhere
- **Off-site backup** of every clip within 5 minutes, so a stolen PC does not take the evidence with it
- **Alarm on sustained motion**: a Discord push with the live link + the light groups you configure turn on as a deterrent
- **Presence simulation**: Philips Hue lights follow a realistic, date-seeded daily rhythm (evening living room, bedtime handoff to the bedroom, occasional late nights and night-time blips) so the home looks lived-in
- **Self-coordinating**: the light simulation flags its own scheduled changes so a lamp in the camera's view never alarms on the simulation itself; brief shakes (a passing train) record a clip but do not page you - a human lingering does
- **Discord receipt** on every arm/disarm, so you never drive off unsure

## Requirements

| Piece | Where it runs | Role | Notes |
|---|---|---|---|
| [Agent DVR](https://www.ispyconnect.com/) | the PC | motion detection + recording | freeware (not OSS); installed as the Windows service `Agent` |
| [Tailscale](https://tailscale.com/) | the PC **and** your phone | reach the live view from anywhere | free tier; enable HTTPS certificates in the admin console |
| [Caddy](https://caddyserver.com/) | the PC | local header-stripping proxy | Agent DVR's free tier rejects proxied clients; see `caddy/Caddyfile.example` |
| [rclone](https://rclone.org/) | the PC | clip backup over SFTP | optional; leave the backup host empty to skip. The target is any box with SSH (a cheap VPS, a NAS) |
| Philips Hue bridge | your LAN | lights + presence simulation | optional; leave the bridge IP empty to skip |
| A Discord webhook | your Discord server | alarms + receipts as phone pushes | optional; Server settings -> Integrations -> Webhooks |

## Install

```powershell
git clone https://github.com/RasmusKD/watchpost
cd watchpost
powershell -ExecutionPolicy Bypass -File setup.ps1
```

Install the pieces from the table first (Agent DVR as a Windows service; sign in to
Tailscale once on the PC and the phone). `setup.ps1` then asks for every value (URL,
webhook, paths, backup host), pairs with the Hue bridge when you press its link button,
copies the Caddyfile into place, registers the scheduled tasks and drops a **Watchpost**
shortcut on the desktop. Two steps remain:

1. **Wire the alarm**: in Agent DVR (`localhost:8090`), add an action on **Alert** for
   the camera that executes
   `powershell -NoProfile -ExecutionPolicy Bypass -File "<repo>\scripts\cam-alert.ps1"`,
   with the sustained-motion seconds you want (~10 s works well).
2. **Backup key**: add the SSH public key setup printed to the backup server's
   `authorized_keys` (skip if you left the backup host empty).

Setting it up with an AI agent, or want the fastest fully command-line path? Point it
at [AGENTS.md](AGENTS.md) - every step, non-interactive.

Everything is driven by `config.json` (gitignored, so your webhook and keys never end
up in a commit or fork). `config.example.json` documents every field, including the presence
schedule (`hue.presence`): evening/bedtime/morning windows, late-evening and
night-blip probabilities.

## Daily use

Double-click **Watchpost**. It reads the current state and flips it, then sends a
Discord receipt ("ON" with the live link, or "OFF"). Keep the PC powered and logged
in (Win+L lock is fine, screen off is fine). After a reboot an armed rig resumes by
itself once you log in: the camera service auto-starts with Windows, and the proxy
starts with your session. No click needed - a click would toggle it off.

## How the alarm behaves

The alarm fires only when armed AND motion is sustained (~10 s by default in Agent
DVR's action). Short vibrations and light switches record clips without paging you.
When the presence simulation makes one of its own scheduled light changes it first
writes a short suppression window (`hue.suppressSeconds`, default 45 s), so a lamp
in the camera's view never alarms on the simulation itself. Only the simulation's
own transitions suppress: a light switched by a person stands (the simulation never
"corrects" it) and alarms normally, and an unreachable Hue bridge changes nothing.

## Troubleshooting

- **No Discord receipt after a click**: don't just click again - the toggle flips state,
  so a second click can disarm what the first armed. Check `sc query Agent` first: RUNNING
  means the rig is armed and only the receipt failed (see `state/discord-last-error.txt`).
- **Live link dead, everything else fine**: Tailscale must be connected on BOTH ends -
  the tray icon on the PC and the app on the phone.
- **Lights not following the schedule**: see `state/hue-last-error.txt` for the last
  bridge error; an empty/missing file means the bridge calls succeed.
- **Alarm never fires**: open Agent DVR (`localhost:8090`) and check that the padlock
  (top left) is locked, and that your alarm action is bound to the default profile
  (arming selects profile 0 on every On).

## Layout

```
setup.ps1 / uninstall.ps1     install and remove (tasks, shortcut, startup entry)
scripts/watchpost.ps1              the On/Off engine (service, tasks, proxy, tailscale serve)
scripts/watchpost-toggle.cmd       the desktop shortcut target (state check -> right task)
scripts/cam-alert.ps1         alarm handler: lights on + Discord ping (or suppressed)
scripts/hue-presence.ps1      date-seeded presence simulation, runs every 5 min
scripts/cam-sync.ps1          rclone SFTP backup, runs every 5 min
scripts/lib.ps1               config loader + Hue/Discord/suppression helpers
caddy/Caddyfile.example       the header-stripping proxy config (ports live here)
state/                        runtime state: suppression window, last errors, sync log
```

`uninstall.ps1` removes the tasks, shortcut and startup entry; config, recordings,
the SSH key pair and the Hue app key stay.

## Roadmap

- Fully open-source camera engine (replacing the freeware detector) with
  AI person detection, so the alarm ignores everything that is not human.
- Config-driven presence roles, so homes with more rooms than "living room +
  bedroom" can give each light group its own schedule. (Today: the alarm already
  takes any number of groups via `hue.groupIds`; the simulation drives exactly two.)

## License

MIT
