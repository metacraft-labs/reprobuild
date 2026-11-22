<#
.SYNOPSIS
  Reprobuild installer — the PowerShell half of M3.

.DESCRIPTION
  irm https://get.reprobuild.com/pwsh | iex
  .\repro-install.ps1 -Method scoop
  .\repro-install.ps1 -Uninstall

  detect -> verify -> register the native repo (a Scoop bucket) -> let
  SCOOP install. After that `scoop update reprobuild` moves the user to
  newer releases, which is the Windows equivalent of `apt upgrade` and
  the reason a bucket is registered instead of a zip being unpacked.

  ## What verification means on this platform, precisely

  Scoop manifests carry a `hash` for every artifact and Scoop refuses a
  download whose hash does not match. That is the package manager's own
  check, it happens on install AND on every update, and it is rooted in
  the manifest — so the thing that has to be trusted is the BUCKET.

  The bucket is a git repository, and the trust root is therefore the
  bucket URL plus (for the repo-less path) an OpenPGP signature over the
  release manifest. There is no Windows equivalent of apt's signed
  InRelease, so this installer does NOT claim one:

    * -Method scoop      : Scoop verifies artifact hashes against the
                           manifest. Bucket authenticity rests on HTTPS
                           to the bucket host.
    * -Method tarball    : the full M2 signature chain, via
                           repro-verify-release.sh, before anything is
                           unpacked. Requires gpg/gpgv on PATH and
                           FAILS CLOSED without it.

  Stating that asymmetry is deliberate. Claiming the Scoop path carries
  an OpenPGP guarantee it does not would be worse than the gap itself.

  ## Shell completion

  -Method scoop adds nothing here: the Scoop manifest registers repro's
  PowerShell completion for the user itself (its post_install), and a
  second registration from this script would load the same script twice.
  -Method tarball has no package to do it, so after the archive is in
  place the installer asks the repro.exe it just installed to register
  completion for the current user: `repro hooks ensure --shell-autocomplete
  --profile`, which writes the user's completion script and a managed block
  in each detected PowerShell's CurrentUserAllHosts profile (Windows
  PowerShell 5.1 and PowerShell 7 have one each), and leaves an up-to-date
  registration alone, so a re-run registers nothing twice. What was done is
  recorded beside the install (.reprobuild\completion) and -Uninstall undoes
  exactly that, with the same binary, before the binary is removed. A
  refusal is reported with the command to re-run and does not fail the
  install. -NoCompletion, or REPRO_NO_COMPLETION=1 in the environment,
  skips it (and a re-run with it removes an earlier registration); with
  -Method scoop it is passed on to the manifest's post_install.

  ## Idempotence

  Every write is a fixed location and a replacement: one bucket named
  `metacraft` (shared by every Metacraft product), one Scoop app. Adding a bucket that is already present is
  detected and skipped rather than retried, so a second run does not
  produce a duplicate bucket or a second app.
#>
[CmdletBinding()]
param(
  # auto | scoop | tarball
  [string]$Method = 'auto',
  [string]$Version = '',
  [switch]$Uninstall,
  # THE configurable base URL. Unset, the production subdomains under
  # -Domain are used; set, every fetch becomes a path under this one base:
  #   <base>/scoop      the Scoop bucket (a git repo)
  #   <base>/downloads  release archives + SHA256SUMS{,.asc}
  #   <base>/keys       the trust anchor
  # so the whole installer retargets at a local server with one switch.
  # The gate does exactly that; nothing here hardcodes a hostname that
  # only resolves against the real (still-undelegated) zone.
  [string]$BaseUrl = $env:REPRO_BASE_URL,
  [string]$Domain = $(if ($env:REPRO_REPO_DOMAIN) { $env:REPRO_REPO_DOMAIN } else { 'metacraft-labs.com' }),
  [string]$BucketUrl = $env:REPRO_BUCKET_URL,
  [string]$Prefix = '',
  # Do not set up shell completion (the same as REPRO_NO_COMPLETION=1):
  # the archive method skips it, and -Method scoop passes it on to the
  # manifest's post_install.
  [switch]$NoCompletion,
  [switch]$DryRun,
  # Accepted and ignored: this installer never prompts (a prompt in an
  # `irm | iex` pipeline has no console to read from).
  [switch]$Yes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Product = 'Reprobuild'
$AppName = if ($env:REPRO_PKG_NAME) { $env:REPRO_PKG_NAME } else { 'reprobuild' }
# The organisation's bucket, shared by every Metacraft product, as the apt
# and RPM repositories are (metacraft-specs
# infrastructure/package-distribution.md §3).
$BucketName = if ($env:REPRO_BUCKET_NAME) { $env:REPRO_BUCKET_NAME } else { 'metacraft' }

function Write-Log  { param([string]$m) Write-Host "[$Product installer] $m" }
function Write-Warn { param([string]$m) Write-Host "[$Product installer] WARNING: $m" -ForegroundColor Yellow }
function Die {
  param([string]$m)
  Write-Host "[$Product installer] ERROR: $m" -ForegroundColor Red
  exit 1
}

# ---------------------------------------------------------------------
# URL construction — one knob
# ---------------------------------------------------------------------
if ($BaseUrl) {
  $b = $BaseUrl.TrimEnd('/')
  $ScoopBucketUrl = if ($BucketUrl) { $BucketUrl } else { "$b/scoop" }
  $DownloadsUrl = "$b/downloads"
  $KeysUrl = "$b/keys"
} else {
  # The organisation's Scoop bucket: bucket/ on the default branch of
  # metacraft-desktop-packages, the repository that also publishes
  # deb./rpm.metacraft-labs.com. Every release refreshes its manifest.
  $ScoopBucketUrl = if ($BucketUrl) { $BucketUrl } else { 'https://github.com/metacraft-labs/metacraft-desktop-packages' }
  $DownloadsUrl = 'https://github.com/metacraft-labs/reprobuild/releases/download'
  $KeysUrl = "https://deb.$Domain/keys"
}

$SkipCompletion = $NoCompletion -or ($env:REPRO_NO_COMPLETION -eq '1')

$KeyringFile = if ($env:REPRO_KEYRING_FILE) { $env:REPRO_KEYRING_FILE } else { 'metacraft-labs-archive-keyring.asc' }

# Expected SHA-256 of the trust anchor: the organisation key, as the POSIX
# installer pins it (see there). Set to an empty string to fail closed.
$KeyringSha256 = if ($null -ne $env:REPRO_KEYRING_SHA256) { $env:REPRO_KEYRING_SHA256 } else { 'aa89db2215ce0b33e029b8302d4d94fac742b92d279f178437abe10d9b54c988' }

# ---------------------------------------------------------------------
# 1. detect
# ---------------------------------------------------------------------
function Get-ReproArch {
  # PROCESSOR_ARCHITECTURE is the process's view and reads AMD64 for a
  # 32-bit-emulated shell on ARM; the OS architecture is what decides
  # which asset to fetch.
  $a = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
  switch ($a) {
    'X64'   { return 'x86_64' }
    'Arm64' { return 'aarch64' }
    default {
      Die "unsupported OS architecture '$a'. See .github/release-platforms.json for the platforms reprobuild publishes (windows-aarch64 is deliberately absent: clingo has no native ARM64 build)."
    }
  }
}

function Test-Command { param([string]$n) return [bool](Get-Command $n -ErrorAction SilentlyContinue) }

function Resolve-Method {
  if ($Method -ne 'auto') { return $Method }
  if (Test-Command 'scoop') { return 'scoop' }
  Write-Log 'scoop was not found; falling back to the signed archive method'
  return 'tarball'
}

function Invoke-Step {
  param([string]$What, [scriptblock]$Action)
  if ($DryRun) { Write-Log "DRY-RUN would: $What"; return $null }
  return & $Action
}

# ---------------------------------------------------------------------
# 2. verify — the trust anchor (tarball path)
# ---------------------------------------------------------------------
function Get-FileSha256 { param([string]$p) return (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLowerInvariant() }

function Save-Url {
  param([string]$Url, [string]$Dest)
  Write-Log "fetch $Url"
  try {
    # -UseBasicParsing for Windows PowerShell 5.1, where the default
    # engine needs IE and throws on a server with no DOM.
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop | Out-Null
  } catch {
    Die "download failed: $Url ($($_.Exception.Message))"
  }
  if (-not (Test-Path -LiteralPath $Dest) -or (Get-Item -LiteralPath $Dest).Length -eq 0) {
    Die "downloaded an empty file from $Url"
  }
}

function Install-TrustAnchor {
  param([string]$WorkDir)
  $kr = Join-Path $WorkDir $KeyringFile
  if ($env:REPRO_KEYRING_LOCAL) {
    if (-not (Test-Path -LiteralPath $env:REPRO_KEYRING_LOCAL)) {
      Die "REPRO_KEYRING_LOCAL=$($env:REPRO_KEYRING_LOCAL) does not exist"
    }
    Copy-Item -LiteralPath $env:REPRO_KEYRING_LOCAL -Destination $kr -Force
  } else {
    Save-Url -Url "$KeysUrl/$KeyringFile" -Dest $kr
  }
  $got = Get-FileSha256 $kr
  if ($KeyringSha256) {
    if ($got -eq $KeyringSha256.ToLowerInvariant()) {
      Write-Log "trust anchor digest OK ($got)"
    } else {
      Die @"
trust anchor digest MISMATCH
  expected $KeyringSha256
  got      $got
Refusing to install a release key that is not the one this installer pins.
"@
    }
  } elseif ($env:REPRO_ALLOW_UNPINNED_KEYRING -eq '1') {
    Write-Warn "using an UNPINNED trust anchor (sha256=$got) because REPRO_ALLOW_UNPINNED_KEYRING=1. Not for production."
  } else {
    Die @"
no trust anchor digest is pinned in this installer (REPRO_KEYRING_SHA256 is empty).
reprobuild has no release key yet, so there is nothing to pin and this
installer fails closed rather than trusting the keyring host blindly.
See docs/release-signing.md.
"@
  }
  return $kr
}

# ---------------------------------------------------------------------
# 3/4. Scoop: register the bucket, let scoop install
# ---------------------------------------------------------------------
function Get-ScoopBuckets {
  # `scoop bucket list` output shape has changed across Scoop versions,
  # so the buckets DIRECTORY is the source of truth rather than a parsed
  # table. A parser that silently matched nothing would make the
  # idempotence check below pass while adding a duplicate bucket.
  $root = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
  $bd = Join-Path $root 'buckets'
  if (-not (Test-Path -LiteralPath $bd)) { return @() }
  return @(Get-ChildItem -LiteralPath $bd -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}

function Register-ScoopBucket {
  if (-not (Test-Command 'scoop')) {
    Die @"
scoop was not found on PATH.
Install Scoop first (https://scoop.sh):
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  irm get.scoop.sh | iex
or re-run this installer with -Method tarball.
"@
  }
  $existing = Get-ScoopBuckets
  if ($existing -contains $BucketName) {
    # IDEMPOTENCE: `scoop bucket add` on an existing name errors out, so
    # the second run must skip rather than retry-and-fail.
    Write-Log "scoop bucket '$BucketName' is already registered; leaving it as is"
    return
  }
  Write-Log "registering scoop bucket '$BucketName' -> $ScoopBucketUrl"
  Invoke-Step "scoop bucket add $BucketName $ScoopBucketUrl" {
    & scoop bucket add $BucketName $ScoopBucketUrl
    if ($LASTEXITCODE -ne 0) { Die "scoop bucket add failed (exit $LASTEXITCODE)" }
  }
}

function Install-WithScoop {
  $target = if ($Version) { "$BucketName/$AppName@$Version" } else { "$BucketName/$AppName" }
  Write-Log "installing $target with scoop"
  # The manifest's post_install registers shell completion and reads the
  # opt-out from the environment, which `scoop install` inherits. Set for
  # that call only: under `irm | iex` this process is the user's own
  # session, which must not keep the variable afterwards.
  $savedOptOut = $env:REPRO_NO_COMPLETION
  if ($SkipCompletion) { $env:REPRO_NO_COMPLETION = '1' }
  try {
    Invoke-Step "scoop install $target" {
      # Scoop's own action, Scoop's own hash verification, Scoop's own exit
      # code. Nothing here re-checks what Scoop already refuses.
      & scoop install $target
      if ($LASTEXITCODE -ne 0) { Die "scoop install $target failed (exit $LASTEXITCODE)" }
    }
  } finally {
    $env:REPRO_NO_COMPLETION = $savedOptOut
  }
}

function Uninstall-WithScoop {
  if (-not (Test-Command 'scoop')) { Write-Log 'scoop not present; nothing for scoop to remove'; return }
  $apps = @(& scoop list 6>$null | Out-String)
  if ($apps -match [regex]::Escape($AppName)) {
    Write-Log "removing $AppName with scoop"
    Invoke-Step "scoop uninstall $AppName" {
      & scoop uninstall $AppName
      if ($LASTEXITCODE -ne 0) { Write-Warn "scoop uninstall $AppName exited $LASTEXITCODE" }
    }
  } else {
    Write-Log "$AppName is not installed; nothing for scoop to remove"
  }
  if ((Get-ScoopBuckets) -contains $BucketName) {
    Write-Log "removing scoop bucket '$BucketName'"
    Invoke-Step "scoop bucket rm $BucketName" {
      & scoop bucket rm $BucketName
      if ($LASTEXITCODE -ne 0) { Write-Warn "scoop bucket rm $BucketName exited $LASTEXITCODE" }
    }
  } else {
    Write-Log "scoop bucket '$BucketName' is not registered; nothing to remove"
  }
}

# ---------------------------------------------------------------------
# the repo-less fallback: signed archive, verified BEFORE extraction
# ---------------------------------------------------------------------
function Get-ArchivePrefix {
  if ($Prefix) { return $Prefix }
  if ($env:REPRO_INSTALL_PREFIX) { return $env:REPRO_INSTALL_PREFIX }
  return (Join-Path $env:LOCALAPPDATA 'Programs\Reprobuild')
}

# ---------------------------------------------------------------------
# shell completion for an archive install (see "Shell completion" above)
# ---------------------------------------------------------------------
function Get-CompletionRecordPath {
  param([string]$Dest)
  return (Join-Path (Join-Path $Dest '.reprobuild') 'completion')
}

# One `name=value` field of the completion record, or ''.
function Get-CompletionRecordField {
  param([string]$Dest, [string]$Name)
  $record = Get-CompletionRecordPath $Dest
  if (-not (Test-Path -LiteralPath $record)) { return '' }
  foreach ($line in @(Get-Content -LiteralPath $record)) {
    if ($line.StartsWith("$Name=")) { return $line.Substring($Name.Length + 1) }
  }
  return ''
}

# Runs `repro hooks <ensure|uninstall> --shell-autocomplete --profile` with
# the given binary, from the root of its drive, so the command neither
# depends on nor looks for a workspace in the directory the installer was
# started from. Returns whether it exited 0.
function Invoke-ReproCompletionHooks {
  param([string]$Verb, [string]$Repro)
  Push-Location -LiteralPath ([System.IO.Path]::GetPathRoot($Repro))
  try {
    & $Repro hooks $Verb --shell-autocomplete --profile | Out-Host
    return ($LASTEXITCODE -eq 0)
  } finally {
    Pop-Location
  }
}

# Undo the registration the record describes, if any, and drop the record.
function Undo-ArchiveCompletion {
  param([string]$Dest)
  $record = Get-CompletionRecordPath $Dest
  if (-not (Test-Path -LiteralPath $record)) { return }
  $repro = Get-CompletionRecordField -Dest $Dest -Name 'repro'
  if ($repro -and (Test-Path -LiteralPath $repro)) {
    if (Invoke-ReproCompletionHooks -Verb 'uninstall' -Repro $repro) {
      Write-Log 'removed the shell completion this install registered (profile)'
    } else {
      Write-Warn 'could not remove all of the shell completion this install registered; see the lines above'
    }
  } else {
    Write-Warn "the completion record $record names no usable binary; left the shells' completion as it is"
  }
  Remove-Item -LiteralPath $record -Force -ErrorAction SilentlyContinue
}

function Set-ArchiveCompletion {
  param([string]$Dest)
  if ($SkipCompletion) {
    # A re-run with the opt-out removes what an earlier run registered, so
    # the opt-out always leaves none.
    Undo-ArchiveCompletion -Dest $Dest
    Write-Log 'shell completion: not set up (-NoCompletion)'
    return
  }
  $repro = Join-Path (Join-Path $Dest 'bin') 'repro.exe'
  if (-not (Test-Path -LiteralPath $repro)) {
    Write-Warn "shell completion: $repro does not exist; not set up"
    return
  }
  Write-Log 'setting up shell completion for repro (this user, profile)'
  # Recorded before it runs: a registration that half-succeeded is still
  # one that -Uninstall must undo.
  Set-Content -LiteralPath (Get-CompletionRecordPath $Dest) -Value "scope=profile`nrepro=$repro" -NoNewline
  if (-not (Invoke-ReproCompletionHooks -Verb 'ensure' -Repro $repro)) {
    # Completion is a convenience on top of a working install, so a refusal
    # (for example another tool's file at one of the paths) is reported, not
    # turned into a failed install.
    Write-Warn @"
shell completion was not fully set up; see the lines above. Re-run it with:
  repro hooks ensure --shell-autocomplete --profile
"@
  }
}
function Find-Verifier {
  if ($env:REPRO_VERIFY_SCRIPT) {
    if (-not (Test-Path -LiteralPath $env:REPRO_VERIFY_SCRIPT)) {
      Die "REPRO_VERIFY_SCRIPT=$($env:REPRO_VERIFY_SCRIPT) does not exist"
    }
    return $env:REPRO_VERIFY_SCRIPT
  }
  $here = Split-Path -Parent $PSCommandPath
  foreach ($c in @(
      (Join-Path $here '..\release-signing\repro-verify-release.sh'),
      (Join-Path $here 'repro-verify-release.sh'))) {
    if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
  }
  Die @"
cannot locate repro-verify-release.sh.
The archive fallback verifies signatures BEFORE extracting and will not
run without the verifier. Set REPRO_VERIFY_SCRIPT. It will not proceed
unverified.
"@
}

function Install-FromArchive {
  $arch = Get-ReproArch
  $ver = if ($Version) { $Version } elseif ($env:REPRO_VERSION) { $env:REPRO_VERSION } else {
    Die 'the archive fallback needs -Version. There is no "latest" to follow: resolving it from a directory listing is not a release policy.'
  }
  $asset = "reprobuild-$ver-windows-$arch.zip"
  $work = Join-Path ([System.IO.Path]::GetTempPath()) ("repro-install-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work -Force | Out-Null
  try {
    Save-Url -Url "$DownloadsUrl/v$ver/$asset" -Dest (Join-Path $work $asset)
    Save-Url -Url "$DownloadsUrl/v$ver/SHA256SUMS" -Dest (Join-Path $work 'SHA256SUMS')
    Save-Url -Url "$DownloadsUrl/v$ver/SHA256SUMS.asc" -Dest (Join-Path $work 'SHA256SUMS.asc')
    Save-Url -Url "$DownloadsUrl/v$ver/$asset.asc" -Dest (Join-Path $work "$asset.asc")

    $anchor = Install-TrustAnchor -WorkDir $work

    # M2's verifier is a POSIX shell script. On Windows it needs a shell:
    # Git for Windows' sh.exe is the one release.yml already assumes is
    # present. No shell => no verification => no install. This is the
    # fail-closed rule from docs/release-signing.md, not an inconvenience
    # to route around.
    $sh = $null
    foreach ($c in @('sh', 'bash')) {
      if (Test-Command $c) { $sh = (Get-Command $c).Source; break }
    }
    if (-not $sh) {
      Die @"
no POSIX shell (sh/bash) found, so repro-verify-release.sh cannot run.
Install Git for Windows, or use -Method scoop (where Scoop verifies
artifact hashes against its manifest). This installer will NOT extract an
unverified archive.
"@
    }
    $verifier = Find-Verifier
    $vargs = @($verifier, '--keyring', $anchor, '--dir', $work, '--artifact', $asset)
    if ($env:REPRO_ALLOW_TEST_KEY -eq '1') { $vargs += '--allow-test-key' }

    Write-Log "verifying $asset with $verifier BEFORE extracting"
    if ($DryRun) { Write-Log 'DRY-RUN would verify and extract'; return }
    & $sh @vargs
    if ($LASTEXITCODE -ne 0) { Die 'signature verification failed; refusing to install' }
    Write-Log 'signature verification passed'

    $dest = Get-ArchivePrefix
    $stage = Join-Path $work 'unpack'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    # .NET's zip reader directly, not Expand-Archive: Windows PowerShell 5.1's
    # cmdlet writes a progress record per entry, which makes an archive of
    # thousands of files (the release carries its own sources) take minutes
    # instead of seconds. $stage is fresh, so nothing needs overwriting.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $work $asset), $stage)
    $top = Join-Path $stage "reprobuild-$ver-windows-$arch"
    if (-not (Test-Path -LiteralPath $top)) {
      Die "archive did not contain the expected top-level directory reprobuild-$ver-windows-$arch"
    }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item -Path (Join-Path $top '*') -Destination $dest -Recurse -Force
    # Record what was installed so -Uninstall removes exactly this.
    $manifestDir = Join-Path $dest '.reprobuild'
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $manifestDir 'version') -Value $ver -NoNewline
    Set-ArchiveCompletion -Dest $dest
    Write-Log "archive install complete under $dest"
    Write-Warn 'an archive install does NOT receive native updates; re-run the installer or use -Method scoop.'
  } finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Uninstall-Archive {
  $dest = Get-ArchivePrefix
  if (Test-Path -LiteralPath (Join-Path $dest '.reprobuild')) {
    # Before the binary goes: it is what removes its own registration.
    if ($DryRun) {
      if (Test-Path -LiteralPath (Get-CompletionRecordPath $dest)) {
        Write-Log "DRY-RUN would remove the shell completion recorded in $(Get-CompletionRecordPath $dest)"
      }
    } else {
      Undo-ArchiveCompletion -Dest $dest
    }
    Write-Log "removing the archive install at $dest"
    if (-not $DryRun) { Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue }
  } else {
    Write-Log "no archive install recorded under $dest; nothing to remove"
  }
}

# ---------------------------------------------------------------------
# main
# ---------------------------------------------------------------------
$resolved = Resolve-Method
Write-Log "$Product installer: os=windows arch=$(Get-ReproArch) method=$resolved"
if ($BaseUrl) { Write-Log "base URL override: $BaseUrl" }

if ($Uninstall) {
  switch ($resolved) {
    'scoop'   { Uninstall-WithScoop; Uninstall-Archive }
    'tarball' { Uninstall-Archive }
    default   { Die "cannot uninstall with method=$resolved" }
  }
  Write-Log 'uninstall complete'
  exit 0
}

switch ($resolved) {
  'scoop' {
    Register-ScoopBucket
    Install-WithScoop
    Write-Log "$Product installed from the Scoop bucket."
    Write-Log "Future upgrades: 'scoop update $AppName' (not this script)."
  }
  'tarball' { Install-FromArchive }
  default   { Die "unsupported method: $resolved" }
}

$bin = Get-Command 'repro' -ErrorAction SilentlyContinue
if (-not $DryRun -and $bin) {
  Write-Log "installed binary: $($bin.Source)"
}
exit 0
