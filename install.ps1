# install.ps1 - installs the ChatGPT Wallpaper Skin for the current user.
#
#   .\install.ps1                     interactive: pick the wallpaper video in a file dialog
#   .\install.ps1 -Video D:\clip.mp4  same, without the dialog
#   .\install.ps1 -NoAutostart        do not add the logon item / keep-alive task
#   .\install.ps1 -SkipLaunch         install only, do not start the skin now
#   .\install.ps1 -InstallDir <path>  install somewhere else
#
# Nothing here modifies the ChatGPT app. The skin is injected at runtime over the
# Chrome DevTools Protocol, and the injection lives only as long as the app process.
#
# ASCII only (see lib.ps1) - Windows PowerShell 5.1 mangles BOM-less UTF-8.
param(
  [string]$Video = '',
  [string]$InstallDir = '',
  [switch]$NoAutostart,
  [switch]$SkipLaunch
)

$ErrorActionPreference = 'Stop'
# Payload lives in .\src next to this script; fall back to this folder when the
# script was copied on its own.
$src = Join-Path $PSScriptRoot 'src'
if (-not (Test-Path (Join-Path $src 'agent.cjs'))) { $src = $PSScriptRoot }

function Say($m) { Write-Host $m }
function Step($n, $m) { Write-Host ''; Write-Host "[$n] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "    ! $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 0. sanity
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'Windows PowerShell 5.1 or newer is required.' }
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'ChatGptWallpaperSkin' }

Step 0 'Checking this machine'
Say "    install dir : $InstallDir"
Say "    powershell  : $($PSVersionTable.PSVersion)"

# ---------------------------------------------------------------- 1. find the app
Step 1 'Looking for the ChatGPT desktop app'
$pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pkg) { $pkg = Get-AppxPackage | Where-Object { $_.Name -like '*OpenAI*' -and $_.InstallLocation } | Select-Object -First 1 }
if (-not $pkg) {
  throw 'The ChatGPT desktop app (OpenAI.Codex) is not installed for this user. Install it from the Microsoft Store / openai.com first.'
}
$exePath = Join-Path $pkg.InstallLocation 'app\ChatGPT.exe'
if (-not (Test-Path $exePath)) {
  throw "Found the package but not its exe ($exePath). This build of the app may be laid out differently."
}
$aumid = "$($pkg.PackageFamilyName)!App"
Say "    package     : $($pkg.Name) $($pkg.Version)"
Say "    aumid       : $aumid"

# ---------------------------------------------------------------- 2. node runtime
Step 2 'Checking the Node.js runtime (the media server and the injector are Node)'
function Find-Node {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @(
    (Join-Path $InstallDir 'runtime\node.exe'),
    (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
  )
  foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
  return $null
}

$node = Find-Node
if ($node) {
  Say "    node        : $node"
} else {
  Say '    node not found - downloading a portable copy (about 30 MB, one time)'
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $index = Invoke-RestMethod 'https://nodejs.org/dist/index.json' -TimeoutSec 30
    $lts = $index | Where-Object { $_.lts } | Select-Object -First 1
    $ver = $lts.version
    $zip = Join-Path $env:TEMP ("node-$ver-win-x64.zip")
    $url = "https://nodejs.org/dist/$ver/node-$ver-win-x64.zip"
    Say "    downloading : $url"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 600
    $runtimeDir = Join-Path $InstallDir 'runtime'
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    $tmp = Join-Path $env:TEMP ("node-$ver-extract")
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
    Copy-Item (Join-Path $inner.FullName 'node.exe') (Join-Path $runtimeDir 'node.exe') -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    $node = Join-Path $runtimeDir 'node.exe'
    Say "    node        : $node (portable)"
  } catch {
    Warn "automatic download failed: $($_.Exception.Message)"
    Warn 'Install Node.js LTS from https://nodejs.org and run install.cmd again,'
    Warn "or drop node.exe into $InstallDir\runtime\ and run it again."
    throw 'node.js is required.'
  }
}

# ---------------------------------------------------------------- 3. wallpaper video
Step 3 'Choosing the wallpaper video'
function Pick-Video {
  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Title = 'Pick a wallpaper video for ChatGPT (mp4 / webm / mov)'
  $dlg.Filter = 'Video files (*.mp4;*.m4v;*.webm;*.mov;*.mkv)|*.mp4;*.m4v;*.webm;*.mov;*.mkv|All files (*.*)|*.*'
  $dlg.CheckFileExists = $true
  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
  return ''
}

if (-not $Video) { $Video = Pick-Video }
if (-not $Video) {
  Say '    no file picked - paste the full path to a video file instead:'
  $Video = (Read-Host '    video path').Trim('"').Trim()
}
if (-not $Video -or -not (Test-Path $Video)) { throw "video not found: $Video" }
$Video = (Resolve-Path $Video).Path
$sizeMb = [math]::Round((Get-Item $Video).Length / 1MB, 1)
Say "    video       : $Video ($sizeMb MB)"
if ($sizeMb -gt 300) {
  Warn 'this clip is large; a 15-40s loop at 1440p is usually plenty and starts faster'
}

# ---------------------------------------------------------------- 4. copy files
Step 4 'Copying files'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$files = @('serve.cjs', 'agent.cjs', 'glass.css', 'lib.ps1', 'start.ps1', 'watchdog.ps1', 'ensure.ps1', 'uninstall.ps1')
foreach ($f in $files) {
  Copy-Item (Join-Path $src $f) (Join-Path $InstallDir $f) -Force
}
Say "    $($files.Count) files -> $InstallDir"

# ---------------------------------------------------------------- 5. config
Step 5 'Writing config.json'
$config = [ordered]@{
  version          = 1
  appName          = 'ChatGPT'
  appExeName       = 'ChatGPT.exe'
  appAumid         = $aumid
  appPackageName   = $pkg.Name
  mediaPort        = 8756
  cdpPort          = 9333
  videoPath        = $Video
  videoObjectFit   = 'cover'
  scrim            = 0.22
  cssFile          = 'glass.css'
  cssExtraFile     = ''
  petExe           = ''
  petProcessName   = ''
  nodePath         = $node
}
$configPath = Join-Path $InstallDir 'config.json'
$json = $config | ConvertTo-Json -Depth 5
# UTF-8 without BOM: Node's JSON.parse chokes on a leading BOM.
[System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Say "    $configPath"

# ---------------------------------------------------------------- 6. autostart
Step 6 'Autostart (so any entry point gets the skin)'
if ($NoAutostart) {
  Say '    skipped (-NoAutostart)'
} else {
  $startup = [Environment]::GetFolderPath('Startup')
  $lnk = Join-Path $startup 'ChatGPT Wallpaper Skin.lnk'
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $watchdog = Join-Path $InstallDir 'watchdog.ps1'
  $shell = New-Object -ComObject WScript.Shell
  $sc = $shell.CreateShortcut($lnk)
  $sc.TargetPath = $ps
  $sc.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $watchdog + '"'
  $sc.WorkingDirectory = $InstallDir
  $sc.WindowStyle = 7
  $sc.Description = 'Keeps the ChatGPT wallpaper skin working from any launch entry'
  $sc.Save()
  Say "    logon item  : $lnk"

  $ensure = Join-Path $InstallDir 'ensure.ps1'
  $taskName = 'ChatGPTWallpaperSkinKeepAlive'
  $cmd = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $ensure + '"'
  & schtasks /Create /TN $taskName /SC MINUTE /MO 2 /TR $cmd /F 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Say "    keep-alive  : scheduled task $taskName (every 2 minutes)"
  } else {
    Warn "could not create the keep-alive task; the logon item still works."
    Warn "Run this once in an elevated prompt if you want it:"
    Warn "  schtasks /Create /TN $taskName /SC MINUTE /MO 2 /TR `"$cmd`" /F"
  }
}

# ---------------------------------------------------------------- 7. start it
Step 7 'Starting the skin'
if ($SkipLaunch) {
  Say '    skipped (-SkipLaunch)'
} else {
  & (Join-Path $InstallDir 'start.ps1') -RestartApp
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host ''
Write-Host '  - From now on, open ChatGPT the way you always do; the skin appears within a few seconds.'
Write-Host '  - Look tweaks: edit glass.css in the install dir (hot-reloaded in ~1.5s).'
Write-Host '  - Brightness of the artwork vs. text: "scrim" in config.json (0 = raw clip, 1 = black).'
Write-Host '  - Logs: watchdog.log, agent.log, media.log next to config.json.'
Write-Host '  - Uninstall: run uninstall.ps1 in the install folder (or uninstall.cmd in the downloaded folder).'
