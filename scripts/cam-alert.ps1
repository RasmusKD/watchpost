# Fired by the camera software on a motion alarm.
# Skips everything while the presence simulation has flagged its own light change (suppress file),
# otherwise: Discord alert first, then the configured light groups ON as a deterrent.
. "$PSScriptRoot\lib.ps1"
$cfg = Get-WatchpostConfig

if (Test-AlarmSuppressed) { exit 0 }

# The push is the alert that matters, and each Hue call can block for its full 10 s timeout,
# so the lights never get to delay it
Send-Discord $cfg "$(Get-MentionPrefix $cfg)$(Expand-Message $cfg $cfg.messages.alarm)"

foreach ($g in $cfg.hue.groupIds) { Set-HueGroup $cfg $g $true }
