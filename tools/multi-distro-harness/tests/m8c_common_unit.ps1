<#
Unit checks of m8c_common.ps1's host-independent helpers, the ones the
Windows completion checks depend on to talk to Git for Windows' MSYS tools
and to native programs at all:

  ConvertTo-ScriptPath   a Windows path in the form every MSYS tool reads
                         (/c/...), UNC and drive-relative paths refused;
                         checked with -Windows, so the Windows rules run on
                         any host
  Invoke-NativeCommand   a native program's standard error is shown, never
                         raised under $ErrorActionPreference = 'Stop', and
                         the preference is restored afterwards
  Get-ReproVersion       the version an archive made from a build tree is
                         named for, from reprobuild.nimble
  Get-PowerShellHome     the $PSHOME a PowerShell reports for itself

  pwsh -NoProfile -File tools/multi-distro-harness/tests/m8c_common_unit.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\multi-distro-harness\tests\m8c_common_unit.ps1

Runs under PowerShell 7 on any host and under Windows PowerShell 5.1; the
native program it starts is `sh` (Git for Windows' on Windows, found beside
its bash). It writes only a scratch directory under the temporary directory,
removed at the end. Exit status 0 when every check passed, 1 otherwise.

Windows PowerShell 5.1 is where a native program's redirected standard error
becomes a terminating error under 'Stop' (PowerShell 7.2 and later no longer
apply the preference to those records), so the check that the OLD call shape
`& sh -c ... 2>&1` throws is reported, not asserted: it is expected to throw
under 5.1 and not under 7.2+. The assertion is that Invoke-NativeCommand does
not throw on either.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'm8c_common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$Work = Join-Path ([IO.Path]::GetTempPath()) ('m8c-common-unit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $Work | Out-Null

function Assert-Throws {
  param([scriptblock]$Block, [string]$Want, [string]$Text)
  try {
    & $Block | Out-Null
    Fail "${Text}: did not throw"
  } catch {
    $msg = $_.Exception.Message
    if ($msg -like "*$Want*") { Pass "${Text}: refused ($msg)" } else { Fail "${Text}: threw '$msg', expected it to mention '$Want'" }
  }
}

$exit = 1
try {
  Write-Step 'ConvertTo-ScriptPath, Windows rules'
  $cases = @(
    @('C:\Users\someone\AppData\Local\Temp\m8c-x\gnupg', '/c/Users/someone/AppData/Local/Temp/m8c-x/gnupg', 'a drive path, backslashes'),
    @('D:\with space\and  two\x.zip', '/d/with space/and  two/x.zip', 'spaces are kept as they are'),
    @('c:/already/forward', '/c/already/forward', 'a drive path with forward slashes'),
    @('E:\mixed/separators\here', '/e/mixed/separators/here', 'mixed separators'),
    @('Z:\', '/z/', 'a drive root'),
    @('relative\dir\file', 'relative/dir/file', 'a relative path only has its separators turned'),
    @('./scripts/x.sh', './scripts/x.sh', 'a relative POSIX path is unchanged')
  )
  foreach ($c in $cases) { Assert-Equal (ConvertTo-ScriptPath -Path $c[0] -Windows $true) $c[1] "ConvertTo-ScriptPath: $($c[2])" }
  Assert-Throws { ConvertTo-ScriptPath -Path '\\server\share\dir' -Windows $true } 'UNC' 'ConvertTo-ScriptPath: a UNC path'
  Assert-Throws { ConvertTo-ScriptPath -Path '//server/share/dir' -Windows $true } 'UNC' 'ConvertTo-ScriptPath: a UNC path with forward slashes'
  Assert-Throws { ConvertTo-ScriptPath -Path '\\?\C:\long\path' -Windows $true } 'UNC' 'ConvertTo-ScriptPath: an extended-length path'
  Assert-Throws { ConvertTo-ScriptPath -Path 'C:relative' -Windows $true } 'relative to the current directory of drive C' 'ConvertTo-ScriptPath: a drive-relative path'
  Assert-Throws { ConvertTo-ScriptPath -Path 'C:' -Windows $true } 'relative to the current directory of drive C' 'ConvertTo-ScriptPath: a bare drive'
  # Off Windows a path is a POSIX path already, backslash and all.
  Assert-Equal (ConvertTo-ScriptPath -Path '/tmp/a\b' -Windows $false) '/tmp/a\b' 'ConvertTo-ScriptPath: off Windows a path is unchanged'
  # Without -Windows the host decides.
  $hostWant = if ($script:M8cOnWindows) { '/c/x/y' } else { 'C:\x\y' }
  Assert-Equal (ConvertTo-ScriptPath 'C:\x\y') $hostWant 'ConvertTo-ScriptPath: without -Windows the host decides'

  Write-Step 'Invoke-NativeCommand under $ErrorActionPreference = Stop'
  $sh = ''
  if ($script:M8cOnWindows) {
    $bash = Get-ScriptBash -RepoRoot $RepoRoot
    if ($bash) { $c = Join-Path (Split-Path -Parent $bash) 'sh.exe'; if (Test-Path -LiteralPath $c) { $sh = $c } }
  } else {
    $c = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $sh = $c.Source }
  }
  if (-not $sh) { throw 'no sh to run (Git for Windows on Windows)' }
  # No double quote in any argument: Windows PowerShell 5.1 passes an
  # argument's embedded double quotes to a native program unescaped, which
  # splits it (PowerShell 7.3+ escapes them), and these checks also run
  # under 5.1.
  $noisy = 'echo out-1; echo err-1 a log line on stderr >&2; echo out-2; echo err-2 >&2; exit 3'
  # The old call shape, for the record: under Windows PowerShell 5.1 it
  # throws on the first stderr line, under PowerShell 7.2+ it does not.
  $oldThrew = $false
  try { & $sh -c $noisy 2>&1 | Out-Null } catch { $oldThrew = $true }
  Write-Host ("old shape '& sh -c ... 2>&1' under Stop on PowerShell {0}: {1}" -f $PSVersionTable.PSVersion, $(if ($oldThrew) { 'THREW (the defect Invoke-NativeCommand avoids)' } else { 'did not throw' }))
  $threw = ''
  $r = $null
  try { $r = Invoke-NativeCommand -FilePath $sh -ArgumentList @('-c', $noisy) -Quiet } catch { $threw = $_.Exception.Message }
  Assert-Equal $threw '' 'Invoke-NativeCommand: stderr lines raise nothing'
  if ($r) {
    Assert-Equal $r.Code 3 'Invoke-NativeCommand: the exit code is the program''s'
    Assert-Equal ($r.Output -join '|') 'out-1|out-2' 'Invoke-NativeCommand: .Output is standard output only, in order'
  } else {
    Fail 'Invoke-NativeCommand: returned nothing'
  }
  Assert-Equal $ErrorActionPreference 'Stop' 'Invoke-NativeCommand: the caller''s preference is Stop again afterwards'
  # With IFS empty, $1 and $2 are not split, so each line is one argument
  # exactly as it arrived.
  $r = Invoke-NativeCommand -FilePath $sh -ArgumentList @('-c', 'IFS=; printf ''%s\n'' $1 $2', 'sh', 'a b', 'c') -Quiet
  Assert-Equal "$($r.Code) $($r.Output -join '|')" '0 a b|c' 'Invoke-NativeCommand: arguments with spaces arrive as one argument each'
  # PowerShell 7.3+ can also turn a non-zero exit into an error under the
  # preference ($PSNativeCommandUseErrorActionPreference). The control: the
  # bare call throws with it set, Invoke-NativeCommand still returns the
  # exit code for its caller to judge.
  if ($PSVersionTable.PSVersion -ge [version]'7.3') {
    $PSNativeCommandUseErrorActionPreference = $true
    try {
      $bareThrew = $false
      try { & $sh -c 'exit 4' } catch { $bareThrew = $true }
      Assert-True $bareThrew 'control: with $PSNativeCommandUseErrorActionPreference a bare non-zero exit throws under Stop'
      $threw = ''
      $r = $null
      try { $r = Invoke-NativeCommand -FilePath $sh -ArgumentList @('-c', 'echo e >&2; exit 4') -Quiet } catch { $threw = $_.Exception.Message }
      Assert-Equal $threw '' 'Invoke-NativeCommand: with $PSNativeCommandUseErrorActionPreference a non-zero exit raises nothing'
      Assert-Equal $(if ($r) { $r.Code } else { 'none' }) 4 'Invoke-NativeCommand: and returns that exit code'
    } finally {
      $PSNativeCommandUseErrorActionPreference = $false
    }
  }
  Assert-Throws { Invoke-NativeCommand -FilePath (Join-Path $Work 'no-such-program') } 'no-such-program' 'Invoke-NativeCommand: a program that does not exist'
  Assert-Equal $ErrorActionPreference 'Stop' 'Invoke-NativeCommand: still Stop after a refused call'

  Write-Step 'Get-ReproVersion'
  $fake = Join-Path $Work 'fake-repo'
  New-Item -ItemType Directory -Force -Path $fake | Out-Null
  Set-Content -LiteralPath (Join-Path $fake 'reprobuild.nimble') -Value @('# a comment', 'version       = "7.6.5"', 'author = "x"')
  Assert-Equal (Get-ReproVersion -RepoRoot $fake) '7.6.5' 'Get-ReproVersion: the version line of reprobuild.nimble'
  Set-Content -LiteralPath (Join-Path $fake 'reprobuild.nimble') -Value @('author = "x"')
  Assert-Throws { Get-ReproVersion -RepoRoot $fake } 'no version line' 'Get-ReproVersion: a nimble file without a version'
  $line = Select-String -LiteralPath (Join-Path $RepoRoot 'reprobuild.nimble') -Pattern '^version' | Select-Object -First 1
  Assert-True ($null -ne $line -and $line.Line.Contains('"' + (Get-ReproVersion -RepoRoot $RepoRoot) + '"')) "Get-ReproVersion: this checkout's version ($(Get-ReproVersion -RepoRoot $RepoRoot))"

  Write-Step 'Get-PowerShellHome'
  $self = (Get-Process -Id $PID).Path
  Assert-Equal (Get-PowerShellHome -PowerShell $self) $PSHOME 'Get-PowerShellHome: this PowerShell reports the $PSHOME it runs with'
  $notPs = Join-Path $Work 'not-a-powershell.cmd'
  if ($script:M8cOnWindows) {
    Set-Content -LiteralPath $notPs -Value '@exit /b 0'
  } else {
    $notPs = Join-Path $Work 'not-a-powershell'
    Set-Content -LiteralPath $notPs -Value "#!/bin/sh`nexit 0"
    $null = Invoke-NativeCommand -FilePath 'chmod' -ArgumentList @('+x', $notPs)
  }
  Assert-Throws { Get-PowerShellHome -PowerShell $notPs } 'did not report' 'Get-PowerShellHome: a program that reports no $PSHOME'

  $exit = Complete-Run -Name 'm8c_common_unit' -Work $Work
} catch {
  Write-Host "HARNESS DIED: $($_.Exception.Message)"
  Write-Host $_.ScriptStackTrace
  $exit = 1
} finally {
  Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}
exit $exit
