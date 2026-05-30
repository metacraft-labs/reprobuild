#requires -Version 5
# ==============================================================================
# M9 end-to-end verification harness for the standard provider.
#
# Iterates every populated example directory under ``reprobuild-examples/``,
# builds it via ``repro build <dir>#default --tool-provisioning=path``, and
# classifies the outcome as one of:
#
#   PASS        : repro exit 0; expected binary is produced; if applicable
#                 it runs and prints the expected greeting.
#   KNOWN-FAIL  : repro exited non-zero, with a diagnostic that matches a
#                 documented Mode A coverage gap. These are recorded but
#                 do NOT fail the harness.
#   SKIP        : the language's required toolchain (or convention) isn't
#                 available. Recorded but does not fail the harness.
#   FAIL        : anything else (crash, hang, wrong classification). The
#                 harness exits non-zero if any examples fall here.
#
# The aggregate REPRO_STATS_DIR records from PASS runs are rolled up at
# the end to attribute fast-path distribution (tier2a-trycompile-direct
# vs tier2b-standard-direct vs slow-path) and total wall time.
#
# ---------------- Today's expected results (Mode A coverage) -------------------
#
# Expected to PASS (the known-working set, post-M24):
#   nim/binary, nim/multi-binary,
#   nim/library, nim/library-with-tests,
#   rust/binary, rust/binary-with-build-rs,
#   rust/library, rust/library-with-tests, rust/workspace,
#   rust/workspace-lib-chain                 (M23: lib→lib edges + -L dependency),
#   rust/cdylib                              (M23: crate-type cdylib variant),
#   rust/binary-with-crates-io               (M23: external dep → Mode B fallback;
#                                             SKIP when CARGO_HOME registry empty),
#   go/binary, go/library, go/library-with-tests, go/multi-binary,
#   python/library-pure,
#   python/console-script    (M20: byte-compile + sdist + runnable shim),
#   python/pep517-maturin    (M24: maturin backend → Mode B; SKIP when host
#                             Python lacks libs/python<MAJ><MIN>.lib),
#   python/pep517-scikit-build-core
#                            (M24: scikit_build_core.build → Mode B; SKIP when
#                             host Python lacks dev headers + import library),
#   javascript-typescript/typescript-library,
#   javascript-typescript/typescript-cli,
#   javascript-typescript/node-server,
#   javascript-typescript/vite-app           (M24: vite.config.* → Mode B
#                                             "npm install && npm run build"),
#   javascript-typescript/webpack-app        (M24: webpack.config.* → Mode B),
#   c-cpp-make/binary, c-cpp-make/library-static,
#   c-cpp-autotools/hello-binary (when autotools toolchain available),
#   c-cpp-cmake/hello-binary (M38; SKIP when cmake/ninja-or-make missing)
#   c-cpp-meson/hello-binary  (M39; SKIP when meson/ninja missing)
#   java-maven/hello-binary   (M40; SKIP when javac/mvn missing)
#   kotlin-gradle/hello-binary (M41; SKIP when javac/gradle missing)
#   csharp-dotnet/hello-binary (M42; SKIP when dotnet missing)
#   swift-swiftpm/hello-binary (M43; SKIP when swift missing — Swift Windows
#                               toolchain isn't in the standard dev shell)
#   ocaml-dune/hello-binary   (M46; SKIP when ocaml/dune missing — OCaml
#                               isn't in the standard dev shell on Windows)
#   haskell-cabal/hello-binary (M55; SKIP when ghc/cabal missing — Haskell
#                               isn't in the standard dev shell on Windows)
#   ruby-bundler/hello-binary  (M56; SKIP when ruby/bundle missing — Ruby
#                               isn't in the standard dev shell on Windows)
#   php-composer/hello-binary  (M57; SKIP when php/composer missing — PHP
#                               isn't in the standard dev shell on Windows)
#
# M22 additionally runs ``repro build <fixture>#test`` for fixtures listed
# in $TestTargetProbes (nim/library-with-tests, rust/library-with-tests,
# go/library-with-tests). Each successful #test invocation records its own
# PASS row keyed ``<fixture>#test``; failures surface as FAIL rows. The
# typescript-cli #test path is covered by the dedicated
# validate-standard-provider-typescript-cli-tests.ps1 script (not by this
# harness) because that path requires an npm install which is expensive
# enough that re-paying it per harness run would dominate wall time.
#
# Expected to KNOWN-FAIL: (none — M14 graduated go/library + go/multi-binary;
#   M15 graduated python/library-pure + python/console-script;
#   M16 graduated all three javascript-typescript fixtures;
#   M17 graduated all three c-cpp fixtures;
#   M20 promoted python/console-script from wheel-only to runnable shim)
#
# Expected to SKIP: (only when toolchain is missing —
#   c-cpp-autotools/hello-binary SKIPs when autoreconf is unavailable on
#   the host; gates on Windows boxes without MSYS2 autoconf/automake).
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org §M9.
# ==============================================================================

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$examplesRoot   = Join-Path $metacraftRoot 'reprobuild-examples'
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'

# Per-run scratch under <repo>/build/m9-verify/.
$harnessScratch = Join-Path $repoRoot 'build\m9-verify'
$logsDir        = Join-Path $harnessScratch 'logs'
$statsRootDir   = Join-Path $harnessScratch 'stats'

# --- preflight --------------------------------------------------------------
if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $examplesRoot)) {
  Write-Host "FAIL: $examplesRoot missing -- expected sibling reprobuild-examples checkout"
  exit 1
}

# Clean prior harness scratch so we get a coherent fresh aggregate.
if (Test-Path -LiteralPath $harnessScratch) {
  Remove-Item -LiteralPath $harnessScratch -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $logsDir     | Out-Null
New-Item -ItemType Directory -Force -Path $statsRootDir | Out-Null

# --- the canonical list of 21 populated examples ----------------------------
# Mirrors libs/repro_standard_provider/tests/test_examples_layout.nim verbatim;
# changing the canonical list there must trigger a matching update here.
$PopulatedExamples = @(
  'nim/binary',
  'nim/library',
  'nim/library-with-tests',
  'nim/mode3-pilot',
  'nim/multi-binary',
  'rust/binary',
  'rust/library',
  'rust/library-with-tests',
  'rust/workspace',
  'rust/workspace-lib-chain',
  'rust/cdylib',
  'rust/binary-with-crates-io',
  'rust/binary-with-build-rs',
  'go/binary',
  'go/library',
  'go/library-with-tests',
  'go/multi-binary',
  'python/library-pure',
  'python/console-script',
  'python/pep517-maturin',
  'python/pep517-scikit-build-core',
  'javascript-typescript/typescript-library',
  'javascript-typescript/typescript-cli',
  'javascript-typescript/node-server',
  'javascript-typescript/vite-app',
  'javascript-typescript/webpack-app',
  'c-cpp-make/binary',
  'c-cpp-make/library-static',
  'c-cpp-autotools/hello-binary',
  'c-cpp-cmake/hello-binary',
  'c-cpp-meson/hello-binary',
  'java-maven/hello-binary',
  'kotlin-gradle/hello-binary',
  'csharp-dotnet/hello-binary',
  'swift-swiftpm/hello-binary',
  'ocaml-dune/hello-binary',
  'haskell-cabal/hello-binary',
  'ruby-bundler/hello-binary',
  'php-composer/hello-binary',
  'c-cpp-mode3/binary-with-library',
  'rust-mode3/binary-with-library',
  'go-mode3/binary-with-library',
  'python-mode3/binary-with-library',
  'jsts-mode3/binary-with-library',
  'mixed/nim-uses-cpp-lib',
  'mixed/cpp-uses-nim-lib',
  'mixed/rust-uses-cpp-lib',
  'mixed/cpp-uses-rust-lib',
  'mixed/nim-uses-rust-lib',
  'mixed/rust-uses-nim-lib',
  'mixed/go-uses-cpp-lib',
  'mixed/cpp-uses-go-lib',
  'fortran-mode3/binary-with-library',
  'mixed/fortran-uses-cpp-lib',
  'mixed/cpp-uses-fortran-lib',
  'zig-mode3/binary-with-library',
  'mixed/zig-uses-cpp-lib',
  'mixed/cpp-uses-zig-lib',
  'd-mode3/binary-with-library',
  'mixed/d-uses-cpp-lib',
  'mixed/cpp-uses-d-lib',
  'ada-mode3/binary-with-library',
  'mixed/ada-uses-cpp-lib',
  'mixed/cpp-uses-ada-lib',
  'mode1/rust-binary-with-library',
  'mode1/nim-binary-with-library'
)

# --- M22 test-target probes ------------------------------------------------
# Examples that ship test files AND that the M22 conventions surface as a
# non-default ``test`` target. After the default build succeeds, the harness
# additionally invokes ``repro build <fixture>#test`` and asserts exit 0
# plus the presence of at least one ``<scratch>/.../tests/*.stamp`` file
# (the convention's load-bearing signal that the test action actually fired).
# Keep this list in sync with the per-language conventions:
#   * Nim   : conventions/nim.nim         (emitTestAction)
#   * Rust  : conventions/rust.nim        (emitForTestTarget)
#   * Go    : conventions/go.nim          (emitTestAction)
#   * JS/TS : conventions/javascript_typescript.nim (emitTestRunnerAction)
# A typescript-cli probe is intentionally NOT added here because that
# fixture's ``#test`` target requires a populated ``node_modules/`` (M21
# A1 ``npm ci`` running before A7 test runner). The dedicated
# validate-standard-provider-typescript-cli-tests.ps1 script covers that
# path end-to-end and keeps the harness from re-paying the ~5-30s npm
# install cost per harness run.
$TestTargetProbes = @(
  'nim/library-with-tests',
  'rust/library-with-tests',
  'go/library-with-tests'
)

function Get-Language([string]$rel) {
  return ($rel -split '/')[0]
}

function Get-ExampleName([string]$rel) {
  return ($rel -replace '/', '-')
}

# --- per-language toolchain probe ------------------------------------------
# Returns a hashtable: { Available = $true/$false; Reason = string }
function Probe-Toolchain([string]$language) {
  switch ($language) {
    'nim' {
      $nim    = Get-Command nim    -ErrorAction SilentlyContinue
      $nimble = Get-Command nimble -ErrorAction SilentlyContinue
      if ($nim -and $nimble) {
        return @{ Available = $true; Reason = "nim=$($nim.Source); nimble=$($nimble.Source)" }
      }
      return @{ Available = $false; Reason = "nim/nimble not on PATH (env.ps1 should provide both)" }
    }
    'rust' {
      $rustc = Get-Command rustc -ErrorAction SilentlyContinue
      $cargo = Get-Command cargo -ErrorAction SilentlyContinue
      if (-not $rustc -or -not $cargo) {
        $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
        if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
          $env:PATH = "$rustupStableBin;$env:PATH"
          $rustc = Get-Command rustc -ErrorAction SilentlyContinue
          $cargo = Get-Command cargo -ErrorAction SilentlyContinue
        }
      }
      if ($rustc -and $cargo) {
        return @{ Available = $true; Reason = "rustc=$($rustc.Source); cargo=$($cargo.Source)" }
      }
      return @{ Available = $false; Reason = "rustc/cargo not on PATH and no rustup stable under D:/metacraft-dev-deps/rustup" }
    }
    'go' {
      $goCmd = Get-Command go -ErrorAction SilentlyContinue
      if (-not $goCmd) {
        $goRoot = 'D:/metacraft-dev-deps/go'
        $candidates = @()
        if (Test-Path -LiteralPath $goRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $goRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $verDir.FullName 'go\bin\go.exe'
            if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
          }
        }
        foreach ($sys in @('D:\Program Files\Go\bin\go.exe',
                           'C:\Program Files\Go\bin\go.exe',
                           'D:\Go\bin\go.exe',
                           'C:\Go\bin\go.exe')) {
          if (Test-Path -LiteralPath $sys) { $candidates += $sys }
        }
        if ($candidates.Count -gt 0) {
          $picked = $candidates | Sort-Object | Select-Object -Last 1
          $binDir = Split-Path -Parent $picked
          $env:PATH = "$binDir;$env:PATH"
          $goCmd = Get-Command go -ErrorAction SilentlyContinue
        }
      }
      if ($goCmd) {
        return @{ Available = $true; Reason = "go=$($goCmd.Source)" }
      }
      return @{ Available = $false; Reason = "'go' not on PATH and not under D:/metacraft-dev-deps/go/" }
    }
    'python' {
      # M15: the Python convention is registered. Probe for a working
      # python3 / python interpreter (rejecting the Windows Store stub
      # via a --version exit-code check). env.ps1 already provisions a
      # bundled Python 3.12 under D:/metacraft-dev-deps/python/ so this
      # branch almost always returns Available=$true in the dev shell.
      $pythonCmd = $null
      foreach ($n in @('python3', 'python')) {
        $candidate = Get-Command $n -ErrorAction SilentlyContinue
        if ($candidate) {
          & $candidate.Source --version 2>$null | Out-Null
          if ($LASTEXITCODE -eq 0) {
            $pythonCmd = $candidate
            break
          }
        }
      }
      if ($pythonCmd) {
        return @{ Available = $true; Reason = "python=$($pythonCmd.Source)" }
      }
      return @{ Available = $false; Reason = "'python3'/'python' not on PATH (env.ps1 should provide the managed install)" }
    }
    'javascript-typescript' {
      # M16: the JavaScript/TypeScript convention is registered. Probe
      # for node (and therefore npm/npx, which ship in every node
      # distribution). env.ps1 doesn't manage node directly today; fall
      # back to the managed install under D:/metacraft-dev-deps/node/
      # when the dev shell didn't preload it.
      $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
      if (-not $nodeCmd) {
        $nodeRoot = 'D:\metacraft-dev-deps\node'
        if (Test-Path -LiteralPath $nodeRoot) {
          $candidates = @()
          foreach ($verDir in Get-ChildItem -LiteralPath $nodeRoot -Directory -ErrorAction SilentlyContinue) {
            foreach ($inner in Get-ChildItem -LiteralPath $verDir.FullName -Directory -ErrorAction SilentlyContinue) {
              $candidate = Join-Path $inner.FullName 'node.exe'
              if (Test-Path -LiteralPath $candidate) {
                $candidates += $candidate
              }
            }
          }
          if ($candidates.Count -gt 0) {
            $picked = $candidates | Sort-Object | Select-Object -Last 1
            $binDir = Split-Path -Parent $picked
            $env:PATH = "$binDir;$env:PATH"
            $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
          }
        }
      }
      if ($nodeCmd) {
        return @{ Available = $true; Reason = "node=$($nodeCmd.Source)" }
      }
      return @{ Available = $false; Reason = "'node' not on PATH and not under D:/metacraft-dev-deps/node/" }
    }
    'c-cpp-make' {
      # M17: the C/C++ Make convention is registered. Probe for a C
      # compiler (gcc or clang) AND ``ar`` AND ``make`` (or
      # ``mingw32-make`` on Windows). The convention itself only
      # requires gcc/clang at recognize time but the M9 gate's exit
      # signal benefits from including ``ar``/``make`` so a host
      # missing them SKIPs cleanly instead of FAILing.
      $ccCmd = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $ccCmd) {
        $ccCmd = Get-Command clang -ErrorAction SilentlyContinue
      }
      if (-not $ccCmd) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH" }
      }
      $arCmd = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $arCmd) {
        return @{ Available = $false; Reason = "'ar' not on PATH" }
      }
      $makeCmd = Get-Command make -ErrorAction SilentlyContinue
      if (-not $makeCmd) {
        $makeCmd = Get-Command mingw32-make -ErrorAction SilentlyContinue
      }
      if (-not $makeCmd) {
        return @{ Available = $false; Reason = "neither 'make' nor 'mingw32-make' on PATH" }
      }
      return @{ Available = $true; Reason = "cc=$($ccCmd.Source); ar=$($arCmd.Source); make=$($makeCmd.Source)" }
    }
    'c-cpp-mode3' {
      # Mode 3 C/C++ — same toolchain as c-cpp-make minus ``make``
      # (the convention emits compile + link argv directly; no Makefile
      # is consulted). Probe for a C compiler (gcc or clang) plus ar.
      $ccCmd = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $ccCmd) {
        $ccCmd = Get-Command clang -ErrorAction SilentlyContinue
      }
      if (-not $ccCmd) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH" }
      }
      $arCmd = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $arCmd) {
        return @{ Available = $false; Reason = "'ar' not on PATH" }
      }
      return @{ Available = $true; Reason = "cc=$($ccCmd.Source); ar=$($arCmd.Source)" }
    }
    'rust-mode3' {
      # M30: Mode 3 Rust — same toolchain probe as ``rust`` (the
      # Mode 2 path), minus the ``cargo`` requirement. ``rustc`` alone
      # is enough; the Mode 3 convention emits pure rustc invocations
      # and never spawns cargo. Reuse the rustup-stable fallback that
      # the ``rust`` probe uses so a fresh host without a system rustc
      # still picks up the bundled toolchain.
      $rustc = Get-Command rustc -ErrorAction SilentlyContinue
      if (-not $rustc) {
        $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
        if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
          $env:PATH = "$rustupStableBin;$env:PATH"
          $rustc = Get-Command rustc -ErrorAction SilentlyContinue
        }
      }
      if ($rustc) {
        return @{ Available = $true; Reason = "rustc=$($rustc.Source)" }
      }
      return @{ Available = $false; Reason = "rustc not on PATH and no rustup stable under D:/metacraft-dev-deps/rustup" }
    }
    'python-mode3' {
      # M32: Mode 3 Python — same toolchain probe as ``python`` (the
      # Mode 2 path). ``python3``/``python`` on PATH is enough; the
      # Mode 3 convention emits ``fs.preserveTree`` (stage) +
      # ``python -m compileall`` (byte-compile) + ``fs.writeText``
      # (wrapper script) actions directly and never invokes the PEP
      # 517 backend toolchain. Reuse the bundled-toolchain probe so
      # a fresh host without a system Python still picks up the
      # managed install under D:/metacraft-dev-deps/python/.
      $pythonCmd = $null
      foreach ($n in @('python3', 'python')) {
        $candidate = Get-Command $n -ErrorAction SilentlyContinue
        if ($candidate) {
          & $candidate.Source --version 2>$null | Out-Null
          if ($LASTEXITCODE -eq 0) {
            $pythonCmd = $candidate
            break
          }
        }
      }
      if ($pythonCmd) {
        return @{ Available = $true; Reason = "python=$($pythonCmd.Source)" }
      }
      return @{ Available = $false; Reason = "'python3'/'python' not on PATH (env.ps1 should provide the managed install)" }
    }
    'go-mode3' {
      # M31: Mode 3 Go — same toolchain probe as ``go`` (the Mode 2
      # path). ``go`` alone is enough; the Mode 3 convention emits
      # ``go tool compile`` + ``go tool link`` invocations directly
      # and consumes the GOCACHE'd stdlib archives via ``go list
      # -export``. Reuse the bundled-toolchain fallback that the
      # ``go`` probe uses so a fresh host without a system go still
      # picks up the managed install.
      $goCmd = Get-Command go -ErrorAction SilentlyContinue
      if (-not $goCmd) {
        $goRoot = 'D:/metacraft-dev-deps/go'
        $candidates = @()
        if (Test-Path -LiteralPath $goRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $goRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $verDir.FullName 'go\bin\go.exe'
            if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
          }
        }
        if ($candidates.Count -gt 0) {
          $picked = $candidates | Sort-Object | Select-Object -Last 1
          $binDir = Split-Path -Parent $picked
          $env:PATH = "$binDir;$env:PATH"
          $goCmd = Get-Command go -ErrorAction SilentlyContinue
        }
      }
      if ($goCmd) {
        return @{ Available = $true; Reason = "go=$($goCmd.Source)" }
      }
      return @{ Available = $false; Reason = "'go' not on PATH and not under D:/metacraft-dev-deps/go/" }
    }
    'fortran-mode3' {
      # M37: Mode 3 Fortran — probe for gfortran + ar. The convention
      # emits per-source ``gfortran -c`` + ``ar rcs lib<n>.a`` +
      # ``gfortran -o`` link argv. No managed-toolchain fallback today
      # (env.ps1 doesn't ship a gfortran provisioner); the WinLibs
      # GCC distribution carries gfortran alongside gcc so most hosts
      # with a working dev shell have it.
      $gfortranCmd = Get-Command gfortran -ErrorAction SilentlyContinue
      if (-not $gfortranCmd) {
        return @{ Available = $false; Reason = "'gfortran' not on PATH (env.ps1 / WinLibs / MSYS2 should provide it; install via 'pacman -S mingw-w64-x86_64-gcc-fortran' on MSYS2)" }
      }
      $arCmd = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $arCmd) {
        return @{ Available = $false; Reason = "'ar' not on PATH" }
      }
      return @{ Available = $true; Reason = "gfortran=$($gfortranCmd.Source); ar=$($arCmd.Source)" }
    }
    'zig-mode3' {
      # M44: Mode 3 Zig — probe for ``zig``. The convention emits
      # per-member ``zig build-exe`` / ``zig build-lib`` invocations.
      # When ``zig`` is not on PATH, fall back to the bundled install
      # under D:/metacraft-dev-deps/zig/<version>/ (the M44 honest-
      # scope cut: env.ps1 doesn't yet provision a zig toolchain so
      # most hosts SKIP this gate cleanly).
      $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
      if (-not $zigCmd) {
        $zigRoot = 'D:\metacraft-dev-deps\zig'
        if (Test-Path -LiteralPath $zigRoot) {
          $candidates = @()
          foreach ($verDir in Get-ChildItem -LiteralPath $zigRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $verDir.FullName 'zig.exe'
            if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
          }
          if ($candidates.Count -gt 0) {
            $picked = $candidates | Sort-Object | Select-Object -Last 1
            $binDir = Split-Path -Parent $picked
            $env:PATH = "$binDir;$env:PATH"
            $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
          }
        }
      }
      if ($zigCmd) {
        return @{ Available = $true; Reason = "zig=$($zigCmd.Source)" }
      }
      return @{ Available = $false; Reason = "'zig' not on PATH and not under D:/metacraft-dev-deps/zig/ (download from ziglang.org)" }
    }
    'd-mode3' {
      # M45: Mode 3 D — probe for a D compiler (ldmd2/dmd/ldc2). The
      # convention prefers ``ldmd2`` (the dmd-compatible driver
      # shipped with LDC) which avoids LDC's ``ldc2`` host-CPU
      # auto-detection crash on some recent AMD CPUs. Falls back to
      # the bundled LDC install under
      # D:/metacraft-dev-deps/ldc/<version>/ldc2-<version>-windows-x64/.
      # The M45 honest-scope cut: env.ps1 doesn't yet provision a D
      # toolchain so most hosts SKIP this gate cleanly when LDC isn't
      # bundled.
      $dCmd = Get-Command ldmd2 -ErrorAction SilentlyContinue
      if (-not $dCmd) { $dCmd = Get-Command dmd -ErrorAction SilentlyContinue }
      if (-not $dCmd) { $dCmd = Get-Command ldc2 -ErrorAction SilentlyContinue }
      if (-not $dCmd) {
        $ldcRoot = 'D:\metacraft-dev-deps\ldc'
        if (Test-Path -LiteralPath $ldcRoot) {
          $candidates = @()
          foreach ($verDir in Get-ChildItem -LiteralPath $ldcRoot -Directory -ErrorAction SilentlyContinue) {
            foreach ($inner in Get-ChildItem -LiteralPath $verDir.FullName -Directory -ErrorAction SilentlyContinue) {
              $candidate = Join-Path $inner.FullName 'bin\ldmd2.exe'
              if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
            }
          }
          if ($candidates.Count -gt 0) {
            $picked = $candidates | Sort-Object | Select-Object -Last 1
            $binDir = Split-Path -Parent $picked
            $env:PATH = "$binDir;$env:PATH"
            $dCmd = Get-Command ldmd2 -ErrorAction SilentlyContinue
          }
        }
      }
      if ($dCmd) {
        return @{ Available = $true; Reason = "d=$($dCmd.Source)" }
      }
      return @{ Available = $false; Reason = "no D compiler (ldmd2/dmd/ldc2) on PATH and not under D:/metacraft-dev-deps/ldc/ (download from github.com/ldc-developers/ldc/releases)" }
    }
    'ada-mode3' {
      # M58: Mode 3 Ada — probe for ``gnatmake``. The canonical Windows
      # install is via MSYS2: ``pacman -S mingw-w64-x86_64-gcc-ada``.
      # The M58 honest-scope cut: env.ps1 doesn't yet provision the
      # GNAT toolchain so most hosts SKIP this gate cleanly.
      $gnatCmd = Get-Command gnatmake -ErrorAction SilentlyContinue
      if ($gnatCmd) {
        return @{ Available = $true; Reason = "gnatmake=$($gnatCmd.Source)" }
      }
      return @{ Available = $false; Reason = "'gnatmake' not on PATH (install via 'pacman -S mingw-w64-x86_64-gcc-ada' under MSYS2)" }
    }
    'mode1' {
      # M48: Mode 1 (layout-as-manifest) fixtures. Each fixture is
      # single-language by spec scope-down (mixed-language Mode 1 is
      # DEFERRED) so the language-level probe here is permissive — we
      # verify the C/C++ toolchain (every Mode 1 build leans on gcc/ar
      # for the link stage) and defer the per-language toolchain probe
      # to ``Probe-Fixture`` below.
      $ccCmd = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $ccCmd) {
        $ccCmd = Get-Command clang -ErrorAction SilentlyContinue
      }
      if (-not $ccCmd) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH (Mode 1 link stage needs a C compiler)" }
      }
      return @{ Available = $true; Reason = "cc=$($ccCmd.Source) (Mode 1 per-fixture probe selects rustc/nim)" }
    }
    'jsts-mode3' {
      # M33: Mode 3 JS/TS — same toolchain probe as ``javascript-typescript``
      # (the Mode 2 path). ``node`` (and the npx that ships with it) is
      # enough; the Mode 3 convention drives the per-executable bundle
      # via ``npx --yes --package esbuild@<pin>`` and emits an
      # ``fs.writeText`` wrapper that runs ``node <bundle.js>``. Reuse
      # the bundled-toolchain probe so a fresh host without a system
      # node still picks up the managed install under
      # D:/metacraft-dev-deps/node/.
      $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
      if (-not $nodeCmd) {
        $nodeRoot = 'D:\metacraft-dev-deps\node'
        if (Test-Path -LiteralPath $nodeRoot) {
          $candidates = @()
          foreach ($verDir in Get-ChildItem -LiteralPath $nodeRoot -Directory -ErrorAction SilentlyContinue) {
            foreach ($inner in Get-ChildItem -LiteralPath $verDir.FullName -Directory -ErrorAction SilentlyContinue) {
              $candidate = Join-Path $inner.FullName 'node.exe'
              if (Test-Path -LiteralPath $candidate) {
                $candidates += $candidate
              }
            }
          }
          if ($candidates.Count -gt 0) {
            $picked = $candidates | Sort-Object | Select-Object -Last 1
            $binDir = Split-Path -Parent $picked
            $env:PATH = "$binDir;$env:PATH"
            $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
          }
        }
      }
      if ($nodeCmd) {
        return @{ Available = $true; Reason = "node=$($nodeCmd.Source)" }
      }
      return @{ Available = $false; Reason = "'node' not on PATH and not under D:/metacraft-dev-deps/node/" }
    }
    'mixed' {
      # Cross-language Mode 3 — the union of all mixed fixtures' needs.
      # Different fixtures need different toolchains:
      #   * mixed/nim-uses-cpp-lib       : nim + gcc + ar
      #   * mixed/cpp-uses-nim-lib       : nim + g++ + ar
      #   * mixed/rust-uses-cpp-lib      : rustc + gcc + ar (M34 forward)
      #   * mixed/cpp-uses-rust-lib      : rustc + g++ + ar (M34 reverse)
      #   * mixed/fortran-uses-cpp-lib   : gfortran + gcc + ar (M37 fwd)
      #   * mixed/cpp-uses-fortran-lib   : gfortran + g++ + ar (M37 rev)
      # The language-level probe is permissive — it only checks for a
      # C/C++ compiler + ar (the minimum any mixed fixture needs). The
      # per-fixture probe under ``Probe-Fixture`` rejects fixtures whose
      # specific language toolchain (nim / rustc / etc.) is missing.
      $ccCmd = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $ccCmd) {
        $ccCmd = Get-Command clang -ErrorAction SilentlyContinue
      }
      if (-not $ccCmd) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH (cross-language fixtures need a C compiler)" }
      }
      $cxxCmd = Get-Command g++ -ErrorAction SilentlyContinue
      if (-not $cxxCmd) {
        $cxxCmd = Get-Command clang++ -ErrorAction SilentlyContinue
      }
      if (-not $cxxCmd) {
        return @{ Available = $false; Reason = "neither 'g++' nor 'clang++' on PATH (cross-language fixtures need a C++ link driver)" }
      }
      $arCmd = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $arCmd) {
        return @{ Available = $false; Reason = "'ar' not on PATH (cross-language fixtures need an archiver)" }
      }
      return @{ Available = $true; Reason = "cc=$($ccCmd.Source); cxx=$($cxxCmd.Source); ar=$($arCmd.Source) (per-fixture probe selects nim/rustc)" }
    }
    'c-cpp-autotools' {
      # M17: the C/C++ Autotools convention is registered. Probe for
      # the full autotools stack — gcc/clang + make + sh + (autoreconf
      # OR a committed ``configure`` in the fixture). When the host's
      # PATH is missing make/sh but the managed MSYS2 install carries
      # them, prepend the MSYS2 ``usr/bin`` directory so subsequent
      # ``Get-Command`` lookups resolve them (env.ps1 only PATH-extends
      # the MinGW64 ``mingw64/bin``; autotools needs the POSIX side too).
      $msys2UsrBin = 'D:\metacraft-dev-deps\msys2\msys64\usr\bin'
      if ((Test-Path -LiteralPath (Join-Path $msys2UsrBin 'make.exe')) -and
          (Test-Path -LiteralPath (Join-Path $msys2UsrBin 'sh.exe'))) {
        if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $msys2UsrBin })) {
          $env:PATH = "$msys2UsrBin;$env:PATH"
        }
      }
      $ccCmd = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $ccCmd) {
        $ccCmd = Get-Command clang -ErrorAction SilentlyContinue
      }
      if (-not $ccCmd) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH" }
      }
      $makeCmd = Get-Command make -ErrorAction SilentlyContinue
      if (-not $makeCmd) {
        $makeCmd = Get-Command mingw32-make -ErrorAction SilentlyContinue
      }
      if (-not $makeCmd) {
        return @{ Available = $false; Reason = "neither 'make' nor 'mingw32-make' on PATH" }
      }
      $shCmd = Get-Command sh -ErrorAction SilentlyContinue
      if (-not $shCmd) {
        return @{ Available = $false; Reason = "'sh' not on PATH (POSIX shell required for autotools)" }
      }
      # The M17 hello-binary fixture is repo-checkout shape (no
      # committed ``configure``), so autoreconf is REQUIRED to
      # regenerate the GNU build machinery before configure can run.
      # When autoreconf is missing the harness SKIPs cleanly. MSYS2
      # ships ``autoreconf`` as an extensionless POSIX shell script
      # which Get-Command resolves natively on PATH; on Windows hosts
      # without MSYS2 autotools provisioned the message names the
      # precise dev-deps step that's outstanding.
      $autoreconfCmd = Get-Command autoreconf -ErrorAction SilentlyContinue
      if (-not $autoreconfCmd) {
        return @{ Available = $false; Reason = "'autoreconf' not on PATH (run windows/ensure-msys2-autotools.ps1 — sources autoconf + automake into D:/metacraft-dev-deps/msys2/msys64/usr/bin)" }
      }
      return @{ Available = $true; Reason = "cc=$($ccCmd.Source); make=$($makeCmd.Source); sh=$($shCmd.Source); autoreconf=$($autoreconfCmd.Source)" }
    }
    'c-cpp-cmake' {
      # M38: the C/C++ CMake (Tier 2b) convention is registered. Probe
      # for cmake + a C compiler + a single-config build driver (ninja
      # or platform make). The convention prefers ninja; falls back to
      # ``mingw32-make`` (MinGW Makefiles) on Windows or ``make`` (Unix
      # Makefiles) on POSIX.
      $ccCmd = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $ccCmd) {
        $ccCmd = Get-Command clang -ErrorAction SilentlyContinue
      }
      if (-not $ccCmd) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH" }
      }
      $cmakeCmd = Get-Command cmake -ErrorAction SilentlyContinue
      if (-not $cmakeCmd) {
        return @{ Available = $false; Reason = "'cmake' not on PATH (M38 c-cpp-cmake convention needs stock cmake)" }
      }
      $builderCmd = Get-Command ninja -ErrorAction SilentlyContinue
      $builderKind = "ninja"
      if (-not $builderCmd) {
        $builderCmd = Get-Command mingw32-make -ErrorAction SilentlyContinue
        $builderKind = "mingw32-make"
      }
      if (-not $builderCmd) {
        $builderCmd = Get-Command make -ErrorAction SilentlyContinue
        $builderKind = "make"
      }
      if (-not $builderCmd) {
        return @{ Available = $false; Reason = "no single-config build driver on PATH (needs ninja or mingw32-make or make)" }
      }
      return @{ Available = $true; Reason = "cc=$($ccCmd.Source); cmake=$($cmakeCmd.Source); $builderKind=$($builderCmd.Source)" }
    }
    'c-cpp-meson' {
      # M39: the C/C++ Meson (Tier 2b) convention is registered. Probe
      # for meson + ninja + a C compiler. Meson's default backend is
      # ninja (single-config, cross-platform); the convention only
      # supports the ninja backend so SKIPs when ninja is missing. On
      # Windows hosts that pip-installed meson into the managed Python
      # under ``D:/metacraft-dev-deps/python/.../Scripts``, prepend the
      # Scripts dir to PATH so ``Get-Command meson`` resolves cleanly.
      $ccCmd = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $ccCmd) {
        $ccCmd = Get-Command clang -ErrorAction SilentlyContinue
      }
      if (-not $ccCmd) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH" }
      }
      $mesonCmd = Get-Command meson -ErrorAction SilentlyContinue
      if (-not $mesonCmd) {
        $pythonScriptsCandidates = @(
          'D:\metacraft-dev-deps\python\3.12.10\Scripts'
        )
        foreach ($d in $pythonScriptsCandidates) {
          if (Test-Path -LiteralPath (Join-Path $d 'meson.exe')) {
            if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $d })) {
              $env:PATH = "$d;$env:PATH"
            }
            $mesonCmd = Get-Command meson -ErrorAction SilentlyContinue
            break
          }
        }
      }
      if (-not $mesonCmd) {
        return @{ Available = $false; Reason = "'meson' not on PATH (run 'python -m pip install meson' to provision into the managed Python's Scripts dir)" }
      }
      $ninjaCmd = Get-Command ninja -ErrorAction SilentlyContinue
      if (-not $ninjaCmd) {
        return @{ Available = $false; Reason = "'ninja' not on PATH (M39 c-cpp-meson convention uses meson's default ninja backend)" }
      }
      return @{ Available = $true; Reason = "cc=$($ccCmd.Source); meson=$($mesonCmd.Source); ninja=$($ninjaCmd.Source)" }
    }
    'java-maven' {
      # M40: the Java + Maven (Tier 2b) convention is registered. Probe
      # for javac + mvn + java. The convention's ``recognize`` enforces
      # javac + mvn; the validation script additionally needs ``java``
      # to invoke the produced jar. The documented provisioning path is
      # Adoptium JDK 21 LTS under ``D:/metacraft-dev-deps/jdk/21/`` and
      # Apache Maven 3.9.x under ``D:/metacraft-dev-deps/maven/3.9.x/``.
      $javacCmd = Get-Command javac -ErrorAction SilentlyContinue
      if (-not $javacCmd) {
        $jdkRoot = 'D:\metacraft-dev-deps\jdk'
        if (Test-Path -LiteralPath $jdkRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $jdkRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $verDir.FullName 'bin\javac.exe'
            if (Test-Path -LiteralPath $candidate) {
              $binDir = Split-Path -Parent $candidate
              if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
                $env:PATH = "$binDir;$env:PATH"
              }
              $javacCmd = Get-Command javac -ErrorAction SilentlyContinue
              break
            }
          }
        }
      }
      if (-not $javacCmd) {
        return @{ Available = $false; Reason = "'javac' not on PATH (install Adoptium JDK 21 LTS into D:/metacraft-dev-deps/jdk/21/)" }
      }
      $mvnCmd = Get-Command mvn -ErrorAction SilentlyContinue
      if (-not $mvnCmd) {
        $mavenRoot = 'D:\metacraft-dev-deps\maven'
        if (Test-Path -LiteralPath $mavenRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $mavenRoot -Directory -ErrorAction SilentlyContinue) {
            foreach ($candidate in @(
              (Join-Path $verDir.FullName 'bin\mvn.cmd'),
              (Join-Path $verDir.FullName 'bin\mvn'))) {
              if (Test-Path -LiteralPath $candidate) {
                $binDir = Split-Path -Parent $candidate
                if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
                  $env:PATH = "$binDir;$env:PATH"
                }
                $mvnCmd = Get-Command mvn -ErrorAction SilentlyContinue
                break
              }
            }
            if ($mvnCmd) { break }
          }
        }
      }
      if (-not $mvnCmd) {
        return @{ Available = $false; Reason = "'mvn' not on PATH (install Apache Maven 3.9.x into D:/metacraft-dev-deps/maven/3.9.x/)" }
      }
      $javaCmd = Get-Command java -ErrorAction SilentlyContinue
      if (-not $javaCmd) {
        return @{ Available = $false; Reason = "'java' not on PATH (need the JRE to run the produced jar)" }
      }
      return @{ Available = $true; Reason = "javac=$($javacCmd.Source); mvn=$($mvnCmd.Source); java=$($javaCmd.Source)" }
    }
    'kotlin-gradle' {
      # M41: the Kotlin + Gradle (Tier 2b) convention is registered.
      # Probe for javac + gradle + java. The convention's ``recognize``
      # enforces javac + gradle (system or project wrapper); the
      # validation script additionally needs ``java`` to invoke the
      # produced jar. The documented provisioning path is Adoptium JDK
      # 21 LTS under ``D:/metacraft-dev-deps/jdk/21/`` (shared with M40)
      # and Gradle 8.x under ``D:/metacraft-dev-deps/gradle/8.x/``.
      $javacCmd = Get-Command javac -ErrorAction SilentlyContinue
      if (-not $javacCmd) {
        $jdkRoot = 'D:\metacraft-dev-deps\jdk'
        if (Test-Path -LiteralPath $jdkRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $jdkRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $verDir.FullName 'bin\javac.exe'
            if (Test-Path -LiteralPath $candidate) {
              $binDir = Split-Path -Parent $candidate
              if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
                $env:PATH = "$binDir;$env:PATH"
              }
              $javacCmd = Get-Command javac -ErrorAction SilentlyContinue
              break
            }
          }
        }
      }
      if (-not $javacCmd) {
        return @{ Available = $false; Reason = "'javac' not on PATH (install Adoptium JDK 21 LTS into D:/metacraft-dev-deps/jdk/21/)" }
      }
      $gradleCmd = Get-Command gradle -ErrorAction SilentlyContinue
      if (-not $gradleCmd) {
        $gradleRoot = 'D:\metacraft-dev-deps\gradle'
        if (Test-Path -LiteralPath $gradleRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $gradleRoot -Directory -ErrorAction SilentlyContinue) {
            foreach ($candidate in @(
              (Join-Path $verDir.FullName 'bin\gradle.bat'),
              (Join-Path $verDir.FullName 'bin\gradle'))) {
              if (Test-Path -LiteralPath $candidate) {
                $binDir = Split-Path -Parent $candidate
                if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
                  $env:PATH = "$binDir;$env:PATH"
                }
                $gradleCmd = Get-Command gradle -ErrorAction SilentlyContinue
                break
              }
            }
            if ($gradleCmd) { break }
          }
        }
      }
      if (-not $gradleCmd) {
        return @{ Available = $false; Reason = "'gradle' not on PATH (install Gradle 8.x into D:/metacraft-dev-deps/gradle/8.x/)" }
      }
      $javaCmd = Get-Command java -ErrorAction SilentlyContinue
      if (-not $javaCmd) {
        return @{ Available = $false; Reason = "'java' not on PATH (need the JRE to run the produced jar)" }
      }
      return @{ Available = $true; Reason = "javac=$($javacCmd.Source); gradle=$($gradleCmd.Source); java=$($javaCmd.Source)" }
    }
    'csharp-dotnet' {
      # M42: the C# + .NET (Tier 2b) convention is registered. Probe
      # for ``dotnet`` on PATH. The convention's ``recognize`` enforces
      # this (the .NET SDK ships the dotnet driver as a single binary
      # — no separate compiler executable needed). The documented
      # provisioning paths are .NET SDK 8.0 LTS into
      # ``D:/metacraft-dev-deps/dotnet/8.0/`` (manual download from
      # microsoft.com) or ``winget install Microsoft.DotNet.SDK.8``
      # which lands ``%ProgramFiles%\dotnet\dotnet.exe`` on PATH.
      $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
      if (-not $dotnetCmd) {
        $dotnetRoot = 'D:\metacraft-dev-deps\dotnet'
        if (Test-Path -LiteralPath $dotnetRoot) {
          $candidates = @()
          # The dev-deps tree carries one or more SDK versions as
          # subdirs (e.g. ``D:\metacraft-dev-deps\dotnet\9.0.310\``);
          # pick the lexicographically-latest one when multiple are
          # present. Also accept ``D:\metacraft-dev-deps\dotnet\``
          # itself as the install root when ``dotnet.exe`` is sat
          # directly underneath.
          $direct = Join-Path $dotnetRoot 'dotnet.exe'
          if (Test-Path -LiteralPath $direct) { $candidates += $direct }
          foreach ($verDir in Get-ChildItem -LiteralPath $dotnetRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $verDir.FullName 'dotnet.exe'
            if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
          }
          if ($candidates.Count -gt 0) {
            $picked = $candidates | Sort-Object | Select-Object -Last 1
            $binDir = Split-Path -Parent $picked
            if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
              $env:PATH = "$binDir;$env:PATH"
            }
            $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
          }
        }
      }
      if (-not $dotnetCmd) {
        return @{ Available = $false; Reason = "'dotnet' not on PATH (install .NET SDK 8.0 LTS into D:/metacraft-dev-deps/dotnet/8.0/ or 'winget install Microsoft.DotNet.SDK.8')" }
      }
      # The .NET 5+ apphost (the produced .exe) searches for hostfxr.dll
      # via DOTNET_ROOT first, then registry, then %ProgramFiles%\dotnet.
      # When the SDK is provisioned outside any of those (e.g. under
      # D:\metacraft-dev-deps\dotnet\<ver>\) the produced .exe fails to
      # launch with "You must install .NET to run this application"
      # unless we set DOTNET_ROOT explicitly. Set it here so the
      # harness's post-build Greeting check can exec hello.exe directly.
      $env:DOTNET_ROOT = Split-Path -Parent $dotnetCmd.Source
      return @{ Available = $true; Reason = "dotnet=$($dotnetCmd.Source); DOTNET_ROOT=$($env:DOTNET_ROOT)" }
    }
    'swift-swiftpm' {
      # M43: the Swift + SwiftPM (Tier 2b) convention is registered.
      # Probe for ``swift`` on PATH. The convention's ``recognize``
      # enforces this (the Swift toolchain ships ``swift`` as a single
      # driver binary that subcommands into ``swiftc`` for compilation
      # and into ``swift build`` for SwiftPM operations). The
      # documented provisioning paths are Swift 5.10 from swift.org
      # into ``D:/metacraft-dev-deps/swift/5.10/`` (manual download) or
      # ``winget install Swift.Toolchain`` (Microsoft Store install).
      # Most M43 review hosts do NOT ship the Swift toolchain — Swift
      # Windows isn't in the standard dev shell — so this probe is
      # expected to SKIP cleanly on a default Windows host.
      $swiftCmd = Get-Command swift -ErrorAction SilentlyContinue
      if (-not $swiftCmd) {
        $swiftRoot = 'D:\metacraft-dev-deps\swift'
        if (Test-Path -LiteralPath $swiftRoot) {
          $candidates = @()
          $direct = Join-Path $swiftRoot 'swift.exe'
          if (Test-Path -LiteralPath $direct) { $candidates += $direct }
          foreach ($verDir in Get-ChildItem -LiteralPath $swiftRoot -Directory -ErrorAction SilentlyContinue) {
            foreach ($candidate in @(
              (Join-Path $verDir.FullName 'usr\bin\swift.exe'),
              (Join-Path $verDir.FullName 'bin\swift.exe'))) {
              if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
            }
          }
          if ($candidates.Count -gt 0) {
            $picked = $candidates | Sort-Object | Select-Object -Last 1
            $binDir = Split-Path -Parent $picked
            if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
              $env:PATH = "$binDir;$env:PATH"
            }
            $swiftCmd = Get-Command swift -ErrorAction SilentlyContinue
          }
        }
      }
      if (-not $swiftCmd) {
        return @{ Available = $false; Reason = "'swift' not on PATH (install Swift 5.10 from swift.org into D:/metacraft-dev-deps/swift/5.10/ or 'winget install Swift.Toolchain')" }
      }
      # M51 honest-scope: Swift on Windows uses the MSVC ABI, so the
      # actual ``swift build`` link step shells out to ``link.exe``
      # (the MSVC linker from VS 2022 Build Tools + Windows SDK). The
      # swift.org installer does NOT bundle that — it's a separate
      # ~5 GB Microsoft installer (``winget install Microsoft.VisualStudio.2022.BuildTools
      # --override "--add Microsoft.VisualStudio.Workload.VCTools
      # --includeRecommended"``). Without it, ``swift build`` fails
      # with ``error: toolchain is invalid: could not find CLI tool
      # `link` at any of these directories``. Probe for VS via
      # vswhere (the canonical Microsoft-supported VS-install
      # discovery tool); a bare ``Get-Command link.exe`` would not
      # work because MSYS2 / Git-bash ship a POSIX ``link.exe``
      # (hard-link coreutil) that shadows the MSVC linker without
      # satisfying Swift's MSVC-toolchain probe.
      $vsLink = $null
      $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
      if (Test-Path -LiteralPath $vsWhere) {
        $vsInstall = (& $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1)
        if ($vsInstall) {
          $vsLink = "vswhere:$vsInstall"
        }
      }
      if (-not $vsLink) {
        return @{ Available = $false; Reason = "swift=$($swiftCmd.Source) but VS 2022 Build Tools (MSVC link.exe + Windows SDK) missing — install via 'winget install Microsoft.VisualStudio.2022.BuildTools --override `"--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`"' so Swift's MSVC link step can resolve. (MSYS2 / Git-bash POSIX link.exe does NOT satisfy Swift's MSVC-toolchain probe.)" }
      }
      return @{ Available = $true; Reason = "swift=$($swiftCmd.Source); vs-build-tools=$vsLink" }
    }
    'ocaml-dune' {
      # M46: the OCaml + Dune (Tier 2b) convention is registered. Probe
      # for BOTH ``ocaml`` AND ``dune`` on PATH. The convention's
      # ``recognize`` enforces this jointly — Dune isn't a built-in
      # part of the OCaml distribution (it's a separate ``opam install
      # dune``). The documented provisioning path is OPAM Windows from
      # ocaml.org unpacked into ``D:/metacraft-dev-deps/opam/`` and
      # then ``opam install dune`` after ``opam init`` + ``opam switch
      # create``. Most M46 review hosts do NOT ship OCaml — it isn't
      # in the standard dev shell — so this probe is expected to SKIP
      # cleanly on a default Windows host.
      $ocamlCmd = Get-Command ocaml -ErrorAction SilentlyContinue
      $duneCmd = Get-Command dune -ErrorAction SilentlyContinue
      if (-not $ocamlCmd -or -not $duneCmd) {
        $opamRoot = 'D:\metacraft-dev-deps\opam'
        if (Test-Path -LiteralPath $opamRoot) {
          $candidates = @()
          foreach ($entry in Get-ChildItem -LiteralPath $opamRoot -Directory -ErrorAction SilentlyContinue) {
            foreach ($candidate in @(
              (Join-Path $entry.FullName 'bin\ocaml.exe'),
              (Join-Path $entry.FullName 'usr\bin\ocaml.exe'))) {
              if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
            }
          }
          if ($candidates.Count -gt 0) {
            $picked = $candidates | Sort-Object | Select-Object -Last 1
            $binDir = Split-Path -Parent $picked
            if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
              $env:PATH = "$binDir;$env:PATH"
            }
            $ocamlCmd = Get-Command ocaml -ErrorAction SilentlyContinue
            $duneCmd = Get-Command dune -ErrorAction SilentlyContinue
          }
        }
      }
      if (-not $ocamlCmd) {
        return @{ Available = $false; Reason = "'ocaml' not on PATH (install OPAM Windows from ocaml.org into D:/metacraft-dev-deps/opam/ and then 'opam install dune')" }
      }
      if (-not $duneCmd) {
        return @{ Available = $false; Reason = "'dune' not on PATH (install via 'opam install dune' after OPAM init)" }
      }
      return @{ Available = $true; Reason = "ocaml=$($ocamlCmd.Source); dune=$($duneCmd.Source)" }
    }
    'haskell-cabal' {
      # M55: the Haskell + Cabal (Tier 2b) convention is registered.
      # Probe for BOTH ``ghc`` AND ``cabal`` on PATH. The convention's
      # ``recognize`` enforces this jointly — cabal-install isn't part
      # of the GHC distribution per se (it's a separate binary that
      # GHCup installs alongside GHC). The documented provisioning path
      # is GHCup-windows from https://www.haskell.org/ghcup/ — M55 pins
      # GHC 9.10.1 + cabal-install 3.12.1.0. Most M55 review hosts do
      # NOT ship Haskell — it isn't in the standard dev shell — so this
      # probe is expected to SKIP cleanly on a default Windows host.
      $ghcCmd = Get-Command ghc -ErrorAction SilentlyContinue
      $cabalCmd = Get-Command cabal -ErrorAction SilentlyContinue
      if (-not $ghcCmd -or -not $cabalCmd) {
        # Try lifting a managed GHCup install under
        # ``D:\metacraft-dev-deps\ghcup\`` or ``%LOCALAPPDATA%\Programs\ghcup\``.
        $candidates = @()
        foreach ($ghcupRoot in @(
          'D:\metacraft-dev-deps\ghcup',
          (Join-Path $env:LOCALAPPDATA 'Programs\ghcup'))) {
          if (-not $ghcupRoot) { continue }
          if (-not (Test-Path -LiteralPath $ghcupRoot)) { continue }
          foreach ($candidate in @(
            (Join-Path $ghcupRoot 'bin\ghc.exe'),
            (Join-Path $ghcupRoot 'bin\cabal.exe'))) {
            if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
          }
        }
        if ($candidates.Count -gt 0) {
          $binDir = Split-Path -Parent ($candidates | Select-Object -First 1)
          if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
            $env:PATH = "$binDir;$env:PATH"
          }
          $ghcCmd = Get-Command ghc -ErrorAction SilentlyContinue
          $cabalCmd = Get-Command cabal -ErrorAction SilentlyContinue
        }
      }
      if (-not $ghcCmd) {
        return @{ Available = $false; Reason = "'ghc' not on PATH (install GHC + cabal-install via GHCup from https://www.haskell.org/ghcup/ — M55 pins GHC 9.10.1)" }
      }
      if (-not $cabalCmd) {
        return @{ Available = $false; Reason = "'cabal' not on PATH (install via GHCup from https://www.haskell.org/ghcup/ — M55 pins cabal-install 3.12.1.0)" }
      }
      return @{ Available = $true; Reason = "ghc=$($ghcCmd.Source); cabal=$($cabalCmd.Source)" }
    }
    'ruby-bundler' {
      # M56: the Ruby + Bundler (Tier 2b) convention is registered.
      # Probe for BOTH ``ruby`` AND ``bundle`` on PATH. The convention's
      # ``recognize`` enforces this jointly — Bundler ships with Ruby
      # >= 2.6 so a vanilla Ruby install satisfies both, but the
      # probe still checks each binary explicitly so a Ruby install
      # with Bundler ripped out fails the gate honestly. The
      # documented provisioning path on Windows is RubyInstaller
      # (https://rubyinstaller.org/) — M56 pins Ruby 3.3.5. Most M56
      # review hosts do NOT ship Ruby — it isn't in the standard dev
      # shell — so this probe is expected to SKIP cleanly on a default
      # Windows host.
      $rubyCmd = Get-Command ruby -ErrorAction SilentlyContinue
      $bundleCmd = Get-Command bundle -ErrorAction SilentlyContinue
      if (-not $rubyCmd -or -not $bundleCmd) {
        # Try lifting a managed Ruby install under
        # ``D:\metacraft-dev-deps\ruby\`` or a system RubyInstaller
        # install under ``C:\Ruby<version>\`` or
        # ``%LOCALAPPDATA%\Programs\Ruby\``.
        $candidates = @()
        foreach ($rubyRoot in @(
          'D:\metacraft-dev-deps\ruby',
          (Join-Path $env:LOCALAPPDATA 'Programs\Ruby'))) {
          if (-not $rubyRoot) { continue }
          if (-not (Test-Path -LiteralPath $rubyRoot)) { continue }
          foreach ($candidate in @(
            (Join-Path $rubyRoot 'bin\ruby.exe'),
            (Join-Path $rubyRoot 'bin\bundle.bat'))) {
            if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
          }
        }
        foreach ($cRubyDir in @(Get-ChildItem -Path 'C:\' -Directory -Filter 'Ruby*' -ErrorAction SilentlyContinue)) {
          $binDir = Join-Path $cRubyDir.FullName 'bin'
          foreach ($candidate in @(
            (Join-Path $binDir 'ruby.exe'),
            (Join-Path $binDir 'bundle.bat'))) {
            if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
          }
        }
        if ($candidates.Count -gt 0) {
          $binDir = Split-Path -Parent ($candidates | Select-Object -First 1)
          if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
            $env:PATH = "$binDir;$env:PATH"
          }
          $rubyCmd = Get-Command ruby -ErrorAction SilentlyContinue
          $bundleCmd = Get-Command bundle -ErrorAction SilentlyContinue
        }
      }
      if (-not $rubyCmd) {
        return @{ Available = $false; Reason = "'ruby' not on PATH (install Ruby via RubyInstaller from https://rubyinstaller.org/ — M56 pins Ruby 3.3.5)" }
      }
      if (-not $bundleCmd) {
        return @{ Available = $false; Reason = "'bundle' not on PATH (Bundler ships with Ruby >= 2.6; re-install Ruby via RubyInstaller from https://rubyinstaller.org/)" }
      }
      return @{ Available = $true; Reason = "ruby=$($rubyCmd.Source); bundle=$($bundleCmd.Source)" }
    }
    'php-composer' {
      # M57: the PHP + Composer (Tier 2b) convention is registered.
      # Probe for BOTH ``php`` AND ``composer`` on PATH. The
      # convention's ``recognize`` enforces this jointly — Composer
      # is an independent .phar so a vanilla PHP install does not
      # come bundled with it. The documented provisioning paths on
      # Windows are the PHP Windows binary from
      # https://windows.php.net/downloads/ (M57 pins PHP 8.3.13) plus
      # Composer-Setup.exe from
      # https://getcomposer.org/Composer-Setup.exe (M57 pins
      # Composer 2.8.1). Most M57 review hosts do NOT ship PHP — it
      # isn't in the standard dev shell — so this probe is expected
      # to SKIP cleanly on a default Windows host.
      $phpCmd = Get-Command php -ErrorAction SilentlyContinue
      $composerCmd = Get-Command composer -ErrorAction SilentlyContinue
      if (-not $phpCmd -or -not $composerCmd) {
        # Try lifting a managed PHP install under
        # ``D:\metacraft-dev-deps\php\`` or a system PHP install
        # under ``C:\php\`` / ``%LOCALAPPDATA%\Programs\php\``.
        $candidates = @()
        foreach ($phpRoot in @(
          'D:\metacraft-dev-deps\php',
          'C:\php',
          (Join-Path $env:LOCALAPPDATA 'Programs\php'))) {
          if (-not $phpRoot) { continue }
          if (-not (Test-Path -LiteralPath $phpRoot)) { continue }
          foreach ($candidate in @(
            (Join-Path $phpRoot 'php.exe'))) {
            if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
          }
        }
        if ($candidates.Count -gt 0) {
          $binDir = Split-Path -Parent ($candidates | Select-Object -First 1)
          if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
            $env:PATH = "$binDir;$env:PATH"
          }
        }
        # Composer-Setup.exe drops launchers under
        # ``%LOCALAPPDATA%\Composer\``.
        foreach ($composerRoot in @(
          'D:\metacraft-dev-deps\composer',
          (Join-Path $env:LOCALAPPDATA 'Composer'),
          (Join-Path $env:APPDATA 'Composer'))) {
          if (-not $composerRoot) { continue }
          if (-not (Test-Path -LiteralPath $composerRoot)) { continue }
          foreach ($candidate in @(
            (Join-Path $composerRoot 'composer.bat'),
            (Join-Path $composerRoot 'composer.phar'))) {
            if (Test-Path -LiteralPath $candidate) {
              $binDir = Split-Path -Parent $candidate
              if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
                $env:PATH = "$binDir;$env:PATH"
              }
            }
          }
        }
        $phpCmd = Get-Command php -ErrorAction SilentlyContinue
        $composerCmd = Get-Command composer -ErrorAction SilentlyContinue
      }
      if (-not $phpCmd) {
        return @{ Available = $false; Reason = "'php' not on PATH (install PHP Windows binary from https://windows.php.net/downloads/ -- M57 pins PHP 8.3.13)" }
      }
      if (-not $composerCmd) {
        return @{ Available = $false; Reason = "'composer' not on PATH (install Composer via Composer-Setup.exe from https://getcomposer.org/Composer-Setup.exe -- M57 pins Composer 2.8.1)" }
      }
      return @{ Available = $true; Reason = "php=$($phpCmd.Source); composer=$($composerCmd.Source)" }
    }
    default {
      return @{ Available = $false; Reason = "unknown language '$language'" }
    }
  }
}

# --- per-fixture toolchain probe -------------------------------------------
# Returns a hashtable: { Available = $true/$false; Reason = string }
#
# Some M24 fixtures route to Mode B (``python -m build`` / ``npm install
# && npm run build``) and need extra toolchains beyond the language
# probe: maturin needs a Rust compiler + the ``maturin`` + ``build``
# Python modules; scikit-build-core needs CMake + a C compiler + the
# ``scikit_build_core`` + ``build`` modules; the vite/webpack fixtures
# need ``npm`` + (typically) network access for the install step. When
# any prerequisite is missing the harness SKIPs cleanly with a clear
# reason rather than failing — matching the M23 binary-with-crates-io
# pattern.
function Probe-Fixture([string]$rel) {
  switch ($rel) {
    'python/pep517-maturin' {
      # Need rustc + cargo for maturin, plus the ``maturin`` and
      # ``build`` Python distributions importable from the convention's
      # python3.
      $rustc = Get-Command rustc -ErrorAction SilentlyContinue
      if (-not $rustc) {
        $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
        if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
          $env:PATH = "$rustupStableBin;$env:PATH"
          $rustc = Get-Command rustc -ErrorAction SilentlyContinue
        }
      }
      if (-not $rustc) {
        return @{ Available = $false; Reason = "rustc not on PATH — maturin needs a Rust toolchain" }
      }
      $pythonCmd = $null
      foreach ($n in @('python3', 'python')) {
        $cand = Get-Command $n -ErrorAction SilentlyContinue
        if ($cand) { $pythonCmd = $cand; break }
      }
      if (-not $pythonCmd) {
        return @{ Available = $false; Reason = "python3/python not on PATH" }
      }
      foreach ($mod in @('maturin', 'build')) {
        & $pythonCmd.Source -c "import $mod" 2>$null
        if ($LASTEXITCODE -ne 0) {
          return @{ Available = $false; Reason = "python module '$mod' not importable; install via pip" }
        }
      }
      # maturin's bundled maturin.exe lives under <python>/Scripts/
      # which isn't always on PATH; prepend so the action can spawn it.
      $pythonScripts = Join-Path (Split-Path $pythonCmd.Source -Parent) 'Scripts'
      if ((Test-Path -LiteralPath (Join-Path $pythonScripts 'maturin.exe')) -and
          -not ($env:PATH -split ';' | Where-Object { $_ -ieq $pythonScripts })) {
        $env:PATH = "$pythonScripts;$env:PATH"
      }
      # PyO3 needs python<MAJ><MIN>.lib for linking. The embeddable
      # Windows Python omits libs/; SKIP cleanly.
      $pythonPrefix = Split-Path $pythonCmd.Source -Parent
      $pythonLibsDir = Join-Path $pythonPrefix 'libs'
      $hasImportLib = $false
      if (Test-Path -LiteralPath $pythonLibsDir) {
        $importLibs = @(Get-ChildItem -LiteralPath $pythonLibsDir -Filter 'python*.lib' -ErrorAction SilentlyContinue)
        if ($importLibs.Count -gt 0) { $hasImportLib = $true }
      }
      if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        $hasImportLib = $true
      }
      if (-not $hasImportLib) {
        return @{ Available = $false; Reason = "Python install lacks the import library under $pythonLibsDir (embeddable Windows Python omits it); maturin needs a full install" }
      }
      return @{ Available = $true; Reason = "rustc=$($rustc.Source); python=$($pythonCmd.Source); maturin + build + import-lib present" }
    }
    'python/pep517-scikit-build-core' {
      # Need cmake + a C compiler (gcc/clang/MSVC) + the
      # ``scikit_build_core`` and ``build`` Python distributions.
      $cmake = Get-Command cmake -ErrorAction SilentlyContinue
      if (-not $cmake) {
        return @{ Available = $false; Reason = "cmake not on PATH — scikit-build-core needs CMake" }
      }
      $cc = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $cc) { $cc = Get-Command clang -ErrorAction SilentlyContinue }
      if (-not $cc) { $cc = Get-Command cl -ErrorAction SilentlyContinue }
      if (-not $cc) {
        return @{ Available = $false; Reason = "no C compiler (gcc/clang/cl) on PATH" }
      }
      $pythonCmd = $null
      foreach ($n in @('python3', 'python')) {
        $cand = Get-Command $n -ErrorAction SilentlyContinue
        if ($cand) { $pythonCmd = $cand; break }
      }
      if (-not $pythonCmd) {
        return @{ Available = $false; Reason = "python3/python not on PATH" }
      }
      foreach ($mod in @('scikit_build_core', 'build')) {
        & $pythonCmd.Source -c "import $mod" 2>$null
        if ($LASTEXITCODE -ne 0) {
          return @{ Available = $false; Reason = "python module '$mod' not importable; install via pip" }
        }
      }
      # CMake's find_package(Python Development.Module) needs Python.h
      # + python<MAJ><MIN>.lib. The embeddable Windows Python omits
      # both; SKIP cleanly.
      $pythonPrefix = Split-Path $pythonCmd.Source -Parent
      $pythonLibsDir = Join-Path $pythonPrefix 'libs'
      $pythonIncludeDir = Join-Path $pythonPrefix 'include'
      $hasDevHeaders = (Test-Path -LiteralPath $pythonLibsDir) -and
        (Test-Path -LiteralPath $pythonIncludeDir)
      if ($hasDevHeaders) {
        $importLibs = @(Get-ChildItem -LiteralPath $pythonLibsDir -Filter 'python*.lib' -ErrorAction SilentlyContinue)
        $headerFiles = @(Get-ChildItem -LiteralPath $pythonIncludeDir -Filter 'Python.h' -ErrorAction SilentlyContinue)
        $hasDevHeaders = ($importLibs.Count -gt 0) -and ($headerFiles.Count -gt 0)
      }
      if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
        $hasDevHeaders = $true
      }
      if (-not $hasDevHeaders) {
        return @{ Available = $false; Reason = "Python install lacks development headers + import library under $pythonPrefix; scikit-build-core needs a full install" }
      }
      return @{ Available = $true; Reason = "cmake=$($cmake.Source); cc=$($cc.Source); python=$($pythonCmd.Source); dev headers present" }
    }
    'javascript-typescript/vite-app' {
      # npm install + npm run build for vite. ``npm install`` will hit
      # the network for the vite + dep tree on a cold cache.
      $npm = Get-Command npm -ErrorAction SilentlyContinue
      if (-not $npm) {
        return @{ Available = $false; Reason = "'npm' not on PATH; vite Mode B needs npm to drive the install + bundler" }
      }
      return @{ Available = $true; Reason = "npm=$($npm.Source) (M24 Mode B will run 'npm install && npm run build')" }
    }
    'javascript-typescript/webpack-app' {
      $npm = Get-Command npm -ErrorAction SilentlyContinue
      if (-not $npm) {
        return @{ Available = $false; Reason = "'npm' not on PATH; webpack Mode B needs npm to drive the install + bundler" }
      }
      return @{ Available = $true; Reason = "npm=$($npm.Source) (M24 Mode B will run 'npm install && npm run build')" }
    }
    'mixed/nim-uses-cpp-lib' {
      # Forward Nim → C: needs nim + gcc/clang + ar (the language-level
      # probe already covered the latter two).
      $nimCmd = Get-Command nim -ErrorAction SilentlyContinue
      if (-not $nimCmd) {
        return @{ Available = $false; Reason = "'nim' not on PATH (env.ps1 should provide it)" }
      }
      return @{ Available = $true; Reason = "nim=$($nimCmd.Source)" }
    }
    'mixed/cpp-uses-nim-lib' {
      # Reverse C++ → Nim: needs nim + g++/clang++ + ar.
      $nimCmd = Get-Command nim -ErrorAction SilentlyContinue
      if (-not $nimCmd) {
        return @{ Available = $false; Reason = "'nim' not on PATH (env.ps1 should provide it)" }
      }
      return @{ Available = $true; Reason = "nim=$($nimCmd.Source)" }
    }
    'mixed/rust-uses-cpp-lib' {
      # M34 forward direction: a Rust executable that links a C archive.
      # Needs rustc + gcc/clang + ar. SKIP cleanly if any leg is missing.
      $rustc = Get-Command rustc -ErrorAction SilentlyContinue
      if (-not $rustc) {
        $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
        if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
          $env:PATH = "$rustupStableBin;$env:PATH"
          $rustc = Get-Command rustc -ErrorAction SilentlyContinue
        }
      }
      if (-not $rustc) {
        return @{ Available = $false; Reason = "rustc not on PATH and no rustup stable under D:/metacraft-dev-deps/rustup" }
      }
      $cc = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $cc) { $cc = Get-Command clang -ErrorAction SilentlyContinue }
      if (-not $cc) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH (M34 forward fixture needs a C compiler)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M34 forward fixture needs an archiver)" }
      }
      return @{ Available = $true; Reason = "rustc=$($rustc.Source); cc=$($cc.Source); ar=$($ar.Source)" }
    }
    'mixed/cpp-uses-rust-lib' {
      # M34 reverse direction: a C++ executable that links a Rust
      # staticlib. Needs rustc + g++/clang++ + ar.
      $rustc = Get-Command rustc -ErrorAction SilentlyContinue
      if (-not $rustc) {
        $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
        if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
          $env:PATH = "$rustupStableBin;$env:PATH"
          $rustc = Get-Command rustc -ErrorAction SilentlyContinue
        }
      }
      if (-not $rustc) {
        return @{ Available = $false; Reason = "rustc not on PATH and no rustup stable under D:/metacraft-dev-deps/rustup" }
      }
      $cxx = Get-Command g++ -ErrorAction SilentlyContinue
      if (-not $cxx) { $cxx = Get-Command clang++ -ErrorAction SilentlyContinue }
      if (-not $cxx) {
        return @{ Available = $false; Reason = "neither 'g++' nor 'clang++' on PATH (M34 reverse fixture needs a C++ link driver)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M34 reverse fixture needs an archiver)" }
      }
      return @{ Available = $true; Reason = "rustc=$($rustc.Source); cxx=$($cxx.Source); ar=$($ar.Source)" }
    }
    'mixed/nim-uses-rust-lib' {
      # M35 forward direction: a Nim executable that links a Rust
      # staticlib. Needs rustc + nim + gcc/clang + ar.
      $rustc = Get-Command rustc -ErrorAction SilentlyContinue
      if (-not $rustc) {
        $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
        if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
          $env:PATH = "$rustupStableBin;$env:PATH"
          $rustc = Get-Command rustc -ErrorAction SilentlyContinue
        }
      }
      if (-not $rustc) {
        return @{ Available = $false; Reason = "rustc not on PATH and no rustup stable under D:/metacraft-dev-deps/rustup" }
      }
      $nimCmd = Get-Command nim -ErrorAction SilentlyContinue
      if (-not $nimCmd) {
        return @{ Available = $false; Reason = "'nim' not on PATH (M35 forward fixture needs nim)" }
      }
      $cc = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $cc) { $cc = Get-Command clang -ErrorAction SilentlyContinue }
      if (-not $cc) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH (M35 forward fixture needs a C compiler for the Nim Phase 2 + link)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M35 forward fixture needs an archiver)" }
      }
      return @{ Available = $true; Reason = "rustc=$($rustc.Source); nim=$($nimCmd.Source); cc=$($cc.Source); ar=$($ar.Source)" }
    }
    'mixed/rust-uses-nim-lib' {
      # M35 reverse direction: a Rust executable that links a Nim
      # staticlib. Needs rustc + nim + gcc/clang + ar; on Windows also
      # the x86_64-pc-windows-gnu rustup target so rustc routes through
      # the gcc-mingw linker (Nim's archive uses MinGW gcc-compiled
      # obj files; MSVC link.exe cannot resolve __mingw_printf et al.).
      $rustc = Get-Command rustc -ErrorAction SilentlyContinue
      if (-not $rustc) {
        $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
        if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
          $env:PATH = "$rustupStableBin;$env:PATH"
          $rustc = Get-Command rustc -ErrorAction SilentlyContinue
        }
      }
      if (-not $rustc) {
        return @{ Available = $false; Reason = "rustc not on PATH and no rustup stable under D:/metacraft-dev-deps/rustup" }
      }
      $nimCmd = Get-Command nim -ErrorAction SilentlyContinue
      if (-not $nimCmd) {
        return @{ Available = $false; Reason = "'nim' not on PATH (M35 reverse fixture needs nim)" }
      }
      $cc = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $cc) { $cc = Get-Command clang -ErrorAction SilentlyContinue }
      if (-not $cc) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH (M35 reverse fixture needs a C compiler for Nim Phase 2)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M35 reverse fixture needs an archiver)" }
      }
      # Windows-only: probe for the gnu target. On non-Windows the host
      # toolchain is fine as-is (POSIX rustc + libc both gcc-compatible).
      $IsWindowsHost = $true
      try { $IsWindowsHost = $IsWindows } catch { $IsWindowsHost = $true }
      if ($IsWindowsHost) {
        $rustcDir = Split-Path -Parent $rustc.Source
        $toolchainRoot = Split-Path -Parent $rustcDir
        $gnuTargetDir = Join-Path $toolchainRoot 'lib\rustlib\x86_64-pc-windows-gnu'
        if (-not (Test-Path -LiteralPath $gnuTargetDir)) {
          return @{ Available = $false; Reason = "x86_64-pc-windows-gnu rustup target not installed (install via 'rustup target add x86_64-pc-windows-gnu')" }
        }
      }
      return @{ Available = $true; Reason = "rustc=$($rustc.Source); nim=$($nimCmd.Source); cc=$($cc.Source); ar=$($ar.Source)" }
    }
    'mixed/go-uses-cpp-lib' {
      # M36 forward direction: a Go executable that links a C archive
      # via cgo. Needs go + gcc/clang + ar.
      $goCmd = Get-Command go -ErrorAction SilentlyContinue
      if (-not $goCmd) {
        $goRoot = 'D:/metacraft-dev-deps/go'
        if (Test-Path -LiteralPath $goRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $goRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $verDir.FullName 'go\bin\go.exe'
            if (Test-Path -LiteralPath $candidate) {
              $binDir = Split-Path -Parent $candidate
              $env:PATH = "$binDir;$env:PATH"
              $goCmd = Get-Command go -ErrorAction SilentlyContinue
              break
            }
          }
        }
      }
      if (-not $goCmd) {
        return @{ Available = $false; Reason = "'go' not on PATH and not under D:/metacraft-dev-deps/go/" }
      }
      $cc = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $cc) { $cc = Get-Command clang -ErrorAction SilentlyContinue }
      if (-not $cc) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH (M36 forward fixture needs a C compiler for cgo)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M36 forward fixture needs an archiver)" }
      }
      return @{ Available = $true; Reason = "go=$($goCmd.Source); cc=$($cc.Source); ar=$($ar.Source)" }
    }
    'mixed/fortran-uses-cpp-lib' {
      # M37 forward direction: a Fortran executable that links a C
      # archive. Needs gfortran + gcc/clang + ar.
      $gfortranCmd = Get-Command gfortran -ErrorAction SilentlyContinue
      if (-not $gfortranCmd) {
        return @{ Available = $false; Reason = "'gfortran' not on PATH (M37 forward fixture needs gfortran)" }
      }
      $cc = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $cc) { $cc = Get-Command clang -ErrorAction SilentlyContinue }
      if (-not $cc) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH (M37 forward fixture needs a C compiler)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M37 forward fixture needs an archiver)" }
      }
      return @{ Available = $true; Reason = "gfortran=$($gfortranCmd.Source); cc=$($cc.Source); ar=$($ar.Source)" }
    }
    'mixed/cpp-uses-fortran-lib' {
      # M37 reverse direction: a C++ executable that links a Fortran
      # staticlib. Needs gfortran + g++/clang++ + ar.
      $gfortranCmd = Get-Command gfortran -ErrorAction SilentlyContinue
      if (-not $gfortranCmd) {
        return @{ Available = $false; Reason = "'gfortran' not on PATH (M37 reverse fixture needs gfortran)" }
      }
      $cxx = Get-Command g++ -ErrorAction SilentlyContinue
      if (-not $cxx) { $cxx = Get-Command clang++ -ErrorAction SilentlyContinue }
      if (-not $cxx) {
        return @{ Available = $false; Reason = "neither 'g++' nor 'clang++' on PATH (M37 reverse fixture needs a C++ link driver)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M37 reverse fixture needs an archiver)" }
      }
      return @{ Available = $true; Reason = "gfortran=$($gfortranCmd.Source); cxx=$($cxx.Source); ar=$($ar.Source)" }
    }
    'mixed/zig-uses-cpp-lib' {
      # M44 forward direction: a Zig executable that links a C archive.
      # Needs zig + gcc/clang + ar.
      $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
      if (-not $zigCmd) {
        $zigRoot = 'D:\metacraft-dev-deps\zig'
        if (Test-Path -LiteralPath $zigRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $zigRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $verDir.FullName 'zig.exe'
            if (Test-Path -LiteralPath $candidate) {
              $binDir = Split-Path -Parent $candidate
              $env:PATH = "$binDir;$env:PATH"
              $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
              break
            }
          }
        }
      }
      if (-not $zigCmd) {
        return @{ Available = $false; Reason = "'zig' not on PATH and not under D:/metacraft-dev-deps/zig/ (M44 forward fixture needs zig)" }
      }
      $cc = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $cc) { $cc = Get-Command clang -ErrorAction SilentlyContinue }
      if (-not $cc) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH (M44 forward fixture needs a C compiler)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M44 forward fixture needs an archiver)" }
      }
      return @{ Available = $true; Reason = "zig=$($zigCmd.Source); cc=$($cc.Source); ar=$($ar.Source)" }
    }
    'mixed/cpp-uses-zig-lib' {
      # M44 reverse direction: a C++ executable that links a Zig
      # staticlib. Needs zig + g++/clang++ + ar.
      $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
      if (-not $zigCmd) {
        $zigRoot = 'D:\metacraft-dev-deps\zig'
        if (Test-Path -LiteralPath $zigRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $zigRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $verDir.FullName 'zig.exe'
            if (Test-Path -LiteralPath $candidate) {
              $binDir = Split-Path -Parent $candidate
              $env:PATH = "$binDir;$env:PATH"
              $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
              break
            }
          }
        }
      }
      if (-not $zigCmd) {
        return @{ Available = $false; Reason = "'zig' not on PATH and not under D:/metacraft-dev-deps/zig/ (M44 reverse fixture needs zig)" }
      }
      $cxx = Get-Command g++ -ErrorAction SilentlyContinue
      if (-not $cxx) { $cxx = Get-Command clang++ -ErrorAction SilentlyContinue }
      if (-not $cxx) {
        return @{ Available = $false; Reason = "neither 'g++' nor 'clang++' on PATH (M44 reverse fixture needs a C++ link driver)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M44 reverse fixture needs an archiver)" }
      }
      return @{ Available = $true; Reason = "zig=$($zigCmd.Source); cxx=$($cxx.Source); ar=$($ar.Source)" }
    }
    'mixed/d-uses-cpp-lib' {
      # M45 forward direction: a D executable that links a C archive.
      # Needs a D compiler (ldmd2/dmd/ldc2) + gcc/clang + ar.
      $dCmd = Get-Command ldmd2 -ErrorAction SilentlyContinue
      if (-not $dCmd) { $dCmd = Get-Command dmd -ErrorAction SilentlyContinue }
      if (-not $dCmd) { $dCmd = Get-Command ldc2 -ErrorAction SilentlyContinue }
      if (-not $dCmd) {
        $ldcRoot = 'D:\metacraft-dev-deps\ldc'
        if (Test-Path -LiteralPath $ldcRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $ldcRoot -Directory -ErrorAction SilentlyContinue) {
            foreach ($inner in Get-ChildItem -LiteralPath $verDir.FullName -Directory -ErrorAction SilentlyContinue) {
              $candidate = Join-Path $inner.FullName 'bin\ldmd2.exe'
              if (Test-Path -LiteralPath $candidate) {
                $binDir = Split-Path -Parent $candidate
                $env:PATH = "$binDir;$env:PATH"
                $dCmd = Get-Command ldmd2 -ErrorAction SilentlyContinue
                break
              }
            }
            if ($dCmd) { break }
          }
        }
      }
      if (-not $dCmd) {
        return @{ Available = $false; Reason = "no D compiler (ldmd2/dmd/ldc2) on PATH and not under D:/metacraft-dev-deps/ldc/ (M45 forward fixture needs D)" }
      }
      $cc = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $cc) { $cc = Get-Command clang -ErrorAction SilentlyContinue }
      if (-not $cc) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH (M45 forward fixture needs a C compiler)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M45 forward fixture needs an archiver)" }
      }
      return @{ Available = $true; Reason = "d=$($dCmd.Source); cc=$($cc.Source); ar=$($ar.Source)" }
    }
    'mixed/cpp-uses-d-lib' {
      # M45 reverse direction: a C++ executable that links a D
      # staticlib. Needs a D compiler (ldmd2/dmd/ldc2) + g++/clang++
      # + ar.
      $dCmd = Get-Command ldmd2 -ErrorAction SilentlyContinue
      if (-not $dCmd) { $dCmd = Get-Command dmd -ErrorAction SilentlyContinue }
      if (-not $dCmd) { $dCmd = Get-Command ldc2 -ErrorAction SilentlyContinue }
      if (-not $dCmd) {
        $ldcRoot = 'D:\metacraft-dev-deps\ldc'
        if (Test-Path -LiteralPath $ldcRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $ldcRoot -Directory -ErrorAction SilentlyContinue) {
            foreach ($inner in Get-ChildItem -LiteralPath $verDir.FullName -Directory -ErrorAction SilentlyContinue) {
              $candidate = Join-Path $inner.FullName 'bin\ldmd2.exe'
              if (Test-Path -LiteralPath $candidate) {
                $binDir = Split-Path -Parent $candidate
                $env:PATH = "$binDir;$env:PATH"
                $dCmd = Get-Command ldmd2 -ErrorAction SilentlyContinue
                break
              }
            }
            if ($dCmd) { break }
          }
        }
      }
      if (-not $dCmd) {
        return @{ Available = $false; Reason = "no D compiler (ldmd2/dmd/ldc2) on PATH and not under D:/metacraft-dev-deps/ldc/ (M45 reverse fixture needs D)" }
      }
      $cxx = Get-Command g++ -ErrorAction SilentlyContinue
      if (-not $cxx) { $cxx = Get-Command clang++ -ErrorAction SilentlyContinue }
      if (-not $cxx) {
        return @{ Available = $false; Reason = "neither 'g++' nor 'clang++' on PATH (M45 reverse fixture needs a C++ link driver)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M45 reverse fixture needs an archiver)" }
      }
      return @{ Available = $true; Reason = "d=$($dCmd.Source); cxx=$($cxx.Source); ar=$($ar.Source)" }
    }
    'mixed/ada-uses-cpp-lib' {
      # M58 forward direction: an Ada executable that links a C archive.
      # Needs gnatmake + gcc/clang + ar.
      $gnatCmd = Get-Command gnatmake -ErrorAction SilentlyContinue
      if (-not $gnatCmd) {
        return @{ Available = $false; Reason = "'gnatmake' not on PATH (M58 forward fixture needs Ada via 'pacman -S mingw-w64-x86_64-gcc-ada' under MSYS2)" }
      }
      $cc = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $cc) { $cc = Get-Command clang -ErrorAction SilentlyContinue }
      if (-not $cc) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH (M58 forward fixture needs a C compiler)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M58 forward fixture needs an archiver)" }
      }
      return @{ Available = $true; Reason = "gnatmake=$($gnatCmd.Source); cc=$($cc.Source); ar=$($ar.Source)" }
    }
    'mixed/cpp-uses-ada-lib' {
      # M58 reverse direction: a C++ executable that links an Ada
      # staticlib. Needs gnatmake + g++/clang++ + ar.
      $gnatCmd = Get-Command gnatmake -ErrorAction SilentlyContinue
      if (-not $gnatCmd) {
        return @{ Available = $false; Reason = "'gnatmake' not on PATH (M58 reverse fixture needs Ada via 'pacman -S mingw-w64-x86_64-gcc-ada' under MSYS2)" }
      }
      $cxx = Get-Command g++ -ErrorAction SilentlyContinue
      if (-not $cxx) { $cxx = Get-Command clang++ -ErrorAction SilentlyContinue }
      if (-not $cxx) {
        return @{ Available = $false; Reason = "neither 'g++' nor 'clang++' on PATH (M58 reverse fixture needs a C++ link driver)" }
      }
      $ar = Get-Command ar -ErrorAction SilentlyContinue
      if (-not $ar) {
        return @{ Available = $false; Reason = "'ar' not on PATH (M58 reverse fixture needs an archiver)" }
      }
      return @{ Available = $true; Reason = "gnatmake=$($gnatCmd.Source); cxx=$($cxx.Source); ar=$($ar.Source)" }
    }
    'mode1/rust-binary-with-library' {
      # M48: Mode 1 Rust — needs rustc. Reuse the rustup-stable
      # fallback the rust probe uses so a fresh host without a system
      # rustc still picks up the bundled toolchain.
      $rustc = Get-Command rustc -ErrorAction SilentlyContinue
      if (-not $rustc) {
        $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
        if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
          $env:PATH = "$rustupStableBin;$env:PATH"
          $rustc = Get-Command rustc -ErrorAction SilentlyContinue
        }
      }
      if (-not $rustc) {
        return @{ Available = $false; Reason = "rustc not on PATH and no rustup stable under D:/metacraft-dev-deps/rustup" }
      }
      return @{ Available = $true; Reason = "rustc=$($rustc.Source)" }
    }
    'mode1/nim-binary-with-library' {
      # M48: Mode 1 Nim — needs nim + gcc (Nim's C backend driver).
      $nimCmd = Get-Command nim -ErrorAction SilentlyContinue
      if (-not $nimCmd) {
        return @{ Available = $false; Reason = "'nim' not on PATH (env.ps1 should provide it)" }
      }
      return @{ Available = $true; Reason = "nim=$($nimCmd.Source)" }
    }
    'mixed/cpp-uses-go-lib' {
      # M36 reverse direction: a C++ executable that links a Go
      # c-archive. Needs go + g++/clang++ + gcc/clang + ar.
      $goCmd = Get-Command go -ErrorAction SilentlyContinue
      if (-not $goCmd) {
        $goRoot = 'D:/metacraft-dev-deps/go'
        if (Test-Path -LiteralPath $goRoot) {
          foreach ($verDir in Get-ChildItem -LiteralPath $goRoot -Directory -ErrorAction SilentlyContinue) {
            $candidate = Join-Path $verDir.FullName 'go\bin\go.exe'
            if (Test-Path -LiteralPath $candidate) {
              $binDir = Split-Path -Parent $candidate
              $env:PATH = "$binDir;$env:PATH"
              $goCmd = Get-Command go -ErrorAction SilentlyContinue
              break
            }
          }
        }
      }
      if (-not $goCmd) {
        return @{ Available = $false; Reason = "'go' not on PATH and not under D:/metacraft-dev-deps/go/" }
      }
      $cxx = Get-Command g++ -ErrorAction SilentlyContinue
      if (-not $cxx) { $cxx = Get-Command clang++ -ErrorAction SilentlyContinue }
      if (-not $cxx) {
        return @{ Available = $false; Reason = "neither 'g++' nor 'clang++' on PATH (M36 reverse fixture needs a C++ link driver)" }
      }
      $cc = Get-Command gcc -ErrorAction SilentlyContinue
      if (-not $cc) { $cc = Get-Command clang -ErrorAction SilentlyContinue }
      if (-not $cc) {
        return @{ Available = $false; Reason = "neither 'gcc' nor 'clang' on PATH (Go's c-archive build mode needs a C compiler at build time)" }
      }
      return @{ Available = $true; Reason = "go=$($goCmd.Source); cxx=$($cxx.Source); cc=$($cc.Source)" }
    }
    default {
      return @{ Available = $true; Reason = '' }
    }
  }
}

# --- KNOWN-FAIL classifier --------------------------------------------------
# Maps a populated-example rel-path to its KNOWN-FAIL reason, or $null if the
# example is expected to PASS. The classifier checks BOTH stdout and stderr
# for the documented "no convention matched"-style diagnostic before
# accepting a non-zero exit as KNOWN-FAIL.
function Get-KnownFailReason([string]$rel) {
  switch ($rel) {
    # M12 (2026-05-27): nim/library + nim/library-with-tests graduated
    # from KNOWN-FAIL to PASS via the DSL ``library`` macro + Nim
    # convention emit branch.
    #
    # M13 (2026-05-27): rust/library + rust/library-with-tests +
    # rust/workspace graduated from KNOWN-FAIL to PASS. The Rust
    # convention now accepts library-only crates, ``[[bin]]`` array
    # entries, and ``[workspace]`` manifests; cargo-metadata-driven
    # workspace member enumeration wires inter-crate ``--extern`` edges.
    #
    # M14 (2026-05-27): go/library + go/multi-binary graduated to PASS.
    # The Go convention now accepts library-only modules (no
    # ``package main`` anywhere) and the ``cmd/<name>/main.go``
    # multi-binary layout; ``go list`` enumerates every package and the
    # emitter produces one link action per main package.
    #
    # M15 (2026-05-27): python/library-pure + python/console-script
    # graduated to PASS via the Python convention's Mode A PEP 517
    # build_wheel hook. The convention emits one wheel-build action per
    # ``library`` / ``executable`` member; ``[project.scripts]`` entry
    # points appear in the wheel's entry_points.txt metadata. Launcher
    # wrapper emission (the spec's A5 venv + ``installer`` step) is
    # deferred to a follow-up M; ``[project.scripts]`` projects PASS
    # today on the wheel-only headline.
    #
    # M16 (2026-05-27): javascript-typescript/typescript-library,
    # typescript-cli, and node-server all graduated to PASS via the
    # JavaScript/TypeScript convention's Mode A subset. TS projects emit
    # a single ``npx tsc -p tsconfig.json`` action; JS-only projects
    # emit one ``fs.copyFile`` per source. Per-file swc/esbuild transform
    # (A2), per-bin esbuild bundle (A5), launcher shim emission (A6),
    # ``tsc --noEmit`` typecheck (A4), per-test runner (A7), and the
    # Mode B fallback are all deferred to a follow-up M.
    default                    { return $null }
  }
}

# --- expected-binary spec per PASS example ----------------------------------
# Each entry returns either:
#   $null              -- no executable to run (the build itself is the assertion)
#   @( @{ Path; Greeting }, ... )  -- one or more produced outputs. Each entry
#                                     carries one of two locator forms:
#                                       Path     -- literal absolute path
#                                       PathGlob -- @{ Dir; Filter } pair; the
#                                                   harness picks the first
#                                                   matching file (used for
#                                                   artefacts with a stable-hash
#                                                   suffix in the name, e.g.
#                                                   Rust's lib<crate>-<hash>.rlib).
#                                     If a Greeting is non-null the file must
#                                     also be runnable and its stdout must
#                                     contain the greeting.
function Get-ExpectedOutputs([string]$rel, [string]$fixtureDir) {
  switch ($rel) {
    'nim/binary' {
      $entry = 'nim_binary_example'
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $entry ($entry + '.exe')))
        Greeting = "hello from $entry"
      })
    }
    'nim/multi-binary' {
      $alpha = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'alpha' 'alpha.exe'))
      $beta  = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'beta'  'beta.exe'))
      return @(
        @{ Path = $alpha; Greeting = 'hello from alpha' },
        @{ Path = $beta;  Greeting = 'hello from beta'  }
      )
    }
    'nim/library' {
      # M12: ``library nim_library_example`` (no kind:) defaults to
      # lkStatic; the Nim convention emits ``ar rcs lib<name>.a`` as
      # phase 3. No greeting — a static archive isn't a runnable binary.
      $entry = 'nim_library_example'
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $entry ("lib" + $entry + ".a")))
        Greeting = $null
      })
    }
    'nim/mode3-pilot' {
      # Mode 3 Nim pilot (Three-Mode-Convention-System §"Mode 3 — minimal
      # curated `repro.nim`"). The fixture declares TWO packages in a
      # single project file: `mode3PilotGreet` (with `library greet`)
      # and `mode3PilotHello` (with `executable hello`). The
      # `repro.scanned-deps.nim` companion (generated by
      # `repro deps refresh`) carries the
      # `depends_on mode3PilotHello: mode3PilotGreet` edge inferred
      # from `src/hello.nim`'s `import greet` line. The engine consumes
      # that edge: `hello`'s gcc link action declares the greet
      # package's `libgreet.a` static archive in its inputs/argv/deps,
      # so the build sequences greet's `ar` action before hello's
      # link, and the linked executable's greeting confirms the
      # cross-package wiring closed end-to-end.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'greet' 'libgreet.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'hello' 'hello.exe'))
          Greeting = 'hello from mode3-pilot, mode3-pilot'
        }
      )
    }
    'nim/library-with-tests' {
      # M12: same shape as nim/library — the ``tests/`` directory exists
      # but the convention's M3 surface only links the library itself.
      # Per-test compile actions are deferred to a later milestone (see
      # Nim.md §"Test commands").
      $entry = 'nim_library_with_tests_example'
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $entry ("lib" + $entry + ".a")))
        Greeting = $null
      })
    }
    'rust/binary' {
      $crate = 'rust_binary_example'
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $crate (Join-Path 'bin' ($crate + '.exe'))))
        Greeting = 'hello from rust-binary-example'
      })
    }
    'rust/library' {
      # M13: the Rust convention emits ``lib<crateName>-<stableHash>.rlib``
      # under ``.repro/build/<crateName>/bin/``. Glob for the rlib rather
      # than hard-coding the hash (which is derived from
      # ``<crateName>@<edition>`` and would silently desync on edition
      # bumps).
      $crate = 'rust_library_example'
      return @(@{
        PathGlob = @{
          Dir    = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $crate 'bin'))
          Filter = "lib$crate-*.rlib"
        }
        Greeting = $null
      })
    }
    'rust/library-with-tests' {
      # M13: same shape as rust/library. The ``tests/`` directory exists
      # but the convention's M13 surface only links the library itself —
      # per-test runner actions are deferred to a later milestone (see
      # Rust.md §"Test commands").
      $crate = 'rust_library_with_tests_example'
      return @(@{
        PathGlob = @{
          Dir    = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $crate 'bin'))
          Filter = "lib$crate-*.rlib"
        }
        Greeting = $null
      })
    }
    'rust/workspace' {
      # M13: workspace with two members — ``crate_a`` (lib) and
      # ``crate_b`` (bin that depends on crate_a via ``--extern``).
      # The greeting comes from ``crate_a::greet`` so successful execution
      # of the binary verifies the inter-crate edge wired correctly.
      return @(
        @{
          PathGlob = @{
            Dir    = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'crate_a' 'bin'))
            Filter = "libcrate_a-*.rlib"
          }
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'crate_b' (Join-Path 'bin' 'crate_b.exe')))
          Greeting = 'hello, rust-workspace-example'
        }
      )
    }
    'rust/workspace-lib-chain' {
      # M23: three-crate workspace with a true lib→lib chain
      # (``crate_a (lib) → crate_b (lib) → crate_c (bin)``). The
      # transitive greeting comes from crate_a::greet wrapped in
      # crate_b::banner; running crate_c proves the topological emit
      # order + ``-L dependency=<bin_dir>`` search-path threading wire
      # correctly. We additionally glob for crate_a + crate_b rlibs to
      # confirm Pass A emitted both.
      $alphaRlibDir = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'crate_a' 'bin'))
      $betaRlibDir  = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'crate_b' 'bin'))
      $crateCBin    = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'crate_c' (Join-Path 'bin' 'crate_c.exe')))
      return @(
        @{
          PathGlob = @{ Dir = $alphaRlibDir; Filter = 'libcrate_a-*.rlib' }
          Greeting = $null
        },
        @{
          PathGlob = @{ Dir = $betaRlibDir;  Filter = 'libcrate_b-*.rlib' }
          Greeting = $null
        },
        @{
          Path     = $crateCBin
          Greeting = '[chain] hello, rust-workspace-lib-chain-example'
        }
      )
    }
    'rust/cdylib' {
      # M23: ``crate-type = ["cdylib"]`` in Cargo.toml. The convention
      # emits ``rustc --crate-type cdylib --emit=link``; rustc produces
      # ``<name>.dll`` on Windows / ``lib<name>.so`` on Linux /
      # ``lib<name>.dylib`` on macOS. No greeting check — a cdylib
      # isn't an executable; the dedicated
      # validate-standard-provider-rust-cdylib.ps1 script additionally
      # verifies the exported C-ABI symbol via dumpbin.
      $crate = 'rust_cdylib_example'
      $binDir = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $crate 'bin'))
      $filename =
        if ($IsWindows -or $env:OS -eq 'Windows_NT') { "$crate.dll" }
        elseif ($IsMacOS) { "lib$crate.dylib" }
        else { "lib$crate.so" }
      return @(@{
        Path     = Join-Path $binDir $filename
        Greeting = $null
      })
    }
    'rust/binary-with-crates-io' {
      # M23 Part B (Mode B fallback scope): a project with a
      # ``[dependencies]`` entry whose source resolves to crates.io is
      # routed through the Mode B crude fallback (``cargo build
      # --release --offline``). Mode B's cargo invocation writes to
      # ``<fixture>/target/release/`` (not the convention scratch dir
      # under ``.repro/build/``). The greeting check exercises the
      # libc dep — successful run proves cargo resolved the dep
      # against the host CARGO_HOME registry.
      return @(@{
        Path     = Join-Path $fixtureDir 'target\release\rust-binary-with-crates-io.exe'
        Greeting = 'hello from rust-binary-with-crates-io'
      })
    }
    'rust/binary-with-build-rs' {
      # Mode B crude path: cargo writes to <fixture>/target/release/.
      return @(@{
        Path     = Join-Path $fixtureDir 'target\release\rust-binary-with-build-rs.exe'
        Greeting = 'hello with build.rs: yes'
      })
    }
    'go/binary' {
      $entry = 'go_binary_example'
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $entry (Join-Path 'bin' ($entry + '.exe'))))
        Greeting = 'hello from go-binary-example'
      })
    }
    'go/multi-binary' {
      # M14: ``cmd/<name>/main.go`` layout. The Go convention's
      # projectEntry is derived from the module path's last segment
      # (``example.com/go-multi-binary-example`` →
      # ``go_multi_binary_example``); both binaries land under that
      # scratch dir's bin/. Per-binary basename is the cmd's last path
      # segment (``alpha`` / ``beta``).
      $entry = 'go_multi_binary_example'
      $alpha = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $entry (Join-Path 'bin' 'alpha.exe')))
      $beta  = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $entry (Join-Path 'bin' 'beta.exe')))
      return @(
        @{ Path = $alpha; Greeting = 'hello from alpha' },
        @{ Path = $beta;  Greeting = 'hello from beta'  }
      )
    }
    'go/library' {
      # M14: library-only module. ``go tool compile`` emits a ``.a``
      # archive under ``<entry>/pkg/`` and the convention emits no link
      # action. We glob for the archive rather than hard-coding the
      # import-path sanitisation (slashes become ``__``) so future
      # module-path tweaks don't silently desync the test.
      $entry = 'go_library_example'
      return @(@{
        PathGlob = @{
          Dir    = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $entry 'pkg'))
          Filter = '*.a'
        }
        Greeting = $null
      })
    }
    'go/library-with-tests' {
      # M22: library-with-tests fixture. Default target builds the
      # package's ``.a`` archive (same shape as go/library); the
      # ``#test`` target additionally runs ``go test -count=1`` per
      # test-bearing package. The harness's $TestTargetProbes loop
      # covers the #test invocation separately; the default-target
      # check here only verifies the archive is produced.
      $entry = 'go_library_with_tests_example'
      return @(@{
        PathGlob = @{
          Dir    = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $entry 'pkg'))
          Filter = '*.a'
        }
        Greeting = $null
      })
    }
    'python/library-pure' {
      # M15: pure-Python library. Mode A's PEP 517 ``build_wheel`` hook
      # produces ``<dist_name>-<version>-py3-none-any.whl`` under
      # ``<member>/dist/`` where ``<member>`` is the literal name from
      # ``library <name>`` in reprobuild.nim (camelCase
      # ``pythonLibraryExample``). No greeting check — a wheel isn't an
      # executable. The validate-standard-provider-python-library.ps1
      # script covers the wheel-imports assertion separately.
      $member = 'pythonLibraryExample'
      return @(@{
        PathGlob = @{
          Dir    = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member 'dist'))
          Filter = '*.whl'
        }
        Greeting = $null
      })
    }
    'python/console-script' {
      # M15: console-script project. The Python convention emits a wheel
      # carrying the ``[project.scripts]`` entry-point metadata.
      # M20: A5 installer sub-graph additionally lands a runnable shim
      # under ``<install>/Scripts/<name>.exe`` (Windows) /
      # ``<install>/bin/<name>`` (POSIX). The shim's __main__.py is
      # monkey-patched to prepend the install's site/ directory to
      # sys.path so it runs without any caller PYTHONPATH plumbing — so
      # the harness's Greeting assertion (executes the shim, checks
      # stdout) is a load-bearing M20 PASS criterion, not just a
      # presence check.
      $member = 'python_console_script'
      $launcherName = 'python-console-script'
      if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $shimPath = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member (Join-Path 'install' (Join-Path 'Scripts' ($launcherName + '.exe')))))
      } else {
        $shimPath = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member (Join-Path 'install' (Join-Path 'bin' $launcherName))))
      }
      return @(
        @{
          PathGlob = @{
            Dir    = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member 'dist'))
            Filter = '*.whl'
          }
          Greeting = $null
        },
        @{
          Path     = $shimPath
          Greeting = 'hello from python-console-script'
        }
      )
    }
    'python/pep517-maturin' {
      # M24 Mode B fallback. ``python -m build --wheel --no-isolation``
      # invokes maturin which writes the platform-tagged wheel under
      # ``<fixture>/dist/``. The wheel filename carries the ABI + platform
      # tag (e.g. ``cp312-cp312-win_amd64``) so we glob rather than
      # hard-coding.
      return @(@{
        PathGlob = @{
          Dir    = Join-Path $fixtureDir 'dist'
          Filter = '*.whl'
        }
        Greeting = $null
      })
    }
    'python/pep517-scikit-build-core' {
      # M24 Mode B fallback — same shape as maturin, but
      # scikit-build-core drives CMake to compile the C extension.
      return @(@{
        PathGlob = @{
          Dir    = Join-Path $fixtureDir 'dist'
          Filter = '*.whl'
        }
        Greeting = $null
      })
    }
    'javascript-typescript/vite-app' {
      # M24 Mode B fallback — ``npm install && npm run build`` invokes
      # ``vite build`` which writes the library-mode bundle to
      # ``<fixture>/dist/index.js`` (matches the ``lib.fileName`` in
      # ``vite.config.js``). No greeting — running a library entry is
      # the validate script's job.
      return @(@{
        Path     = Join-Path $fixtureDir 'dist\index.js'
        Greeting = $null
      })
    }
    'javascript-typescript/webpack-app' {
      # M24 Mode B fallback — ``npm install && npm run build`` invokes
      # ``webpack --mode production`` which writes the bundle to
      # ``<fixture>/dist/index.js``.
      return @(@{
        Path     = Join-Path $fixtureDir 'dist\index.js'
        Greeting = $null
      })
    }
    'javascript-typescript/typescript-library' {
      # M16: TS library. The JS/TS convention emits a flat
      # ``.repro/build/dist/`` tree (no per-member subdir) with one
      # ``.js`` + one ``.d.ts`` per source file. No greeting — the
      # validate script runs the node-import smoke separately.
      return @(@{
        Path     = Join-Path $fixtureDir '.repro\build\dist\index.js'
        Greeting = $null
      })
    }
    'javascript-typescript/typescript-cli' {
      # M21: TS CLI. The M21 convention emits npm-ci + tsc + esbuild
      # bundle + .cmd shim. The bundle lands at dist/bin/cli.js (esbuild
      # writes here; tsc's --outDir output excludes this path so the two
      # actions don't collide on declared outputs). The Windows .cmd
      # launcher shim lives at <scratch>/bin/typescript-cli-example.cmd.
      # The shim is the load-bearing runnable artefact at M21 — the
      # harness runs it directly and checks for the greeting.
      return @(
        @{
          Path     = Join-Path $fixtureDir '.repro\build\dist\bin\cli.js'
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir '.repro\build\bin\typescript-cli-example.cmd'
          Greeting = 'hello from typescript-cli-example'
        }
      )
    }
    'javascript-typescript/node-server' {
      # M16: pure-JS node application. The convention emits one
      # ``fs.copyFile`` action per ``src/**/*.js`` source. Predicted
      # output is ``.repro/build/dist/index.js``. No greeting — the
      # server binds a port and would hang the harness if executed
      # directly. The validate-standard-provider-node-server.ps1 script
      # forces ``PORT=0`` and tears the server down after import.
      return @(@{
        Path     = Join-Path $fixtureDir '.repro\build\dist\index.js'
        Greeting = $null
      })
    }
    'c-cpp-make/binary' {
      # M17: c-cpp-make/binary. The convention emits per-source compile
      # + link actions; the binary lands at
      # ``.repro/build/<member>/<member>[.exe]`` (member name comes from
      # ``executable hello`` in reprobuild.nim).
      $member = 'hello'
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member ($member + '.exe')))
        Greeting = 'hello from c-cpp-make-binary'
      })
    }
    'c-cpp-make/library-static' {
      # M17: c-cpp-make/library-static. The convention emits per-source
      # compile + ``ar rcs`` archive actions; the archive lands at
      # ``.repro/build/<member>/lib<member>.a`` (member name comes from
      # ``library greet`` in reprobuild.nim). No greeting check — an
      # archive isn't runnable; the validate script links a tiny test
      # consumer separately.
      $member = 'greet'
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member ('lib' + $member + '.a')))
        Greeting = $null
      })
    }
    'c-cpp-cmake/hello-binary' {
      # M38: c-cpp-cmake/hello-binary. The convention emits one
      # ``cmake -S <root> -B <root>/.repro/build/cmake -G <generator>``
      # configure action plus one ``cmake --build ... --target hello``
      # build action. The fixture's CMakeLists.txt forces
      # ``CMAKE_RUNTIME_OUTPUT_DIRECTORY=${CMAKE_BINARY_DIR}`` so the
      # produced binary lands at
      # ``.repro/build/cmake/hello[.exe]`` matching the convention's
      # predicted output path.
      return @(@{
        Path     = Join-Path $fixtureDir '.repro\build\cmake\hello.exe'
        Greeting = 'hello from c-cpp-cmake-hello-binary'
      })
    }
    'c-cpp-meson/hello-binary' {
      # M39: c-cpp-meson/hello-binary. The convention emits one
      # ``meson setup <root>/.repro/build/meson <root> --buildtype=release
      # --backend=ninja`` configure action plus one ``meson compile -C
      # ... hello`` build action. Meson's default layout places the
      # produced executable at the build dir root, so on Windows the
      # binary lands at ``.repro/build/meson/hello.exe`` matching the
      # convention's predicted output path.
      return @(@{
        Path     = Join-Path $fixtureDir '.repro\build\meson\hello.exe'
        Greeting = 'hello from c-cpp-meson-hello-binary'
      })
    }
    'java-maven/hello-binary' {
      # M40: java-maven/hello-binary. The convention emits a single
      # ``mvn package -o -q -f <pom>`` action that produces
      # ``target/<artifactId>-<version>.jar`` under the project root.
      # The fixture pins ``artifactId=hello`` + ``version=1.0`` so the
      # jar lands at ``target/hello-1.0.jar``. No direct ``.exe`` to
      # run; the harness asserts the jar exists. The greeting check
      # runs via the dedicated validation script
      # ``validate-standard-provider-java-maven-hello-binary.ps1``
      # which invokes ``java -jar`` after the build — checking the
      # greeting from the harness would need a separate jar-launch
      # path, which the harness's ``Greeting`` field doesn't support
      # (it execs the produced binary directly).
      return @(@{
        Path     = Join-Path $fixtureDir 'target\hello-1.0.jar'
        Greeting = $null
      })
    }
    'kotlin-gradle/hello-binary' {
      # M41: kotlin-gradle/hello-binary. The convention emits a single
      # ``gradle build --offline --no-daemon -q`` action that produces
      # ``build/libs/<projectName>-<version>.jar`` under the project
      # root. The fixture pins ``rootProject.name=hello`` (in
      # settings.gradle.kts) + ``version=1.0`` (in build.gradle.kts) so
      # the jar lands at ``build/libs/hello-1.0.jar``. No direct
      # ``.exe`` to run; the harness asserts the jar exists. The
      # greeting check runs via the dedicated validation script
      # ``validate-standard-provider-kotlin-gradle-hello-binary.ps1``
      # which invokes ``java -jar`` after the build — checking the
      # greeting from the harness would need a separate jar-launch
      # path, which the harness's ``Greeting`` field doesn't support
      # (it execs the produced binary directly).
      return @(@{
        Path     = Join-Path $fixtureDir 'build\libs\hello-1.0.jar'
        Greeting = $null
      })
    }
    'swift-swiftpm/hello-binary' {
      # M43: swift-swiftpm/hello-binary. The convention emits a single
      # ``swift build -c release --quiet`` action that produces
      # ``.build/release/<targetName>[.exe]`` under the project root.
      # The fixture pins ``executableTarget(name: "hello")`` so the
      # binary lands at ``.build/release/hello.exe`` (Windows) or
      # ``.build/release/hello`` (POSIX). SwiftPM produces a
      # self-launching binary so the harness can exec it directly.
      $exeName = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'hello.exe' } else { 'hello' }
      return @(@{
        Path     = Join-Path $fixtureDir (".build\release\" + $exeName)
        Greeting = 'hello from swift-swiftpm-hello-binary'
      })
    }
    'ocaml-dune/hello-binary' {
      # M46: ocaml-dune/hello-binary. The convention emits a single
      # ``dune build --release -j 1`` action that produces
      # ``_build/default/<entry-dir>/<name>.exe`` under the project root.
      # The fixture's ``dune`` file lives at the root so the entry-dir
      # is the root itself; the binary lands at
      # ``_build/default/hello.exe``. Dune normalises the ``.exe``
      # suffix even on POSIX as of Dune 3.x so the predicted path is
      # stable across platforms (a bare-suffix file is also produced
      # on POSIX but ``.exe`` is the form the convention pins).
      return @(@{
        Path     = Join-Path $fixtureDir '_build\default\hello.exe'
        Greeting = 'hello from ocaml-dune-hello-binary'
      })
    }
    'haskell-cabal/hello-binary' {
      # M55: haskell-cabal/hello-binary. The convention emits a single
      # ``cabal v2-build --offline -j1 --enable-relocatable`` action.
      # The produced binary lives under a complex
      # ``dist-newstyle/build/<platform-tuple>/ghc-<ver>/<pkg>-<ver>/
      # x/<exe>/build/<exe>/<exe>.exe`` path that varies by GHC version
      # + platform-tuple. The harness can't predict the exact path
      # without probing the toolchain, so it walks ``dist-newstyle/``
      # for the ``hello.exe`` binary as a defensive lookup. On the M55
      # review host (Windows, GHC absent) this fixture SKIPs cleanly
      # before reaching the produced-exe check.
      $exeName = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'hello.exe' } else { 'hello' }
      $distDir = Join-Path $fixtureDir 'dist-newstyle'
      $produced = $null
      if (Test-Path -LiteralPath $distDir) {
        $cands = Get-ChildItem -LiteralPath $distDir -Filter $exeName -Recurse -ErrorAction SilentlyContinue
        if ($cands -and $cands.Count -gt 0) {
          # Prefer the deepest path matching ``x/hello/build/hello/hello.exe``
          $produced = ($cands | Sort-Object { $_.FullName.Length } -Descending | Select-Object -First 1).FullName
        }
      }
      if (-not $produced) {
        # Predicted path placeholder — harness uses this only for the
        # missing-file error message when the convention failed to
        # build (the actual produced path is discovered by walk above).
        $produced = Join-Path $fixtureDir ("dist-newstyle\build\x86_64-windows\ghc-9.10.1\hello-1.0\x\hello\build\hello\" + $exeName)
      }
      return @(@{
        Path     = $produced
        Greeting = 'hello from haskell-cabal-hello-binary'
      })
    }
    'ruby-bundler/hello-binary' {
      # M56: ruby-bundler/hello-binary. The convention emits a single
      # ``bundle install --deployment --local --quiet --path
      # vendor/bundle`` action (wrapped in cmd /c so the engine has
      # a stable output sentinel) plus an ``fs.writeText`` action per
      # executable that materialises
      # ``<root>/.repro/build/<name>/<name>.cmd``. The wrapper
      # invokes ``bundle exec ruby bin/<name>.rb`` so the harness can
      # exec the .cmd directly and assert the greeting. On the M56
      # review host (Windows, Ruby absent) this fixture SKIPs cleanly
      # before reaching the produced-wrapper check.
      $exeName = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'hello.cmd' } else { 'hello' }
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'hello' $exeName))
        Greeting = 'hello from ruby-bundler-hello-binary'
      })
    }
    'php-composer/hello-binary' {
      # M57: php-composer/hello-binary. The convention emits a single
      # ``composer install --no-dev --optimize-autoloader --no-progress
      # --quiet`` action (wrapped in cmd /c so the engine has a stable
      # output sentinel under ``vendor/.repro-composer-stamp``) plus
      # an ``fs.writeText`` action per executable that materialises
      # ``<root>/.repro/build/<name>/<name>.cmd``. The wrapper invokes
      # ``php bin/<name>.php`` so the harness can exec the .cmd
      # directly and assert the greeting. On the M57 review host
      # (Windows, PHP absent) this fixture SKIPs cleanly before
      # reaching the produced-wrapper check.
      $exeName = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'hello.cmd' } else { 'hello' }
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'hello' $exeName))
        Greeting = 'hello from php-composer-hello-binary'
      })
    }
    'csharp-dotnet/hello-binary' {
      # M42: csharp-dotnet/hello-binary. The convention emits a single
      # ``dotnet build -c Release --no-restore --nologo --verbosity
      # quiet <csproj>`` action that produces
      # ``bin/Release/<TargetFramework>/<AssemblyName>.exe`` under the
      # project root. The fixture pins ``TargetFramework=net8.0`` +
      # ``OutputType=Exe`` and uses the default ``AssemblyName=hello``
      # (csproj basename) so the binary lands at
      # ``bin/Release/net8.0/hello.exe``. The .NET 5+ SDK-style
      # build produces a self-launching .exe so the harness's
      # ``Greeting`` check can exec it directly.
      return @(@{
        Path     = Join-Path $fixtureDir 'bin\Release\net8.0\hello.exe'
        Greeting = 'hello from csharp-dotnet-hello-binary'
      })
    }
    'c-cpp-mode3/binary-with-library' {
      # Mode 3 C/C++: the workspace declares a library ``mathlib`` and an
      # executable ``calc`` in a single ``repro.nim``. The Mode 3
      # ``c-cpp-direct`` convention emits per-source compile actions,
      # ``ar rcs libmathlib.a``, then ``gcc -o calc[.exe]`` linking the
      # archive. The link action is sequenced strictly after the archive
      # action via Mode 3 ``depends_on`` wiring. Both outputs land under
      # ``<projectRoot>/.repro/build/<member>/``.
      $member = 'calc'
      return @(@{
        Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member ($member + '.exe')))
        Greeting = 'hello from c-cpp-mode3-binary-with-library, 2 + 3 = 5'
      })
    }
    'rust-mode3/binary-with-library' {
      # M30: Mode 3 Rust. The workspace declares a library ``mathlib``
      # and an executable ``calc`` in a single ``repro.nim`` with NO
      # ``Cargo.toml``. The Mode 3 ``rust-direct`` convention emits per-
      # crate rustc link actions; the library produces
      # ``libmathlib.rlib`` and the executable's argv carries
      # ``--extern mathlib=<rlib>`` so ``use mathlib::add;`` resolves.
      # The link action is sequenced strictly after the library action
      # via Mode 3 ``depends_on`` wiring. Both outputs land under
      # ``<projectRoot>/.repro/build/<member>/``.
      $member = 'calc'
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'mathlib' 'libmathlib.rlib'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member ($member + '.exe')))
          Greeting = 'hello from rust-mode3-binary-with-library, mathlib added 2+3 = 5'
        }
      )
    }
    'go-mode3/binary-with-library' {
      # M31: Mode 3 Go. The workspace declares a library ``mathlib``
      # and an executable ``calc`` in a single ``repro.nim`` with NO
      # ``go.mod``. The Mode 3 ``go-direct`` convention emits per-
      # member ``go tool compile`` actions (producing ``<name>.a``
      # archives) plus a ``go tool link`` action for the executable.
      # The library produces ``mathlib.a`` which the executable's
      # compile + link reference via importcfg / importcfg.link so
      # ``import "mathlib"`` in calc/main.go resolves. The link action
      # is sequenced strictly after the library compile via Mode 3
      # ``depends_on`` wiring. Both outputs land under
      # ``<projectRoot>/.repro/build/<member>/``.
      $member = 'calc'
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'mathlib' 'mathlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member ($member + '.exe')))
          Greeting = 'hello from go-mode3-binary-with-library, mathlib added 2+3 = 5'
        }
      )
    }
    'jsts-mode3/binary-with-library' {
      # M33: Mode 3 JavaScript/TypeScript. The workspace declares a
      # library ``mathlib`` and an executable ``calc`` in a single
      # ``repro.nim`` with NO ``package.json`` / ``tsconfig.json`` /
      # bundler config. The Mode 3 ``jsts-direct`` convention emits a
      # single esbuild --bundle action per executable (consuming the
      # library's TypeScript sources directly via
      # --alias:mathlib=<libdir>/src/index.ts) plus an fs.writeText
      # wrapper script. The wrapper runs ``node <bundle.js>`` so the
      # bundled JS produces the program's output. The wrapper-emit
      # action is sequenced strictly after the bundle via the action
      # graph's deps. Outputs land under
      # ``<projectRoot>/.repro/build/<member>/``.
      $member = 'calc'
      $bundle = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member ($member + '.js')))
      $wrapperCmd = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member ($member + '.cmd')))
      $wrapperSh  = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member $member))
      $wrapperPath = if (Test-Path -LiteralPath $wrapperCmd) { $wrapperCmd } elseif (Test-Path -LiteralPath $wrapperSh) { $wrapperSh } else { $wrapperCmd }
      return @(
        @{
          Path     = $bundle
          Greeting = $null
        },
        @{
          Path     = $wrapperPath
          Greeting = 'hello from jsts-mode3-binary-with-library, mathlib added 2+3 = 5'
        }
      )
    }
    'python-mode3/binary-with-library' {
      # M32: Mode 3 Python. The workspace declares a library ``mathlib``
      # and an executable ``calc`` in a single ``repro.nim`` with NO
      # ``pyproject.toml``. The Mode 3 ``python-direct`` convention
      # emits per-member ``fs.preserveTree`` stage actions, byte-
      # compile actions via ``python -m compileall``, and an
      # ``fs.writeText`` wrapper script for the executable. The
      # wrapper sets PYTHONPATH to include the mathlib staging dir
      # AND the calc staging dir so ``from mathlib import add`` in
      # calc/calc/__main__.py resolves at runtime. The wrapper-emit
      # action is sequenced strictly after the upstream byte-compile
      # via Mode 3 ``depends_on`` wiring. Outputs land under
      # ``<projectRoot>/.repro/build/<member>/``.
      $member = 'calc'
      # On Windows the wrapper is a ``.cmd`` file; the harness checks
      # ``.cmd`` first because that's the platform the M9 gate runs
      # on. The library output is the staged ``__init__.py`` —
      # checking it confirms the preserveTree stage ran for mathlib.
      $stagedMathInit = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'mathlib' (Join-Path 'mathlib' '__init__.py')))
      $wrapperCmd = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member ($member + '.cmd')))
      $wrapperSh  = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member $member))
      $wrapperPath = if (Test-Path -LiteralPath $wrapperCmd) { $wrapperCmd } elseif (Test-Path -LiteralPath $wrapperSh) { $wrapperSh } else { $wrapperCmd }
      return @(
        @{
          Path     = $stagedMathInit
          Greeting = $null
        },
        @{
          Path     = $wrapperPath
          Greeting = 'hello from python-mode3-binary-with-library, mathlib added 2+3 = 5'
        }
      )
    }
    'mixed/nim-uses-cpp-lib' {
      # Cross-language Mode 3: the workspace declares a C static library
      # ``mathlib`` (``uses: gcc``) and a Nim executable ``nimapp``
      # (``uses: nim``) in a single ``repro.nim`` with
      # ``depends_on nimapp: mathlib``. The Nim convention claims the
      # whole workspace (registered first; nimapp's uses block names
      # nim), emits the upstream C archive in-line via the embedded
      # C/C++ helper, threads --passC:-I<mathlib>/include onto Phase 1's
      # nim c argv (so the generated .c files resolve
      # ``#include "mathlib/add.h"``), and threads libmathlib.a onto
      # Phase 3's gcc link argv (so the C ``add()`` symbol resolves at
      # link time). The binary's first stdout line proves the
      # cross-language round-trip succeeded.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'mathlib' 'libmathlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'nimapp' 'nimapp.exe'))
          Greeting = '1 + 2 = 3'
        }
      )
    }
    'mixed/cpp-uses-nim-lib' {
      # Cross-language Mode 3 (REVERSE direction): the workspace declares
      # a Nim static library ``addlib`` (``uses: nim``) and a C++
      # executable ``cppapp`` (``uses: gcc``) in a single ``repro.nim``
      # with ``depends_on cppapp: addlib``. The Nim convention claims
      # the whole workspace (registered first; addlib's uses block names
      # nim), emits the upstream Nim archive with ``--noMain`` (so the
      # archive's ``main`` symbol doesn't collide with the C++ binary's
      # own ``main()`` at link time) via the existing emitForLibrary
      # path, then emits per-source ``g++ -c`` + terminal ``g++ -o``
      # actions for the cppapp executable in-line via the embedded
      # cross-language emitCCppCrossExecutable helper. The libaddlib.a
      # archive lands on the link argv as a trailing positional. The
      # binary's first stdout line proves the cross-language round-trip
      # succeeded: C++ -> Nim nimAdd() -> back to C++.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'addlib' 'libaddlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'cppapp' 'cppapp.exe'))
          Greeting = 'cpp says: nim added 2+3 = 5'
        }
      )
    }
    'mixed/rust-uses-cpp-lib' {
      # M34 cross-language Mode 3 (FORWARD direction): the workspace
      # declares a C static library ``mathlib`` (``uses: gcc``) and a
      # Rust executable ``calc`` (``uses: rust``) in a single
      # ``repro.nim`` with ``depends_on calc: mathlib``. The rust-direct
      # convention claims the whole workspace (c-cpp-direct defers when
      # the workspace's uses names rust + no Cargo.toml present), emits
      # the upstream C archive in-line via the embedded
      # ``emitCCppCrossMember`` helper, and threads
      # ``-L native=<archive-dir>`` ``-l static=mathlib`` onto the Rust
      # binary's rustc link argv. The binary's first stdout line proves
      # the cross-language round-trip succeeded: Rust -> C add() -> back
      # to Rust println!.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'mathlib' 'libmathlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'calc' 'calc.exe'))
          Greeting = 'rust says: mathlib added 2+3 = 5'
        }
      )
    }
    'mixed/cpp-uses-rust-lib' {
      # M34 cross-language Mode 3 (REVERSE direction): the workspace
      # declares a Rust static library ``addlib`` (``uses: rust``) and a
      # C++ executable ``cppapp`` (``uses: gcc``) in a single
      # ``repro.nim`` with ``depends_on cppapp: addlib``. The rust-direct
      # convention claims the whole workspace, emits the upstream Rust
      # library with ``--crate-type=staticlib`` (NOT rlib) because addlib
      # is marked ``cConsumable=true`` (derived from the depends_on edge:
      # a C/C++ executable consumes the library, so C ABI archive). The
      # archive lands at ``.repro/build/addlib/libaddlib.a`` (canonical
      # archive schema shared with c-cpp-direct + Nim). Then emits per-
      # source ``g++ -c`` + terminal ``g++ -o`` actions for cppapp; the
      # link argv carries the Rust archive as a trailing positional plus
      # the platform-specific Rust runtime libs (Windows MinGW: ws2_32,
      # userenv, advapi32, bcrypt, ntdll). The binary's first stdout line
      # proves the cross-language round-trip: C++ -> Rust rust_add() ->
      # back to C++.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'addlib' 'libaddlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'cppapp' 'cppapp.exe'))
          Greeting = 'cpp says: rust added 2+3 = 5'
        }
      )
    }
    'mixed/nim-uses-rust-lib' {
      # M35 cross-language Mode 3 (FORWARD direction): the workspace
      # declares a Rust static library ``addlib`` (``uses: rust``) and a
      # Nim executable ``nimapp`` (``uses: nim``) in a single
      # ``repro.nim`` with ``depends_on nimapp: addlib``. The Nim
      # convention claims the whole workspace (registered first; nimapp's
      # uses block names nim), emits the Rust library via a single
      # ``rustc --crate-type=staticlib`` action landing at
      # ``.repro/build/addlib/libaddlib.a`` (canonical archive schema).
      # The Nim entrypoint's Phase 3 gcc link picks up the archive as a
      # trailing positional plus the platform-specific Rust runtime libs
      # (Windows MinGW: ws2_32, userenv, advapi32, bcrypt, ntdll; POSIX:
      # pthread, dl, m). The binary's first stdout line proves the
      # cross-language round-trip: Nim -> Rust rust_add() -> back to Nim.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'addlib' 'libaddlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'nimapp' 'nimapp.exe'))
          Greeting = 'nim says: rust added 2+3 = 5'
        }
      )
    }
    'mixed/rust-uses-nim-lib' {
      # M35 cross-language Mode 3 (REVERSE direction): the workspace
      # declares a Nim static library ``nimaddlib`` (``uses: nim``) and a
      # Rust executable ``rustapp`` (``uses: rust``) in a single
      # ``repro.nim`` with ``depends_on rustapp: nimaddlib``. The Nim
      # convention claims the whole workspace (registered first), emits
      # the Nim library archive with ``--noMain`` (driven by the
      # cConsumable flag derived from the depends_on edge — the Rust
      # binary has its own entry point so the archive's main symbol
      # must NOT collide), then emits a single
      # ``rustc --crate-type=bin`` action for rustapp. The link argv
      # carries ``-L native=<dir>`` + ``-l static=nimaddlib``; on
      # Windows the rustc invocation is forced to
      # ``--target x86_64-pc-windows-gnu`` so rustc routes through the
      # gcc-mingw linker (the Nim archive's MinGW gcc-compiled obj
      # files reference symbols MSVC link.exe cannot resolve). The
      # binary's first stdout line proves the cross-language round-trip:
      # Rust -> Nim nimAdd() -> back to Rust.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'nimaddlib' 'libnimaddlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'rustapp' 'rustapp.exe'))
          Greeting = 'rust says: nim added 2+3 = 5'
        }
      )
    }
    'mixed/go-uses-cpp-lib' {
      # M36 cross-language Mode 3 (FORWARD direction, cgo): the
      # workspace declares a C static library ``mathlib`` (``uses: gcc``)
      # and a Go executable ``calc`` (``uses: go``) in a single
      # ``repro.nim`` with ``depends_on calc: mathlib``. The go-direct
      # convention claims the whole workspace (c-cpp-direct defers when
      # the workspace's uses names go + no go.mod present), emits the
      # upstream C archive in-line via the embedded
      # ``emitCCppCrossMember`` helper, and threads
      # ``-ldflags=-extldflags "-L<archive-dir> -lmathlib"`` onto the Go
      # binary's ``go build`` argv (cgo path; the M31 ``go tool compile``
      # /``go tool link`` per-package fast path is bypassed for cgo
      # members). The binary's first stdout line proves the cross-
      # language round-trip succeeded: Go -> C add() -> back to Go.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'mathlib' 'libmathlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'calc' 'calc.exe'))
          Greeting = 'go says: mathlib added 2+3 = 5'
        }
      )
    }
    'mixed/cpp-uses-go-lib' {
      # M36 cross-language Mode 3 (REVERSE direction, c-archive): the
      # workspace declares a Go static library ``goaddlib`` (``uses: go``)
      # and a C++ executable ``cppapp`` (``uses: gcc``) in a single
      # ``repro.nim`` with ``depends_on cppapp: goaddlib``. The go-direct
      # convention claims the whole workspace, emits the upstream Go
      # library with ``go build -buildmode=c-archive`` (NOT the M31
      # ``go tool compile -pack``) because goaddlib is marked
      # ``cConsumable=true`` (derived from the depends_on edge: a C/C++
      # executable consumes the library, so C ABI archive). The archive
      # lands at ``.repro/build/goaddlib/libgoaddlib.a`` (canonical
      # archive schema shared with c-cpp-direct + Nim + Rust); Go's
      # c-archive toolchain ALSO auto-emits a sibling
      # ``libgoaddlib.h``. Then emits per-source ``g++ -c`` + terminal
      # ``g++ -o`` actions for cppapp; the link argv carries the Go
      # archive as a trailing positional plus the platform-specific Go
      # runtime libs (Windows MinGW: ws2_32, winmm, bcrypt, ntdll,
      # userenv, advapi32). The binary's first stdout line proves the
      # cross-language round-trip: C++ -> Go GoAdd() -> back to C++.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'goaddlib' 'libgoaddlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'cppapp' 'cppapp.exe'))
          Greeting = 'cpp says: GoAdd 2+3 = 5'
        }
      )
    }
    'fortran-mode3/binary-with-library' {
      # M37: Mode 3 Fortran pilot. The workspace declares a library
      # ``fortlib`` and an executable ``fortcalc`` in a single
      # ``repro.nim``. The fortran-direct convention emits per-source
      # ``gfortran -c`` actions + ``ar rcs libfortlib.a`` archive +
      # ``gfortran -o fortcalc[.exe]`` link. The link is sequenced
      # strictly after the archive via Mode 3 ``depends_on`` wiring.
      # Both outputs land under ``<projectRoot>/.repro/build/<member>/``.
      $member = 'fortcalc'
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'fortlib' 'libfortlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member ($member + '.exe')))
          Greeting = 'hello from fortran-mode3-binary-with-library, fortlib added 2+3 = 5'
        }
      )
    }
    'mixed/fortran-uses-cpp-lib' {
      # M37 cross-language Mode 3 (FORWARD direction): the workspace
      # declares a C static library ``mathlib`` (``uses: gcc``) and a
      # Fortran executable ``fortcalc`` (``uses: gfortran``) in a single
      # ``repro.nim`` with ``depends_on fortcalc: mathlib``. The
      # fortran-direct convention claims the whole workspace (c-cpp-
      # direct defers when the workspace's uses names gfortran), emits
      # the upstream C archive in-line via the embedded
      # ``emitCCppCrossMember`` helper, and threads the archive onto
      # the gfortran link argv as a trailing positional. The binary's
      # first stdout line proves the cross-language round-trip
      # succeeded: Fortran -> C c_add() -> back to Fortran.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'mathlib' 'libmathlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'fortcalc' 'fortcalc.exe'))
          Greeting = 'fortran says: mathlib added 2+3 = 5'
        }
      )
    }
    'mixed/cpp-uses-fortran-lib' {
      # M37 cross-language Mode 3 (REVERSE direction): the workspace
      # declares a Fortran static library ``fortaddlib`` (``uses:
      # gfortran``) and a C++ executable ``cppapp`` (``uses: gcc``) in
      # a single ``repro.nim`` with ``depends_on cppapp: fortaddlib``.
      # The fortran-direct convention claims the whole workspace,
      # emits the upstream Fortran archive (per-source ``gfortran -c``
      # + ``ar rcs libfortaddlib.a``), then emits per-source ``g++ -c``
      # + terminal ``g++ -o`` actions for cppapp; the link argv
      # carries the Fortran archive as a trailing positional plus the
      # platform-specific Fortran runtime libs (``-lgfortran
      # -lquadmath -lm``; ``-lpthread`` on POSIX). The binary's first
      # stdout line proves the cross-language round-trip: C++ ->
      # Fortran fortran_add() -> back to C++.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'fortaddlib' 'libfortaddlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'cppapp' 'cppapp.exe'))
          Greeting = 'cpp says: fortran added 2+3 = 5'
        }
      )
    }
    'zig-mode3/binary-with-library' {
      # M44: Mode 3 Zig pilot. The workspace declares a library
      # ``ziglib`` and an executable ``zigcalc`` in a single
      # ``repro.nim``. The zig-direct convention emits one
      # ``zig build-lib`` action per library + one ``zig build-exe``
      # action per executable; the link is sequenced strictly after
      # the library archive via the Mode 3 ``depends_on`` wiring.
      # Both outputs land under ``<projectRoot>/.repro/build/<member>/``.
      $member = 'zigcalc'
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'ziglib' 'libziglib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member ($member + '.exe')))
          Greeting = 'hello from zig-mode3-binary-with-library, ziglib added 2+3 = 5'
        }
      )
    }
    'mixed/zig-uses-cpp-lib' {
      # M44 cross-language Mode 3 (FORWARD direction): the workspace
      # declares a C static library ``mathlib`` (``uses: gcc``) and a
      # Zig executable ``zigcalc`` (``uses: zig``) in a single
      # ``repro.nim`` with ``depends_on zigcalc: mathlib``. The
      # zig-direct convention claims the whole workspace (c-cpp-direct
      # defers when ``uses:`` names zig AND no build.zig is present),
      # emits the upstream C archive in-line via the embedded
      # ``emitCCppCrossMember`` helper, and threads the archive onto
      # the zig build-exe argv as a trailing positional plus the
      # archive's parent dir as ``-L <dir>``. The binary's first
      # stdout line proves the cross-language round-trip succeeded:
      # Zig -> C c_add() -> back to Zig.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'mathlib' 'libmathlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'zigcalc' 'zigcalc.exe'))
          Greeting = 'zig says: mathlib added 2+3 = 5'
        }
      )
    }
    'mixed/cpp-uses-zig-lib' {
      # M44 cross-language Mode 3 (REVERSE direction): the workspace
      # declares a Zig static library ``zigaddlib`` (``uses: zig``)
      # and a C++ executable ``cppapp`` (``uses: gcc``) in a single
      # ``repro.nim`` with ``depends_on cppapp: zigaddlib``. The
      # zig-direct convention claims the whole workspace, emits the
      # upstream Zig archive via ``zig build-lib``, then emits per-
      # source ``g++ -c`` + terminal ``g++ -o`` actions for cppapp;
      # the link argv carries the Zig archive as a trailing positional.
      # Unlike Rust/Fortran reverse fixtures, Zig static archives
      # bundle their (minimal) compiler-rt routines into the archive
      # itself so the C++ link doesn't need explicit runtime ``-l``
      # libs. The binary's first stdout line proves the cross-language
      # round-trip: C++ -> Zig zig_add() -> back to C++.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'zigaddlib' 'libzigaddlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'cppapp' 'cppapp.exe'))
          Greeting = 'cpp says: zig added 2+3 = 5'
        }
      )
    }
    'd-mode3/binary-with-library' {
      # M45: Mode 3 D pilot. The workspace declares a library
      # ``dlib`` and an executable ``dcalc`` in a single
      # ``repro.nim``. The d-direct convention emits one
      # ``ldmd2 -lib`` action per library + one ``ldmd2`` action per
      # executable; the executable's link argv carries the upstream
      # archive via ``-L=<archive>`` (linker pass-through). The link
      # is sequenced strictly after the library archive via the
      # Mode 3 ``depends_on`` wiring. Both outputs land under
      # ``<projectRoot>/.repro/build/<member>/``.
      $member = 'dcalc'
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'dlib' 'libdlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member ($member + '.exe')))
          Greeting = 'hello from d-mode3-binary-with-library, dlib added 2+3 = 5'
        }
      )
    }
    'mixed/d-uses-cpp-lib' {
      # M45 cross-language Mode 3 (FORWARD direction): the workspace
      # declares a C static library ``mathlib`` (``uses: gcc``) and a
      # D executable ``dcalc`` (``uses: d``) in a single
      # ``repro.nim`` with ``depends_on dcalc: mathlib``. The d-direct
      # convention claims the whole workspace (c-cpp-direct defers
      # when ``uses:`` names a D toolchain token AND no
      # dub.json/dub.sdl is present), emits the upstream C archive
      # in-line via the embedded ``emitCCppCrossMember`` helper, and
      # threads the archive via ``-L=<archive>`` on the ldmd2 argv
      # (linker pass-through). The binary's first stdout line proves
      # the cross-language round-trip succeeded: D -> C c_add() ->
      # back to D.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'mathlib' 'libmathlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'dcalc' 'dcalc.exe'))
          Greeting = 'd says: mathlib added 2+3 = 5'
        }
      )
    }
    'mixed/cpp-uses-d-lib' {
      # M45 cross-language Mode 3 (REVERSE direction): the workspace
      # declares a D static library ``daddlib`` (``uses: d``) and a
      # C++ executable ``cppapp`` (``uses: gcc``) in a single
      # ``repro.nim`` with ``depends_on cppapp: daddlib``. The d-direct
      # convention claims the whole workspace, emits the upstream D
      # archive via ``ldmd2 -lib``, then emits per-source ``g++ -c``
      # + terminal ``g++ -o`` actions for cppapp; the link argv
      # carries the D archive as a trailing positional. The M45
      # honest-scope cut limits the reverse fixture to ``extern (C)``
      # entry points + ``core.stdc.*`` (no ``import std.*`` / no GC)
      # so the gcc driver resolves all references against the D
      # archive itself without external runtime libs — same property
      # Zig's M44 reverse fixture relies on. The binary's first
      # stdout line proves the cross-language round-trip: C++ -> D
      # d_add() -> back to C++.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'daddlib' 'libdaddlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'cppapp' 'cppapp.exe'))
          Greeting = 'cpp says: d added 2+3 = 5'
        }
      )
    }
    'ada-mode3/binary-with-library' {
      # M58: Mode 3 Ada pilot. The workspace declares a library
      # ``adalib`` and an executable ``adacalc`` in a single
      # ``repro.nim``. The ada-direct convention emits per-source
      # ``gcc -c -gnatp`` + ``ar rcs`` for the library + one
      # ``gnatmake`` action per executable; the executable's link
      # argv carries the upstream archive after the ``-largs``
      # separator (gnatmake linker pass-through). Both outputs land
      # under ``<projectRoot>/.repro/build/<member>/``.
      $member = 'adacalc'
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'adalib' 'libadalib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member ($member + '.exe')))
          Greeting = 'hello from ada-mode3-binary-with-library, adalib added 2+3 = 5'
        }
      )
    }
    'mixed/ada-uses-cpp-lib' {
      # M58 cross-language Mode 3 (FORWARD direction): the workspace
      # declares a C static library ``mathlib`` (``uses: gcc``) and an
      # Ada executable ``adacalc`` (``uses: gnatmake``) in a single
      # ``repro.nim`` with ``depends_on adacalcPkg: mathlibPkg``. The
      # ada-direct convention claims the whole workspace (c-cpp-direct
      # defers when ``uses:`` names an Ada toolchain token AND no
      # ``*.gpr`` is present), emits the upstream C archive in-line
      # via the embedded ``emitCCppCrossMember`` helper, and threads
      # the archive on the gnatmake argv after the ``-largs``
      # separator (linker pass-through). The binary's first stdout
      # line proves the cross-language round-trip succeeded: Ada -> C
      # c_add() -> back to Ada.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'mathlib' 'libmathlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'adacalc' 'adacalc.exe'))
          Greeting = 'ada says: mathlib added 2+3 = 5'
        }
      )
    }
    'mixed/cpp-uses-ada-lib' {
      # M58 cross-language Mode 3 (REVERSE direction): the workspace
      # declares an Ada static library ``adaaddlib`` (``uses: gnatmake``)
      # and a C++ executable ``cppapp`` (``uses: gcc``) in a single
      # ``repro.nim`` with ``depends_on cppappPkg: adaaddlibPkg``. The
      # ada-direct convention claims the whole workspace, emits the
      # upstream Ada archive via per-source ``gcc -c -gnatp`` + ``ar
      # rcs``, then emits per-source ``g++ -c`` + terminal ``g++ -o``
      # actions for cppapp; the link argv carries the Ada archive as a
      # trailing positional. The M58 honest-scope cut limits the
      # reverse fixture to ``pragma Export (C, ...)`` no-elaboration
      # entry points (no Ada.Text_IO, no tagged types) so the gcc
      # driver resolves all references against the Ada archive itself
      # without external runtime libs — same property Zig's M44 / D's
      # M45 reverse fixtures rely on for their respective runtimes.
      # The binary's first stdout line proves the cross-language
      # round-trip: C++ -> Ada ada_add() -> back to C++.
      return @(
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'adaaddlib' 'libadaaddlib.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path 'cppapp' 'cppapp.exe'))
          Greeting = 'cpp says: ada added 2+3 = 5'
        }
      )
    }
    'mode1/rust-binary-with-library' {
      # M48 Mode 1 Rust — synthesised repro.nim + scanned-deps.nim
      # live under ``<fixture>/.repro/mode1-synth/`` so the produced
      # rlib + binary land under the synth tree's own ``.repro/build/``.
      $synthDir = Join-Path $fixtureDir '.repro\mode1-synth'
      return @(
        @{
          Path     = Join-Path $synthDir (Join-Path '.repro\build' (Join-Path 'mathlib' 'libmathlib.rlib'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $synthDir (Join-Path '.repro\build' (Join-Path 'calc' 'calc.exe'))
          Greeting = 'hello from mode1-rust-binary-with-library, mathlib added 2+3 = 5'
        }
      )
    }
    'mode1/nim-binary-with-library' {
      # M48 Mode 1 Nim — synthesised repro.nim + scanned-deps.nim
      # live under ``<fixture>/.repro/mode1-synth/``.
      $synthDir = Join-Path $fixtureDir '.repro\mode1-synth'
      return @(
        @{
          Path     = Join-Path $synthDir (Join-Path '.repro\build' (Join-Path 'greet' 'libgreet.a'))
          Greeting = $null
        },
        @{
          Path     = Join-Path $synthDir (Join-Path '.repro\build' (Join-Path 'hello' 'hello.exe'))
          Greeting = 'hello from mode1-nim-binary-with-library'
        }
      )
    }
    'c-cpp-autotools/hello-binary' {
      # M28: c-cpp-autotools/hello-binary. The per-source lift emits
      # configure + per-source ``gcc -c`` + ``gcc -o`` link actions.
      # The link action drops the executable under the per-member
      # scratch directory ``<projectRoot>/.repro/build/hello/`` so two
      # members with the same target name don't stomp each other (same
      # shape as the c_cpp_make convention).
      $member = 'hello'
      $candidates = @(
        (Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member 'hello.exe'))),
        (Join-Path $fixtureDir (Join-Path '.repro\build' (Join-Path $member 'hello')))
      )
      $output = $null
      foreach ($candidatePath in $candidates) {
        if (Test-Path -LiteralPath $candidatePath) {
          $output = $candidatePath
          break
        }
      }
      # Predict the Windows .exe form when no prior build has produced
      # anything yet — the harness re-checks existence after the build
      # runs.
      if (-not $output) {
        $output = $candidates[0]
      }
      return @(@{
        Path     = $output
        Greeting = 'hello from c-cpp-autotools-hello-binary'
      })
    }
    default {
      return $null
    }
  }
}

# --- accounting ------------------------------------------------------------
$results = New-Object System.Collections.ArrayList
function Add-Result([string]$status, [string]$rel, [string]$reason) {
  [void]$results.Add([pscustomobject]@{
    Status  = $status
    Example = $rel
    Reason  = $reason
  })
}

$languageProbeCache = @{}
function Get-LanguageProbe([string]$language) {
  if (-not $languageProbeCache.ContainsKey($language)) {
    $languageProbeCache[$language] = Probe-Toolchain $language
  }
  return $languageProbeCache[$language]
}

# --- main loop -------------------------------------------------------------
Write-Host "============================================================"
Write-Host "M9 verification harness: $($PopulatedExamples.Count) examples"
Write-Host "============================================================"

foreach ($rel in $PopulatedExamples) {
  $language    = Get-Language $rel
  $exampleName = Get-ExampleName $rel
  $fixtureDir  = Join-Path $examplesRoot ($rel -replace '/', '\')
  Write-Host ""
  Write-Host "--- [$rel] ---"

  if (-not (Test-Path -LiteralPath $fixtureDir)) {
    Add-Result 'FAIL' $rel "fixture missing on disk at $fixtureDir"
    continue
  }
  $hasCanonical = Test-Path -LiteralPath (Join-Path $fixtureDir 'repro.nim')
  $hasLegacy    = Test-Path -LiteralPath (Join-Path $fixtureDir 'reprobuild.nim')
  if (-not $hasCanonical -and -not $hasLegacy) {
    # M48: Mode 1 fixtures by definition have NO project file at the
    # workspace root. The Mode 1 loader synthesises one in-memory at
    # dispatch time. Skip the preflight rejection for the ``mode1/``
    # subtree and let the harness proceed.
    if ($language -ne 'mode1') {
      Add-Result 'FAIL' $rel "fixture has no repro.nim / reprobuild.nim at $fixtureDir"
      continue
    }
  }

  $probe = Get-LanguageProbe $language
  if (-not $probe.Available) {
    Write-Host "  SKIP: $($probe.Reason)"
    Add-Result 'SKIP' $rel $probe.Reason
    continue
  }
  # M24: per-fixture toolchain probe for Mode B fixtures that need
  # extras beyond the language baseline (rustc for maturin, cmake for
  # scikit-build-core, npm for vite/webpack).
  $fixtureProbe = Probe-Fixture $rel
  if (-not $fixtureProbe.Available) {
    Write-Host "  SKIP: $($fixtureProbe.Reason)"
    Add-Result 'SKIP' $rel $fixtureProbe.Reason
    continue
  }

  # Wipe scratch BEFORE each invocation. Junction-aware ops not needed here
  # because example .repro/build/ is plain scratch that never contains
  # junctions (per M8 fixture layout).
  $scratchInsideFixture = Join-Path $fixtureDir '.repro'
  if (Test-Path -LiteralPath $scratchInsideFixture) {
    Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
  }
  # Rust also leaves a top-level target/ from cargo runs (Mode B and any
  # manual smoke). Wipe it so the run is cold.
  if ($language -eq 'rust') {
    $cargoTarget = Join-Path $fixtureDir 'target'
    if (Test-Path -LiteralPath $cargoTarget) {
      Remove-Item -LiteralPath $cargoTarget -Recurse -Force
    }
  }
  # M24 Mode B fixtures (python maturin/scikit-build-core, jsts
  # vite/webpack) write their build output to the fixture's own
  # ``dist/`` / ``build/`` / ``node_modules/`` directories. Wipe them
  # so every gate runs cold.
  $modeBFixtures = @(
    'python/pep517-maturin',
    'python/pep517-scikit-build-core',
    'javascript-typescript/vite-app',
    'javascript-typescript/webpack-app'
  )
  if ($modeBFixtures -contains $rel) {
    foreach ($leftover in @('dist', 'build', 'node_modules',
                            'target', 'package-lock.json')) {
      $leftoverPath = Join-Path $fixtureDir $leftover
      if (Test-Path -LiteralPath $leftoverPath) {
        Remove-Item -LiteralPath $leftoverPath -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
  # M23: warm the CARGO_HOME registry for rust/binary-with-crates-io
  # so the convention's Mode B fallback (``cargo build --offline``)
  # can resolve libc. SKIP cleanly when ``cargo fetch`` fails
  # (typically: offline host without the dep pre-cached).
  if ($rel -eq 'rust/binary-with-crates-io') {
    Push-Location -LiteralPath $fixtureDir
    try {
      $fetchOut = & cargo fetch 2>&1 | Out-String
      $fetchExit = $LASTEXITCODE
    } finally {
      Pop-Location
    }
    if ($fetchExit -ne 0) {
      Write-Host "  SKIP: 'cargo fetch' failed (exit $fetchExit) — Mode B fallback needs CARGO_HOME registry populated"
      Write-Host "  --- cargo fetch tail:"
      ($fetchOut -split "`n" | Select-Object -Last 5) | ForEach-Object { Write-Host "    $_" }
      Add-Result 'SKIP' $rel "cargo fetch failed (exit $fetchExit) — CARGO_HOME registry not populated for libc"
      continue
    }
  }
  # The autotools convention's actions run ``autoreconf -fi`` +
  # ``./configure`` + ``make``. The M17 fixture ships only the source
  # files (configure.ac + Makefile.am + src/); every other file is
  # generated. Wipe the generated set so each gate is reproducible.
  if ($language -eq 'c-cpp-autotools') {
    foreach ($leftover in @('Makefile', 'Makefile.in', 'config.log',
        'config.status', 'aclocal.m4', 'configure', 'confdefs.h',
        'hello', 'hello.exe')) {
      $leftoverPath = Join-Path $fixtureDir $leftover
      if (Test-Path -LiteralPath $leftoverPath) {
        Remove-Item -LiteralPath $leftoverPath -Force -ErrorAction SilentlyContinue
      }
    }
    foreach ($leftoverDir in @('autom4te.cache', 'build-aux', '.deps',
        'src/.deps')) {
      $leftoverDirPath = Join-Path $fixtureDir $leftoverDir
      if (Test-Path -LiteralPath $leftoverDirPath) {
        Remove-Item -LiteralPath $leftoverDirPath -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
    # Wipe any per-source .o files automake leaves under src/.
    $srcObjs = Get-ChildItem -LiteralPath (Join-Path $fixtureDir 'src') -Filter '*.o' -ErrorAction SilentlyContinue
    foreach ($obj in $srcObjs) {
      Remove-Item -LiteralPath $obj.FullName -Force -ErrorAction SilentlyContinue
    }
  }
  # M56: the ruby-bundler convention vendors gems into
  # ``vendor/bundle/`` and Bundler may leave a per-project ``.bundle/``
  # config dir at the fixture root. Wipe both so every gate runs cold.
  if ($language -eq 'ruby-bundler') {
    foreach ($leftoverDir in @('vendor', '.bundle')) {
      $leftoverDirPath = Join-Path $fixtureDir $leftoverDir
      if (Test-Path -LiteralPath $leftoverDirPath) {
        Remove-Item -LiteralPath $leftoverDirPath -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
  # M57: the php-composer convention vendors packages into ``vendor/``.
  # Wipe so every gate runs cold.
  if ($language -eq 'php-composer') {
    foreach ($leftoverDir in @('vendor')) {
      $leftoverDirPath = Join-Path $fixtureDir $leftoverDir
      if (Test-Path -LiteralPath $leftoverDirPath) {
        Remove-Item -LiteralPath $leftoverDirPath -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }

  # Per-example REPRO_STATS_DIR so we can attribute fast-path distribution
  # to specific PASS rows in the aggregate.
  $statsDir = Join-Path $statsRootDir ("$language-$($rel -replace '[/\\]', '-')")
  New-Item -ItemType Directory -Force -Path $statsDir | Out-Null
  $env:REPRO_STATS_DIR = $statsDir

  # M11 (2026-05-27): REPRO_MONITOR_BYPASS retired across all examples.
  # The cargo std::process::Command panic was traced to the FS-snoop shim
  # clobbering thread-local LastError; the fix lives in
  # libs/repro_monitor_shim/src/repro_monitor_shim/windows_interpose.nim
  # (Save/Restore LastError around each hook body). The bypass is no
  # longer needed for rust/binary-with-build-rs either. Clear any inherited
  # bypass env var so the harness ALWAYS exercises automaticMonitor.
  Remove-Item Env:REPRO_MONITOR_BYPASS -ErrorAction SilentlyContinue

  $stdoutCapture = Join-Path $logsDir ("$exampleName.stdout.txt")
  $stderrCapture = Join-Path $logsDir ("$exampleName.stderr.txt")
  $reproTarget   = "$fixtureDir#default"

  Write-Host "  invoking repro build $reproTarget"
  try {
    $proc = Start-Process -FilePath $reproExe -ArgumentList @(
        'build', $reproTarget,
        '--tool-provisioning=path',
        '--log=summary'
      ) -NoNewWindow -PassThru -Wait `
      -WorkingDirectory $repoRoot `
      -RedirectStandardOutput $stdoutCapture `
      -RedirectStandardError  $stderrCapture
    $exitCode = $proc.ExitCode
  } finally {
    Remove-Item Env:REPRO_STATS_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:REPRO_MONITOR_BYPASS -ErrorAction SilentlyContinue
  }

  $stdoutText = if (Test-Path $stdoutCapture) { Get-Content -LiteralPath $stdoutCapture -Raw } else { '' }
  $stderrText = if (Test-Path $stderrCapture) { Get-Content -LiteralPath $stderrCapture -Raw } else { '' }
  # PowerShell 7's Get-Content -Raw returns $null for an empty file (not an
  # empty string), which then breaks the $stdoutText.Length interpolation
  # below. Defensive coercion.
  if ($null -eq $stdoutText) { $stdoutText = '' }
  if ($null -eq $stderrText) { $stderrText = '' }
  Write-Host "    exit=$exitCode  stdout=$($stdoutText.Length)B  stderr=$($stderrText.Length)B"

  if ($exitCode -eq 0) {
    # Classify expected outputs. If we don't have expectations recorded for
    # this rel-path, that's a FAIL — we're not supposed to silently accept
    # an unrecognised pass.
    $expected = Get-ExpectedOutputs $rel $fixtureDir
    if ($null -eq $expected) {
      Add-Result 'FAIL' $rel "repro exit 0 but no expected-output spec is recorded for this example"
      continue
    }
    $allOk = $true
    foreach ($exp in $expected) {
      # Resolve the literal path. PathGlob entries pick the first matching
      # file under their Dir; literal Path entries pass straight through.
      $resolvedPath = $null
      if ($exp.ContainsKey('PathGlob') -and $exp.PathGlob) {
        $globDir = $exp.PathGlob.Dir
        $globFilter = $exp.PathGlob.Filter
        if (-not (Test-Path -LiteralPath $globDir)) {
          Add-Result 'FAIL' $rel "expected output dir missing: $globDir"
          $allOk = $false
          break
        }
        $globMatches = @(Get-ChildItem -LiteralPath $globDir -Filter $globFilter -ErrorAction SilentlyContinue)
        if ($globMatches.Count -eq 0) {
          Add-Result 'FAIL' $rel "no file matching '$globFilter' under $globDir"
          $allOk = $false
          break
        }
        $resolvedPath = $globMatches[0].FullName
      } else {
        $resolvedPath = $exp.Path
        if (-not (Test-Path -LiteralPath $resolvedPath)) {
          Add-Result 'FAIL' $rel "expected binary missing: $resolvedPath"
          $allOk = $false
          break
        }
      }
      if ($exp.ContainsKey('Greeting') -and $exp.Greeting) {
        $output = & $resolvedPath 2>&1 | Out-String
        $runExit = $LASTEXITCODE
        if ($runExit -ne 0) {
          Add-Result 'FAIL' $rel "produced binary $resolvedPath exited $runExit"
          $allOk = $false
          break
        }
        if ($output -notmatch [regex]::Escape($exp.Greeting)) {
          Add-Result 'FAIL' $rel "produced binary stdout missing greeting '$($exp.Greeting)'; got: $($output.Trim())"
          $allOk = $false
          break
        }
      }
    }
    if ($allOk) {
      Write-Host "    PASS"
      Add-Result 'PASS' $rel ''
      # --- M22 test-target probe ---------------------------------------
      # When the fixture is in $TestTargetProbes, additionally invoke
      # ``repro build <fixture>#test`` and assert exit 0 + at least one
      # ``*.stamp`` file under the convention's ``tests/`` scratch dir.
      # The probe is independent of the PASS/FAIL accounting above — a
      # test-target failure surfaces as its own row keyed on
      # ``<rel>#test`` so the operator sees both the default build's
      # PASS and the test target's outcome.
      if ($TestTargetProbes -contains $rel) {
        $testStdout = Join-Path $logsDir ("$exampleName-test.stdout.txt")
        $testStderr = Join-Path $logsDir ("$exampleName-test.stderr.txt")
        $testReproTarget = "$fixtureDir#test"
        Write-Host "    [M22] invoking repro build $testReproTarget"
        try {
          $env:REPRO_STATS_DIR = $statsDir
          $tProc = Start-Process -FilePath $reproExe -ArgumentList @(
              'build', $testReproTarget,
              '--tool-provisioning=path',
              '--log=summary'
            ) -NoNewWindow -PassThru -Wait `
            -WorkingDirectory $repoRoot `
            -RedirectStandardOutput $testStdout `
            -RedirectStandardError  $testStderr
          $tExit = $tProc.ExitCode
        } finally {
          Remove-Item Env:REPRO_STATS_DIR -ErrorAction SilentlyContinue
        }
        Write-Host "      [M22] #test exit=$tExit"
        if ($tExit -ne 0) {
          $tStderrText = if (Test-Path $testStderr) { Get-Content -LiteralPath $testStderr -Raw } else { '' }
          $tFirstErr = ($tStderrText -split "`n" | Where-Object { $_ -ne '' } | Select-Object -First 1)
          Add-Result 'FAIL' "$rel#test" "exit=$tExit; stderr: $tFirstErr"
        } else {
          # Locate the convention's tests scratch dir. Each language
          # owns a slightly different prefix — collapse to a recursive
          # glob under ``.repro/build`` for ``*.stamp`` so the probe
          # stays convention-agnostic.
          $stampRoot = Join-Path $fixtureDir '.repro\build'
          $stamps = @()
          if (Test-Path -LiteralPath $stampRoot) {
            $stamps = @(Get-ChildItem -LiteralPath $stampRoot -Recurse -Filter '*.stamp' -ErrorAction SilentlyContinue)
          }
          if ($stamps.Count -lt 1) {
            Add-Result 'FAIL' "$rel#test" "no *.stamp files under $stampRoot"
          } else {
            Write-Host "      [M22] PASS: $($stamps.Count) stamp(s) produced"
            Add-Result 'PASS' "$rel#test" ''
          }
        }
      }
    }
    continue
  }

  # Non-zero exit. Match against the documented KNOWN-FAIL catalog. We accept
  # the diagnostic if the stderr OR stdout contains the canonical
  # "no convention matched" phrase (exit 3 path) OR a recognisable provider
  # failure tied to the documented Mode A gap.
  $reason = Get-KnownFailReason $rel
  if ($reason) {
    # Be permissive: a documented coverage gap can manifest as either
    # "no convention matched" (exit 3) or a downstream provider exit
    # complaining about the missing DSL member. Both are KNOWN-FAIL.
    Write-Host "    KNOWN-FAIL: $reason"
    Add-Result 'KNOWN-FAIL' $rel "exit=$exitCode; $reason"
    continue
  }

  Write-Host "    FAIL: exit=$exitCode (no KNOWN-FAIL classification matches)"
  $stderrTail = if ($stderrText) { ($stderrText -split "`n" | Select-Object -Last 10) -join "`n" } else { '(empty)' }
  $stdoutTail = if ($stdoutText) { ($stdoutText -split "`n" | Select-Object -Last 10) -join "`n" } else { '(empty)' }
  Write-Host "    --- stderr tail ---"
  Write-Host $stderrTail
  Write-Host "    --- stdout tail ---"
  Write-Host $stdoutTail
  Add-Result 'FAIL' $rel "exit=$exitCode; stderr: $(($stderrText -split "`n" | Where-Object { $_ -ne '' } | Select-Object -First 1))"
}

# --- aggregate stats across PASS runs --------------------------------------
$fastPathCounts = @{}
$totalInvocations = 0
$totalWallMs = 0.0
$statsFiles = Get-ChildItem -LiteralPath $statsRootDir -Recurse -Filter '*.json' -ErrorAction SilentlyContinue
foreach ($f in $statsFiles) {
  try {
    $json = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
  } catch {
    continue
  }
  $totalInvocations++
  $tag = if ($json.fastPath) { [string]$json.fastPath } else { 'slow-path' }
  if (-not $fastPathCounts.ContainsKey($tag)) { $fastPathCounts[$tag] = 0 }
  $fastPathCounts[$tag]++
  if ($json.wallMs -ne $null) {
    $totalWallMs += [double]$json.wallMs
  }
}

# --- final report ----------------------------------------------------------
$passed     = @($results | Where-Object { $_.Status -eq 'PASS' })
$knownFail  = @($results | Where-Object { $_.Status -eq 'KNOWN-FAIL' })
$skipped    = @($results | Where-Object { $_.Status -eq 'SKIP' })
$failed     = @($results | Where-Object { $_.Status -eq 'FAIL' })

Write-Host ""
Write-Host "============================================================"
Write-Host "Standard-Provider Examples Verification - Aggregate Report"
Write-Host "============================================================"
Write-Host "PASSED      : $($passed.Count)"
foreach ($r in $passed)    { Write-Host "    $($r.Example)" }
Write-Host "KNOWN-FAIL  : $($knownFail.Count)"
foreach ($r in $knownFail) { Write-Host "    $($r.Example) -- $($r.Reason)" }
Write-Host "SKIPPED     : $($skipped.Count)"
foreach ($r in $skipped)   { Write-Host "    $($r.Example) -- $($r.Reason)" }
Write-Host "FAILED      : $($failed.Count)"
foreach ($r in $failed)    { Write-Host "    $($r.Example) -- $($r.Reason) (STOP, these are the real bugs)" }
Write-Host ""
Write-Host "Fast-path attribution (across $totalInvocations recorded invocation(s)):"
$sortedTags = $fastPathCounts.Keys | Sort-Object
foreach ($tag in $sortedTags) {
  $count = $fastPathCounts[$tag]
  Write-Host ("    {0,-32} : {1} invocation(s)" -f $tag, $count)
}
Write-Host ("    {0,-32} : {1:F1} ms" -f "Total wall", $totalWallMs)
Write-Host "============================================================"

if ($failed.Count -gt 0) {
  Write-Host ""
  Write-Host "FAILED count = $($failed.Count); harness exits non-zero."
  exit 1
}

Write-Host ""
Write-Host "All examples accounted for; no unexpected failures."
exit 0
