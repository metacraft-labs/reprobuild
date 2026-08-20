## Platform-And-Microarchitecture-Constraints PMC-1 (Package-Model.md
## §"GAP: a package cannot declare the platforms it exists on" → "A lint
## becomes possible") — a provisioning arm whose ``os =`` / ``cpu =`` falls
## outside the package's declared ``platforms:`` is refused at AUTHORING time.
##
## Before PMC-1 nothing could catch this. Availability was inferred from
## whichever arms happened to exist, so an ``os = "linux"`` tarball on a
## Windows-only package was not a contradiction — there was nothing for it to
## contradict. The arm was simply unreachable: no consumer of that package
## could ever legitimately select it, and no diagnostic said so.
##
## The check runs inside the ``package`` macro, so the failure is a COMPILE
## error at the offending arm rather than a resolution-time surprise on some
## other machine. That is why this test compiles fixture recipes with ``nim
## c`` rather than calling a proc: the behaviour under test *is* the compile.
##
## Assertions:
##   1. A ``tarball`` arm with ``os = "linux"`` under ``platforms: [windows]``
##      FAILS to compile.
##   2. The diagnostic names the package, the declared set, and the offending
##      arm's coordinate — enough for the author to see which of the two is
##      the typo without opening the spec.
##   3. CONTROL: the same recipe with the arm's ``os`` corrected to
##      ``"windows"`` compiles cleanly. Without this, assertion (1) would also
##      pass if the fixture were simply malformed for an unrelated reason.
##   4. CONTROL: the same offending arm with NO ``platforms:`` block compiles
##      cleanly — the lint fires on a DECLARATION, and the ~262 stdlib entries
##      that declare nothing are untouched by it.
##   5. A ``platforms:`` block naming an unknown token (e.g. a PMC-2
##      microarchitecture level, which is not part of this axis) is refused
##      too, rather than silently ignored.
##
## Hermetic: fixture recipes are written to a temp directory under the repo
## root (so the repository's compiler configuration applies) and removed
## afterwards. Nothing on the host is consulted.

import std/[os, osproc, strutils, tempfiles, unittest]

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir
  ## tests/integration/<this>.nim -> tests/integration -> tests -> repo root.
  ## Derived from the source path rather than ``getCurrentDir()`` so the
  ## fixture compiles land under the repository (and therefore inherit its
  ## ``config.nims`` search paths) no matter what directory the test runner
  ## launches the binary from.

const ArmBody = """
  provisioning:
    tarball url = "https://example.invalid/thing-1.0.tar.gz",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "tar.gz",
      executablePath = "bin/thing",
      packageId = "thing@1.0",
      cpu = "x86_64",
      os = "$1",
      lockIdentity = "tarball:thing@1.0"
"""

proc recipeSource(platformsBlock, armOs: string): string =
  "import repro_project_dsl\n\n" &
  "package pmc1LintFixture:\n" &
  platformsBlock &
  ArmBody % [armOs]

proc compileFixture(root, name, source: string):
    tuple[output: string; exitCode: int] =
  let dir = root / name
  createDir(dir)
  let file = dir / (name & ".nim")
  writeFile(file, source)
  # ``workingDir`` is load-bearing: the repository's dependency search paths
  # (nimcrypto, blake3, the vendored serialization libs) resolve relative to
  # the compiler's working directory, and the test runner does not promise to
  # launch this binary from the repo root. Without it the fixture compile
  # fails on a MISSING IMPORT — which still exits non-zero, so the
  # "expected a compile error" assertion would pass for entirely the wrong
  # reason. The message assertions below are the second line of defence
  # against exactly that.
  execCmdEx("nim c --hints:off --warnings:off --compileOnly" &
    " --nimcache:" & quoteShell(dir / "nimcache") &
    " " & quoteShell(file),
    workingDir = RepoRoot)

suite "PMC-1 — an arm outside declared platforms: is a lint error":

  test "t_arm_outside_declared_platforms_is_a_lint_error":
    # Under the repo's ``build/`` tree so the repository's own compiler
    # configuration (``config.nims``, the ``libs/`` search paths) governs the
    # fixture compile exactly as it governs every other recipe — Nim walks
    # parent directories looking for it — while keeping generated ``.nim``
    # files out of the source directories other tests scan.
    let scratchParent = RepoRoot / "build" / "test-tmp"
    createDir(scratchParent)
    let scratch = createTempDir("repro-pmc1-lint-", "", scratchParent)
    defer: removeDir(scratch)

    # ---- (1) + (2) the offending arm is refused -------------------------
    block armOutsideDeclaration:
      let (output, exitCode) = compileFixture(scratch, "outside",
        recipeSource("  platforms: [windows]\n", "linux"))
      if exitCode == 0:
        checkpoint "expected a compile error, got a clean compile"
      check exitCode != 0
      check output.contains("pmc1LintFixture")
      check output.contains("platforms:")
      check output.contains("windows")
      check output.contains("os = \"linux\"")

    # ---- (3) CONTROL: the corrected arm compiles ------------------------
    block armInsideDeclaration:
      let (output, exitCode) = compileFixture(scratch, "inside",
        recipeSource("  platforms: [windows]\n", "windows"))
      if exitCode != 0:
        checkpoint output
      check exitCode == 0

    # ---- (4) CONTROL: no declaration, no lint ---------------------------
    block noDeclaration:
      let (output, exitCode) = compileFixture(scratch, "undeclared",
        recipeSource("", "linux"))
      if exitCode != 0:
        checkpoint output
      check exitCode == 0

    # ---- (5) an unknown platform token is refused -----------------------
    block unknownToken:
      let (output, exitCode) = compileFixture(scratch, "badtoken",
        recipeSource("  platforms: [\"x86-64-v3\"]\n", "windows"))
      if exitCode == 0:
        checkpoint "expected a compile error, got a clean compile"
      check exitCode != 0
      check output.contains("unknown platform token")
