## ``repro lock refresh`` refuses to write a lock from a solve that could not
## reach a develop-set sibling's recipe, instead of writing one the next build
## in a complete workspace refuses.
##
## Issue: reprobuild-pm/issues/2026-10-12-lock-refresh-grounds-a-package-at-
## the-root-floor-so-the-writer-cannot-produce-a-lock-the-checker-accepts.md.
##
## THE DEFECT. A recipe's ``uses:`` selectors pull sibling recipes into the
## solve transitively (``foldProviderSolverInputs``). A sibling that is not on
## disk where the refresh runs was skipped in silence, so its declared ranges
## never reached the solve: the lock fell to the floors of the recipes that
## WERE reachable, while ``deps`` still carried the sibling's pin forward
## (Unified-Locking-And-Hooks.md §14.3). The lock looked complete and was a
## partial solve. The next build in a complete workspace saw the sibling's
## stricter floor and refused with ``ELockConflict`` — and its message told
## the reader to run ``repro lock refresh``, the command that wrote the lock.
##
## Fixture (built ``./build/bin/repro``, black-box), three git repos side by
## side with no workspace manifest, so the develop set is the one the
## committed lock records (the standalone-clone / CI case):
##
##   <scratch>/
##     consumer/  package consumer   uses: "cargo >=1", "mid"
##     mid/       package mid_pkg    uses: "leaf"
##     leaf/      package leaf_pkg   uses: "cargo >=1.85"
##
## ``leaf`` is reached only TRANSITIVELY, through ``mid`` — the issue's shape,
## where ``isonim-gpui`` was the sole declarer of ``cargo >=1.85``.
##
## Asserts:
##   1. Complete workspace: refresh pins ``cargo = 1.85.0`` and records
##      ``leaf_pkg`` (the evidence the solve saw leaf's recipe) and ``../leaf``.
##   2. ``leaf`` moved away: refresh exits ``5``, leaves the committed lock
##      byte-identical, and names ``leaf`` and the ``mid`` recipe that uses it.
##   3. Same tree, ``repro lock solve`` (which does not write): exit 0, the
##      same finding printed as a warning, the lock still byte-identical.
##   4. Positive control: ``leaf`` checked out again but carrying NO recipe —
##      a checkout that declares no constraints drops none — refresh exits 0
##      and prints no refusal. Without this, a check that refused on every
##      undiscovered selector would pass (2).
##
## A second case, ``t_a_sibling_outside_the_enabled_project_still_counts``,
## puts the same three repos inside a workspace whose ENABLED project includes
## ``consumer`` and ``mid`` but not ``leaf`` — the shape that produced the
## issue's bad lock, where ``codetracer``'s project was enabled and the one
## containing ``isonim-gpui`` was not. The resolved membership then contains no
## ``leaf`` at all, so a develop set read off the resolved ``depends`` closure
## alone is blind to the one sibling that matters:
##
##   5. Complete: refresh exits 0 with ``cargo = 1.85.0``.
##   6. ``leaf`` moved away and NO committed lock: refresh still exits ``5`` and
##      creates no lock, because ``consumer``'s manifest ``depends`` names it.
##   7. The ``depends`` edge removed, the complete lock restored: exits ``5``,
##      lock byte-identical, because the committed lock pins ``leaf``.
##
## Falsifiability: on the unfixed code (2) exits 0, rewrites the lock with
## ``cargo = 1.0.0`` and drops ``leaf_pkg``, so the exit-code and
## byte-identity checks both fail; (3) prints no warning. A develop set taken from the resolved membership alone
## (the first version of this fix) passes the first case and exits 0 at (6)
## and (7), writing the floor lock — measured.
##
## Test-double policy: NO mocks, doubles, or fakes — real git repositories,
## the real built ``repro`` binary, real provider compiles and real solves.
##
## Hermetic: every git repo lives in a fresh tempdir; nothing touches $HOME.
## Skip rule: ``git`` missing on PATH, repro unbuilt, or no
## ``reprobuild-packages`` checkout to resolve the plain ``cargo`` tool use
## against (the refresh needs a catalog for a selector that names no sibling).

import std/[os, osproc, strutils, unittest]
import repro_lock
import repro_test_support
import repro_test_support/reasoned_skip
import repro_workspace_manifests

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  ## The reprobuild checkout root, from THIS SOURCE FILE's path rather than
  ## the working directory (see t_lock_refresh_folds_uses_sibling_producer_deps
  ## for why the working directory must not be a fixture input).
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const RefusalExitCode = 5
  ## The refresh's "a develop-set sibling's recipe is unreachable" refusal.
  ## 1 (generic failure), 2 (usage), 3 (UNSAT) and 4 (pin regression) are the
  ## verb's other codes; a distinct one lets a caller tell this apart.

const consumerRecipe = """
import repro_project_dsl

package consumer:
  defaultToolProvisioning "path"
  uses:
    "cargo >=1"
    "mid"
  build:
    discard aggregate("consumer-aggregate", actions = @[])
"""

const midRecipe = """
import repro_project_dsl

package mid_pkg:
  library mid
  defaultToolProvisioning "path"
  uses:
    "leaf"
  build:
    discard aggregate("mid-aggregate", actions = @[])
"""

const leafRecipe = """
import repro_project_dsl

package leaf_pkg:
  library leaf
  defaultToolProvisioning "path"
  uses:
    "cargo >=1.85"
  build:
    discard aggregate("leaf-aggregate", actions = @[])
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc initRepoWith(gitBin, dir, recipe: string; origin = "") =
  ## A git repo at ``dir`` whose single commit carries ``recipe`` as its
  ## ``repro.nim`` (or no recipe at all when ``recipe`` is empty). With
  ## ``origin``, a bare repository is created there, registered as ``origin``
  ## and the commit is pushed to it (a workspace member needs a remote).
  createDir(dir)
  check git(gitBin, "", "init -q -b main " & q(dir)).code == 0
  if origin.len > 0:
    check git(gitBin, "", "init -q --bare -b main " & q(origin)).code == 0
    check git(gitBin, dir, "remote add origin " & q(fileUrl(origin))).code == 0
  check git(gitBin, dir, "config user.email t@example.invalid").code == 0
  check git(gitBin, dir, "config user.name Tester").code == 0
  if recipe.len > 0:
    writeFile(dir / "repro.nim", recipe)
  else:
    writeFile(dir / "README", "a sibling that declares no constraints\n")
  check git(gitBin, dir, "add -A").code == 0
  check git(gitBin, dir, "commit -q -m init").code == 0
  if origin.len > 0:
    check git(gitBin, dir, "push -q -u origin main").code == 0

proc lockedVersion(lockBody, package: string): string =
  for pkg in parseSolvedGraphLock(lockBody).packages:
    if pkg.name == package: return pkg.version
  ""

proc fragment(name: string; depends: seq[string]): string =
  ## A workspace repo fragment for ``name`` at ``<workspace>/<name>``.
  result = "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
    "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
    "remote = \"" & name & "-origin\"\nrevision = \"main\"\n"
  if depends.len > 0:
    result.add("depends = [")
    for i, d in depends:
      if i > 0: result.add(", ")
      result.add("\"" & d & "\"")
    result.add("]\n")

proc packagesRoot(): string =
  ## A ``reprobuild-packages`` checkout for the plain ``cargo`` tool use: the
  ## caller's ``REPROBUILD_PACKAGES_ROOT`` when set, else the workspace sibling
  ## of this reprobuild checkout. "" when neither exists.
  let fromEnv = getEnv("REPROBUILD_PACKAGES_ROOT")
  if fromEnv.len > 0 and dirExists(fromEnv): return fromEnv
  let sibling = ReprobuildRepoRoot.parentDir() / "reprobuild-packages"
  if dirExists(sibling): return sibling
  ""

suite "lock refresh refuses a solve missing a develop-set sibling's recipe":

  test "t_lock_refresh_refuses_a_solve_missing_a_develop_sibling_recipe":
    let gitBin = findExe("git")
    let catalog = packagesRoot()
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real sibling repositories")
    elif not fileExists(reproBinary):
      skip("build/bin/repro is not built; this case drives the real CLI")
    elif catalog.len == 0:
      skip("no reprobuild-packages checkout (set REPROBUILD_PACKAGES_ROOT); " &
        "the refresh resolves the plain `cargo` tool use against it")
    else:
      let hadCatalogEnv = existsEnv("REPROBUILD_PACKAGES_ROOT")
      let oldCatalogEnv = getEnv("REPROBUILD_PACKAGES_ROOT")
      putEnv("REPROBUILD_PACKAGES_ROOT", catalog)
      defer:
        if hadCatalogEnv: putEnv("REPROBUILD_PACKAGES_ROOT", oldCatalogEnv)
        else: delEnv("REPROBUILD_PACKAGES_ROOT")
      let scratch = getTempDir() / ("lock-refresh-missing-sibling-" &
        $getCurrentProcessId())
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      let consumer = scratch / "consumer"
      let mid = scratch / "mid"
      let leaf = scratch / "leaf"
      # Parked OUTSIDE the walk-up path of every recipe: sibling discovery
      # probes ``<ancestor>/leaf`` at each level above ``mid``, never
      # ``<scratch>/parked/leaf``.
      let parked = scratch / "parked"
      initRepoWith(gitBin, consumer, consumerRecipe)
      initRepoWith(gitBin, mid, midRecipe)
      initRepoWith(gitBin, leaf, leafRecipe)
      let lockPath = consumer / "repro.lock"

      # ---- (1) complete workspace: leaf's floor reaches the solve. ----------
      let full = run(q(reproBinary) & " lock refresh " & q(consumer))
      checkpoint("complete refresh exit=" & $full.code)
      checkpoint(full.output)
      require full.code == 0
      let completeLock = readFile(lockPath)
      check lockedVersion(completeLock, "cargo") == "1.85.0"
      check lockedVersion(completeLock, "leaf_pkg").len > 0
      check "{ name = \"leaf\"," in completeLock
      check "{ name = \"mid\"," in completeLock

      # ---- (2) leaf not checked out: the refresh refuses, writing nothing. --
      createDir(parked)
      moveDir(leaf, parked / "leaf")
      let narrow = run(q(reproBinary) & " lock refresh " & q(consumer))
      checkpoint("narrow refresh exit=" & $narrow.code)
      checkpoint(narrow.output)
      check narrow.code == RefusalExitCode
      # Byte-identical: not "equivalent", not "re-serialized the same".
      check readFile(lockPath) == completeLock
      # Names the missing sibling, the recipe whose `uses:` reaches it, and
      # the remedy.
      check "'leaf'" in narrow.output
      check mid / "repro.nim" in narrow.output
      check "not checked out" in narrow.output
      check "repro sync" in narrow.output

      # ---- (3) the non-writing solve reports the same finding as a warning. -
      let solve = run(q(reproBinary) & " lock solve " & q(consumer))
      checkpoint("solve exit=" & $solve.code)
      checkpoint(solve.output)
      check solve.code == 0
      check "warning" in solve.output
      check "'leaf'" in solve.output
      check readFile(lockPath) == completeLock

      # ---- (4) control: a recipe-less leaf checkout is not a dropped solve. -
      # It is named by mid's `uses:` and is in the lock's develop set, but it
      # declares no constraints, so a solve without it loses nothing.
      initRepoWith(gitBin, leaf, "")
      let recipeless = run(q(reproBinary) & " lock refresh " & q(consumer))
      checkpoint("recipe-less sibling refresh exit=" & $recipeless.code)
      checkpoint(recipeless.output)
      check recipeless.code == 0
      check "not checked out" notin recipeless.output
      check "could not reach" notin recipeless.output

  test "t_a_sibling_outside_the_enabled_project_still_counts":
    let gitBin = findExe("git")
    let catalog = packagesRoot()
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real sibling repositories")
    elif not fileExists(reproBinary):
      skip("build/bin/repro is not built; this case drives the real CLI")
    elif catalog.len == 0:
      skip("no reprobuild-packages checkout (set REPROBUILD_PACKAGES_ROOT); " &
        "the refresh resolves the plain `cargo` tool use against it")
    else:
      let hadCatalogEnv = existsEnv("REPROBUILD_PACKAGES_ROOT")
      let oldCatalogEnv = getEnv("REPROBUILD_PACKAGES_ROOT")
      putEnv("REPROBUILD_PACKAGES_ROOT", catalog)
      defer:
        if hadCatalogEnv: putEnv("REPROBUILD_PACKAGES_ROOT", oldCatalogEnv)
        else: delEnv("REPROBUILD_PACKAGES_ROOT")
      let scratch = getTempDir() / ("lock-refresh-inactive-sibling-" &
        $getCurrentProcessId())
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)
      let workspace = scratch / "workspace"
      createDir(workspace)
      let consumer = workspace / "consumer"
      let leaf = workspace / "leaf"
      let parked = scratch / "parked"
      for (name, recipe) in [("consumer", consumerRecipe), ("mid", midRecipe),
                             ("leaf", leafRecipe)]:
        initRepoWith(gitBin, workspace / name, recipe,
          origin = scratch / ("origin-" & name & ".git"))

      # The enabled project includes consumer and mid only; leaf's fragment
      # exists (as every repo's does in a real manifest) but is not included.
      createDir(workspace / "projects")
      createDir(workspace / "repos")
      var project = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"app\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n"
      for name in ["consumer", "mid", "leaf"]:
        project.add("[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
          fileUrl(scratch / ("origin-" & name & ".git")) & "\"\n\n")
      project.add("includes = [\n  \"repos/consumer.toml\",\n" &
        "  \"repos/mid.toml\",\n]\n")
      writeFile(workspace / "projects" / "app.toml", project)
      writeFile(workspace / "repos" / "consumer.toml",
        fragment("consumer", @["mid", "leaf"]))
      writeFile(workspace / "repos" / "mid.toml", fragment("mid", @[]))
      writeFile(workspace / "repos" / "leaf.toml", fragment("leaf", @[]))
      writeWorkspaceBranch(workspace, project = "app", branch = "main")
      let lockPath = consumer / "repro.lock"

      # ---- (5) complete: leaf is checked out, its floor reaches the solve. --
      let full = run(q(reproBinary) & " lock refresh " & q(consumer))
      checkpoint("complete refresh exit=" & $full.code)
      checkpoint(full.output)
      require full.code == 0
      let completeLock = readFile(lockPath)
      check lockedVersion(completeLock, "cargo") == "1.85.0"
      check "{ name = \"leaf\"," in completeLock

      # ---- (6) leaf away, no committed lock: the manifest edge declares it. -
      createDir(parked)
      moveDir(leaf, parked / "leaf")
      removeFile(lockPath)
      let byManifest = run(q(reproBinary) & " lock refresh " & q(consumer))
      checkpoint("manifest-only refresh exit=" & $byManifest.code)
      checkpoint(byManifest.output)
      check byManifest.code == RefusalExitCode
      check not fileExists(lockPath)
      check "'leaf'" in byManifest.output
      check "not checked out" in byManifest.output

      # ---- (7) edge removed, lock restored: the lock's pin declares it. -----
      writeFile(workspace / "repos" / "consumer.toml",
        fragment("consumer", @["mid"]))
      writeFile(lockPath, completeLock)
      let byLock = run(q(reproBinary) & " lock refresh " & q(consumer))
      checkpoint("lock-only refresh exit=" & $byLock.code)
      checkpoint(byLock.output)
      check byLock.code == RefusalExitCode
      check readFile(lockPath) == completeLock
      check "'leaf'" in byLock.output
