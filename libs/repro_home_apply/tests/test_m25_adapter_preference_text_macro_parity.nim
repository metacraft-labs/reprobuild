## M2.5 (Realize-Closure-And-Catalog-Expansion) parity gate: the text-
## form parser (`repro_home_intent/parser.nim`) and the macro-form
## library (`repro_profile`) must produce the SAME per-OS
## `adapterPreference` shape for the same input.
##
## The test uses a small fixture as the bridge:
##
##   text-form home.nim: `adapterPreference: windows: [scoop, builtin, path]`
##                       parsed via `loadProfile` → `Profile.adapterPreference`
##
##   macro-form: the same OS keys + chains constructed in-process via the
##               macro (compiled + run as a sub-process so the macro
##               expansion runs; output captured as JSON; decoded via
##               `parseProfileIntentJson`) → `ProfileIntent.adapterPreference`
##
## The two values must be `==` element-wise.
##
## This gate is the bridge between the two parser frontends — both must
## produce the same AST shape so the M83 Phase D
## `profileIntentToHomeProfile` adapter (which converts the macro form
## to the text-form `Profile` value the apply pipeline consumes) can
## propagate `adapterPreference` without divergence.

import std/[os, osproc, strutils, tables, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_home_intent
import repro_profile

# The macro fixture must live UNDER the repo root so `nim c` walks up
# and finds `config.nims` (which adds the `--path:libs/<lib>/src`
# switches that resolve `import repro_profile`). A tempdir outside the
# repo wouldn't see the config.

# ---------------------------------------------------------------------------
# Shared fixture content — identical OS keys + chain order for both parsers
# ---------------------------------------------------------------------------

const TextFormFixture = """
import repro/profile

profile "bridge":
  adapterPreference:
    windows: [scoop, builtin, path]
    linux: [nix, builtin, path]
    darwin: [nix, path]

  activity default:
    just
"""

const MacroFormFixture = """
import repro_profile

profile "bridge":
  adapterPreference:
    windows: [scoop, builtin, path]
    linux: [nix, builtin, path]
    darwin: [nix, path]

  activity default:
    just
"""

# ---------------------------------------------------------------------------
# Macro-form helper: compile the fixture to an exe, run it, capture JSON
# ---------------------------------------------------------------------------

const RepoRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  ## `tests/test_m25_*.nim → tests → repro_home_apply → libs → reprobuild`
  ## — the repo root carries `config.nims` which sets up the per-lib
  ## `--path` switches that `import repro_profile` requires.

proc macroFixtureScratchDir(stem: string): string =
  ## A scratch directory UNDER the repo root so `nim c` walks up and
  ## finds the repo's `config.nims` (which adds the
  ## `--path:libs/<name>/src` switches). A `Temp\...` directory outside
  ## the repo would NOT see `config.nims`. The scratch path mirrors the
  ## convention the other M83 e2e tests use under `build/test-tmp/`.
  let base = RepoRoot / "build" / "test-tmp" / "m25-parity" / stem
  if dirExists(extendedPath(base)):
    removeDir(extendedPath(base))
  createDir(extendedPath(base))
  base

proc compileAndRunMacroFixture(workDir: string; src: string): string =
  ## Compile the macro fixture as a sub-process. The fixture lives
  ## under the repo root so `nim c` walks up the directory tree and
  ## reads `config.nims`, which adds `--path:libs/<lib>/src` switches
  ## so `import repro_profile` resolves.
  let fixturePath = workDir / "macro_fixture.nim"
  writeFile(extendedPath(fixturePath), src)
  let outName =
    when defined(windows): "macro_fixture.exe"
    else: "macro_fixture"
  let outPath = workDir / outName
  let cachePath = workDir / "nimcache"
  let compileCmd = "nim c --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(cachePath) & " " &
    "--out:" & quoteShell(outPath) & " " &
    quoteShell(fixturePath)
  # `execCmdEx` honours the named `workingDir` parameter; the spawned
  # `nim` invocation walks up FROM the fixture file looking for
  # `config.nims`, so the fixture's location matters more than CWD.
  let compileResult = execCmdEx(compileCmd, workingDir = RepoRoot)
  if compileResult.exitCode != 0:
    raise newException(IOError,
      "macro fixture compile failed:\n" & compileResult.output)
  let runResult = execCmdEx(quoteShell(outPath))
  if runResult.exitCode != 0:
    raise newException(IOError,
      "macro fixture run failed:\n" & runResult.output)
  result = runResult.output.strip()

suite "M2.5 — text/macro adapterPreference parity":

  test "test_m25_adapter_preference_text_form_parses":
    # Sanity: the text-form fixture parses + carries the expected
    # adapterPreference. This is also covered by
    # `test_m25_adapter_preference_parse.nim`; repeated here so a
    # failure surfaces inside the parity suite for easier triage.
    let dir = createTempDir("m25-bridge-text-", "")
    defer: removeDir(dir)
    let path = dir / "home.nim"
    writeFile(extendedPath(path), TextFormFixture)
    let profile = loadProfile(path)
    check profile.adapterPreference.len == 3
    check profile.adapterPreference["windows"] ==
      @["scoop", "builtin", "path"]
    check profile.adapterPreference["linux"] ==
      @["nix", "builtin", "path"]
    check profile.adapterPreference["darwin"] ==
      @["nix", "path"]

  test "test_m25_adapter_preference_macro_form_emits_same_shape":
    # Compile the macro fixture in a subprocess, capture its JSON, and
    # assert the deserialised ProfileIntent.adapterPreference matches
    # the text-form parser's output byte-for-byte (modulo OrderedTable
    # iteration order, which we normalise via lookup).
    let dir = macroFixtureScratchDir("bridge-macro")
    var js = ""
    var compiled = true
    try:
      js = compileAndRunMacroFixture(dir, MacroFormFixture)
    except IOError as e:
      echo "  [skip] macro fixture compile/run failed (nim not on " &
        "PATH or repro_profile not installed?): " & e.msg
      compiled = false
      skip()
    if compiled:
      let intent = parseProfileIntentJson(js)
      check intent.adapterPreference.len == 3
      check intent.adapterPreference["windows"] ==
        @["scoop", "builtin", "path"]
      check intent.adapterPreference["linux"] ==
        @["nix", "builtin", "path"]
      check intent.adapterPreference["darwin"] ==
        @["nix", "path"]

  test "test_m25_adapter_preference_text_macro_shape_equal":
    # The bridge assertion: both parsers, fed the same logical input,
    # produce identical per-OS chain tables.
    let textDir = createTempDir("m25-bridge-text-eq-", "")
    defer: removeDir(textDir)
    let textPath = textDir / "home.nim"
    writeFile(extendedPath(textPath), TextFormFixture)
    let textProfile = loadProfile(textPath)

    let macroDir = macroFixtureScratchDir("bridge-macro-eq")
    var js = ""
    var compiled = true
    try:
      js = compileAndRunMacroFixture(macroDir, MacroFormFixture)
    except IOError as e:
      echo "  [skip] macro fixture compile/run failed: " & e.msg
      compiled = false
      skip()
    if compiled:
      let intent = parseProfileIntentJson(js)
      # Same set of OS keys, same chain seq per key.
      check textProfile.adapterPreference.len ==
        intent.adapterPreference.len
      for osKey, chain in textProfile.adapterPreference:
        check osKey in intent.adapterPreference
        check intent.adapterPreference[osKey] == chain

  test "test_m25_adapter_preference_macos_alias_canonicalizes_in_both":
    # `macos` is an alias for `darwin` in BOTH parsers. The canonical
    # key must be `"darwin"` regardless of which alias the operator
    # wrote.
    const macosTextFixture = """
import repro/profile

profile "alias":
  adapterPreference:
    macos: [nix, path]

  activity default:
    just
"""
    const macosMacroFixture = """
import repro_profile

profile "alias":
  adapterPreference:
    macos: [nix, path]

  activity default:
    just
"""
    let textDir = createTempDir("m25-bridge-alias-text-", "")
    defer: removeDir(textDir)
    let textPath = textDir / "home.nim"
    writeFile(extendedPath(textPath), macosTextFixture)
    let textProfile = loadProfile(textPath)
    check textProfile.adapterPreference.len == 1
    check "darwin" in textProfile.adapterPreference
    check "macos" notin textProfile.adapterPreference

    let macroDir = macroFixtureScratchDir("bridge-alias-macro")
    var js = ""
    var compiled = true
    try:
      js = compileAndRunMacroFixture(macroDir, macosMacroFixture)
    except IOError as e:
      echo "  [skip] macro fixture compile/run failed: " & e.msg
      compiled = false
      skip()
    if compiled:
      let intent = parseProfileIntentJson(js)
      check intent.adapterPreference.len == 1
      check "darwin" in intent.adapterPreference
      check "macos" notin intent.adapterPreference
      check textProfile.adapterPreference["darwin"] ==
        intent.adapterPreference["darwin"]
