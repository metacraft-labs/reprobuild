<#
Shared helpers of the Windows completion checks:

  m8c_install_completion_windows.ps1        the install script's archive method
  m8c_windows_packages_carry_completion.ps1 the MSI and the Scoop manifest

Dot-source it. Windows PowerShell 5.1 and PowerShell 7 compatible; the parts
that do not depend on Windows also run under pwsh on Linux.

ISOLATION. Every PowerShell or repro these checks start runs with an
environment built here from nothing but the system variables Windows needs
and a scratch home: USERPROFILE, HOME, LOCALAPPDATA, APPDATA, TEMP and TMP
(on Linux HOME and the XDG directories) all point inside the run's scratch
directory. PowerShell's per-user profiles live under the Documents folder,
which Windows reads from the registry (`User Shell Folders\Personal`). Its
default value is `%USERPROFILE%\Documents`, expanded with the process's own
environment, so a redirected USERPROFILE moves it into the scratch home for
repro (SHGetFolderPathW) and for PowerShell alike. Assert-DocumentsInScratch
asks a PowerShell started in that environment where Documents is and REFUSES
to go on when the answer lies outside the scratch directory (a Documents
folder the registry names absolutely, such as one redirected to OneDrive):
nothing then could keep the run off the invoking user's real profiles. The
real profiles' hashes are recorded before and after (Get-RealProfileState),
so a write that slipped past would show.
#>

Set-StrictMode -Version Latest

$script:M8cChecks = 0
$script:M8cFails = 0
$script:M8cNotRun = New-Object System.Collections.Generic.List[string]
$script:M8cOnWindows = ($env:OS -eq 'Windows_NT')

function Write-Step { param([string]$Text) Write-Host ''; Write-Host "=== $Text ===" }
function Pass { param([string]$Text) $script:M8cChecks++; Write-Host "PASS  $Text" }
function Fail { param([string]$Text) $script:M8cChecks++; $script:M8cFails++; Write-Host "FAIL  $Text" }
function NotRun { param([string]$Text) $script:M8cNotRun.Add($Text); Write-Host "NOT RUN  $Text" }
function Assert-Equal {
  param($Got, $Want, [string]$Text)
  if ("$Got" -eq "$Want") { Pass "$Text (= $Got)" } else { Fail "${Text}: expected '$Want', got '$Got'" }
}
function Assert-True {
  param([bool]$Condition, [string]$Text)
  if ($Condition) { Pass $Text } else { Fail $Text }
}

# The summary line and exit status: 0 when every check passed and nothing was
# NOT RUN, 1 on a failure, 3 when all passed but something was NOT RUN.
function Complete-Run {
  param([string]$Name, [string]$Work)
  Write-Host ''
  Write-Host ("{0}: {1} checks, {2} failure(s); scratch directory {3}" -f $Name, $script:M8cChecks, $script:M8cFails, $Work)
  foreach ($n in $script:M8cNotRun) { Write-Host "NOT RUN: $n" }
  if ($script:M8cFails -gt 0) { return 1 }
  if ($script:M8cChecks -eq 0) { Write-Host 'no check ran'; return 1 }
  if ($script:M8cNotRun.Count -gt 0) { return 3 }
  return 0
}

# Quotes one argument for a Windows command line, the way
# CommandLineToArgvW and the .NET runtime split it
# (https://learn.microsoft.com/cpp/c-language/parsing-c-command-line-arguments).
function ConvertTo-CommandLineArgument {
  param([string]$Value)
  if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $slashes = 0
  foreach ($ch in $Value.ToCharArray()) {
    if ($ch -eq '\') { $slashes++; continue }
    if ($ch -eq '"') { [void]$sb.Append('\' * ($slashes * 2 + 1)); [void]$sb.Append('"'); $slashes = 0; continue }
    if ($slashes -gt 0) { [void]$sb.Append('\' * $slashes); $slashes = 0 }
    [void]$sb.Append($ch)
  }
  if ($slashes -gt 0) { [void]$sb.Append('\' * ($slashes * 2)) }
  [void]$sb.Append('"')
  return $sb.ToString()
}

# The environment of an isolated process: the system variables Windows needs
# to start a program, and the scratch home's per-user directories. Nothing of
# the invoking user's own environment (in particular no PSModulePath, which a
# PowerShell 7 parent would hand to Windows PowerShell 5.1 and break it).
function New-IsolatedEnvironment {
  param([string]$HomeDir, [string]$TempDir, [string[]]$PathDirs)
  $e = @{}
  if ($script:M8cOnWindows) {
    foreach ($n in @('SystemRoot', 'windir', 'SystemDrive', 'ComSpec', 'PATHEXT', 'OS',
        'PROCESSOR_ARCHITECTURE', 'NUMBER_OF_PROCESSORS', 'ProgramData', 'ProgramFiles',
        'ProgramFiles(x86)', 'ProgramW6432', 'CommonProgramFiles', 'CommonProgramFiles(x86)',
        'CommonProgramW6432', 'USERNAME', 'USERDOMAIN', 'COMPUTERNAME')) {
      $v = [Environment]::GetEnvironmentVariable($n)
      if ($v) { $e[$n] = $v }
    }
    $e['USERPROFILE'] = $HomeDir
    $e['HOME'] = $HomeDir
    $e['HOMEDRIVE'] = [IO.Path]::GetPathRoot($HomeDir).TrimEnd('\')
    $e['HOMEPATH'] = $HomeDir.Substring($e['HOMEDRIVE'].Length)
    $e['LOCALAPPDATA'] = [IO.Path]::Combine($HomeDir, 'AppData', 'Local')
    $e['APPDATA'] = [IO.Path]::Combine($HomeDir, 'AppData', 'Roaming')
    $sep = ';'
  } else {
    foreach ($n in @('LANG', 'TERM', 'USER', 'LOGNAME')) {
      $v = [Environment]::GetEnvironmentVariable($n)
      if ($v) { $e[$n] = $v }
    }
    $e['HOME'] = $HomeDir
    $e['XDG_CONFIG_HOME'] = [IO.Path]::Combine($HomeDir, '.config')
    $e['XDG_DATA_HOME'] = [IO.Path]::Combine($HomeDir, '.local', 'share')
    $e['XDG_CACHE_HOME'] = [IO.Path]::Combine($HomeDir, '.cache')
    $e['XDG_STATE_HOME'] = [IO.Path]::Combine($HomeDir, '.local', 'state')
    $sep = ':'
  }
  $e['TEMP'] = $TempDir
  $e['TMP'] = $TempDir
  $e['TMPDIR'] = $TempDir
  $e['PATH'] = ($PathDirs | Where-Object { $_ }) -join $sep
  $e['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
  $e['POWERSHELL_UPDATECHECK'] = 'Off'
  $e['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
  return $e
}

# Runs one program with exactly the environment given; returns its exit code
# and its standard output and error, interleaved by stream, not by time.
function Invoke-Isolated {
  param([string]$FilePath, [string[]]$Arguments, [hashtable]$Environment,
        [string]$WorkingDirectory, [int]$TimeoutSeconds = 600)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = (@($Arguments) | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
  $psi.EnvironmentVariables.Clear()
  foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] }
  $p = [System.Diagnostics.Process]::Start($psi)
  $errTask = $p.StandardError.ReadToEndAsync()
  $outTask = $p.StandardOutput.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    # Only the process this function started.
    try { $p.Kill() } catch { }
    $p.WaitForExit()
    return [pscustomobject]@{ Code = 124; Output = "TIMEOUT after $TimeoutSeconds s`n" + $outTask.Result + $errTask.Result }
  }
  $p.WaitForExit()
  return [pscustomobject]@{ Code = $p.ExitCode; Output = ($outTask.Result + $errTask.Result) }
}

# A PowerShell command line that runs $Script without quoting trouble:
# -EncodedCommand takes base64 of UTF-16LE.
function Get-EncodedCommand {
  param([string]$Script)
  return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
}

# The PowerShells to test, as [name, path] pairs: Windows PowerShell 5.1 and
# PowerShell 7 on Windows, pwsh elsewhere.
function Get-TestPowerShells {
  $list = @()
  if ($script:M8cOnWindows) {
    $wp = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $wp) { $list += , @('Windows PowerShell 5.1', $wp) }
  }
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh) { $list += , @('PowerShell 7', $pwsh.Source) }
  return , $list
}

# Where a PowerShell started in $Environment says the Documents folder is.
function Get-IsolatedDocuments {
  param([string]$PowerShell, [hashtable]$Environment, [string]$WorkingDirectory)
  $r = Invoke-Isolated -FilePath $PowerShell -Arguments @('-NoProfile', '-NonInteractive',
      '-EncodedCommand', (Get-EncodedCommand "[Console]::Out.WriteLine('M8C_DOCS:' + [Environment]::GetFolderPath('MyDocuments'))")) `
    -Environment $Environment -WorkingDirectory $WorkingDirectory -TimeoutSeconds 120
  foreach ($l in ($r.Output -split "`r?`n")) {
    if ($l.StartsWith('M8C_DOCS:')) { return $l.Substring(9).Trim() }
  }
  return ''
}

# Refuses to continue unless every PowerShell resolves Documents inside the
# scratch directory in the isolated environment (see the header). On Linux
# PowerShell's profile is under XDG_CONFIG_HOME, which the environment sets,
# so there is nothing to ask.
function Assert-DocumentsInScratch {
  param([object[]]$PowerShells, [hashtable]$Environment, [string]$Scratch, [string]$WorkingDirectory)
  if (-not $script:M8cOnWindows) { return $true }
  foreach ($ps in $PowerShells) {
    $docs = Get-IsolatedDocuments -PowerShell $ps[1] -Environment $Environment -WorkingDirectory $WorkingDirectory
    $inside = $docs -and $docs.StartsWith($Scratch.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) {
      Write-Host "REFUSED: $($ps[0]) resolves Documents to '$docs' with USERPROFILE=$($Environment['USERPROFILE']); that is not inside $Scratch, so the run would write the invoking user's real profiles. Nothing was run."
      return $false
    }
    Pass "$($ps[0]) resolves Documents inside the scratch directory: $docs"
  }
  return $true
}

# The invoking user's real profiles and per-user completion script (and on
# Windows the machine's all-users PowerShell profiles), each as
# "<sha256|absent> <path>", read in THIS process's own environment.
function Get-RealProfileState {
  $paths = @()
  if ($script:M8cOnWindows) {
    $d = [Environment]::GetFolderPath('MyDocuments')
    # "" when the folder does not exist: the profile paths would turn
    # relative and the comparison would cover the wrong files.
    if (-not $d) { throw 'the invoking user''s Documents folder does not resolve; cannot record the real profiles' }
    foreach ($rel in @('PowerShell\Profile.ps1', 'PowerShell\Microsoft.PowerShell_profile.ps1',
        'WindowsPowerShell\Profile.ps1', 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')) {
      $paths += (Join-Path $d $rel)
    }
    $paths += (Join-Path $env:LOCALAPPDATA 'repro\completions\repro.ps1')
    # The all-users profiles ($PSHOME\Profile.ps1) of Windows PowerShell 5.1
    # and of the PowerShell 7 on PATH, which `repro hooks ensure
    # --shell-autocomplete --system` writes and these checks must not.
    $paths += [IO.Path]::Combine($env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'Profile.ps1')
    # PowerShell 7's $PSHOME, asked of that PowerShell: the pwsh.exe on PATH
    # can be a launcher elsewhere (Scoop's shims directory), so the
    # directory it sits in is not where its all-users profile is.
    $pwsh = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh) { $paths += (Join-Path (Get-PowerShellHome -PowerShell $pwsh.Source) 'Profile.ps1') }
  } else {
    # REPRO_M8C_REAL_HOME: the invoking user's home when this script itself
    # runs with a scratch HOME (so that pwsh's own caches stay out of it).
    $realHome = if ($env:REPRO_M8C_REAL_HOME) { $env:REPRO_M8C_REAL_HOME } else { $HOME }
    $cfg = if ($env:REPRO_M8C_REAL_HOME) { Join-Path $realHome '.config' } elseif ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $realHome '.config' }
    $data = if ($env:REPRO_M8C_REAL_HOME) { Join-Path $realHome '.local/share' } elseif ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $realHome '.local/share' }
    $paths += (Join-Path $cfg 'powershell/profile.ps1')
    $paths += (Join-Path $cfg 'powershell/Microsoft.PowerShell_profile.ps1')
    $paths += (Join-Path $data 'repro/completions/repro.ps1')
  }
  return @($paths | ForEach-Object {
      if (Test-Path -LiteralPath $_) { (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash + ' ' + $_ } else { 'absent ' + $_ }
    })
}

# The per-user completion locations in a scratch home, as `repro hooks ensure
# --shell-autocomplete --profile` writes them: the script and one profile per
# PowerShell (CurrentUserAllHosts).
function Get-UserCompletionPaths {
  param([string]$HomeDir, [string]$Documents)
  if ($script:M8cOnWindows) {
    return [pscustomobject]@{
      Script = [IO.Path]::Combine($HomeDir, 'AppData', 'Local', 'repro', 'completions', 'repro.ps1')
      Profiles = @((Join-Path $Documents 'PowerShell\Profile.ps1'), (Join-Path $Documents 'WindowsPowerShell\Profile.ps1'))
    }
  }
  return [pscustomobject]@{
    Script = [IO.Path]::Combine($HomeDir, '.local', 'share', 'repro', 'completions', 'repro.ps1')
    Profiles = @([IO.Path]::Combine($HomeDir, '.config', 'powershell', 'profile.ps1'))
  }
}

# How many managed completion blocks a profile holds (0 when it is absent).
function Get-CompletionBlockCount {
  param([string]$Profile)
  if (-not (Test-Path -LiteralPath $Profile)) { return 0 }
  return @(Get-Content -LiteralPath $Profile | Where-Object { $_ -match '^# >>> .*repro-completion-powershell' }).Count
}

# The CompletionTexts a FRESH session of $PowerShell (its profiles loaded, as
# a user starts it) offers for `repro wor`, through TabExpansion2, the
# function PowerShell's own Tab key calls. -ExecutionPolicy Bypass for this
# process only: under the Restricted policy Windows PowerShell's default on a
# client, no profile script loads at all, whoever wrote it.
function Get-CompletionCandidates {
  param([string]$PowerShell, [hashtable]$Environment, [string]$WorkingDirectory, [string]$Line = 'repro wor')
  $script = "`$l = '$($Line.Replace("'", "''"))'; " +
    "foreach (`$m in (TabExpansion2 -inputScript `$l -cursorColumn `$l.Length).CompletionMatches) { [Console]::Out.WriteLine('M8C_CAND:' + `$m.CompletionText) }; " +
    "[Console]::Out.WriteLine('M8C_DONE')"
  $r = Invoke-Isolated -FilePath $PowerShell -Arguments @('-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-EncodedCommand', (Get-EncodedCommand $script)) -Environment $Environment -WorkingDirectory $WorkingDirectory -TimeoutSeconds 300
  $cands = @()
  $done = $false
  foreach ($l in ($r.Output -split "`r?`n")) {
    if ($l.StartsWith('M8C_CAND:')) { $cands += $l.Substring(9).Trim() }
    if ($l.Trim() -eq 'M8C_DONE') { $done = $true }
  }
  return [pscustomobject]@{ Done = $done; Candidates = $cands; Output = $r.Output }
}

function Assert-Completes {
  param([object[]]$PowerShells, [hashtable]$Environment, [string]$WorkingDirectory, [bool]$Want, [string]$Tag)
  foreach ($ps in $PowerShells) {
    $c = Get-CompletionCandidates -PowerShell $ps[1] -Environment $Environment -WorkingDirectory $WorkingDirectory
    if (-not $c.Done) { Fail "${Tag}: $($ps[0]) did not finish the probe:`n$($c.Output)"; continue }
    $got = $c.Candidates -contains 'workspace'
    if ($got -eq $Want) {
      Pass "${Tag}: a fresh $($ps[0]) session completes 'repro wor<Tab>' -> workspace: $Want (candidates: $($c.Candidates -join ' '))"
    } else {
      Fail "${Tag}: a fresh $($ps[0]) session: expected completion=$Want, candidates: $($c.Candidates -join ' ')`n$($c.Output)"
    }
  }
}

# A local HTTP server for $Root on $Port, in a process of its own: the
# PowerShell running this script, with System.Net.HttpListener. Returns the
# process; stop it with Stop-FileServer, which kills only that process.
function Start-FileServer {
  param([string]$Root, [int]$Port, [string]$Work)
  $serve = Join-Path $Work 'serve.ps1'
  Set-Content -LiteralPath $serve -Encoding UTF8 -Value @'
param([string]$Root, [int]$Port)
$l = New-Object System.Net.HttpListener
$l.Prefixes.Add("http://localhost:$Port/")
$l.Start()
[Console]::Out.WriteLine('M8C_SERVING')
while ($l.IsListening) {
  $ctx = $l.GetContext()
  $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/')
  $path = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $rel))
  if ($path.StartsWith([IO.Path]::GetFullPath($Root)) -and [IO.File]::Exists($path)) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  } else {
    $ctx.Response.StatusCode = 404
  }
  $ctx.Response.Close()
}
'@
  $self = (Get-Process -Id $PID).Path
  $sp = @{
    FilePath = $self
    ArgumentList = @('-NoProfile', '-NonInteractive', '-File', $serve, '-Root', $Root, '-Port', $Port)
    PassThru = $true
    RedirectStandardOutput = (Join-Path $Work 'serve.out')
    RedirectStandardError = (Join-Path $Work 'serve.err')
  }
  # -WindowStyle exists on Windows only.
  if ($script:M8cOnWindows) { $sp['WindowStyle'] = 'Hidden' }
  return (Start-Process @sp)
}

function Stop-FileServer {
  param($Process)
  if ($Process -and -not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
}

function Wait-Url {
  param([string]$Url, [int]$Seconds = 20)
  $end = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $end) {
    try { Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2 | Out-Null; return $true } catch { Start-Sleep -Milliseconds 300 }
  }
  return $false
}

# bash for the repository's shell scripts: Git for Windows' bash on Windows
# (never the WSL launcher; windows\toolchain-utils.ps1 decides), bash on PATH
# elsewhere.
function Get-ScriptBash {
  param([string]$RepoRoot)
  if ($script:M8cOnWindows) {
    . (Join-Path $RepoRoot 'windows\toolchain-utils.ps1')
    return (Resolve-UsableBashExe)
  }
  $b = Get-Command bash -ErrorAction SilentlyContinue
  if ($b) { return $b.Source }
  return ''
}

# A path as the repository's shell scripts and the MSYS tools they run take
# it. On Windows those are Git for Windows' MSYS2 programs (bash, sh, gpg),
# and an absolute Windows path must be given in MSYS form, /<drive>/<rest>:
# bash itself accepts C:/x, but MSYS gpg treats C:/x as a RELATIVE name
# (`gpg --homedir C:/x` resolves it under the working directory), so every
# path is converted the one way all of them read
# (https://www.msys2.org/docs/filesystem-paths/). A UNC path (\\server\share
# or \\?\C:\...) and a drive-relative one (C:x) have no form every MSYS tool
# reads the same way and are refused; the scratch directories are under
# %TEMP%, a drive path. A relative path only has its separators turned. Off
# Windows a path is returned as it is. -Windows overrides the host test, so
# the Windows rules can be checked on any host.
function ConvertTo-ScriptPath {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path, [Nullable[bool]]$Windows = $null)
  $onWindows = if ($null -ne $Windows) { [bool]$Windows } else { $script:M8cOnWindows }
  if (-not $onWindows) { return $Path }
  if ($Path -match '^[\\/]{2}') {
    throw "ConvertTo-ScriptPath: '$Path' is a UNC path, which the MSYS tools do not all read; use a path on a drive"
  }
  $m = [regex]::Match($Path, '^(?<drive>[A-Za-z]):(?<rest>.*)$')
  if ($m.Success) {
    $rest = $m.Groups['rest'].Value -replace '\\', '/'
    if (-not $rest.StartsWith('/')) {
      throw "ConvertTo-ScriptPath: '$Path' is relative to the current directory of drive $($m.Groups['drive'].Value):; use an absolute path"
    }
    return '/' + $m.Groups['drive'].Value.ToLowerInvariant() + $rest
  }
  return ($Path -replace '\\', '/')
}

# Runs a native program and returns its exit code and its standard output
# lines; standard error is shown on the host, never raised. Windows
# PowerShell 5.1 wraps each line a native program writes to a redirected
# standard error in an ErrorRecord, and with $ErrorActionPreference = 'Stop'
# (these checks run under it) the first such line is a terminating error,
# however harmless (a progress log line), so `& bash x.sh 2>&1` dies in the
# harness instead of reporting the program's exit code
# (https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_redirection;
# PowerShell 7.2 and later stopped applying the preference to these records,
# and 7.3's $PSNativeCommandUseErrorActionPreference is about the exit code,
# but these checks also run under 5.1). The preference is therefore
# 'Continue' around the call only, restored in `finally`, and the caller
# judges the exit code. -Quiet keeps standard output off the host (the
# caller reads it from .Output).
function Invoke-NativeCommand {
  param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$ArgumentList = @(), [switch]$Quiet)
  # A program that is not there is the caller's error, reported as such
  # (and $LASTEXITCODE would otherwise be a previous program's).
  $null = Get-Command -Name $FilePath -CommandType Application -ErrorAction Stop
  $stdout = New-Object System.Collections.Generic.List[string]
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $FilePath @ArgumentList 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) {
        Write-Host $_.ToString()
      } else {
        $line = "$_"
        $stdout.Add($line)
        if (-not $Quiet) { Write-Host $line }
      }
    }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $saved
  }
  return [pscustomobject]@{ Code = $code; Output = $stdout.ToArray() }
}

# The $PSHOME a PowerShell reports for itself (where its all-users profile
# lives). Throws when it reports none, so that a check comparing the real
# profiles never silently compares the wrong file.
function Get-PowerShellHome {
  param([Parameter(Mandatory = $true)][string]$PowerShell)
  $r = Invoke-NativeCommand -FilePath $PowerShell -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', '$PSHOME') -Quiet
  # Not $psHome: PowerShell variable names ignore case, and $PSHOME is a
  # read-only automatic variable.
  $reported = (@($r.Output) | Where-Object { $_.Trim() } | Select-Object -Last 1)
  if ($r.Code -ne 0 -or -not $reported -or -not [IO.Path]::IsPathRooted($reported.Trim())) {
    throw "$PowerShell did not report its `$PSHOME (exit $($r.Code)): $($r.Output -join ' ')"
  }
  return $reported.Trim()
}

# The version this checkout builds, from reprobuild.nimble, as
# scripts/release/package_windows_release.ps1 reads it: the archive a check
# makes from a build tree is named for the version of that build.
function Get-ReproVersion {
  param([Parameter(Mandatory = $true)][string]$RepoRoot)
  $nimble = Join-Path $RepoRoot 'reprobuild.nimble'
  $m = Select-String -LiteralPath $nimble -Pattern '^version\s*=\s*"([^"]+)"' | Select-Object -First 1
  if ($null -eq $m) { throw "no version line in $nimble" }
  return $m.Matches[0].Groups[1].Value
}

# The release archive of the Windows asset's shape, from a build tree:
# bin\ (the images and their DLLs), lib\, and share\repro\completions\repro.ps1
# generated by scripts/release/stage_release_completions.sh from that build's
# own repro, zipped with the top directory reprobuild-<version>-windows-<arch>.
# On Linux the build's `repro` and `reprobuild` go in as bin/repro.exe and
# bin/reprobuild, the names the installer runs and the client looks beside
# itself for, so the installer's logic can run there too.
function New-TestArchive {
  param([string]$RepoRoot, [string]$BuildDir, [string]$Version, [string]$Arch, [string]$OutDir, [string]$Bash)
  $top = "reprobuild-$Version-windows-$Arch"
  $src = Join-Path $OutDir 'archive-src'
  $root = Join-Path $src $top
  if (Test-Path -LiteralPath $src) { Remove-Item -LiteralPath $src -Recurse -Force }
  New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin'), (Join-Path $root 'lib') | Out-Null
  if ($script:M8cOnWindows) {
    # The runtime DLLs the images load sit beside them in a release
    # (windows\stage-release-dlls.ps1 stages them into build\bin, as
    # scripts/release/package_windows_release.ps1 does); without them the
    # isolated PATH finds none.
    & (Join-Path $RepoRoot 'windows\stage-release-dlls.ps1') | Out-Host
    Get-ChildItem -LiteralPath (Join-Path $BuildDir 'bin') -File |
      Where-Object { $_.Name -notmatch '\.(stale|old)$' } |
      ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $root 'bin') }
    $reproBin = Join-Path $BuildDir 'bin\repro.exe'
  } else {
    Copy-Item -LiteralPath (Join-Path $BuildDir 'bin/repro') -Destination (Join-Path $root 'bin/repro.exe')
    Copy-Item -LiteralPath (Join-Path $BuildDir 'bin/reprobuild') -Destination (Join-Path $root 'bin/reprobuild')
    $reproBin = Join-Path $BuildDir 'bin/repro'
  }
  $lib = Join-Path $BuildDir 'lib'
  if (Test-Path -LiteralPath $lib) {
    Get-ChildItem -LiteralPath $lib -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $root 'lib') }
  }
  $env:REPRO_COMPLETION_BIN = ConvertTo-ScriptPath $reproBin
  Push-Location -LiteralPath $RepoRoot
  try {
    $code = (Invoke-NativeCommand -FilePath $Bash -ArgumentList @('./scripts/release/stage_release_completions.sh', (ConvertTo-ScriptPath $root), 'powershell')).Code
  } finally {
    Pop-Location
    Remove-Item Env:\REPRO_COMPLETION_BIN -ErrorAction SilentlyContinue
  }
  if ($code -ne 0) { throw "stage_release_completions.sh failed (exit $code)" }
  $zip = Join-Path $OutDir "$top.zip"
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::CreateFromDirectory($root, $zip, [System.IO.Compression.CompressionLevel]::Fastest, $true)
  return $zip
}
