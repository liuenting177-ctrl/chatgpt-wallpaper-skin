# Shared helpers for the ChatGPT Wallpaper Skin scripts.
# ASCII only on purpose: Windows PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI
# and mangles non-ASCII characters, which turns quoting into syntax errors.
#
# Dot-source:  . (Join-Path $PSScriptRoot 'lib.ps1')

$script:Root = $PSScriptRoot
$script:ConfigPath = Join-Path $Root 'config.json'

function Read-SkinConfig {
  if (-not (Test-Path $script:ConfigPath)) {
    throw "config.json not found in $Root - run install.ps1 first."
  }
  return Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
}

function Write-SkinLog {
  param([string]$Message, [string]$LogName = 'skin.log')
  $path = Join-Path $Root $LogName
  try {
    Add-Content -Path $path -Value ("{0} {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Message) -Encoding UTF8
  } catch { }
}

function Test-SkinPort {
  param([int]$Port)
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(300)) { return $false }
    $client.EndConnect($iar)
    return $true
  } catch { return $false } finally { $client.Close() }
}

function Test-SkinUrl {
  param([string]$Url)
  try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
    return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500)
  } catch { return $false }
}

function Get-AppProcesses {
  param([string]$ExeName)
  Get-CimInstance Win32_Process -Filter "Name='$ExeName'" -ErrorAction SilentlyContinue
}

function Get-AppBrowserProcess {
  param([string]$ExeName)
  Get-AppProcesses -ExeName $ExeName |
    Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' } |
    Sort-Object CreationDate | Select-Object -First 1
}

function Get-SkinAgentProcess {
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*agent.cjs*' } | Select-Object -First 1
}

function Get-SkinMediaProcess {
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*serve.cjs*' } | Select-Object -First 1
}

function Get-SkinWatchdogProcess {
  param([int]$SelfPid = 0)
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and
      $_.CommandLine -like '*watchdog.ps1*' -and
      $_.CommandLine -notmatch '(?i)-Command' -and
      $_.ProcessId -ne $SelfPid
    }
}

function Resolve-NodeExe {
  param($Config)
  if ($Config.nodePath -and (Test-Path $Config.nodePath)) { return $Config.nodePath }
  $runtime = Join-Path $Root 'runtime\node.exe'
  if (Test-Path $runtime) { return $runtime }
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Start-SkinLauncher {
  param([string]$LauncherPath, [switch]$RestartApp)
  $args = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $LauncherPath + '"'))
  if ($RestartApp) { $args += '-RestartApp' }
  Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden | Out-Null
}

# IApplicationActivationManager: launches the MSIX package *with its identity* (so the
# taskbar keeps one icon) while still passing command-line switches to it.
if (-not ('SkinPkgActivate' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ISkinAppActivationManager {
  IntPtr ActivateApplication([In] string appUserModelId, [In] string arguments, [In] int options, [Out] out uint processId);
  IntPtr ActivateForFile(IntPtr appUserModelId, IntPtr itemArray, IntPtr verb, out uint processId);
  IntPtr ActivateForProtocol(IntPtr appUserModelId, IntPtr itemArray, out uint processId);
}
[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
public class SkinAppActivationManager { }
public class SkinPkgActivate {
  public static uint Activate(string aumid, string args) {
    var mgr = (ISkinAppActivationManager)new SkinAppActivationManager();
    uint pid;
    mgr.ActivateApplication(aumid, args, 0, out pid);
    return pid;
  }
}
'@ -ErrorAction SilentlyContinue
}

function Resolve-AppAumid {
  param($Config)
  if ($Config.appAumid) { return $Config.appAumid }
  if (-not $Config.appPackageName) { return $null }
  $pkg = Get-AppxPackage -Name $Config.appPackageName -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($pkg) { return "$($pkg.PackageFamilyName)!App" }
  return $null
}

function Get-AppExePath {
  param($Config)
  if (-not $Config.appPackageName) { return $null }
  $pkg = Get-AppxPackage -Name $Config.appPackageName -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $pkg -or -not $pkg.InstallLocation) { return $null }
  $candidate = Join-Path $pkg.InstallLocation ('app\' + $Config.appExeName)
  if (Test-Path $candidate) { return $candidate }
  return $null
}
