# ensure.ps1 - keep-alive for watchdog.ps1.
#
# The watchdog is the only thing that makes a normal app launch get the skin, so if it
# ever dies the feature silently stops working until the next logon. This script is what
# the scheduled task ("ChatGPTWallpaperSkinKeepAlive", every 2 minutes) runs: if no
# watchdog is alive, start one.
#
# ASCII only (see lib.ps1).
param([switch]$Quiet)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')

$running = @(Get-SkinWatchdogProcess)
if ($running.Count -gt 0) {
  if (-not $Quiet) { "watchdog already running (pid $($running.ProcessId -join ', '))" }
  exit 0
}

$watchdog = Join-Path $PSScriptRoot 'watchdog.ps1'
if (-not (Test-Path $watchdog)) {
  Write-SkinLog -Message "ensure: watchdog.ps1 missing next to ensure.ps1 - installation is broken" -LogName 'keepalive.log'
  exit 1
}

Start-Process -FilePath 'powershell.exe' `
  -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $watchdog + '"')) `
  -WindowStyle Hidden | Out-Null

Start-Sleep -Milliseconds 900
$running = @(Get-SkinWatchdogProcess)
$message = if ($running.Count -gt 0) { "ensure: watchdog restarted (pid $($running.ProcessId -join ', '))" } else { 'ensure: tried to start watchdog, it did not come up' }
Write-SkinLog -Message $message -LogName 'keepalive.log'
if (-not $Quiet) { $message }
