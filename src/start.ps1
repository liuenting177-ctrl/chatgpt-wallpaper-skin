# start.ps1 - bring the wallpaper skin up (or take it down).
#
#   .\start.ps1                ensure media server + skinned app + agent + watchdog
#   .\start.ps1 -RestartApp    if the app is already running without the debug port,
#                              restart it (unsent input is lost - that is the tradeoff)
#   .\start.ps1 -Stop          stop agent / media server / watchdog
#   .\start.ps1 -NoWatchdog    do not start the background watchdog
#
# ASCII only (see lib.ps1) - Windows PowerShell 5.1 mangles BOM-less UTF-8.
param(
  [switch]$RestartApp,
  [switch]$Stop,
  [switch]$NoWatchdog
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$config = Read-SkinConfig
$media = [int]$config.mediaPort
$cdp = [int]$config.cdpPort
$node = Resolve-NodeExe -Config $config

function Stop-Matching([string]$Pattern, [string]$Label) {
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like $Pattern } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; "stopped $Label pid $($_.ProcessId)" }
}

# ---------------------------------------------------------------- stop
if ($Stop) {
  Stop-Matching '*agent.cjs*' 'agent'
  Stop-Matching '*serve.cjs*' 'media server'
  Get-SkinWatchdogProcess | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    "stopped watchdog pid $($_.ProcessId)"
  }
  "done. Close and reopen $($config.appName) to get the unskinned app back."
  exit 0
}

if (-not $node) {
  throw "node.exe not found. Run install.ps1 again, or set nodePath in config.json."
}

# ---------------------------------------------------------------- 1. media server
if (Test-SkinUrl "http://127.0.0.1:$media/health") {
  "media server: already up on $media"
} else {
  Start-Process -FilePath $node -ArgumentList @((Join-Path $PSScriptRoot 'serve.cjs'), '--port', "$media") -WindowStyle Hidden
  $waited = 0
  while ($waited -lt 40) {
    Start-Sleep -Milliseconds 200
    $waited++
    if (Test-SkinUrl "http://127.0.0.1:$media/health") { break }
  }
  if (-not (Test-SkinUrl "http://127.0.0.1:$media/health")) {
    throw "media server did not start. Check that videoPath in config.json points at a real video file."
  }
  "media server: started on $media"
}

# ---------------------------------------------------------------- 2. app with CDP
$aumid = Resolve-AppAumid -Config $config
$appProc = Get-AppBrowserProcess -ExeName $config.appExeName
$cdpUp = Test-SkinUrl "http://127.0.0.1:$cdp/json/version"

if ($appProc -and -not $cdpUp) {
  if (-not $RestartApp) {
    "$($config.appName) is running without the debug port, so the skin cannot attach."
    "Close it and run this script again, or run with -RestartApp to restart it now"
    "(unsent input in that window is lost)."
    exit 2
  }
  "restarting $($config.appName) with the debug port..."
  Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($config.appExeName)) -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 900
  $appProc = $null
}

if (-not $appProc) {
  if (-not $aumid) {
    throw "Cannot find the $($config.appName) package (appPackageName=$($config.appPackageName)). Re-run install.ps1."
  }
  # Two attempts: if the user clicks a pinned/search entry at the same moment, that
  # (portless) instance can win the singleton race and Activate just focuses it. Then
  # kill it and activate again with the flag.
  $ok = $false
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    [SkinPkgActivate]::Activate($aumid, "--remote-debugging-port=$cdp") | Out-Null
    "activate attempt $attempt via $aumid"
    $waited = 0
    while ($waited -lt 80) {
      Start-Sleep -Milliseconds 250
      $waited++
      if (Test-SkinUrl "http://127.0.0.1:$cdp/json/version") { $ok = $true; break }
    }
    if ($ok) { break }
    $portless = Get-AppProcesses -ExeName $config.appExeName |
      Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--remote-debugging-port' -and $_.CommandLine -notmatch '--type=' }
    if ($portless) {
      "a portless instance won the race -> killing it and retrying"
      Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($config.appExeName)) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 1500
    }
  }
  if (-not $ok) { throw "debug port $cdp never answered. Is $($config.appName) starting at all?" }
  "app: running with --remote-debugging-port=$cdp"
}

# ---------------------------------------------------------------- 3. agent
$agent = Get-SkinAgentProcess
if ($agent) {
  "agent: already running (pid $($agent.ProcessId))"
} else {
  Start-Process -FilePath $node -ArgumentList @((Join-Path $PSScriptRoot 'agent.cjs')) -WindowStyle Hidden
  Start-Sleep -Milliseconds 1200
  $agent = Get-SkinAgentProcess
  if ($agent) { "agent: started (pid $($agent.ProcessId))" } else { throw "agent did not start - see agent.log" }
}

# ---------------------------------------------------------------- 4. watchdog
if ($NoWatchdog) {
  "watchdog: skipped (-NoWatchdog)"
} else {
  $wd = Get-SkinWatchdogProcess
  if ($wd) {
    "watchdog: already running (pid $($wd.ProcessId -join ', '))"
  } else {
    Start-Process -FilePath 'powershell.exe' `
      -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $PSScriptRoot 'watchdog.ps1') + '"')) `
      -WindowStyle Hidden | Out-Null
    Start-Sleep -Milliseconds 800
    $wd = Get-SkinWatchdogProcess
    if ($wd) { "watchdog: started (pid $($wd.ProcessId -join ', '))" } else { "watchdog: did not start (the skin still works until you close the app)" }
  }
}

"skin is up. Look tweaks go in glass.css (hot-reloaded), scrim in config.json."
