# doctor.ps1 - "it stopped working, why?"
#
#   .\doctor.ps1            print a checklist and a verdict
#
# Read-only: nothing is started, stopped or changed. Run it first whenever the skin
# disappears; last-error.txt (written by start.ps1) usually has the exact reason.
#
# ASCII only (see lib.ps1).
param(
  [string]$Root = ''
)

$ErrorActionPreference = 'Continue'
if ($Root) { $script:Root = $Root }
. (Join-Path $PSScriptRoot 'lib.ps1')

$bad = 0
function Ok($m) { Write-Host ('  [ok] ' + $m) -ForegroundColor Green }
function Bad($m) { Write-Host ('  [!!] ' + $m) -ForegroundColor Red; $script:bad = $script:bad + 1 }
function Note($m) { Write-Host ('  [--] ' + $m) -ForegroundColor DarkGray }
function Head($m) { Write-Host ''; Write-Host $m -ForegroundColor Cyan }

Write-Host ("ChatGPT Wallpaper Skin - doctor  (" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ")")
Write-Host ("install dir: " + $Root)

# ---------------------------------------------------------------- 1. config
Head '1. config'
$config = $null
try {
  $config = Read-SkinConfig
  Ok ('config.json parses (version ' + $config.version + ')')
} catch {
  Bad ('config.json: ' + $_.Exception.Message)
}

if ($config) {
  $videoProblem = Test-VideoPath -Config $config
  if ($videoProblem) { Bad ('wallpaper: ' + $videoProblem) }
  else {
    $sizeMb = [math]::Round((Get-Item -LiteralPath $config.videoPath).Length / 1MB, 1)
    Ok ('wallpaper exists: ' + $config.videoPath + ' (' + $sizeMb + ' MB)')
  }

  $node = Resolve-NodeExe -Config $config
  if ($node) { Ok ('node: ' + $node) } else { Bad 'node.exe not found (set nodePath in config.json)' }

  $aumid = Resolve-AppAumid -Config $config
  if ($aumid) { Ok ('app package: ' + $aumid) } else { Bad ('app package not installed: ' + $config.appPackageName) }
}

# ---------------------------------------------------------------- 2. runtime
if ($config) {
  $media = [int]$config.mediaPort
  $cdp = [int]$config.cdpPort
  $exeName = $config.appExeName

  Head '2. processes and ports'
  $browser = Get-AppBrowserProcess -ExeName $exeName
  if (-not $browser) {
    Note 'the app is not running (nothing to attach to)'
  } elseif ($browser.CommandLine -match '--remote-debugging-port') {
    Ok ('app running with the debug port (pid ' + $browser.ProcessId + ')')
  } else {
    Bad ('app running WITHOUT the debug port (pid ' + $browser.ProcessId + ') - the watchdog should replace it within seconds')
  }

  if (Test-SkinPort $media) { Ok ('media server listening on ' + $media) } else { Bad ('media server not listening on ' + $media) }
  if (Test-SkinUrl ('http://127.0.0.1:' + $media + '/health')) { Ok 'media server answers /health' } else { Bad 'media server does not answer /health' }
  if (Test-SkinUrl ('http://127.0.0.1:' + $cdp + '/json/version')) { Ok ('debug port ' + $cdp + ' answers') } else { Bad ('debug port ' + $cdp + ' does not answer') }

  $agent = Get-SkinAgentProcess
  if ($agent) { Ok ('injector running (pid ' + $agent.ProcessId + ')') } else { Bad 'injector (agent.cjs) is not running' }
  $wd = @(Get-SkinWatchdogProcess)
  if ($wd.Count -gt 0) { Ok ('watchdog running (pid ' + (($wd | ForEach-Object { $_.ProcessId }) -join ',') + ')') } else { Bad 'watchdog is not running (autostart or the keep-alive task is broken)' }
}

# ---------------------------------------------------------------- 3. autostart
Head '3. autostart'
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ChatGPT Wallpaper Skin.lnk'
if (Test-Path $lnk) { Ok ('logon item: ' + $lnk) } else { Bad 'logon item missing in shell:startup (re-run install.ps1)' }

$taskName = 'ChatGPTWallpaperSkinKeepAlive'
$q = & schtasks /Query /TN $taskName 2>&1 | Out-String
if ($q -match 'ERROR|cannot find|Beim|no se') { Bad ('scheduled task missing: ' + $taskName) }
else {
  $csv = & schtasks /Query /TN $taskName /FO CSV /NH 2>&1 | Out-String
  Ok ('scheduled task present: ' + $taskName)
  Note ('  ' + ($csv.Trim() -replace '\s+', ' '))
}

# ---------------------------------------------------------------- 4. logs
Head '4. logs'
$errFile = Join-Path $Root 'last-error.txt'
if (Test-Path $errFile) {
  Bad 'last-error.txt exists - the last start failed:'
  Get-Content $errFile -Encoding UTF8 | ForEach-Object { Write-Host ('       ' + $_) -ForegroundColor Yellow }
} else {
  Ok 'no last-error.txt (the last start did not fail)'
}

foreach ($name in @('watchdog.log', 'agent.log', 'media.log')) {
  $p = Join-Path $Root $name
  if (Test-Path $p) {
    $last = Get-Content $p -Tail 1 -Encoding UTF8
    Note ($name + ': ' + $last)
  } else {
    Note ($name + ': missing')
  }
}

# ---------------------------------------------------------------- verdict
Write-Host ''
if ($bad -eq 0) {
  Write-Host 'VERDICT: everything looks healthy. If the wallpaper is still missing, the app may' -ForegroundColor Green
  Write-Host '         be showing a page the injector cannot reach - close and reopen it.' -ForegroundColor Green
} else {
  Write-Host ('VERDICT: ' + $bad + ' problem(s) above.') -ForegroundColor Red
  Write-Host '  Most fixes are one of:' -ForegroundColor Yellow
  Write-Host '    start.ps1                  start whatever is missing (media server, injector, watchdog)' -ForegroundColor Yellow
  Write-Host '    start.ps1 -RestartApp      also restart the app when it is running without the port' -ForegroundColor Yellow
  Write-Host '    install.ps1 -Video <path>  rewrite config.json with a wallpaper that exists' -ForegroundColor Yellow
}
Write-Host ''
exit ([int]($bad -gt 0))
