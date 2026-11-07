# uninstall.ps1 - removes the ChatGPT Wallpaper Skin.
#
#   .\uninstall.ps1           stop everything, remove autostart + scheduled task, keep files
#   .\uninstall.ps1 -Purge    ... and delete the install folder afterwards
#
# The app itself is never modified: once the processes here are stopped, restarting
# ChatGPT gives you the stock window back.
#
# ASCII only (see lib.ps1).
param(
  [switch]$Purge,
  [string]$InstallDir = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')

if ($InstallDir) { $dir = $InstallDir } else { $dir = $PSScriptRoot }

function Say($m) { Write-Host $m }

Say "uninstalling from $dir"

# 1+2. remove autostart first, so nothing can respawn a process mid-cleanup
# 1b. logon item
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ChatGPT Wallpaper Skin.lnk'
if (Test-Path $lnk) {
  Remove-Item $lnk -Force -ErrorAction SilentlyContinue
  Say "  removed logon item $lnk"
}

# 1c. scheduled task
$taskName = 'ChatGPTWallpaperSkinKeepAlive'
& schtasks /Query /TN $taskName 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
  & schtasks /Delete /TN $taskName /F 2>&1 | Out-Null
  Say "  removed scheduled task $taskName"
}

# 2. processes (now that nothing restarts them)
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and ($_.CommandLine -like '*agent.cjs*' -or $_.CommandLine -like '*serve.cjs*') } |
  ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    Say "  stopped node pid $($_.ProcessId)"
  }
Get-SkinWatchdogProcess | ForEach-Object {
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  Say "  stopped watchdog pid $($_.ProcessId)"
}

Say ''
Say 'The injector and the media server are gone. Close and reopen ChatGPT to get the'
Say 'stock window back.'

# 3. optional purge (delete ourselves after the process exits)
if ($Purge) {
  $cmd = "timeout /t 2 >nul & rmdir /s /q `"$dir`""
  Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmd) -WindowStyle Hidden | Out-Null
  Say "  install folder will be deleted: $dir"
}
