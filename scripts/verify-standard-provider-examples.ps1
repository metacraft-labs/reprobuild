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
# Expected to PASS (the known-working set, post-M20):
#   nim/binary, nim/multi-binary,
#   nim/library, nim/library-with-tests,
#   rust/binary, rust/binary-with-build-rs,
#   rust/library, rust/library-with-tests, rust/workspace,
#   go/binary, go/library, go/multi-binary,
#   python/library-pure,
#   python/console-script    (M20: byte-compile + sdist + runnable shim),
#   javascript-typescript/typescript-library,
#   javascript-typescript/typescript-cli,
#   javascript-typescript/node-server,
#   c-cpp-make/binary, c-cpp-make/library-static,
#   c-cpp-autotools/hello-binary (when autotools toolchain available)
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

# --- the canonical list of 20 populated examples ----------------------------
# Mirrors libs/repro_standard_provider/tests/test_examples_layout.nim verbatim;
# changing the canonical list there must trigger a matching update here.
$PopulatedExamples = @(
  'nim/binary',
  'nim/library',
  'nim/library-with-tests',
  'nim/multi-binary',
  'rust/binary',
  'rust/library',
  'rust/library-with-tests',
  'rust/workspace',
  'rust/binary-with-build-rs',
  'go/binary',
  'go/library',
  'go/multi-binary',
  'python/library-pure',
  'python/console-script',
  'javascript-typescript/typescript-library',
  'javascript-typescript/typescript-cli',
  'javascript-typescript/node-server',
  'c-cpp-make/binary',
  'c-cpp-make/library-static',
  'c-cpp-autotools/hello-binary'
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
      # When autoreconf is missing the harness SKIPs cleanly.
      $autoreconfCmd = Get-Command autoreconf -ErrorAction SilentlyContinue
      if (-not $autoreconfCmd) {
        return @{ Available = $false; Reason = "'autoreconf' not on PATH (autoconf + automake required for repo-checkout shape)" }
      }
      return @{ Available = $true; Reason = "cc=$($ccCmd.Source); make=$($makeCmd.Source); sh=$($shCmd.Source); autoreconf=$($autoreconfCmd.Source)" }
    }
    default {
      return @{ Available = $false; Reason = "unknown language '$language'" }
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
    'c-cpp-autotools/hello-binary' {
      # M17: c-cpp-autotools/hello-binary. The convention emits a
      # configure action + a make action; in-tree automake build leaves
      # the executable at the project root.
      $candidates = @('hello.exe', 'hello')
      $output = $null
      foreach ($candidate in $candidates) {
        $candidatePath = Join-Path $fixtureDir $candidate
        if (Test-Path -LiteralPath $candidatePath) {
          $output = $candidatePath
          break
        }
      }
      # Predict the Windows .exe form when no prior build has produced
      # anything yet — the harness re-checks existence after the build
      # runs.
      if (-not $output) {
        $output = Join-Path $fixtureDir 'hello.exe'
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
  if (-not (Test-Path -LiteralPath (Join-Path $fixtureDir 'reprobuild.nim'))) {
    Add-Result 'FAIL' $rel "fixture has no reprobuild.nim at $fixtureDir"
    continue
  }

  $probe = Get-LanguageProbe $language
  if (-not $probe.Available) {
    Write-Host "  SKIP: $($probe.Reason)"
    Add-Result 'SKIP' $rel $probe.Reason
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
