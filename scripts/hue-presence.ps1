# Hue presence simulation while away. Runs every 5 min via Task Scheduler (HuePresence).
# Two zones: living room (evenings + mornings) and bedroom (bedtime handoff, night blip).
. "$PSScriptRoot\lib.ps1"
$cfg = Get-WatchpostConfig
$P = $cfg.hue.presence
$bed = [string]$cfg.hue.bedroomGroupId
$liv = [string]$cfg.hue.livingRoomGroupId

$now = Get-Date
$d = $now.Date

function MinutesOf([string]$hhmm) {
  $t = [timespan]::Parse($hhmm)
  [int]$t.TotalMinutes
}

# Same random offsets all day (seeded by date) so every 5-min run agrees. The date alone would
# let anyone with this public source compute the day's transitions, and each transition opens a
# short alarm-suppression window - so the seed is salted with the local Hue api key (secret,
# stable per install)
$md5 = [System.Security.Cryptography.MD5]::Create()
$salt = [BitConverter]::ToInt32($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$cfg.hue.apiKey)), 0)
$seed = [int]($now.ToString('yyyyMMdd')) -bxor $salt
Get-Random -SetSeed $seed | Out-Null
$evStart = $d.AddMinutes((MinutesOf $P.eveningStart) + (Get-Random -Minimum -40 -Maximum 21))
$evBed   = $d.AddMinutes((MinutesOf $P.bedtime) + (Get-Random -Minimum -15 -Maximum 21))
# Some evenings run late (movie night): bedtime slides 45-90 min
if ((Get-Random -Minimum 0 -Maximum 100) -lt [int]$P.lateEveningChancePct) {
  $evBed = $evBed.AddMinutes(45 + (Get-Random -Minimum 0 -Maximum 46))
}
$evEnd   = $evBed.AddMinutes(12 + (Get-Random -Minimum 0 -Maximum 16))
$moStart = $d.AddMinutes((MinutesOf $P.morningStart) + (Get-Random -Minimum -10 -Maximum 16))
$moEnd   = $d.AddMinutes((MinutesOf $P.morningEnd) + (Get-Random -Minimum -15 -Maximum 11))

# Living room: evening until "bedtime", plus the morning window
$livOn = (($now -ge $evStart -and $now -lt $evBed) -or ($now -ge $moStart -and $now -lt $moEnd))
# Bedroom: light shifts there just before the living room goes dark (going to bed), off a bit
# later; mornings it goes dark first
$bedOn = (($now -ge $evBed.AddMinutes(-8) -and $now -lt $evEnd) -or ($now -ge $moStart -and $now -lt $moEnd.AddMinutes(-20)))
# Some nights: a short bedroom light between 01:00 and 04:30 (nightly bathroom trip)
$blipTonight = (Get-Random -Minimum 0 -Maximum 100) -lt [int]$P.nightBlipChancePct
$blipStart = $d.AddMinutes(60 + (Get-Random -Minimum 0 -Maximum 211))
$bedOn = $bedOn -or ($blipTonight -and $now -ge $blipStart -and $now -lt $blipStart.AddMinutes(6))

# The sim acts only on its OWN transitions (the desired state differing from the last tick's),
# never by reconciling against the bridge: a light a person switched on stands, and only a real
# sim change may suppress the motion alarm - reconciliation once silenced a genuine alarm 13s
# after a tick turned off a light the returning owner had just lit
if (-not (Get-HueGroups $cfg)) { exit 0 }  # bridge unreachable: no change, never a suppression
$desiredFile = Join-Path (Get-StateDir) 'hue-last-desired.txt'
$lastDesired = if (Test-Path $desiredFile) { Get-Content $desiredFile -First 1 } else { '' }
$desired = '{0}{1}' -f [int]$livOn, [int]$bedOn
if ($desired -ne $lastDesired) {
  Set-AlarmSuppression $cfg
  Start-Sleep -Seconds 2
  Set-HueGroup $cfg $liv $livOn
  Set-HueGroup $cfg $bed $bedOn
  # written after the apply: if the bridge dropped mid-apply, the next tick retries the transition
  Set-Content -LiteralPath $desiredFile -Value $desired
}
