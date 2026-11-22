## A pre-push gate run in a clone that is not part of a workspace, and whose
## committed `repro.lock` pins siblings that are not checked out beside it,
## refuses BEFORE it derives anything from the recipe, saying the push needs
## a workspace and naming a remedy that works there
## (Unified-Locking-And-Hooks.md §13.5, "Outside a workspace, with siblings
## absent"; Interactive-UX-And-Progress.md: every refusal names a remedy that
## works).
##
## THE DEFECT: the pre-push check in a clone without its sibling checkouts
## failed inside an interface compile instead of asking for a workspace. A
## codetracer clone made outside any workspace ran
## the gate on `git push`. Stage 3d compiled the recipe to derive its
## dependency set, the compile could not find the siblings the recipe reads,
## and the refusal was `committed_lock_dependency_set_unverified` with a Nim
## compiler error as evidence and `repro lock refresh` as the remedy, which
## fails the same way. The session concluded that the gate cannot pass in a
## bare clone and parked the commit as a bundle.
##
## Fixture (built `./build/bin/repro`, black-box; real git, real recipes,
## real provider compiles):
##
##   <scratch>/siblings/app     repro.nim: `uses: "lib-b"`, and it imports
##                              `../lib-b/lib_b_contract`; lock pins lib-b
##   <scratch>/siblings/lib-b   a library recipe and that contract module
##   <scratch>/alone/app        a clone of app's origin, nothing beside it
##
## Case 3 builds its own (`buildCatalogFixture`):
##
##   <scratch>/siblings/reprobuild-packages  a catalog defining one package
##   <scratch>/siblings/tool-user            `uses:` that package; its lock
##                                           pins the catalog
##   <scratch>/alone/tool-user               a clone of it, nothing beside it
##
## No directory carries workspace metadata, so every gate run here is a
## committed-lock-only run of a repository that is not part of a workspace.
##
## Cases:
##
##   1. `t_a_clone_with_its_siblings_beside_it_passes` (control) — the gate
##      run in `siblings/app`, where `../lib-b` is checked out the way CI's
##      `clone-siblings` places it, passes. Outside a workspace is not in
##      itself a reason to refuse.
##   2. `t_a_clone_without_its_siblings_is_told_it_needs_a_workspace` — the
##      gate run in `alone/app` refuses with `pre_push_needs_workspace` and
##      nothing else: no `committed_lock_dependency_set_unverified` and no
##      `committed_lock_dependency_set_stale`. The evidence names lib-b and
##      where it was looked for; the remedy names `repro workspace init` and
##      `repro ws enable`, and does not name `repro lock refresh` (which
##      cannot help here). The recipe was not compiled: its import of a
##      module from the absent lib-b would fail the provider compile with
##      `cannot open file`, which is the shape of the issue's evidence, and
##      nothing in the gate's output carries a compiler error. Then lib-b is
##      cloned beside it, and the same push passes.
##   3. `t_a_clone_whose_only_absent_pin_is_the_catalog_passes` (control) —
##      a clone whose lock pins only the `reprobuild-packages` catalog, with
##      no catalog checked out beside it, passes. The catalog pin is not a
##      sibling the derivation needs: the recipe compile materializes the
##      pinned revision under `.repro/cross-repo-producers/`
##      (Provisioning-Contributions.md §"Lookup"), so refusing here would turn
##      a push that derives its set truthfully into "needs a workspace".
##
## Falsifiability: against reprobuild `c09f5d8b96` (unfixed) case 2 fails —
## measured with the binary built from that commit and run from
## `build/bin`, the refusal is `committed_lock_dependency_set_unverified`,
## its evidence is the provider compile's
## `cannot open file: ../lib-b/lib_b_contract`, and its remedy is
## `repro lock refresh`, which fails the same way. A hand-built clone of
## case 3's shape passes the gate of that commit, and the first version of
## this fix refused it with `pre_push_needs_workspace` naming
## `reprobuild-packages`; case 3 guards that regression.
##
## `REPROBUILD_PACKAGES_ROOT` is cleared for case 3's refresh and gate runs:
## when set it is the only place a catalog is looked for, and the case is
## about the catalog the lock pins.
##
## NO MOCKS. Every repository is a real local git repository with a real bare
## origin, every recipe is compiled by the real provider path `repro lock
## refresh` uses. Nothing touches the network.
##
## Skip rule: `git` missing on PATH.

import std/[json, os, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/[reasoned_skip, recipe_dependencies]

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type Fixture = object
  scratch, siblings, alone, reproBin, gitBin: string

proc run(fx: Fixture; cwd: string; args: varargs[string]): string =
  var argv = @[fx.gitBin, "-c", "user.email=tester@example.invalid", "-c",
    "user.name=Gate Tester", "-c", "commit.gpgsign=false"]
  for a in args: argv.add(a)
  let res = runShell(shellCommand(argv), cwd = cwd)
  if res.code != 0:
    raise newException(OSError, argv.join(" ") & " (in " & cwd &
      ") exited " & $res.code & ":\n" & res.output)
  res.output.strip()

proc seedRepo(fx: Fixture; name: string; uses: openArray[string];
    library: bool; extra: proc (dir: string) = nil): string =
  ## A clone at ``siblings/<name>`` of a fresh bare origin, carrying a recipe
  ## that uses ``uses``, committed and published. Returns the origin's path.
  result = fx.scratch / ("origin-" & name & ".git")
  discard fx.run(fx.scratch, "init", "-q", "--bare", "-b", "main", result)
  discard fx.run(fx.scratch, "clone", "-q", fileUrl(result),
    fx.siblings / name)
  let dir = fx.siblings / name
  # The clone of an empty origin is unborn on the host's default branch name.
  discard fx.run(dir, "symbolic-ref", "HEAD", "refs/heads/main")
  writeDependencyRecipe(dir, uses, library = library)
  if extra != nil: extra(dir)
  discard fx.run(dir, "add", "-A")
  discard fx.run(dir, "commit", "-q", "-m", "seed " & name)
  discard fx.run(dir, "push", "-q", "origin", "HEAD:main")

proc buildFixture(): Fixture =
  result.gitBin = findExe("git")
  result.reproBin = reproBinary()
  result.scratch = createTempDir("repro-pre-push-needs-workspace-", "")
  result.siblings = result.scratch / "siblings"
  result.alone = result.scratch / "alone"
  createDir(result.siblings)
  createDir(result.alone)
  # The contract module app's recipe imports from its sibling, the way a
  # recipe reads a sibling's sources: present beside app, the provider
  # compiles; absent, the compile cannot open it.
  discard result.seedRepo("lib-b", [], library = true,
    extra = proc (dir: string) =
      writeFile(dir / "lib_b_contract.nim",
        "## What app's recipe reads from lib-b.\n"))
  let appOrigin = result.seedRepo("app", ["lib-b"], library = false,
    extra = proc (dir: string) =
      let recipe = readFile(dir / "repro.nim")
      writeFile(dir / "repro.nim", recipe.replace(
        "import repro_project_dsl\n",
        "import repro_project_dsl\nimport \"../lib-b/lib_b_contract\"\n")))
  let app = result.siblings / "app"
  let refresh = refreshCommittedLock(result.reproBin, app)
  if refresh.code != 0:
    raise newException(OSError, "repro lock refresh in " & app &
      " exited " & $refresh.code & ":\n" & refresh.output)
  if "lib-b" notin readFile(app / "repro.lock"):
    raise newException(OSError, "the refreshed lock does not pin lib-b:\n" &
      readFile(app / "repro.lock"))
  discard result.run(app, "add", "-A")
  discard result.run(app, "commit", "-q", "-m", "pin lib-b")
  discard result.run(app, "push", "-q", "origin", "HEAD:main")
  # The clone the issue describes: app alone, nothing beside it.
  discard result.run(result.alone, "clone", "-q", fileUrl(appOrigin),
    result.alone / "app")

const CatalogPackageInterface = """
import repro_project_dsl

package rpneedsworkspacefixture:
  provisioning:
    tarball url = "https://example.invalid/rpneedsworkspacefixture-1.0.zip",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip",
      executablePath = "rpneedsworkspacefixture",
      packageId = "rpneedsworkspacefixture@1.0",
      lockIdentity = "tarball:rpneedsworkspacefixture@1.0:sha256:0000000000000000000000000000000000000000000000000000000000000000"
"""
  ## A package only the fixture catalog defines, so the consumer's `uses:`
  ## resolves through the catalog and its refreshed lock pins it.

const NoCatalogRootEnv = [("REPROBUILD_PACKAGES_ROOT", "")]
  ## Empty is unset for the lookup (it tests `.len > 0`).

proc buildCatalogFixture(): Fixture =
  ## Case 3: a consumer whose lock pins the `reprobuild-packages` catalog and
  ## nothing else, refreshed beside a catalog checkout, then cloned alone.
  result.gitBin = findExe("git")
  result.reproBin = reproBinary()
  result.scratch = createTempDir("repro-pre-push-catalog-pin-", "")
  result.siblings = result.scratch / "siblings"
  result.alone = result.scratch / "alone"
  createDir(result.siblings)
  createDir(result.alone)
  # The origin's leaf names the repository: a lock records a dependency
  # under the name its URL gives.
  let origins = result.scratch / "origins"
  createDir(origins)
  for name in ["reprobuild-packages", "tool-user"]:
    discard result.run(result.scratch, "init", "-q", "--bare", "-b", "main",
      origins / (name & ".git"))
    discard result.run(result.scratch, "clone", "-q",
      fileUrl(origins / (name & ".git")), result.siblings / name)
    discard result.run(result.siblings / name, "symbolic-ref", "HEAD",
      "refs/heads/main")
  let catalog = result.siblings / "reprobuild-packages"
  let iface = catalog / "packages" / "interfaces" / "rpneedsworkspacefixture"
  createDir(iface)
  writeFile(iface / "repro.nim", CatalogPackageInterface)
  discard result.run(catalog, "add", "-A")
  discard result.run(catalog, "commit", "-q", "-m", "seed catalog")
  discard result.run(catalog, "push", "-q", "origin", "HEAD:main")
  let user = result.siblings / "tool-user"
  writeDependencyRecipe(user, ["rpneedsworkspacefixture"], library = false)
  let refresh = runShell(shellCommand(@[result.reproBin, "lock", "refresh"],
    @[("REPROBUILD_NO_RUNQUOTA", "1")] & @NoCatalogRootEnv), cwd = user)
  if refresh.code != 0:
    raise newException(OSError, "repro lock refresh in " & user &
      " exited " & $refresh.code & ":\n" & refresh.output)
  let lock = readFile(user / "repro.lock")
  if "\"reprobuild-packages\"" notin lock:
    raise newException(OSError, "the refreshed lock does not pin the " &
      "catalog:\n" & lock)
  discard result.run(user, "add", "-A")
  discard result.run(user, "commit", "-q", "-m", "use a catalog package")
  discard result.run(user, "push", "-q", "origin", "HEAD:main")
  discard result.run(result.alone, "clone", "-q",
    fileUrl(origins / "tool-user.git"), result.alone / "tool-user")

proc runGate(fx: Fixture; repo: string;
    env: openArray[tuple[name, value: string]] = []):
    tuple[code: int; report: JsonNode; output: string] =
  ## The gate as the managed hook runs it in a checkout that is its own
  ## workspace root (no workspace metadata anywhere above it).
  let head = fx.run(repo, "rev-parse", "HEAD")
  let refsFile = fx.scratch / "pushed-refs.txt"
  writeFile(refsFile, "refs/heads/main " & head &
    " refs/heads/main 0000000000000000000000000000000000000000\n")
  let res = runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push",
    "--workspace-root=" & repo,
    "--current-repo=" & repo,
    "--pushed-refs=" & refsFile,
    "--json",
  ], @[("REPROBUILD_NO_RUNQUOTA", "1")] & @env), cwd = repo)
  checkpoint("gate in " & repo & " exited " & $res.code & ":\n" & res.output)
  let start = res.output.find('{')
  if start < 0:
    return (res.code, newJObject(), res.output)
  (res.code, parseJson(res.output[start .. ^1]), res.output)

proc properties(report: JsonNode): seq[string] =
  if report.hasKey("failures"):
    for f in report["failures"]: result.add(f["property"].getStr())

proc failureOf(report: JsonNode; property: string): JsonNode =
  if report.hasKey("failures"):
    for f in report["failures"]:
      if f["property"].getStr() == property: return f
  newJNull()

suite "a pre-push gate outside a workspace asks for one":

  test "t_a_clone_with_its_siblings_beside_it_passes":
    if findExe("git").len == 0:
      skip("git is not on PATH")
    else:
      let fx = buildFixture()
      defer: removeDir(fx.scratch)
      let green = fx.runGate(fx.siblings / "app")
      check green.code == 0
      check green.report.properties.len == 0

  test "t_a_clone_without_its_siblings_is_told_it_needs_a_workspace":
    if findExe("git").len == 0:
      skip("git is not on PATH")
    else:
      let fx = buildFixture()
      defer: removeDir(fx.scratch)
      let clone = fx.alone / "app"
      check "lib_b_contract" in readFile(clone / "repro.nim")

      let refused = fx.runGate(clone)
      check refused.code == 2
      check refused.report.properties == @["pre_push_needs_workspace"]
      check "committed_lock_dependency_set_unverified" notin
        refused.report.properties
      check "committed_lock_dependency_set_stale" notin
        refused.report.properties
      let f = refused.report.failureOf("pre_push_needs_workspace")
      require f.kind == JObject
      let evidence = f["evidence"].getStr()
      let remedy = f["remediation"].getStr()
      check evidence.contains("lib-b")
      check evidence.contains(fx.alone / "lib-b")
      check evidence.contains("not part of a workspace")
      check remedy.contains("repro workspace init")
      check remedy.contains("repro ws enable")
      check not remedy.contains("repro lock refresh")
      # Refused before deriving: the recipe's import of the absent lib-b
      # would have failed the provider compile, and no compiler error is
      # anywhere in what the gate printed.
      check "cannot open file" notin refused.output
      check "Error:" notin refused.output

      # The second remedy, siblings checked out beside the clone, works.
      discard fx.run(fx.alone, "clone", "-q",
        fileUrl(fx.scratch / "origin-lib-b.git"), fx.alone / "lib-b")
      let green = fx.runGate(clone)
      check green.code == 0
      check green.report.properties.len == 0

  test "t_a_clone_whose_only_absent_pin_is_the_catalog_passes":
    if findExe("git").len == 0:
      skip("git is not on PATH")
    else:
      let fx = buildCatalogFixture()
      defer: removeDir(fx.scratch)
      let clone = fx.alone / "tool-user"
      check "reprobuild-packages" in readFile(clone / "repro.lock")
      check not dirExists(fx.alone / "reprobuild-packages")
      let green = fx.runGate(clone, NoCatalogRootEnv)
      check green.code == 0
      check green.report.properties.len == 0
      check "pre_push_needs_workspace" notin green.output
