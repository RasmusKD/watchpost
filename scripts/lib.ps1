# Shared helpers for all watchpost scripts. Dot-source: . "$PSScriptRoot\lib.ps1"
$script:RepoRoot = Split-Path $PSScriptRoot -Parent

function Get-WatchpostConfig {
  $p = Join-Path $script:RepoRoot 'config.json'
  if (-not (Test-Path -LiteralPath $p)) {
    throw "config.json missing. Copy config.example.json to config.json and fill it in, or run setup.ps1."
  }
  Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
}

function Get-StateDir {
  $d = Join-Path $script:RepoRoot 'state'
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
  $d
}

# Latest-only error files under state/: one write per failure, removed on the next success,
# so a non-empty file always describes the CURRENT failure
function Write-LastError([string]$file, [string]$msg) {
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Set-Content (Join-Path (Get-StateDir) $file)
}
function Clear-LastError([string]$file) {
  Remove-Item (Join-Path (Get-StateDir) $file) -ErrorAction SilentlyContinue
}

# Hue calls go over plain http on the LAN: the bridge's self-signed cert forced validation off,
# which authenticated nothing, and Windows PowerShell's Schannel stopped negotiating TLS with
# newer bridge firmware entirely, so every https call failed silently and the lights went dead

# The bridge reports API failures (revoked key, unknown group) as HTTP 200 with an error array,
# so an exception-only check would count them as success
function Test-HueResponse([object]$resp, [string]$ctx) {
  $err = @($resp) | Where-Object { $_.error } | Select-Object -First 1
  if ($err) { Write-LastError 'hue-last-error.txt' "${ctx}: $($err.error.description)"; return $false }
  Clear-LastError 'hue-last-error.txt'
  $true
}

function Set-HueGroup([object]$cfg, [string]$groupId, [bool]$on) {
  if (-not $cfg.hue.bridgeIp -or -not $cfg.hue.apiKey) { return }
  $body = '{"on":' + $(if ($on) { 'true' } else { 'false' }) + '}'
  $uri = "http://$($cfg.hue.bridgeIp)/api/$($cfg.hue.apiKey)/groups/$groupId/action"
  try {
    $r = Invoke-RestMethod -Method Put -Uri $uri -Body $body -TimeoutSec 10
    Test-HueResponse $r "Set-HueGroup $groupId" | Out-Null
  }
  catch { Write-LastError 'hue-last-error.txt' "Set-HueGroup ${groupId}: $($_.Exception.Message)" }
}

function Get-HueGroups([object]$cfg) {
  if (-not $cfg.hue.bridgeIp -or -not $cfg.hue.apiKey) { return $null }
  try {
    $r = Invoke-RestMethod -Method Get -Uri "http://$($cfg.hue.bridgeIp)/api/$($cfg.hue.apiKey)/groups" -TimeoutSec 10
    if (Test-HueResponse $r 'Get-HueGroups') { $r } else { $null }
  }
  catch { Write-LastError 'hue-last-error.txt' "Get-HueGroups: $($_.Exception.Message)"; $null }
}

function Get-SuppressFile { Join-Path (Get-StateDir) 'alarm-suppress.txt' }

function Set-AlarmSuppression([object]$cfg) {
  # Written before we change lights ourselves, so the motion alarm skips its Discord ping
  (Get-Date).AddSeconds([int]$cfg.hue.suppressSeconds).ToString('yyyyMMddHHmmss') | Set-Content (Get-SuppressFile)
}

function Test-AlarmSuppressed {
  $sf = Get-SuppressFile
  if (-not (Test-Path -LiteralPath $sf)) { return $false }
  try {
    return (Get-Date) -lt [datetime]::ParseExact((Get-Content -LiteralPath $sf -First 1), 'yyyyMMddHHmmss', $null)
  } catch { return $false }
}

function Get-MentionPrefix([object]$cfg) {
  $p = ''
  if ($cfg.discord.everyone) { $p += '@everyone ' }
  if ($cfg.discord.mention) { $p += "$($cfg.discord.mention) " }
  $p
}

function Send-Discord([object]$cfg, [string]$text) {
  if (-not $cfg.discord.webhookUrl) { return }
  try {
    $body = @{ content = $text } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri $cfg.discord.webhookUrl -ContentType 'application/json; charset=utf-8' `
      -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 10 | Out-Null
    Clear-LastError 'discord-last-error.txt'
  } catch { Write-LastError 'discord-last-error.txt' "Send-Discord: $($_.Exception.Message)" }
}

function Expand-Message([object]$cfg, [string]$template) {
  $template.Replace('{live}', [string]$cfg.liveUrl)
}
