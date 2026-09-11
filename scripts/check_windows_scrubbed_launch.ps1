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

function Get-PeImportedModules {
  <#
    THE GENERAL PE-IMPORT WALK -- M1's N31, and the PE half of what
    `runtimeClosureScript` does for ELF. It reads the IMPORT DIRECTORY
    (data directory 1) and the DELAY-LOAD IMPORT DIRECTORY (data
    directory 13) out of the file's OWN BYTES and returns every module
    they name. No list, no registry, no loader, nothing about this host.
  #>
  param([Parameter(Mandatory = $true)][string]$Path)

  $b = [IO.File]::ReadAllBytes($Path)
  if ($b.Length -lt 0x40) { throw "not a PE: $Path (too short)" }
  if ($b[0] -ne 0x4D -or $b[1] -ne 0x5A) { throw "not a PE: $Path (no MZ)" }
  $peOff = [BitConverter]::ToInt32($b, 0x3C)
  if ($peOff -le 0 -or $peOff + 24 -ge $b.Length) { throw "not a PE: $Path (bad e_lfanew)" }
  if ($b[$peOff] -ne 0x50 -or $b[$peOff + 1] -ne 0x45) { throw "not a PE: $Path (no PE signature)" }

  $numSections = [BitConverter]::ToUInt16($b, $peOff + 6)
  $sizeOfOpt = [BitConverter]::ToUInt16($b, $peOff + 20)
  $optOff = $peOff + 24
  $magic = [BitConverter]::ToUInt16($b, $optOff)
  # The data directories sit after the optional header's fixed part, and
  # the fixed part is a different length in PE32 and PE32+ because four
  # fields widen to 64 bits. Both are handled: the payload is PE32+, but
  # a 32-bit helper in the same tree must not silently parse as garbage.
  if ($magic -eq 0x20B) { $ddOff = $optOff + 112 }
  elseif ($magic -eq 0x10B) { $ddOff = $optOff + 96 }
  else { throw ("not a PE: {0} (optional-header magic 0x{1:X})" -f $Path, $magic) }
  $numRvaAndSizes = [BitConverter]::ToUInt32($b, $ddOff - 4)

  $secOff = $optOff + $sizeOfOpt
  $sections = @()
  for ($i = 0; $i -lt $numSections; $i++) {
    $s = $secOff + ($i * 40)
    $sections += [pscustomobject]@{
      VirtualSize = [BitConverter]::ToUInt32($b, $s + 8)
      VirtualAddress = [BitConverter]::ToUInt32($b, $s + 12)
      SizeOfRawData = [BitConverter]::ToUInt32($b, $s + 16)
      PointerToRaw = [BitConverter]::ToUInt32($b, $s + 20)
    }
  }

  function Convert-RvaToOffset {
    param([uint32]$Rva)
    foreach ($s in $sections) {
      $span = [Math]::Max($s.VirtualSize, $s.SizeOfRawData)
      if ($Rva -ge $s.VirtualAddress -and $Rva -lt ($s.VirtualAddress + $span)) {
        return [int]($s.PointerToRaw + ($Rva - $s.VirtualAddress))
      }
    }
    return -1
  }
  function Read-AsciiAt {
    param([int]$Offset)
    if ($Offset -lt 0 -or $Offset -ge $b.Length) { return '' }
    $end = $Offset
    while ($end -lt $b.Length -and $b[$end] -ne 0) { $end++ }
    return [Text.Encoding]::ASCII.GetString($b, $Offset, $end - $Offset)
  }

  $names = New-Object System.Collections.Generic.List[string]

  if ($numRvaAndSizes -gt 1) {
    $impRva = [BitConverter]::ToUInt32($b, $ddOff + (1 * 8))
    if ($impRva -ne 0) {
      $o = Convert-RvaToOffset $impRva
      while ($o -ge 0 -and ($o + 20) -le $b.Length) {
        $oft = [BitConverter]::ToUInt32($b, $o + 0)
        $nameRva = [BitConverter]::ToUInt32($b, $o + 12)
        $ft = [BitConverter]::ToUInt32($b, $o + 16)
        if ($nameRva -eq 0 -and $oft -eq 0 -and $ft -eq 0) { break }
        $n = Read-AsciiAt (Convert-RvaToOffset $nameRva)
        if ($n) { [void]$names.Add($n) }
        $o += 20
      }
    }
  }

  # DELAY-LOAD. The loader does NOT resolve these at image load, so a
  # missing one is a crash at the first call through the stub rather than
  # a refusal at start -- strictly worse to diagnose, and invisible to
  # both of the cheap arms. It counts as a requirement.
  if ($numRvaAndSizes -gt 13) {
    $dlyRva = [BitConverter]::ToUInt32($b, $ddOff + (13 * 8))
    if ($dlyRva -ne 0) {
      $o = Convert-RvaToOffset $dlyRva
      while ($o -ge 0 -and ($o + 32) -le $b.Length) {
        $attrs = [BitConverter]::ToUInt32($b, $o + 0)
        $nameRva = [BitConverter]::ToUInt32($b, $o + 4)
        if ($attrs -eq 0 -and $nameRva -eq 0) { break }
        # Bit 0 (dlattrRva) says the descriptor's addresses are RVAs.
        # Pre-VS2005 linkers emitted absolute VAs, which are not
        # convertible without the image base; those are skipped rather
        # than mis-parsed into a name that is not there.
        if (($attrs -band 1) -eq 1) {
          $n = Read-AsciiAt (Convert-RvaToOffset $nameRva)
          if ($n) { [void]$names.Add($n) }
        }
        $o += 32
      }
    }
  }

  return $names.ToArray()
}

function Test-ApiSetName {
  param([Parameter(Mandatory = $true)][string]$Name)
  # API-set forwarders are resolved by the loader from the schema in
  # ntdll and have no file anywhere on disk, so a Test-Path over the
  # system directories would call every one of them missing.
  return ($Name -match '^(?i)(api-ms-win-|ext-ms-win-)')
}

function Test-RedistributableName {
  param([Parameter(Mandatory = $true)][string]$Name)
  # NOT Windows, even when System32 has it. The Visual C++
  # redistributable is a SEPARATE Microsoft package; it is in System32 on
  # this host because a developer tool installed it, which is exactly the
  # developer-machine dependency this check exists to expose. The names
  # here are the redistributable's own families -- a property of
  # Microsoft's packaging, not of reprobuild's payload.
  #
  # It used to WARN, because "ship them / declare an MSI prerequisite /
  # rebuild clingo" was an open packaging decision and not a script's to
  # make. The decision is made (M1's N32: vendored app-local from the
  # Visual Studio redist directory), so the closure arm below now FAILS
  # on a redistributable requirement that is not staged.
  return ($Name -match '^(?i)(msvcp[0-9]|vcruntime[0-9]|concrt[0-9]|vcomp[0-9]|vcamp[0-9]|mfc[0-9]|msvcr[0-9])')
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


# ---- ARM 2: THE REQUIREMENT CLOSURE, AND THEN THE LOADS ---------------
#
# WHY ARM 1 IS NOT ENOUGH, MEASURED RATHER THAN REASONED. Deleting each
# staged library in turn and re-running arm 1 refuses four of the nine --
# libcrypto, libssl, sqlite3 and clingo, all resolved at MODULE INIT, all
# caught before `main`. It does NOT refuse `libgcc_s_seh-1.dll`, because
# that one is a STATIC import of `librepro_project_dsl_runtime.dll`, and
# `repro --version` never loads that DLL. An entry-point launch can only
# exercise what the entry point reaches.
#
# AND WHY THE OLD ARM 2 WAS NOT ENOUGH EITHER -- M1's N31, as the
# seventh-pass review widened it. It enumerated the DLLs in `bin/`, which
# is WHAT IS STAGED, and then loaded each one. A check built that way
# agrees with whatever the staging list says: delete a DLL from the list
# AND from the tree and there is nothing left to disagree with. Measured:
# deleting `libzstd.dll`, `librepro_monitor_shim.dll` or
# `librepro_project_dsl_runtime.dll` left BOTH arms green.
#
# SO THE CLOSURE IS DERIVED FIRST. `Get-PeImportedModules` reads the
# import and delay-load directories out of each staged image's own bytes
# and the walk follows them TRANSITIVELY, which is how
# `librepro_project_dsl_runtime.dll -> libgcc_s_seh-1.dll ->
# libwinpthread-1.dll` terminates at KERNEL32 and the API-set forwarders.
# Every name the closure reaches that the system directories do not supply
# is a REQUIREMENT, and a requirement that is not in `bin/` FAILS -- by
# name, before anything is launched, and without consulting any list.
$dlls = @(Get-ChildItem -LiteralPath $binDir -Filter '*.dll' -File | Sort-Object Name)
$images = @($exes) + @($dlls)

$requiredBy = @{}     # requirement (lower) -> importers
$displayName = @{}    # requirement (lower) -> name as the import table spells it
$walked = @{}
$parsed = 0
$importEdges = 0
$queue = New-Object System.Collections.Generic.Queue[string]
foreach ($img in $images) { $queue.Enqueue($img.FullName) }
while ($queue.Count -gt 0) {
  $path = $queue.Dequeue()
  $key = $path.ToLowerInvariant()
  if ($walked.ContainsKey($key)) { continue }
  $walked[$key] = $true
  $imports = @()
  try {
    $imports = @(Get-PeImportedModules -Path $path)
    $parsed++
  } catch {
    $script:failed++
    Write-Output ("FAIL cannot parse as PE: {0}" -f (Split-Path -Leaf $path))
    Write-Output ("       {0}" -f $_.Exception.Message)
    continue
  }
  foreach ($imp in $imports) {
    $importEdges++
    if (Test-ApiSetName -Name $imp) { continue }
    $ik = $imp.ToLowerInvariant()
    $staged = Join-Path $binDir $imp
    $isStaged = Test-Path -LiteralPath $staged
    if (-not $isStaged) {
      # Supplied by the host, or supplied by nobody. Either way it is not
      # a module this package ships, so the walk stops here -- but a
      # redistributable that only LOOKS like a system module is called out.
      $isSystem = $false
      foreach ($d in $SystemDirectories) {
        if (Test-Path -LiteralPath (Join-Path $d $imp)) { $isSystem = $true; break }
      }
      if ($isSystem -and -not (Test-RedistributableName -Name $imp)) { continue }
    }
    if (-not $requiredBy.ContainsKey($ik)) {
      $requiredBy[$ik] = New-Object System.Collections.Generic.List[string]
      $displayName[$ik] = $imp
    }
    [void]$requiredBy[$ik].Add((Split-Path -Leaf $path))
    if ($isStaged) { $queue.Enqueue((Resolve-Path -LiteralPath $staged).Path) }
  }
}

Write-Output ''
Write-Output ("closure   : {0} images parsed, {1} import edges, {2} non-system requirements" -f $parsed, $importEdges, $requiredBy.Count)
if ($parsed -eq 0 -or $importEdges -eq 0) {
  # VACUITY REFUSAL for the walk itself. A PE parser that returns nothing
  # is indistinguishable from a package that needs nothing, and the second
  # of those has never existed.
  Write-Output "FAIL the import walk parsed nothing -- it cannot report a closure it did not read"
  $failed++
}

foreach ($k in ($requiredBy.Keys | Sort-Object)) {
  $name = $displayName[$k]
  $by = ($requiredBy[$k] | Sort-Object -Unique) -join ', '
  if (Test-Path -LiteralPath (Join-Path $binDir $name)) {
    Write-Output ("req  {0} <- {1}" -f $name, $by)
  } elseif (Test-RedistributableName -Name $name) {
    # WAS A WARNING, AND IS NOW A FAILURE (M1's N32, resolved). The warning
    # was deliberate while "vendor / declare / rebuild" was an open
    # packaging decision a script had no business making. The decision is
    # made -- the three DLLs are vendored app-local from the Visual Studio
    # redist directory, declared in `reprobuildWindowsLoaderLibraries` and
    # staged by `stage_payload_windows.sh` -- so the only thing a
    # redistributable requirement that is NOT staged can now mean is that
    # something regressed, and a warning is not how this campaign reports
    # that. Note the asymmetry that makes this arm worth having at all: a
    # redistributable is in System32 on every developer machine, so arm 1
    # cannot see it and only the import table can.
    $failed++
    Write-Output ("FAIL redistributable requirement not shipped: {0} <- {1}" -f $name, $by)
    Write-Output "       NOT part of Windows: this is the Visual C++ redistributable, a"
    Write-Output "       SEPARATE Microsoft package that a clean install may not have. It"
    Write-Output "       resolves on this host only because some developer tool installed"
    Write-Output "       it into System32, which is why a launch cannot catch it."
  } else {
    $failed++
    Write-Output ("FAIL missing requirement {0} <- {1}" -f $name, $by)
    Write-Output "       named by the import table of a shipped image, absent from bin/,"
    Write-Output "       and absent from the system directories"
  }
}

# WHAT THE STATIC CLOSURE CANNOT SEE, stated rather than left implied. A
# library the process resolves by NAME at run time -- Nim's `{.dynlib.}`
# bindings, and reprobuild's own two shared libraries, which the CLI loads
# through a computed path -- leaves no import-table entry anywhere, so no
# walk over import tables can require it. Arm 1 catches the module-init
# ones; the run-time ones are what the build gate exercises by building
# something. Naming them here is what keeps the gap visible instead of
# letting a green run imply a completeness nothing established.
$unjustified = @()
foreach ($d in $dlls) {
  if (-not $requiredBy.ContainsKey($d.Name.ToLowerInvariant())) { $unjustified += $d.Name }
}
if ($unjustified.Count -gt 0) {
  Write-Output ("note      : staged but not reachable from any import table: {0}" -f ($unjustified -join ', '))
  Write-Output "            (loaded by name at run time -- see the comment above)"
}

# ---- AND THEN THE LOADS ----------------------------------------------
#
# Each staged DLL is loaded DIRECTLY, in its own scrubbed process, with
# `LOAD_WITH_ALTERED_SEARCH_PATH` so the loader resolves the loaded
# module's own dependencies from the module's directory -- which is what
# the real process does, since its image sits in that same `bin/`. A
# static import the package failed to ship fails here with
# ERROR_MOD_NOT_FOUND (126) naming nothing, which is why the failing
# DLL's NAME is printed by this loop rather than by the loader.
#
# The probe host is the SYSTEM `powershell.exe`: it is on every Windows
# machine, it is outside the staged tree (so it contributes no search path
# of its own), and it takes its environment from the same scrub.
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
Write-Output "PROBED=$($exes.Count) LOADS=$($dlls.Count) REQUIRED=$($requiredBy.Count) FAILED=$failed"
if ($failed -gt 0) { exit 1 }
exit 0
