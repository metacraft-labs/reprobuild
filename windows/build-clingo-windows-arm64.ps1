# build-clingo-windows-arm64.ps1 -- build and qualify the windows-aarch64
# clingo.dll from its tag tarball.
#
# reprobuild-pm spec/Distribution-And-Packaging.md §7.1, decision W3 (approved
# by Zahary Karadjov, 2026-11-16). conda-forge publishes clingo for win-64
# only, potassco publishes no Windows binaries, its PyPI wheels are win_amd64
# only and MSYS2 packages none. So the arm64 leg builds clingo itself, from
# two sha256-pinned inputs: the tag tarball and the leg's own llvm-mingw.
#
# Why llvm-mingw with -static: the result imports only KERNEL32.dll and the
# UCRT api-ms-win-crt-* set (measured 2026-11-16), so no C++ or MSVC runtime
# DLL joins the release closure. C++ exceptions never cross clingo's C API --
# it catches them and returns error codes -- so a mingw-built engine never
# unwinds through libc++.
#
# The tag tarball is self-contained: clasp, libpotassco and third-party headers
# are in-tree, and the generated grammar sources are checked in, so neither
# bison nor re2c is needed. An empty CMAKE_SHARED_LIBRARY_PREFIX (set from a
# project include, below) names the DLL clingo.dll -- the name repro_solver
# binds -- and makes clingo.exe import it under that name.
#
# Driven by .github/workflows/clingo-windows-arm64.yml. Runs only on a native
# Windows ARM64 host; every image it builds or runs is ARM64.
param(
    [Parameter(Mandatory = $true)][string]$ClingoVersion,
    [Parameter(Mandatory = $true)][string]$ClingoTarballSha256,
    [Parameter(Mandatory = $true)][string]$LlvmMingwRelease,
    [Parameter(Mandatory = $true)][string]$LlvmMingwSha256,
    [Parameter(Mandatory = $true)][string]$CMakeVersion,
    [Parameter(Mandatory = $true)][string]$CMakeSha256,
    [Parameter(Mandatory = $true)][string]$WorkRoot,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$ProducerRevision
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $false

. (Join-Path $PSScriptRoot 'toolchain-utils.ps1')

if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') {
    throw 'build-clingo-windows-arm64: this host is not Windows ARM64; the build must be native.'
}

function Get-PinnedArchive([string]$Url, [string]$Sha256, [string]$Path) {
    Invoke-WithRetry -Script { Invoke-WebRequest -Uri $Url -OutFile $Path }
    Assert-FileSha256 -Path $Path -Expected $Sha256
}

function Invoke-Checked([string]$Name, [scriptblock]$Body) {
    $started = Get-Date
    & $Body
    $code = $LASTEXITCODE
    Write-Host ("== {0}: exit {1} in {2:N0}s" -f $Name, $code, ((Get-Date) - $started).TotalSeconds)
    if ($code -ne 0) { throw "build-clingo-windows-arm64: $Name failed with exit code $code" }
}

New-Item -ItemType Directory -Force -Path $WorkRoot, $OutDir | Out-Null
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'

# Inputs, each authenticated before extraction.
$llvmZip = Join-Path $WorkRoot "llvm-mingw-$LlvmMingwRelease-ucrt-aarch64.zip"
Get-PinnedArchive "https://github.com/mstorsjo/llvm-mingw/releases/download/$LlvmMingwRelease/llvm-mingw-$LlvmMingwRelease-ucrt-aarch64.zip" $LlvmMingwSha256 $llvmZip
$cmakeZip = Join-Path $WorkRoot "cmake-$CMakeVersion-windows-arm64.zip"
Get-PinnedArchive "https://github.com/Kitware/CMake/releases/download/v$CMakeVersion/cmake-$CMakeVersion-windows-arm64.zip" $CMakeSha256 $cmakeZip
$clingoTgz = Join-Path $WorkRoot "clingo-$ClingoVersion.tar.gz"
Get-PinnedArchive "https://github.com/potassco/clingo/archive/refs/tags/v$ClingoVersion.tar.gz" $ClingoTarballSha256 $clingoTgz
foreach ($archive in @($llvmZip, $cmakeZip, $clingoTgz)) {
    & $tar -xf $archive -C $WorkRoot
    if ($LASTEXITCODE -ne 0) { throw "build-clingo-windows-arm64: extracting $archive failed" }
}
$llvmBin = Join-Path $WorkRoot "llvm-mingw-$LlvmMingwRelease-ucrt-aarch64\bin"
$cmake = Join-Path $WorkRoot "cmake-$CMakeVersion-windows-arm64\bin\cmake.exe"
Assert-PeMachine -Path (Join-Path $llvmBin 'clang.exe') -Arch arm64 -Consumer 'build-clingo-windows-arm64'
Assert-PeMachine -Path $cmake -Arch arm64 -Consumer 'build-clingo-windows-arm64'
# Only the pinned tools and the system directories, for the build and every
# qualification below; the caller's PATH is put back on the way out, since
# this script may be dot-run inside a longer job.
$callerPath = $env:PATH
$env:PATH = "$llvmBin;$(Split-Path -Parent $cmake);$env:SystemRoot\System32;$env:SystemRoot"
try {

    $source = Join-Path $WorkRoot "clingo-$ClingoVersion"
    $build = Join-Path $WorkRoot 'build'
    # CMake's Windows-GNU platform file sets CMAKE_SHARED_LIBRARY_PREFIX to "lib"
    # as a normal variable, which shadows a -D cache entry. A project include runs
    # after the platform files, so setting it there names the DLL clingo.dll.
    $noLibPrefix = Join-Path $WorkRoot 'no-lib-prefix.cmake'
    [IO.File]::WriteAllText($noLibPrefix, "set(CMAKE_SHARED_LIBRARY_PREFIX `"`")`n")
    Invoke-Checked 'configure' {
        & $cmake -S $source -B $build -G 'MinGW Makefiles' '-DCMAKE_BUILD_TYPE=Release' `
            '-DCMAKE_C_COMPILER=gcc' '-DCMAKE_CXX_COMPILER=g++' '-DCMAKE_MAKE_PROGRAM=mingw32-make' `
            '-DCMAKE_POLICY_VERSION_MINIMUM=3.5' "-DCMAKE_PROJECT_INCLUDE=$noLibPrefix" `
            '-DCMAKE_SHARED_LINKER_FLAGS=-static' '-DCMAKE_EXE_LINKER_FLAGS=-static' `
            '-DCLINGO_BUILD_WITH_PYTHON=OFF' '-DCLINGO_BUILD_WITH_LUA=OFF' `
            '-DCLINGO_BUILD_SHARED=ON' '-DCLINGO_BUILD_APPS=ON' '-DCLINGO_BUILD_TESTS=OFF' 2>&1 | Out-Host
    }
    Invoke-Checked 'build' { & $cmake --build $build --parallel ([Environment]::ProcessorCount) 2>&1 | Out-Host }

    $dll = Join-Path $build 'bin\clingo.dll'
    $exe = Join-Path $build 'bin\clingo.exe'
    foreach ($image in @($dll, $exe)) {
        if (-not (Test-Path -LiteralPath $image -PathType Leaf)) { throw "build-clingo-windows-arm64: $image was not produced" }
        Assert-PeMachine -Path $image -Arch arm64 -Consumer 'build-clingo-windows-arm64'
    }

    # Qualification 1: the closure. Only system DLLs: KERNEL32 and the UCRT set,
    # plus (for clingo.exe) clingo.dll itself.
    foreach ($image in @($dll, $exe)) {
        $imports = @(& (Join-Path $llvmBin 'llvm-readobj.exe') --coff-imports $image |
            Select-String -Pattern '^\s*Name:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
        foreach ($import in $imports) {
            if ($import -notmatch '^(?i:kernel32\.dll|api-ms-win-crt-[a-z0-9-]+\.dll|clingo\.dll)$') {
                throw "build-clingo-windows-arm64: $image imports $import, outside the allowed closure"
            }
        }
        Write-Host "$([IO.Path]::GetFileName($image)) imports: $($imports -join ', ')"
    }

    # Qualification 2: the solver, with PATH cut to the system directories.
    $program = Join-Path $WorkRoot 'choice.lp'
    [IO.File]::WriteAllText($program, "a :- not b. b :- not a.`n")
    $solve = & $exe $program 0 2>&1 | Out-String
    $solveExit = $LASTEXITCODE
    Write-Host $solve
    # clingo's exit code: 10 satisfiable, +20 search space exhausted.
    if ($solveExit -ne 30 -or $solve -notmatch 'Models\s*:\s*2\b') {
        throw "build-clingo-windows-arm64: clingo.exe did not find exactly the two models (exit $solveExit)"
    }
    $versionLine = (& $exe --version | Select-Object -First 1).Trim()
    if ($versionLine -ne "clingo version $ClingoVersion") {
        throw "build-clingo-windows-arm64: clingo.exe reports '$versionLine', not $ClingoVersion"
    }

    # Qualification 3: a separate C image loads clingo.dll by name through the C
    # API, as repro_solver does (LoadLibrary, not import-table binding).
    $probe = Join-Path $WorkRoot 'load_clingo.c'
    [IO.File]::WriteAllText($probe, @'
#include <windows.h>
#include <stdio.h>
#include <stdbool.h>
#include <stddef.h>
typedef void (*version_fn)(int *, int *, int *);
typedef bool (*control_new_fn)(char const *const *, size_t, void *, void *, unsigned, void **);
typedef bool (*control_add_fn)(void *, char const *, char const *const *, size_t, char const *);
typedef bool (*control_ground_fn)(void *, void const *, size_t, void *, void *);
typedef void (*control_free_fn)(void *);
typedef struct { char const *name; void const *params; size_t size; } part_t;
int main(void) {
  HMODULE h = LoadLibraryA("clingo.dll");
  if (!h) { printf("LoadLibrary failed: %lu\n", GetLastError()); return 2; }
  version_fn version = (version_fn)GetProcAddress(h, "clingo_version");
  control_new_fn control_new = (control_new_fn)GetProcAddress(h, "clingo_control_new");
  control_add_fn control_add = (control_add_fn)GetProcAddress(h, "clingo_control_add");
  control_ground_fn control_ground = (control_ground_fn)GetProcAddress(h, "clingo_control_ground");
  control_free_fn control_free = (control_free_fn)GetProcAddress(h, "clingo_control_free");
  if (!version || !control_new || !control_add || !control_ground || !control_free) return 3;
  int ma, mi, re; version(&ma, &mi, &re);
  void *ctl = NULL;
  if (!control_new(NULL, 0, NULL, NULL, 20, &ctl)) return 4;
  if (!control_add(ctl, "base", NULL, 0, "a :- not b. b :- not a.")) return 5;
  part_t part = { "base", NULL, 0 };
  if (!control_ground(ctl, &part, 1, NULL, NULL)) return 6;
  control_free(ctl);
  printf("clingo %d.%d.%d loaded and grounded through the C API\n", ma, mi, re);
  return 0;
}
'@)
    $probeExe = Join-Path (Split-Path -Parent $dll) 'load_clingo.exe'
    Invoke-Checked 'probe-compile' { & (Join-Path $llvmBin 'gcc.exe') -O2 -o $probeExe $probe 2>&1 | Out-Host }
    $probeOut = & $probeExe 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $probeOut -notmatch "clingo $([regex]::Escape($ClingoVersion)) loaded") {
        throw "build-clingo-windows-arm64: loading clingo.dll through the C API failed (exit $LASTEXITCODE): $probeOut"
    }
    Write-Host $probeOut
    Remove-Item -LiteralPath $probeExe -Force

    # Package. One top-level directory, named like the ZIP.
    $name = "clingo-$ClingoVersion-windows-arm64-$($ProducerRevision.Substring(0, 12))"
    $stage = Join-Path $WorkRoot $name
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -LiteralPath $dll, $exe -Destination $stage
    Copy-Item -LiteralPath (Join-Path $source 'libclingo\clingo.h') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $source 'LICENSE.md') -Destination $stage
    @(
        "clingo_version=$ClingoVersion"
        "clingo_tarball_sha256=$($ClingoTarballSha256.ToLowerInvariant())"
        "compiler=llvm-mingw-$LlvmMingwRelease-ucrt-aarch64 sha256=$($LlvmMingwSha256.ToLowerInvariant())"
        "cmake=$CMakeVersion sha256=$($CMakeSha256.ToLowerInvariant())"
        "producer_revision=$ProducerRevision"
        "runner=$env:RUNNER_NAME"
    ) | Set-Content -LiteralPath (Join-Path $stage 'BUILDINFO.txt') -Encoding ascii
    $zip = Join-Path $OutDir "$name.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
    $zipSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    $dllSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $dll).Hash.ToLowerInvariant()
    "$zipSha  $name.zip" | Set-Content -LiteralPath (Join-Path $OutDir 'SHA256SUMS') -Encoding ascii
    Write-Host "Packaged $name.zip sha256 $zipSha (clingo.dll sha256 $dllSha)"
} finally {
    $env:PATH = $callerPath
}
