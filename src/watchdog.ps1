# watchdog.ps1 - keeps the skin working for ANY entry point (Start menu, search, pinned
# taskbar icon, file association). No special shortcut, no "start it this way" rule.
#
# Why a loop instead of a launch hook: Chromium cannot add --remote-debugging-port to an
# already running process. The only option is to catch the process the moment it appears
# and activate the packaged app again with the flag, usually within ~1s. Win32_ProcessStartTrace
# would be event-driven but subscribing needs admin rights, so polling is the portable path.
#
# Measured on the reference machine: ~2.6s from a normal click to a debug port, ~6-8s
# cold start including the app's own startup.
#
# ASCII only (see lib.ps1).
param(
  [int]$PollMs = 250,
  [string]$LogName = 'watchdog.log'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib.ps1')

$config = Read-SkinConfig
$media = [int]$config.mediaPort
$cdp = [int]$config.cdpPort
$exeName = $config.appExeName
$exeBase = [IO.Path]::GetFileNameWithoutExtension($exeName)
$launcher = Join-Path $PSScriptRoot 'start.ps1'
$node = Resolve-NodeExe -Config $config
$aumid = Resolve-AppAumid -Config $config

if (-not $aumid) {
  Write-SkinLog -Message "cannot resolve the app AUMID - run install.ps1 again" -LogName $LogName
  exit 1
}

# single instance
$others = @(Get-SkinWatchdogProcess -SelfPid $PID)
if ($others.Count -gt 0) { exit 0 }

Write-SkinLog -LogName $LogName -Message ("watchdog started (poll=${PollMs}ms aumid=$aumid media=$media cdp=$cdp)")

# ------------------------------------------------------------------ optional desktop pet
# Some people pair this skin with a desktop pet that should appear together with the app.
# If config.json has petExe, launch it on the rising edge (app was not running, now it is)
# and only once - closing the pet by hand is respected until the app is opened again.
$petExe = $null
if ($config.petExe -and (Test-Path $config.petExe)) {
  $petExe = $config.petExe
  Write-SkinLog -LogName $LogName -Message ("pet: $petExe")
} elseif ($config.petExe) {
  Write-SkinLog -LogName $LogName -Message ("pet: configured but missing -> " + $config.petExe)
}
$petProcessName = if ($config.petProcessName) { $config.petProcessName } else { '' }
if (-not $petProcessName -and $petExe) { $petProcessName = [IO.Path]::GetFileNameWithoutExtension($petExe) }

$cooldownUntil = Get-Date
$killTimes = @()
$appWasUp = $false
$lastHelperCheck = Get-Date
$helperCooldownUntil = Get-Date

while ($true) {
  try {
    $now = Get-Date
    $browser = Get-AppBrowserProcess -ExeName $exeName

    # ---- optional pet follows the app on the rising edge
    if ($petExe) {
      $appUp = [bool]$browser
      if ($appUp -and -not $appWasUp) {
        $petRunning = @(Get-Process -Name $petProcessName -ErrorAction SilentlyContinue).Count -gt 0
        if (-not $petRunning) {
          try {
            Start-Process -FilePath $petExe -WorkingDirectory (Split-Path $petExe)
            Write-SkinLog -LogName $LogName -Message "app just started -> launching desktop pet"
          } catch {
            Write-SkinLog -LogName $LogName -Message ("pet launch failed: " + $_.Exception.Message)
          }
        }
      }
      $appWasUp = $appUp
    }

    # ---- a running app without the debug port: replace it with a skinned instance
    if ($browser -and $now -gt $cooldownUntil -and ($browser.CommandLine -notmatch '--remote-debugging-port')) {
      # safety valve: if correcting keeps failing, stop fighting and back off instead of
      # restarting the app forever
      $recent = @($killTimes | Where-Object { ($now - $_).TotalMinutes -lt 2 })
      $killTimes = @($recent)
      if ($recent.Count -ge 4) {
        Write-SkinLog -LogName $LogName -Message "4 corrections in 2 minutes -> backing off for 5 minutes (activation is probably failing)"
        $cooldownUntil = $now.AddMinutes(5)
        Start-Sleep -Milliseconds $PollMs
        continue
      }
      $killTimes = @($recent + $now)
      Write-SkinLog -LogName $LogName -Message ("portless app pid " + $browser.ProcessId + " -> replacing with a skinned instance")
      $cooldownUntil = $now.AddSeconds(15)
      Get-Process -Name $exeBase -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
      # wait for it to really go away, otherwise the new activation just focuses the corpse
      $gone = 0
      while ($gone -lt 25 -and (Get-AppProcesses -ExeName $exeName)) { Start-Sleep -Milliseconds 100; $gone++ }
      $activated = $false
      try {
        [SkinPkgActivate]::Activate($aumid, "--remote-debugging-port=$cdp") | Out-Null
        $activated = $true
      } catch {
        Write-SkinLog -LogName $LogName -Message ("activate failed: " + $_.Exception.Message + " -> falling back to the launcher")
      }
      if (-not $activated) { Start-SkinLauncher -LauncherPath $launcher -RestartApp }
    }

    # ---- helpers (media server, agent) every 3s
    if (($now - $lastHelperCheck).TotalSeconds -ge 3) {
      $lastHelperCheck = $now
      $agentUp = [bool](Get-SkinAgentProcess)
      $mediaUp = Test-SkinPort $media
      # Only when the app is running: without it there is nothing to inject into, and
      # asking the launcher for helpers would also *start* the app - i.e. the PC would
      # open it by itself at every logon.
      if ($browser -and $now -gt $helperCooldownUntil -and (-not $mediaUp -or -not $agentUp)) {
        Write-SkinLog -LogName $LogName -Message ("helper missing (media=$mediaUp agent=$agentUp) -> launcher dispatched")
        $helperCooldownUntil = $now.AddSeconds(25)
        Start-SkinLauncher -LauncherPath $launcher
      }
      # the launcher can be dispatched twice by two racing ticks and each copy starts an
      # agent; keep exactly one
      $agents = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*agent.cjs*' } | Sort-Object CreationDate)
      if ($agents.Count -gt 1) {
        $agents[0..($agents.Count - 2)] | ForEach-Object {
          Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
          Write-SkinLog -LogName $LogName -Message ("killed duplicate agent pid " + $_.ProcessId)
        }
      }
      # a launcher that hangs (e.g. stuck in ActivateApplication) would block every later
      # correction, so reap our own children that overstay
      $stuck = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ParentProcessId -eq $PID -and $_.CommandLine -like '*start.ps1*' })
      foreach ($s in $stuck) {
        if ((($now - $s.CreationDate).TotalSeconds) -gt 120) {
          Stop-Process -Id $s.ProcessId -Force -ErrorAction SilentlyContinue
          Write-SkinLog -LogName $LogName -Message ("killed stuck launcher pid " + $s.ProcessId)
        }
      }
    }
  } catch {
    Write-SkinLog -LogName $LogName -Message ("error: " + $_.Exception.Message)
  }
  Start-Sleep -Milliseconds $PollMs
}
