# reprobuild Windows DIY dev environment (PowerShell).
#
# Usage:
#     . .\env.ps1
#
# The Linux/macOS dev shell comes from `.envrc` (`use flake`) -- this
# script is the equivalent on Windows, providing the toolchain
# `bash scripts/build_apps.sh` and `just test` need:
#
#   * Nim 2.2.x + a working C compiler (gcc/clang/cl)         -- via
#     windows/bootstrap-toolchain.ps1 (Ensure-Nim + Ensure-Gcc), which
#     lives in THIS repo: no sibling checkout of any other repo is needed
#     to bootstrap. `just`, `gh`, `python3`, `gpg` and `git-repo` are NOT
#     provisioned -- none is required to build repro, and the gpg step in
#     particular used to trigger a UAC elevation prompt.
#   * bash                                                    -- resolved from
#     git's own installation and put AHEAD of the WSL launcher that Windows
#     puts on PATH by default. Both build entry points below are bash scripts,
#     so without this the environment reports "ready" and then the build fails
#     with a WSL "no installed distributions" message.
#   * clingo.dll (the ASP solver repro_solver dlopens at module init)
#                                                             -- via
#     windows/ensure-clingo.ps1. reprobuild-specific, so it lives here
#     rather than in the shared framework. On Linux/macOS the flake
#     devShell supplies it (`pkgs.clingo`); this is the Windows
#     counterpart, and `scripts/build_apps.sh` stages the DLL it
#     installs next to the built `repro.exe`.
#   * nim-bearssl + its csources submodule (repro_peer_cache/auth.nim
#     imports `bearssl/ec`)                                   -- via
#     windows/ensure-nim-bearssl.ps1, the Windows counterpart of the
#     flake's `bearssl-src` input, pinned to the same revision.
#   * OpenSSL import libraries + runtime DLLs (`repro`,
#     `repro-binary-cache` and `repro-harvest-apt` are `--define:ssl`
#     entry points, and the catalog's nim typed-tool links them with
#     `-lssl -lcrypto`)                                     -- via
#     windows/ensure-openssl.ps1. Note this is a LINK dependency, and is
#     unrelated to the nix-only `openssl` CLI entry in the builtin
#     catalog. The flake devShell carries the equivalent search path in
#     `NIX_LDFLAGS`; this script exports it as `LIBRARY_PATH`, which gcc
#     consults for `-l` lookup, so both the shell route
#     (`scripts/build_apps.sh`) and the graph route (`repro build .#apps`)
#     link without either of them naming OpenSSL.
#   * Sibling repos checked out alongside `reprobuild/`:
#       - codetracer/                  (libs/nim-stew, libs/nim-faststreams,
#                                       libs/nim-serialization, libs/nimcrypto
#                                       submodules under it)
#       - runquota/                    (Nim libs under libs/runquota_*)
#       - nim-stackable-hooks/         (framework primitives the monitor shim builds on)
#
#   Once the sibling layout is satisfied, `config.nims` resolves every
#   third-party package without touching `nimble install`.
#
# Knobs (unchanged from the framework these scripts came from):
#   $env:WINDOWS_DIY_SYNC = "0"            skip all toolchain downloads
#   $env:WINDOWS_DIY_SKIP_NIM = "1"        skip the nim step
#   $env:WINDOWS_DIY_SKIP_GCC = "1"        skip the gcc step
#   $env:WINDOWS_DIY_INSTALL_ROOT = <dir>  where toolchains land
#   (the JUST / GH / PYTHON / REPO / GPG skips are gone with the steps
#   themselves -- see the nim/gcc note above)
#
# Knobs specific to reprobuild:
#   $env:WINDOWS_DIY_SKIP_CLINGO = "1" skip the clingo step. Note that
#       every `repro` binary built afterwards will abort at startup with
#       `could not load: clingo.dll` unless clingo is on PATH by some
#       other means -- the skip exists for hosts that provision it
#       independently, not as a way to opt out of the dependency.
#   $env:WINDOWS_DIY_SKIP_NIM_BEARSSL = "1" skip the nim-bearssl step. The
#       build then fails with `cannot open file: bearssl/ec` unless
#       $BEARSSL_SRC or a `../nim-bearssl` sibling supplies it. Same
#       caveat as clingo: for hosts that provision it independently.
#   $env:WINDOWS_DIY_SKIP_OPENSSL = "1" skip the OpenSSL step. The build
#       then fails to link `repro`, `repro-binary-cache` and
#       `repro-harvest-apt` with `ld.exe: cannot find -lssl` unless
#       $LIBRARY_PATH already names a directory holding
#       `libssl.dll.a`/`libcrypto.dll.a` built against a UCRT mingw
#       toolchain. Same caveat as clingo: for hosts that provision it
#       independently, not a way to opt out of the dependency.
#   $env:STACKABLE_HOOKS_SRC = <path>  override `../nim-stackable-hooks/src`.
#   $env:RUNQUOTA_SRC     = <path>  override `../runquota`.
#   $env:NIMCRYPTO_SRC    = <path>  override `../codetracer/libs/nimcrypto`.
#   $env:NIM_STEW_SRC     = <path>  override `../codetracer/libs/nim-stew`.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# --- 1. Cold-start toolchain bootstrap (nim + gcc) ---------------------------
# Self-contained: this repo now carries its own copies of the provisioning
# scripts under windows/ (toolchain-utils.ps1, ensure-nim.ps1, ensure-gcc.ps1
# plus the bootstrap-toolchain.ps1 driver), moved here from the archived
# repo-workspaces framework this script used to require as a sibling
# checkout. A reprobuild checkout on a bare Windows box now bootstraps with
# no other repo present.
#
# Scope note: this is the ONLY provisioning that cannot go through
# reprobuild's own builtin catalog, because running the catalog needs a
# working `repro` and `just bootstrap` is exactly the case where there is
# not one. See windows/bootstrap-toolchain.ps1 for the full rationale, and
# libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/{nim,gcc_winlibs}.nim
# for the declarative entries that supersede it once a repro exists.
. (Join-Path $scriptDir "windows\bootstrap-toolchain.ps1")
$installRoot = Invoke-ReproToolchainBootstrap

# --- 1b. clingo (reprobuild-specific) ----------------------------------------
# The bootstrap above brought the shared helpers ($installRoot,
# Get-WindowsArch, Test-BootstrapStepEnabled, Read-KeyValueFile, ...) into
# this scope. Its $toolchain covers only the cold-start nim/gcc pins, so read
# THIS repo's pin file again here for the clingo entries.
#
# Unlike the framework steps, a failure here is fatal rather than a warning:
# every `repro` binary built without clingo aborts at module init, so a build
# that proceeds past a failed clingo bootstrap only produces a broken binary
# and defers the error to a much more confusing place.
$clingoDir = ""
if (Test-BootstrapStepEnabled "CLINGO") {
    . (Join-Path $scriptDir "windows\ensure-clingo.ps1")
    $reproToolchain = Read-KeyValueFile -Path (Join-Path $scriptDir "windows\toolchain-versions.env")
    $clingoDir = Ensure-Clingo -Root $installRoot -Arch (Get-WindowsArch) -Toolchain $reproToolchain
    # Two independent handles on the same directory, because
    # `scripts/build_apps.sh` accepts either: the PATH entry makes
    # `command -v clingo.exe` resolve (the long-standing discovery route, which
    # also works for a hand-provisioned clingo), and the explicit variable
    # names the pinned install directly so staging does not depend on PATH
    # ordering against some other clingo that may be ahead of it.
    Add-PathEntry -Dir $clingoDir
    $env:REPRO_WINDOWS_CLINGO_DIR = $clingoDir
}

# --- 1c. nim-bearssl (reprobuild-specific) -----------------------------------
# `repro_peer_cache/auth.nim` imports `bearssl/ec`, so this is a hard build
# dependency of `repro` itself. Linux/macOS receive it from the flake's
# `bearssl-src` input; on Windows `config.nims` would otherwise fall back to
# searching `../nim-bearssl`, which exists only on hosts where somebody cloned
# it by hand. Fatal for the same reason as clingo: a build that proceeds
# without it fails deep in the C stage with `cannot open file: bearssl/ec`,
# which reads as a reprobuild bug rather than a missing dependency.
$bearsslDir = ""
if (Test-BootstrapStepEnabled "NIM_BEARSSL") {
    . (Join-Path $scriptDir "windows\ensure-nim-bearssl.ps1")
    $reproToolchain = Read-KeyValueFile -Path (Join-Path $scriptDir "windows\toolchain-versions.env")
    $bearsslDir = Ensure-NimBearssl -Root $installRoot -Toolchain $reproToolchain
    # `config.nims` reads $BEARSSL_SRC first and only then probes the sibling
    # candidates, so exporting it makes the pinned checkout win over any stale
    # hand-cloned `../nim-bearssl` a developer may still have lying around.
    $env:BEARSSL_SRC = $bearsslDir
}

# --- 1d. OpenSSL link artefacts (reprobuild-specific) ------------------------
# `repro`, `repro-binary-cache` and `repro-harvest-apt` are compiled with
# `--define:ssl`, and for any such entry point the builtin catalog's nim
# typed-tool appends the portable linker names `-lssl -lcrypto`
# (`packages/nim.nim`, `opensslPassLForSsl`). It deliberately bakes NO search
# path into them -- `t_nim_ssl_dependency.nim` asserts that an ambient path
# never reaches `passL` -- so supplying the search directory is this script's
# job. On Linux/macOS the flake devShell does it via `NIX_LDFLAGS`; without a
# Windows counterpart, `just test` built 15 of its 18 apps and failed the
# other three with `ld.exe: cannot find -lssl`.
#
# Fatal like the two steps above, and for the same reason: a build that
# proceeds without it does not degrade, it fails later in the C link stage
# with a message that reads as a broken checkout.
$openSslDir = ""
if (Test-BootstrapStepEnabled "OPENSSL") {
    . (Join-Path $scriptDir "windows\ensure-openssl.ps1")
    $reproToolchain = Read-KeyValueFile -Path (Join-Path $scriptDir "windows\toolchain-versions.env")
    $openSslDir = Ensure-OpenSsl -Root $installRoot -Arch (Get-WindowsArch) -Toolchain $reproToolchain

    # LIBRARY_PATH rather than a --passL, because it has to reach BOTH build
    # routes: `bash scripts/build_apps.sh` (which sets its own nim flags) and
    # `repro build .#apps` (whose actions the build engine spawns, and which
    # therefore never observe build_apps.sh's variables). gcc consults
    # LIBRARY_PATH natively for `-l` lookup, so neither route needs to know
    # this step exists. Prepend rather than overwrite: a developer may already
    # be carrying a LIBRARY_PATH for another toolchain.
    $openSslLibDir = Join-Path $openSslDir "lib"
    if ($env:LIBRARY_PATH) {
        $env:LIBRARY_PATH = $openSslLibDir + [IO.Path]::PathSeparator + $env:LIBRARY_PATH
    } else {
        $env:LIBRARY_PATH = $openSslLibDir
    }
    # The import libraries above only get the link to succeed. `libssl-3-x64.dll`
    # and `libcrypto-3-x64.dll` must also be findable at RUN time, or every ssl
    # binary starts and immediately dies in the loader -- including the ones the
    # test suite builds and executes.
    Add-PathEntry -Dir (Join-Path $openSslDir "bin")
    # Named explicitly as well, so a consumer that needs the directory (release
    # staging, a diagnostic) does not have to parse LIBRARY_PATH back apart.
    $env:REPRO_WINDOWS_OPENSSL_DIR = $openSslDir
}

# --- 2. Sibling repo discovery -----------------------------------------------
$parentDir = Split-Path -Parent $scriptDir

function Test-SiblingRepo {
    param([string]$Name, [string]$Marker)
    $candidate = Join-Path $parentDir $Name
    if (Test-Path -LiteralPath (Join-Path $candidate $Marker)) {
        return $candidate
    }
    return ""
}

$codetracerDir = Test-SiblingRepo -Name "codetracer" -Marker "libs"
$runquotaDir = Test-SiblingRepo -Name "runquota" -Marker "libs"
$stackableHooksDir = Test-SiblingRepo -Name "nim-stackable-hooks" -Marker "stackable_hooks.nimble"

if ([string]::IsNullOrEmpty($codetracerDir)) {
    Write-Warning "reprobuild env.ps1: ../codetracer sibling missing -- nimcrypto/nim-stew/nim-faststreams/nim-serialization come from there. Clone it and run 'git submodule update --init libs/nimcrypto libs/nim-stew libs/nim-faststreams libs/nim-serialization' before building."
}
if ([string]::IsNullOrEmpty($runquotaDir)) {
    Write-Warning "reprobuild env.ps1: ../runquota sibling missing -- the runquota_* libraries are required by config.nims. Clone metacraft-labs/runquota and run 'git checkout dev'."
}
if ([string]::IsNullOrEmpty($stackableHooksDir)) {
    Write-Warning "reprobuild env.ps1: ../nim-stackable-hooks sibling missing -- the monitor shim's hook_registry, reentrancy guard, and inline-detour primitive all come from there. Clone metacraft-labs/nim-stackable-hooks if you plan to build the Windows monitor shim."
}

# Re-export the resolved sibling paths so `config.nims` doesn't have to
# walk relative-path candidates. Only the entries that have no vendored
# fallback inside `reprobuild/libs/` are exported here:
#
#   * RUNQUOTA_SRC / STACKABLE_HOOKS_SRC -- no vendored fallback, must
#     point at the sibling checkout.
#
# `NIMCRYPTO_SRC` / `NIM_STEW_SRC` / `NIM_FASTSTREAMS_SRC` are
# DELIBERATELY NOT exported, even though their codetracer-side copies
# exist: `config.nims` already searches `reprobuild/libs/` FIRST, and
# the vendored copies under `reprobuild/libs/` are newer than the
# pinned submodule snapshots under `codetracer/libs/`. Setting an
# override would force the older copy and miss API additions
# (notably `stew/ptrops.baseAddr` which the vendored
# `nim-faststreams/buffers.nim` depends on).
if ($runquotaDir) { $env:RUNQUOTA_SRC = $runquotaDir }
if ($stackableHooksDir) {
    $env:STACKABLE_HOOKS_SRC = Join-Path $stackableHooksDir "src"
}

# --- io-mon live interpose monitor wiring (Incremental-Test-Runner M8) --------
# Make io-mon's standalone `io-mon.exe` CLI + interpose shim discoverable on
# PATH / via env when the io-mon sibling is present and built, so the CodeTracer
# incremental test runner's live read-file capture can resolve them
# out-of-process. Mirrors codetracer/.envrc + .envrc (POSIX) on the Windows DIY
# path.
#
# Windows capture uses the CreateRemoteThread + LoadLibraryW injector
# (io_mon/windows_injector.nim), not the POSIX DYLD/LD_PRELOAD env var. This
# block only seeds discovery of already-built artifacts; the runner still fails
# safe to a re-run if capture is empty or fails.
$ioMonDir = Test-SiblingRepo -Name "io-mon" -Marker "io_mon.nimble"
if ($ioMonDir) {
    $ioMonExe = Join-Path $ioMonDir "build\bin\io-mon.exe"
    if (Test-Path -LiteralPath $ioMonExe) {
        $env:IO_MON = $ioMonExe
        $env:PATH = (Join-Path $ioMonDir "build\bin") + [IO.Path]::PathSeparator + $env:PATH
    }
    $ioMonShimDll = Join-Path $ioMonDir "build\lib\librepro_monitor_shim.dll"
    if (Test-Path -LiteralPath $ioMonShimDll) {
        $env:REPRO_MONITOR_SHIM_LIB = $ioMonShimDll
    }
    $env:IO_MON_SRC = Join-Path $ioMonDir "src"
}

# --- 2b. bash (the thing every "Next steps" line below invokes) --------------
# `scripts/build_apps.sh` and `scripts/run_tests.sh` are bash scripts, so this
# environment is not "ready" without a bash that can run them. Windows makes
# that a real trap: `C:\Windows\System32\bash.exe` (the WSL launcher, also
# surfaced via the WindowsApps alias) is on PATH by DEFAULT and shadows Git
# Bash. On a host with no WSL distro installed it does not fail as "bash is
# missing" — it prints a WSL advertisement, exits non-zero, and the build dies
# with a message about distributions that has nothing to do with reprobuild.
#
# git ships the bash we want and `Ensure-Git` (framework, above) has already
# put git on PATH, so the fix is to resolve bash from git's own installation
# and put it AHEAD of the WSL stub rather than to provision anything new.
function Get-CommandSourceOrEmpty {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return "" }
    if ($cmd.CommandType -eq "Alias") { return $cmd.Definition }
    return $cmd.Source
}

function Test-UsableBash {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    # The WSL launcher lives in System32 / WindowsApps and is never the bash we
    # want here, even when a distro IS installed: the build must run against the
    # host filesystem with the host toolchain on PATH, not inside a Linux VM.
    $dir = Split-Path -Parent $Path
    if ($dir -match '\\(System32|SysWOW64|WindowsApps)$') { return $false }
    return $true
}

function Resolve-GitBashDir {
    # `git.exe` lives in `<root>\cmd` (or `<root>\bin`); bash sits in
    # `<root>\bin\bash.exe` for every supported layout (Git for Windows,
    # scoop, winget).
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) { return "" }
    $gitExe = if ($git.CommandType -eq "Alias") { $git.Definition } else { $git.Source }
    if ([string]::IsNullOrWhiteSpace($gitExe)) { return "" }
    $root = Split-Path -Parent (Split-Path -Parent $gitExe)
    foreach ($candidate in @((Join-Path $root "bin"), (Join-Path $root "usr\bin"))) {
        if (Test-Path -LiteralPath (Join-Path $candidate "bash.exe")) {
            return $candidate
        }
    }
    return ""
}

$currentBash = Get-CommandSourceOrEmpty 'bash'
if (-not (Test-UsableBash $currentBash)) {
    $gitBashDir = Resolve-GitBashDir
    if ($gitBashDir) {
        Add-PathEntry -Dir $gitBashDir
    } else {
        Write-Warning "reprobuild env.ps1: no usable bash found (PATH resolves bash to '$currentBash', and git's own bash could not be located). 'bash scripts/build_apps.sh' will fail -- install Git for Windows."
    }
}
$bashPath = Get-CommandSourceOrEmpty 'bash'

# --- 3. Status summary -------------------------------------------------------
function Get-CommandSource {
    # `repo-workspaces/env.ps1` exposes nim / just / python / gh / repo as
    # PowerShell *aliases* (CommandType -ne Application), so the canonical
    # `.Source` property is empty. Resolve through the alias' `Definition`
    # when present and fall back to the application source otherwise.
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return "(not on PATH)" }
    if ($cmd.CommandType -eq "Alias") {
        return $cmd.Definition
    }
    return $cmd.Source
}

function Get-ToolPathWithVersion {
    # Report the version the binary ITSELF claims, not the one implied by the
    # directory it happens to sit in.
    #
    # `GCC_VERSION` in windows/toolchain-versions.env is a FALLBACK pin, not a
    # hard one: `Test-CompilerOnPath` deliberately skips provisioning whenever
    # any sane gcc is already on PATH (MSYS2, a system mingw), so the installed
    # tree keeps whatever directory name it was given when it was first
    # provisioned. On this box that produced
    # `D:\metacraft-dev-deps\gcc\15.2.0\bin\gcc.exe` -- a junction into a
    # WinLibs package that reports 16.1.0. Every log line and every status
    # summary then repeated 15.2.0, which is the sort of thing discovered
    # months later while bisecting a miscompile.
    param([string]$Name)
    $source = Get-CommandSource $Name
    if ($source -eq "(not on PATH)") { return $source }
    try {
        $line = & $source --version 2>&1 | Select-Object -First 1
        if ("$line" -match '([0-9]+\.[0-9]+(\.[0-9]+)?)') {
            return "$source  (reports $($Matches[1]))"
        }
    } catch {}
    return $source
}

Write-Host ""
Write-Host "reprobuild dev environment ready."
Write-Host "  nim          = $(Get-CommandSource 'nim')"
Write-Host "  gcc          = $(Get-ToolPathWithVersion 'gcc')"
Write-Host "  just         = $(Get-CommandSource 'just')"
Write-Host "  bash         = $(if ($bashPath) { $bashPath } else { '(missing -- the build scripts cannot run)' })"
Write-Host "  clingo       = $(if ($clingoDir) { Join-Path $clingoDir 'clingo.dll' } else { '(skipped -- repro.exe will not start)' })"
Write-Host "  nim-bearssl  = $(if ($bearsslDir) { $bearsslDir } else { '(skipped -- repro will not build)' })"
Write-Host "  openssl      = $(if ($openSslDir) { Join-Path $openSslDir 'lib' } else { '(skipped -- the --define:ssl apps will not link)' })"
Write-Host "  codetracer   = $(if ($codetracerDir) { $codetracerDir } else { '(missing -- see warning)' })"
Write-Host "  runquota     = $(if ($runquotaDir) { $runquotaDir } else { '(missing -- see warning)' })"
Write-Host "  stackable-hooks = $(if ($stackableHooksDir) { $stackableHooksDir } else { '(missing -- see warning)' })"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  bash scripts/build_apps.sh      # compile every app entry point under build/bin/"
Write-Host "  bash scripts/run_tests.sh       # compile + run the local test suite"
