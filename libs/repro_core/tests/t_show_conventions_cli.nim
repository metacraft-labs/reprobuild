## E2E test for ``repro show-conventions``.
##
## The contract is documented in
## ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Observability":
##
##   * ``repro show-conventions`` prints the resolved convention stack
##     for a project: detected targets, the convention claiming each,
##     the scanner-inferred edges, and the manual ``depends_on``
##     overrides.
##   * ``--project=PATH`` overrides the workspace root.
##   * ``--target=NAME`` filters output to a single target.
##   * ``--json`` emits JSON instead of human-readable text.
##
## We spawn the real ``build/bin/repro.exe`` and assert on its exit
## codes + stdout content. The text-extractor of manual deps is unit-
## tested in ``t_show_conventions_manual_deps.nim``; this test covers
## the CLI plumbing.

import std/[json, os, osproc, strutils, tables, unittest]

const ReproBinaryRel = "build/bin/repro.exe"

proc findReproBinary(): string =
  ## Walk up from the cwd until we find ``build/bin/repro.exe``. Same
  ## heuristic as ``t_deps_refresh_check.nim``.
  var dir = getCurrentDir()
  while dir.len > 0:
    let candidate = dir / ReproBinaryRel
    if fileExists(candidate):
      return candidate
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  ""

proc findPilotFixture(): string =
  ## Locate ``reprobuild-examples/nim/mode3-pilot`` from the workspace
  ## root. The harness runs tests from the repo root and the fixture
  ## lives as a sibling checkout under ``../reprobuild-examples``.
  var dir = getCurrentDir()
  while dir.len > 0:
    let candidate = parentDir(dir) / "reprobuild-examples" / "nim" /
      "mode3-pilot"
    if fileExists(candidate / "repro.nim"):
      return candidate
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  ""

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-show-conventions-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc writeTwoPackageFixture(dir: string) =
  ## Synthetic two-package workspace with one manual ``depends_on``
  ## edge so we can assert on the full text-output shape.
  writeFile(dir / "repro.nim", """
import repro_project_dsl

package libPkg:
  uses:
    "nim >=2.2 <3.0"
  library libpkg

package appPkg:
  uses:
    "nim >=2.2 <3.0"
  executable app:
    discard

depends_on appPkg: libPkg
""")
  createDir(dir / "src")
  writeFile(dir / "src" / "libpkg.nim",
    "proc hello*(): string = \"hi\"\n")
  writeFile(dir / "src" / "app.nim", """
import libpkg

echo hello()
""")

let reproBin = findReproBinary()

suite "repro show-conventions: CLI smoke":

  test "build/bin/repro.exe is on disk":
    if reproBin.len == 0:
      skip()
    else:
      check fileExists(reproBin)

  test "synthetic two-package workspace produces expected text shape":
    if reproBin.len == 0:
      skip()
    else:
      let dir = makeScratch("two-package-text")
      writeTwoPackageFixture(dir)
      let (output, exitCode) = execCmdEx(quoteShellCommand(@[
        reproBin, "show-conventions", dir]))
      if exitCode != 0:
        echo "stdout/stderr from show-conventions:\n", output
      check exitCode == 0
      # Mentions the project root + project file.
      check output.contains("Project:")
      check output.contains("Project file: repro.nim")
      # Mentions both targets, with correct package.member labels.
      check output.contains("Target: appPkg.app")
      check output.contains("Target: libPkg.libpkg")
      # The scanner finds the cross-package import edge.
      check output.contains("appPkg") and output.contains("libpkg")
      # Manual depends_on edge appears under the appPkg target.
      check output.contains("Workspace deps (manual")
      check output.contains("libPkg (declared at repro.nim:")
      # The convention registry is listed.
      check output.contains("Conventions registered")
      for name in ["nim", "rust", "go", "python", "javascript-typescript",
          "c-cpp-make", "c-cpp-autotools"]:
        check output.contains(name)
      removeDir(dir)

  test "--json produces parseable JSON with the expected fields":
    if reproBin.len == 0:
      skip()
    else:
      let dir = makeScratch("two-package-json")
      writeTwoPackageFixture(dir)
      let (output, exitCode) = execCmdEx(quoteShellCommand(@[
        reproBin, "show-conventions", "--json", dir]))
      if exitCode != 0:
        echo "stdout/stderr from show-conventions --json:\n", output
      check exitCode == 0
      let doc = parseJson(output)
      check doc.hasKey("project")
      check doc.hasKey("projectFile")
      check doc.hasKey("targets")
      check doc.hasKey("conventions")
      check doc["projectFile"].kind == JObject
      check doc["projectFile"]{"fileName"}.getStr == "repro.nim"
      check doc["projectFile"]{"canonical"}.getBool == true
      check doc["targets"].kind == JArray
      check doc["targets"].len == 2
      var sawAppPkg = false
      var sawLibPkg = false
      for entry in doc["targets"]:
        case entry{"package"}.getStr
        of "appPkg":
          sawAppPkg = true
          check entry{"member"}.getStr == "app"
          check entry{"convention"}.getStr == "nim"
          # Manual depends_on edge captured.
          var sawLibPkgManual = false
          for d in entry{"manualDeps"}:
            if d{"to"}.getStr == "libPkg":
              sawLibPkgManual = true
          check sawLibPkgManual
        of "libPkg":
          sawLibPkg = true
          check entry{"member"}.getStr == "libpkg"
        else:
          discard
      check sawAppPkg
      check sawLibPkg
      check doc["conventions"].kind == JArray
      check doc["conventions"].len == 28
      # First convention is "nim" — pins the dispatch order.
      check doc["conventions"][0].getStr == "nim"
      # c-cpp-autotools must come BEFORE c-cpp-cmake BEFORE c-cpp-meson
      # BEFORE c-cpp-make BEFORE c-cpp-direct in the registry mirror;
      # the order is documented in
      # ``apps/repro-standard-provider/repro_standard_provider.nim``.
      # A project carrying both a Makefile and configure.ac routes
      # through Autotools because it recognise-matches first; a
      # project with a CMakeLists.txt routes through c-cpp-cmake
      # (M38) ahead of the Make convention's defensive reject; a
      # project with a meson.build routes through c-cpp-meson (M39)
      # ahead of the Make convention's defensive reject; a project
      # with a Makefile but no autotools/cmake/meson artefacts routes
      # through Make; only a project with NO Makefile / CMakeLists /
      # configure.ac / meson.build falls through to the Mode 3
      # c-cpp-direct. If this assertion flips the static mirror has
      # drifted from the standard-provider's registration order.
      var autotoolsIdx = -1
      var cmakeIdx = -1
      var mesonIdx = -1
      var makeIdx = -1
      var directIdx = -1
      var rustIdx = -1
      var rustDirectIdx = -1
      var goIdx = -1
      var goDirectIdx = -1
      for i in 0 ..< doc["conventions"].len:
        case doc["conventions"][i].getStr
        of "c-cpp-autotools": autotoolsIdx = i
        of "c-cpp-cmake":     cmakeIdx = i
        of "c-cpp-meson":     mesonIdx = i
        of "c-cpp-make":      makeIdx = i
        of "c-cpp-direct":    directIdx = i
        of "rust":            rustIdx = i
        of "rust-direct":     rustDirectIdx = i
        of "go":              goIdx = i
        of "go-direct":       goDirectIdx = i
        else: discard
      check autotoolsIdx >= 0
      check cmakeIdx >= 0
      check mesonIdx >= 0
      check makeIdx >= 0
      check directIdx >= 0
      check autotoolsIdx < cmakeIdx
      check cmakeIdx < mesonIdx
      check mesonIdx < makeIdx
      check makeIdx < directIdx
      # M30: rust (Mode 2) registered BEFORE rust-direct (Mode 3) so
      # a project with a Cargo.toml routes through the Cargo-driven
      # convention; rust-direct catches the no-Cargo.toml case.
      check rustIdx >= 0
      check rustDirectIdx >= 0
      check rustIdx < rustDirectIdx
      # M31: go (Mode 2) registered BEFORE go-direct (Mode 3) so
      # a project with a go.mod routes through the go-list-driven
      # convention; go-direct catches the no-go.mod case.
      check goIdx >= 0
      check goDirectIdx >= 0
      check goIdx < goDirectIdx
      removeDir(dir)

  test "--target=NAME filters to a single member":
    if reproBin.len == 0:
      skip()
    else:
      let dir = makeScratch("target-filter")
      writeTwoPackageFixture(dir)
      let (output, exitCode) = execCmdEx(quoteShellCommand(@[
        reproBin, "show-conventions", "--target=app", dir]))
      check exitCode == 0
      check output.contains("Target: appPkg.app")
      # libpkg target should NOT appear when filtered.
      check not output.contains("Target: libPkg.libpkg")
      removeDir(dir)

  test "missing workspace root returns non-zero":
    if reproBin.len == 0:
      skip()
    else:
      let nonexistent = getTempDir() / "repro-show-conv-nope-xyz-123"
      let (output, exitCode) = execCmdEx(quoteShellCommand(@[
        reproBin, "show-conventions", nonexistent]))
      check exitCode != 0
      check output.contains("show-conventions") or
        output.contains("does not exist")

  test "mode3-pilot fixture: exits 0 and mentions packages":
    if reproBin.len == 0:
      skip()
    else:
      let pilot = findPilotFixture()
      if pilot.len == 0:
        skip()
      else:
        let (output, exitCode) = execCmdEx(quoteShellCommand(@[
          reproBin, "show-conventions", pilot]))
        if exitCode != 0:
          echo "stdout/stderr from show-conventions:\n", output
        check exitCode == 0
        check output.len > 0
        # The pilot declares one package `mode3Pilot` with two members
        # (greet + hello). Output must mention both names.
        check output.contains("mode3Pilot")
        check output.contains("greet")
        check output.contains("hello")
        # And the convention registry list must appear.
        check output.contains("Conventions registered")

suite "repro show-conventions: registry mirror sanity":

  test "static mirror order matches addDefaultConvention calls in the binary":
    ## Drift pin. ``KnownConventionRegistry`` in
    ## ``libs/repro_cli_support/src/repro_cli_support.nim`` is a static
    ## mirror of the registration order in
    ## ``apps/repro-standard-provider/repro_standard_provider.nim`` (the
    ## CLI doesn't link the per-language plugins, so it can't introspect
    ## ``defaultConventionRegistry`` directly). This test reads both
    ## files as text and asserts the lists match exactly — in name AND
    ## order — so a future PR that registers a new convention without
    ## updating the mirror fails here loudly.
    let reproBin = findReproBinary()
    if reproBin.len == 0:
      skip()
    else:
      # Locate the reprobuild repo root (parent of build/bin/repro.exe).
      var repoRoot = reproBin
      while repoRoot.len > 0 and not fileExists(
          repoRoot / "apps" / "repro-standard-provider" /
          "repro_standard_provider.nim"):
        let parent = parentDir(repoRoot)
        if parent == repoRoot:
          repoRoot = ""
          break
        repoRoot = parent
      check repoRoot.len > 0
      let providerSrc = repoRoot / "apps" / "repro-standard-provider" /
        "repro_standard_provider.nim"
      let cliSrc = repoRoot / "libs" / "repro_cli_support" / "src" /
        "repro_cli_support.nim"
      check fileExists(providerSrc)
      check fileExists(cliSrc)
      # Extract registered convention names (in registration order) from
      # the standard-provider binary. We do this in two passes:
      #
      #   1. Parse ``import repro_standard_provider/conventions/<file>
      #      as <alias>`` lines to build an alias -> filename map. The
      #      filename (e.g. ``c_cpp_autotools``) converted underscore ->
      #      hyphen IS the canonical convention name (the ``name:``
      #      field each plugin sets — verified for all 8 plugins).
      #   2. Walk the ``addDefaultConvention(<alias>.<factory>())`` lines
      #      in source order, resolving each alias to its kebab name.
      #
      # This pin breaks loudly if a future PR adds a convention plugin
      # or reorders registration without updating
      # ``KnownConventionRegistry``.
      const importPrefix = "import repro_standard_provider/conventions/"
      var aliasToKebab: Table[string, string]
      for line in lines(providerSrc):
        let stripped = line.strip()
        if not stripped.startsWith(importPrefix):
          continue
        let asIdx = stripped.find(" as ")
        if asIdx < 0:
          continue
        let pathPart = stripped[importPrefix.len ..< asIdx]
        let alias = stripped[asIdx + " as ".len .. ^1].strip()
        let kebab = pathPart.strip().replace('_', '-')
        aliasToKebab[alias] = kebab
      var registered: seq[string] = @[]
      const addPrefix = "addDefaultConvention("
      for line in lines(providerSrc):
        let stripped = line.strip()
        if not stripped.startsWith(addPrefix):
          continue
        let dotIdx = stripped.find('.')
        if dotIdx < 0:
          continue
        let alias = stripped[addPrefix.len ..< dotIdx].strip()
        if alias in aliasToKebab:
          registered.add(aliasToKebab[alias])
      # Extract the static mirror list from repro_cli_support.nim,
      # between ``KnownConventionRegistry* = [`` and the closing ``]``.
      var mirror: seq[string] = @[]
      var inside = false
      for line in lines(cliSrc):
        let stripped = line.strip()
        if not inside:
          if stripped.startsWith("KnownConventionRegistry") and
              stripped.endsWith("["):
            inside = true
          continue
        if stripped.startsWith("]"):
          break
        # Each entry is ``"<name>",`` on its own line.
        let trimmed = stripped.strip(chars = {',', ' ', '"'})
        if trimmed.len > 0:
          mirror.add(trimmed)
      check registered.len == 28
      check mirror.len == 28
      check registered == mirror
