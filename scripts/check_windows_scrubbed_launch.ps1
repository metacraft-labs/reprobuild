<#
.SYNOPSIS
  Refuse a Windows package whose staged executables cannot start away from
  the developer machine that built them.

.DESCRIPTION
  THE GAP THIS CLOSES (Distribution-And-Packaging M1, N26).

  `runtime_contract.stageInstallTree` gates the runtime-closure walk, the
  RPATH rewrite and the ELF-interpreter rewrite on `toLinux`. There is no PE
  equivalent, so a Windows package ships its executables and NOTHING they
  load, and `RuntimeContract.dlopenLeafNames` -- the CHECKED POST-CONDITION
  that fails a Linux build when a declared name will not resolve into the
  vendored closure -- has no Windows counterpart either.

  The substitute is `reprobuildWindowsLoaderLibraries`, a curated union of a
  Nim `dynlib`-string scan and a PE-import-table scan, staged by the recipe.
  Review's finding was not that the list is wrong: it is that NOTHING PINS
  IT. The next library `repro.exe` learns to load ships missing and looks
  correct on the developer host that built it -- which is precisely how three
  reviews passed a package whose service could never start.

  THIS IS THAT PIN, and it is deliberately not the PE walk. It runs each
  staged executable in a process whose environment is REBUILT FROM EMPTY,
  with `PATH` set to the two system directories and nothing else, in an empty
  working directory. A DLL the package failed to ship is then not on any
  search path the process has, and the launch fails -- in seconds, over the
  SHIPPED BYTES rather than over a list, and for every library the image
  loads rather than only for the ones someone remembered to enumerate.

  WHAT A MISSING LIBRARY LOOKS LIKE, both forms:

  * a Nim `{.dynlib.}` binding resolved at MODULE INIT writes
    `could not load: libcrypto-3-x64.dll` and exits 1 -- before `main`, so it
    is not a degraded code path, it is a process that prints one line and
    dies;
  * a STATIC PE import (`libgcc_s_seh-1.dll`) never reaches user code at all:
    the loader fails the image and the exit code is STATUS_DLL_NOT_FOUND,
    0xC0000135.

  Both are refused here, and so is a zero-probe run: a check that found
  nothing to launch must not report success.

.PARAMETER TreeRoot
  A staged, PREFIX-ROOTED install tree (the `msi` or `tar` variant staged by
  `stageInstallTree`, or an installed prefix). Executables are probed from
  `<TreeRoot>\bin`.

.PARAMETER SystemDirectories
  The `PATH` the scrubbed process is given. The default is the two Windows
  system directories and nothing else.

.EXAMPLE
  pwsh scripts/check_windows_scrubbed_launch.ps1 `
    -TreeRoot tests/fixtures/packaging/reprobuild-dist/build/dist/reprobuild-0.1.3/msi
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$TreeRoot,
  [string[]]$SystemDirectories = @("$env:SystemRoot\system32", "$env:SystemRoot"),
  [int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# WHAT EACH EXECUTABLE IS ASKED, and why the default is the weak one.
#
# A public entry point has a documented flag that must answer 0, and that is
# the strong assertion: the image started, ran to `main`, and printed. Every
# OTHER staged executable is a helper whose command line this check has no
# business knowing, so it gets the UNIVERSAL assertion instead -- it may exit
# with any status it likes, but it must not exit with a loader status and must
# not print a module-init load failure. That still catches the whole class,
# because both failure forms happen BEFORE argument parsing.
$Probes = @{
  'repro-real.exe'         = @{ Args = @('--version'); ExpectExit = 0 }
  'repro-binary-cache.exe' = @{ Args = @('--help');    ExpectExit = 0 }
}

# 0xC0000135 STATUS_DLL_NOT_FOUND, 0xC0000142 STATUS_DLL_INIT_FAILED,
# 0xC0000139 STATUS_ENTRYPOINT_NOT_FOUND. These are the loader's answers and
# never a program's own exit status.
$LoaderStatuses = @{
  [int]0xC0000135 = 'STATUS_DLL_NOT_FOUND'
  [int]0xC0000142 = 'STATUS_DLL_INIT_FAILED'
  [int]0xC0000139 = 'STATUS_ENTRYPOINT_NOT_FOUND'
}

function Invoke-Scrubbed {
  param([string]$Exe, [string[]]$Arguments, [string]$WorkDir, [string[]]$PathDirs,
        [int]$TimeoutSeconds)

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $Exe
  foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.WorkingDirectory = $WorkDir
  # THE SCRUB. `.Environment` arrives pre-populated from THIS process, which
  # is the developer environment the whole check exists to get away from.
  $psi.Environment.Clear()
  $psi.Environment['PATH'] = ($PathDirs -join ';')
  # SystemRoot is not a convenience: ntdll, the CRT and Winsock read it, and
  # a process without it fails for reasons that have nothing to do with the
  # package. It names a DIRECTORY, not a search path, so it cannot supply a
  # missing DLL the way %PATH% can -- which is what keeps it honest.
  $psi.Environment['SystemRoot'] = $env:SystemRoot
  $psi.Environment['windir'] = $env:SystemRoot

  $p = [System.Diagnostics.Process]::Start($psi)
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    try { $p.Kill($true) } catch { }
    return @{ TimedOut = $true; Exit = -1; Out = ''; Err = '' }
  }
  return @{
    TimedOut = $false
    Exit     = $p.ExitCode
    Out      = $outTask.GetAwaiter().GetResult()
    Err      = $errTask.GetAwaiter().GetResult()
  }
}

$TreeRoot = (Resolve-Path -LiteralPath $TreeRoot).Path
$binDir = Join-Path $TreeRoot 'bin'
if (-not (Test-Path -LiteralPath $binDir)) {
  Write-Output "FAIL no bin/ under $TreeRoot"
  exit 1
}

$exes = @(Get-ChildItem -LiteralPath $binDir -Filter '*.exe' -File | Sort-Object Name)
if ($exes.Count -eq 0) {
  # VACUITY REFUSAL. This check has no value it can report when it launched
  # nothing, and "0 failures" over 0 probes is the shape of a false green.
  Write-Output "FAIL no executables under $binDir -- nothing was probed"
  exit 1
}

$workRoot = Join-Path ([IO.Path]::GetTempPath()) ("repro-scrubbed-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $workRoot
Write-Output "tree      : $TreeRoot"
Write-Output "PATH      : $($SystemDirectories -join ';')"
Write-Output "cwd       : $workRoot (empty)"
Write-Output "probes    : $($exes.Count)"
Write-Output ''

$failed = 0
foreach ($exe in $exes) {
  $probe = if ($Probes.ContainsKey($exe.Name)) { $Probes[$exe.Name] } else { $null }
  $argv = if ($null -ne $probe) { $probe.Args } else { @('--version') }
  $r = Invoke-Scrubbed -Exe $exe.FullName -Arguments $argv -WorkDir $workRoot `
        -PathDirs $SystemDirectories -TimeoutSeconds $TimeoutSeconds

  $why = @()
  if ($r.TimedOut) {
    $why += "timed out after ${TimeoutSeconds}s"
  } else {
    if ($LoaderStatuses.ContainsKey($r.Exit)) {
      $why += ("loader refused the image: 0x{0:X8} {1}" -f $r.Exit, $LoaderStatuses[$r.Exit])
    }
    $combined = "$($r.Out)`n$($r.Err)"
    if ($combined -match 'could not load:\s*(\S+)') {
      $why += "module-init dynlib failure: $($Matches[0].Trim())"
    }
    if ($combined -match 'The code execution cannot proceed') {
      $why += 'loader error dialog text on the stream'
    }
    if ($null -ne $probe -and $r.Exit -ne $probe.ExpectExit) {
      $why += ("expected exit {0} from '{1}', got {2}" -f $probe.ExpectExit, ($argv -join ' '), $r.Exit)
    }
  }

  if ($why.Count -gt 0) {
    $failed++
    Write-Output ("FAIL {0} [{1}]" -f $exe.Name, ($argv -join ' '))
    foreach ($w in $why) { Write-Output "       $w" }
    $tail = (("$($r.Out)`n$($r.Err)").Trim() -split "`n" | Select-Object -First 3)
    foreach ($t in $tail) { if ($t.Trim()) { Write-Output "       | $($t.Trim())" } }
  } else {
    Write-Output ("ok   {0} [{1}] exit={2}" -f $exe.Name, ($argv -join ' '), $r.Exit)
  }
}


# ---- ARM 2: every staged DLL must LOAD, scrubbed ----------------------
#
# WHY ARM 1 IS NOT ENOUGH, MEASURED RATHER THAN REASONED. Deleting each
# staged library in turn and re-running arm 1 refuses four of the six --
# libcrypto, libssl, sqlite3 and clingo, all resolved at MODULE INIT, all
# caught before `main`. It does NOT refuse `libgcc_s_seh-1.dll`, because
# that one is a STATIC import of `librepro_project_dsl_runtime.dll`, and
# `repro --version` never loads that DLL. An entry-point launch can only
# exercise what the entry point reaches.
#
# So the staged DLLs are loaded DIRECTLY as well, each in its own scrubbed
# process, with `LOAD_WITH_ALTERED_SEARCH_PATH` so that the loader resolves
# the loaded module's own dependencies from the module's directory -- which
# is what the real process does, since its image sits in that same `bin/`.
# A static import the package failed to ship then fails here with
# ERROR_MOD_NOT_FOUND (126) naming nothing, which is why the failing DLL's
# NAME is printed by this loop rather than by the loader.
#
# The probe host is the SYSTEM `powershell.exe`: it is on every Windows
# machine, it is outside the staged tree (so it contributes no search path
# of its own), and it takes its environment from the same scrub.
$dlls = @(Get-ChildItem -LiteralPath $binDir -Filter '*.dll' -File | Sort-Object Name)
$systemPwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ($dlls.Count -gt 0 -and (Test-Path -LiteralPath $systemPwsh)) {
  Write-Output ''
  Write-Output "loads     : $($dlls.Count) staged DLLs, each LoadLibraryEx'd scrubbed"
  $loaderProbe = @'
param([string]$Dll)
$sig = @"
using System;
using System.Runtime.InteropServices;
public static class L {
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr LoadLibraryExW(string f, IntPtr h, uint flags);
}
"@
Add-Type -TypeDefinition $sig
$h = [L]::LoadLibraryExW($Dll, [IntPtr]::Zero, 0x00000008)
if ($h -eq [IntPtr]::Zero) {
  $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  Write-Output ("LOADFAIL {0} win32={1}" -f $Dll, $e)
  exit 1
}
Write-Output "LOADOK $Dll"
exit 0
'@
  $probeFile = Join-Path $workRoot 'loadprobe.ps1'
  Set-Content -LiteralPath $probeFile -Value $loaderProbe -Encoding UTF8
  foreach ($dll in $dlls) {
    $r = Invoke-Scrubbed -Exe $systemPwsh `
          -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probeFile, '-Dll', $dll.FullName) `
          -WorkDir $workRoot -PathDirs $SystemDirectories -TimeoutSeconds $TimeoutSeconds
    $combined = "$($r.Out)`n$($r.Err)"
    if ($r.TimedOut -or $r.Exit -ne 0 -or $combined -match 'LOADFAIL') {
      $failed++
      Write-Output ("FAIL load {0}" -f $dll.Name)
      $tail = ($combined.Trim() -split "`n" | Select-Object -First 3)
      foreach ($t in $tail) { if ($t.Trim()) { Write-Output "       | $($t.Trim())" } }
    } else {
      Write-Output ("ok   load {0}" -f $dll.Name)
    }
  }
} elseif ($dlls.Count -eq 0) {
  # A prefix-rooted Windows tree with no DLL beside its executables is the
  # exact shape the shipped packages had for three passes. It is not a
  # reason to pass quietly.
  Write-Output ''
  Write-Output "WARN no DLLs staged beside the executables in $binDir"
}

Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ''
Write-Output "PROBED=$($exes.Count) LOADS=$($dlls.Count) FAILED=$failed"
if ($failed -gt 0) { exit 1 }
exit 0
