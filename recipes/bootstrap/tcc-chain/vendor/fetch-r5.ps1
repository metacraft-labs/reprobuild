# fetch-r5.ps1 — re-materialise R5 (tcc -> gcc bootstrap loop) vendored
# sources from upstream.  All sources are gitignored; this script fetches
# them and sha256-verifies against SHA256SUMS-r5.txt.
#
# Pins match nixpkgs/pkgs/os-specific/linux/minimal-bootstrap/ at the
# reference commit 06a4933d0 -- in particular:
#   - binutils 2.46.0 (binutils/default.nix)
#   - musl 1.2.6        (musl/default.nix)
#   - gcc 4.6.4 + gmp 4.3.2 + mpfr 2.4.2 + mpc 1.0.3 (gcc/4.6.nix)
#   - gcc 10.4.0 + gmp 6.2.1 + mpfr 4.2.2 + mpc 1.3.1 + isl 0.24 (gcc/10.nix)
#   - gcc 15.2.0 + gmp 6.3.0 + mpfr 4.2.2 + mpc 1.3.1 + isl 0.24 (gcc/latest.nix)
#
# Usage: pwsh recipes/bootstrap/tcc-chain/vendor/fetch-r5.ps1

$ErrorActionPreference = 'Stop'
$vendorDir = $PSScriptRoot

# Map: url -> filename.  Filenames match the SHA256SUMS-r5.txt entries.
$urls = @(
  @{ name = 'binutils-2.46.0.tar.xz';
     url  = 'https://ftpmirror.gnu.org/binutils/binutils-2.46.0.tar.xz' },
  @{ name = 'musl-1.2.6.tar.gz';
     url  = 'https://musl.libc.org/releases/musl-1.2.6.tar.gz' },
  @{ name = 'musl-sigsetjmp.patch';
     url  = 'https://github.com/fosslinux/live-bootstrap/raw/d98f97e21413efc32c770d0356f1feda66025686/sysa/musl-1.1.24/patches/sigsetjmp.patch' },
  @{ name = 'gcc-core-4.6.4.tar.gz';
     url  = 'https://ftpmirror.gnu.org/gcc/gcc-4.6.4/gcc-core-4.6.4.tar.gz' },
  @{ name = 'gcc-g++-4.6.4.tar.gz';
     url  = 'https://ftpmirror.gnu.org/gcc/gcc-4.6.4/gcc-g++-4.6.4.tar.gz' },
  @{ name = 'gmp-4.3.2.tar.gz';
     url  = 'https://ftpmirror.gnu.org/gmp/gmp-4.3.2.tar.gz' },
  @{ name = 'mpfr-2.4.2.tar.gz';
     url  = 'https://ftpmirror.gnu.org/mpfr/mpfr-2.4.2.tar.gz' },
  @{ name = 'mpc-1.0.3.tar.gz';
     url  = 'https://ftpmirror.gnu.org/mpc/mpc-1.0.3.tar.gz' },
  @{ name = 'gcc-10.4.0.tar.xz';
     url  = 'https://ftpmirror.gnu.org/gcc/gcc-10.4.0/gcc-10.4.0.tar.xz' },
  @{ name = 'gmp-6.2.1.tar.xz';
     url  = 'https://ftpmirror.gnu.org/gmp/gmp-6.2.1.tar.xz' },
  @{ name = 'mpfr-4.2.2.tar.xz';
     url  = 'https://ftpmirror.gnu.org/mpfr/mpfr-4.2.2.tar.xz' },
  @{ name = 'mpc-1.3.1.tar.gz';
     url  = 'https://ftpmirror.gnu.org/mpc/mpc-1.3.1.tar.gz' },
  @{ name = 'isl-0.24.tar.bz2';
     url  = 'https://gcc.gnu.org/pub/gcc/infrastructure/isl-0.24.tar.bz2' },
  @{ name = 'gcc-15.2.0.tar.xz';
     url  = 'https://ftpmirror.gnu.org/gcc/gcc-15.2.0/gcc-15.2.0.tar.xz' },
  @{ name = 'gmp-6.3.0.tar.xz';
     url  = 'https://ftpmirror.gnu.org/gmp/gmp-6.3.0.tar.xz' }
  # tinycc-mes: see vendor/MANIFEST.md — repo.or.cz is Anubis-gated, so
  # we re-materialise via `git clone https://repo.or.cz/tinycc.git` +
  # `git archive cb41cbfe7`.  Not included in the URL loop; refresh via
  # scripts/_mkarchive.sh + scripts/_mktargz.sh after cloning.
)

Push-Location $vendorDir
try {
  foreach ($entry in $urls) {
    $target = Join-Path $vendorDir $entry.name
    if (Test-Path $target) {
      Write-Host "[fetch] skip (exists): $($entry.name)"
      continue
    }
    Write-Host "[fetch] downloading $($entry.name) ..."
    Invoke-WebRequest -Uri $entry.url -OutFile $target -UseBasicParsing
    Write-Host "[fetch] OK: $($entry.name) ($((Get-Item $target).Length) bytes)"
  }

  Write-Host '[fetch] verifying sha256s against SHA256SUMS-r5.txt'
  $sumsFile = Join-Path $vendorDir 'SHA256SUMS-r5.txt'
  if (-not (Test-Path $sumsFile)) {
    Write-Host "[fetch] WARNING: no SHA256SUMS-r5.txt yet; printing sha256s for capture"
    foreach ($entry in $urls) {
      $target = Join-Path $vendorDir $entry.name
      if (Test-Path $target) {
        $h = (Get-FileHash -Algorithm SHA256 $target).Hash.ToLower()
        Write-Host "$h  $($entry.name)"
      }
    }
    return
  }
  $expected = @{}
  Get-Content $sumsFile | ForEach-Object {
    if ($_ -match '^([0-9a-f]{64})\s+(\S+)\s*$') {
      $expected[$Matches[2]] = $Matches[1]
    }
  }
  foreach ($entry in $urls) {
    $target = Join-Path $vendorDir $entry.name
    if (-not (Test-Path $target)) {
      throw "missing: $($entry.name)"
    }
    $h = (Get-FileHash -Algorithm SHA256 $target).Hash.ToLower()
    if (-not $expected.ContainsKey($entry.name)) {
      Write-Host "[fetch] WARN: $($entry.name) not in SHA256SUMS-r5.txt; got $h"
      continue
    }
    if ($h -ne $expected[$entry.name]) {
      throw ("sha256 mismatch for {0}: got {1}, expected {2}" `
             -f $entry.name, $h, $expected[$entry.name])
    }
    Write-Host "[fetch] OK: $($entry.name) sha256 = $h"
  }
}
finally {
  Pop-Location
}
