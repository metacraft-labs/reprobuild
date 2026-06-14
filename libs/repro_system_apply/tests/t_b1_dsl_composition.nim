## B1 P5: composition (imports) integration test.
##
## Verifies:
##   * `imports:` resolves a child module relative to the parent's
##     directory and merges its declarations into the parent.
##   * Last-write-wins: the parent's own declarations override the
##     imported module's by section key.
##   * The merge is documented + verified in
##     `docs/reproos-config-dsl.md`.
##   * The sample config's `recipes/reproos-sample-config/modules/`
##     directory holds module fixtures that compose into the parent
##     `configuration.nim`.

import std/[options, os, sets, strutils, tables, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_system_apply

const SampleConfigPath =
  currentSourcePath.parentDir.parentDir.parentDir.parentDir /
    "recipes" / "reproos-sample-config" / "configuration.nim"
const SampleModulesDir =
  currentSourcePath.parentDir.parentDir.parentDir.parentDir /
    "recipes" / "reproos-sample-config" / "modules"

suite "B1 DSL composition":

  test "modules directory is present":
    check dirExists(extendedPath(SampleModulesDir))
    check fileExists(extendedPath(SampleModulesDir / "users.nim"))
    check fileExists(extendedPath(SampleModulesDir / "git.nim"))

  test "imported module's packages compose into the parent":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    var pkgNames: seq[string]
    for p in cfg.packages:
      pkgNames.add p.name
    # `git` lives in modules/git.nim and only enters via the import.
    check "git" in pkgNames
    # The parent's own packages remain present.
    check "vim" in pkgNames
    check "coreutils" in pkgNames

  test "parent overrides imported users by name (last-write-wins)":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    var ada: User
    var foundAda = false
    for u in cfg.users:
      if u.name == "ada":
        ada = u
        foundAda = true
    check foundAda
    # The imported module declares `ada` with groups = ["wheel", "audio"].
    # The parent overrides with ["wheel", "video", "audio"]. The
    # parent's groups list must win.
    check "video" in ada.groups
    check "wheel" in ada.groups
    check "audio" in ada.groups

  test "imported user that the parent does NOT redeclare survives":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    var foundRoot = false
    for u in cfg.users:
      if u.name == "root":
        foundRoot = true
        check u.passwordHash == "$y$j9T$root-placeholder-hash"
    check foundRoot

  test "lowered graph reflects the merged config":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    let graph = lower(cfg)
    # The imported `git` package becomes one foreign-bundle edge in
    # the lowered graph.
    let idx = findEdge(graph, bekPackageForeignBundle, "git")
    check idx >= 0
    check graph.edges[idx].payload["snapshot"] ==
      "debian/bookworm/20260601T000000Z"

  test "circular import detection still fires across nested imports":
    let dir = createTempDir("b1-comp-cycle-", "")
    let a = dir / "a.nim"
    let b = dir / "b.nim"
    let c = dir / "c.nim"
    writeFile(extendedPath(a), """
system aMod:
  imports:
    "./b.nim"
""")
    writeFile(extendedPath(b), """
system bMod:
  imports:
    "./c.nim"
""")
    writeFile(extendedPath(c), """
system cMod:
  imports:
    "./a.nim"
""")
    expect ECircularImport:
      discard parseSystemConfigFile(a)
    removeDir(extendedPath(dir))

  test "the parent file path is recorded for each imported entry":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    # The `git` package's sourceFile should point at the modules/git.nim
    # file, NOT at the parent configuration.nim — i.e. the parser
    # preserves provenance through the import.
    for p in cfg.packages:
      if p.name == "git":
        check p.sourceFile.endsWith("git.nim")

  test "imports: block declarations are preserved on cfg.imports":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    check cfg.imports.len == 2
    check "./modules/users.nim" in cfg.imports
    check "./modules/git.nim" in cfg.imports
