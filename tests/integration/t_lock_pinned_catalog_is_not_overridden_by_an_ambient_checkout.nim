## A consumer whose committed `repro.lock` pins `reprobuild-packages` builds
## against that pin, not against whatever `reprobuild-packages` checkout
## happens to sit beside it or an ancestor -- and one consumer, and one
## compile, never takes interfaces from two catalog revisions.
##
## reprobuild-pm issue
## `issues/2026-11-12-any-ambient-reprobuild-packages-checkout-beside-the-project-or-an-ancestor-overrides-the.md`:
## the lookup consulted ANY `reprobuild-packages` directory beside the consumer
## or an ancestor BEFORE the lock-pinned catalog, so a stale
## `~/src/reprobuild-packages` silently replaced the pin of every project under
## `~/src`; and a checkout that lacked an interface passed the lookup on to the
## next place, so one graph could mix two catalog revisions.
## Provisioning-Contributions.md §"Catalog Lookup And Provisioning" → "Lookup"
## (amended 2026-11-16) now selects exactly one external catalog per consumer.
##
## Nothing is mocked. The catalog is a real git repository with two commits:
## `Q` (stale: `rppinnedfixture` 0.9 and `rpambientonly`) and `R` (the pin:
## `rppinnedfixture` 1.0 and `rppinnedsecond`; `rpambientonly` deleted). The
## pin is materialized by the production `ensureLockPinnedCatalog`, fetching
## from that repository by its local path; ambient checkouts are real clones
## at `Q`; the compile-time leg runs the real `package` macro under the real
## `nim check`.
##
## Legs (the letters follow the task that introduced the test):
##   a. a stale ambient checkout beside the consumer does not replace the pin;
##   b. an interface the pin lacks is NOT taken from the ambient checkout, and
##      the diagnostic names the checkout it passed over;
##   c. a checkout at the pinned commit IS the pin (detached HEAD, a branch
##      resolved through `packed-refs`, and a linked worktree whose `.git` is
##      a file);
##   d. develop mode substitutes a checkout: the workspace's own declared
##      checkout, a workspace develop override, a project develop override;
##      an override naming a missing checkout selects nothing;
##   e. with no pin, an ambient checkout is still the catalog;
##   f. a catalog inside the consumer's repository still wins per interface;
##   g. `catalogSelectionIdentity` and `ensureLockPinnedCatalog` agree with the
##      lookup in every leg above;
##   h. one compile that would resolve interfaces from two catalog revisions
##      is refused, naming both; the positive control (both locks at `R`)
##      compiles.

import std/[compilesettings, os, osproc, strtabs, strutils, tempfiles,
  unittest]

import repro_cli_support
import repro_project_dsl/reprobuild_packages_catalog

const CompileSearchPaths = querySettingSeq(MultipleValueSetting.searchPaths)
  ## The module search paths this test was compiled with: what a consumer's
  ## `import repro_project_dsl` needs in leg h.

proc interfaceModule(name, version: string): string =
  let zero = repeat('0', 64)
  "import repro_project_dsl\n\n" &
    "package " & name & ":\n" &
    "  provisioning:\n" &
    "    tarball url = \"https://example.invalid/" & name & "-" & version &
    ".zip\",\n" &
    "      sha256 = \"" & zero & "\",\n" &
    "      archiveType = \"zip\",\n" &
    "      executablePath = \"" & name & "\",\n" &
    "      packageId = \"" & name & "@" & version & "\",\n" &
    "      lockIdentity = \"tarball:" & name & "@" & version & ":sha256:" &
    zero & "\"\n"

proc git(repo: string; args: varargs[string]): string =
  var command = quoteShell(findExe("git")) & " -C " & quoteShell(repo)
  for arg in args:
    command.add(" " & quoteShell(arg))
  let execution = execCmdEx(command, options = {poUsePath, poStdErrToStdOut})
  doAssert execution.exitCode == 0, command & "\n" & execution.output
  execution.output.strip()

proc initRepo(dir: string) =
  createDir(dir)
  discard git(dir, "init", "--quiet", "--initial-branch=main",
    "--object-format=sha1", "--template=")
  discard git(dir, "config", "commit.gpgsign", "false")
  discard git(dir, "config", "user.name", "Catalog Fixture")
  discard git(dir, "config", "user.email", "fixture@example.invalid")

proc writeInterface(catalog, name, version: string) =
  let dir = catalog / "packages" / "interfaces" / name
  createDir(dir)
  writeFile(dir / "repro.nim", interfaceModule(name, version))

proc commitAll(repo, message: string): string =
  discard git(repo, "add", "-A")
  discard git(repo, "commit", "--quiet", "--allow-empty", "-m", message)
  git(repo, "rev-parse", "HEAD")

proc writeLock(consumer, url, revision: string) =
  ## A committed lock pinning the catalog at ``revision``, with the
  ## consumer's own self record first, as a real lock has it.
  createDir(consumer)
  writeFile(consumer / "repro.lock",
    "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
    "[lock]\nplatform = \"x86_64-linux\"\npackages = []\n" &
    "deps = [{ name = \"consumer\", path = \".\", coord_kind = \"vcs\", " &
    "url = \"https://example.invalid/consumer.git\", revision = \"" &
    repeat('c', 40) & "\", integrity = \"git-sha1:" & repeat('c', 40) &
    "\", version = \"\", visibility = \"public\", participation = \"\", " &
    "depends = \"reprobuild-packages\", tags = \"\" }, " &
    "{ name = \"reprobuild-packages\", path = \"../reprobuild-packages\", " &
    "coord_kind = \"vcs\", url = " & escape(url) &
    ", revision = " & escape(revision) &
    ", integrity = " & escape("git-sha1:" & revision) &
    ", version = \"\", visibility = \"public\", participation = \"\", " &
    "depends = \"\", tags = \"\" }]\n")

proc makeConsumer(dir: string; url = ""; revision = ""): string =
  ## A consumer repository with a recipe, pinning the catalog when
  ## ``revision`` is given. Returns the recipe path.
  initRepo(dir)
  writeFile(dir / "repro.nim", "discard\n")
  if revision.len > 0:
    writeLock(dir, url, revision)
  discard commitAll(dir, "consumer")
  dir / "repro.nim"

proc cloneAt(upstream, dest, revision: string) =
  createDir(dest.parentDir)
  let execution = execCmdEx(quoteShell(findExe("git")) & " clone --quiet " &
    quoteShell(upstream) & " " & quoteShell(dest),
    options = {poUsePath, poStdErrToStdOut})
  doAssert execution.exitCode == 0, execution.output
  discard git(dest, "checkout", "--quiet", "--detach", revision)

proc materialized(consumer, revision: string): string =
  consumer / ".repro" / "cross-repo-producers" / "reprobuild-packages" /
    revision

proc moduleIn(catalog, name: string): string =
  catalog / "packages" / "interfaces" / name / "repro"

proc nimCheck(consumer: string): tuple[output: string, exitCode: int] =
  var parts = @[findExe("nim").quoteShell, "check", "--hints:off",
    "--warnings:off",
    ("--nimcache:" & consumer.parentDir / "nimcache").quoteShell]
  for path in CompileSearchPaths:
    parts.add(("--path:" & path).quoteShell)
  parts.add(consumer.quoteShell)
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key notin [ReprobuildPackagesRootEnv, LockedCatalogEnv,
        "REPRO_WORKSPACE_CONFIG"]:
      env[key] = value
  execCmdEx(parts.join(" "), options = {poStdErrToStdOut}, env = env)

# The variables that would select a catalog, or a workspace, behind the
# fixture's back; and a git configuration of the fixture's own.
for name in [ReprobuildPackagesRootEnv, LockedCatalogEnv,
    "REPRO_WORKSPACE_CONFIG"]:
  delEnv(name)
var gitEnvironment: seq[string] = @[]
for key, _ in envPairs():
  if key.startsWith("GIT_"):
    gitEnvironment.add(key)
for key in gitEnvironment:
  delEnv(key)

let scratch = createTempDir("repro-ambient-catalog-", "")
writeFile(scratch / "empty.gitconfig", "")
putEnv("GIT_CONFIG_GLOBAL", scratch / "empty.gitconfig")
putEnv("GIT_CONFIG_NOSYSTEM", "1")

# The catalog's history: Q is the stale revision, R the pinned one.
let upstream = scratch / "upstream" / "reprobuild-packages"
initRepo(upstream)
writeFile(upstream / "repro.nim", "discard\n")
writeInterface(upstream, "rppinnedfixture", "0.9")
writeInterface(upstream, "rpambientonly", "0.9")
let staleRevision = commitAll(upstream, "Q: the stale catalog")
writeInterface(upstream, "rppinnedfixture", "1.0")
writeInterface(upstream, "rppinnedsecond", "1.0")
removeDir(upstream / "packages" / "interfaces" / "rpambientonly")
let pinnedRevision = commitAll(upstream, "R: the pinned catalog")

suite "a lock-pinned catalog is not overridden by an ambient checkout":

  test "a: a stale checkout beside the consumer does not replace the pin":
    let src = scratch / "a" / "src"
    let recipe = makeConsumer(src / "consumer", upstream, pinnedRevision)
    cloneAt(upstream, src / "reprobuild-packages", staleRevision)
    let pinned = materialized(src / "consumer", pinnedRevision)
    check ensureLockPinnedCatalog(recipe, src / "consumer") == pinned
    check dirExists(pinned)
    if dirExists(pinned):
      check git(pinned, "rev-parse", "HEAD") == pinnedRevision
    let search = reprobuildPackagesSearch("rppinnedfixture", recipe)
    checkpoint(describeReprobuildPackagesSearch(search))
    check search.module == moduleIn(pinned, "rppinnedfixture")
    check catalogSelectionIdentity(recipe) == "catalog-locked:" &
      pinnedRevision

  test "b: an interface the pin lacks is not taken from the ambient checkout":
    let src = scratch / "b" / "src"
    let recipe = makeConsumer(src / "consumer", upstream, pinnedRevision)
    let ambient = src / "reprobuild-packages"
    cloneAt(upstream, ambient, staleRevision)
    let pinned = materialized(src / "consumer", pinnedRevision)
    check ensureLockPinnedCatalog(recipe, src / "consumer") == pinned
    let search = reprobuildPackagesSearch("rpambientonly", recipe)
    let described = describeReprobuildPackagesSearch(search)
    checkpoint(described)
    check search.module == ""
    # It names the pin it consulted and the checkout it passed over, and why.
    check (pinned & " (locked at " & pinnedRevision & ")") in described
    check (ambient & ": passed over, its HEAD is " & staleRevision) in
      described

  test "c: a checkout at the pinned commit is the pinned catalog":
    let ci = scratch / "c" / "ci"
    let recipe = makeConsumer(ci / "consumer", upstream, pinnedRevision)
    let sibling = ci / "reprobuild-packages"
    cloneAt(upstream, sibling, pinnedRevision)
    check reprobuildPackagesSearch("rppinnedfixture", recipe).module ==
      moduleIn(sibling, "rppinnedfixture")
    check ensureLockPinnedCatalog(recipe, ci / "consumer") == ""
    check not dirExists(ci / "consumer" / ".repro" / "cross-repo-producers")
    check catalogSelectionIdentity(recipe) == "catalog-locked:" &
      pinnedRevision
    # The same commit on a branch whose ref lives only in packed-refs.
    let packed = scratch / "c" / "packed"
    let packedRecipe = makeConsumer(packed / "consumer", upstream,
      pinnedRevision)
    cloneAt(upstream, packed / "reprobuild-packages", pinnedRevision)
    discard git(packed / "reprobuild-packages", "checkout", "--quiet", "-B",
      "pinned-branch", pinnedRevision)
    discard git(packed / "reprobuild-packages", "pack-refs", "--all")
    check not fileExists(packed / "reprobuild-packages" / ".git" / "refs" /
      "heads" / "pinned-branch")
    check reprobuildPackagesSearch("rppinnedfixture", packedRecipe).module ==
      moduleIn(packed / "reprobuild-packages", "rppinnedfixture")
    check catalogSelectionIdentity(packedRecipe) == "catalog-locked:" &
      pinnedRevision
    # A linked worktree at the pinned commit: its `.git` is a FILE naming a
    # git directory whose refs live in the shared one (`commondir`).
    let linked = scratch / "c" / "linked"
    let linkedRecipe = makeConsumer(linked / "consumer", upstream,
      pinnedRevision)
    let main = scratch / "c" / "linked-main"
    cloneAt(upstream, main, staleRevision)
    discard git(main, "worktree", "add", "--quiet", "-b", "pinned-worktree",
      linked / "reprobuild-packages", pinnedRevision)
    discard git(main, "pack-refs", "--all")
    check fileExists(linked / "reprobuild-packages" / ".git")
    check reprobuildPackagesSearch("rppinnedfixture", linkedRecipe).module ==
      moduleIn(linked / "reprobuild-packages", "rppinnedfixture")
    check ensureLockPinnedCatalog(linkedRecipe, linked / "consumer") == ""

  test "d: develop mode substitutes a checkout for the pin":
    # The workspace's own declared checkout, at a path that is not a sibling,
    # while a stale checkout sits beside the consumer.
    let ws = scratch / "d" / "ws"
    createDir(ws / "repos")
    writeFile(ws / "repro-workspace.toml", "")
    writeFile(ws / "repos" / "reprobuild-packages.toml",
      "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\n" &
      "name = \"reprobuild-packages\"\npath = \"catalogs/rp-dev\"\n")
    let declared = ws / "catalogs" / "rp-dev"
    cloneAt(upstream, declared, staleRevision)
    cloneAt(upstream, ws / "reprobuild-packages", staleRevision)
    let wsRecipe = makeConsumer(ws / "consumer", upstream, pinnedRevision)
    check reprobuildPackagesSearch("rpambientonly", wsRecipe).module ==
      moduleIn(declared, "rpambientonly")
    check catalogSelectionIdentity(wsRecipe) == ""
    check ensureLockPinnedCatalog(wsRecipe, ws / "consumer") == ""
    check not dirExists(ws / "consumer" / ".repro" / "cross-repo-producers")

    # A workspace develop override (`repro develop`) beside the lock.
    let dev = scratch / "d" / "dev"
    let devRecipe = makeConsumer(dev / "consumer", upstream, pinnedRevision)
    cloneAt(upstream, dev / "reprobuild-packages", pinnedRevision)
    let overridden = scratch / "d" / "elsewhere" / "rp-override"
    cloneAt(upstream, overridden, staleRevision)
    createDir(dev / "consumer" / ".repro")
    writeFile(dev / "consumer" / ".repro" / "develop-overrides.toml",
      "schema = \"reprobuild.workspace.develop-overrides.v1\"\n\n" &
      "[[override]]\npackage = \"reprobuild-packages\"\n" &
      "local_path = \"../../elsewhere/rp-override\"\nstate = \"editable\"\n" &
      "created_at = \"2026-11-16T00:00:00Z\"\n")
    check reprobuildPackagesSearch("rppinnedfixture", devRecipe).module ==
      moduleIn(normalizedPath(overridden), "rppinnedfixture")
    check catalogSelectionIdentity(devRecipe) == ""
    check ensureLockPinnedCatalog(devRecipe, dev / "consumer") == ""

    # A project develop override, the document in the project's git dir.
    let proj = scratch / "d" / "proj"
    let projRecipe = makeConsumer(proj / "consumer", upstream, pinnedRevision)
    cloneAt(upstream, proj / "reprobuild-packages", staleRevision)
    createDir(proj / "consumer" / ".git" / "reprobuild")
    writeFile(proj / "consumer" / ".git" / "reprobuild" /
      "develop-overrides.json",
      "{\"version\": 1, \"overrides\": [{\"node\": \"reprobuild-packages\"," &
      " \"path\": " & escape(overridden) & "}]}")
    check reprobuildPackagesSearch("rpambientonly", projRecipe).module ==
      moduleIn(overridden, "rpambientonly")
    check catalogSelectionIdentity(projRecipe) == ""
    check ensureLockPinnedCatalog(projRecipe, proj / "consumer") == ""

    # An override naming a checkout that does not exist selects nothing: the
    # pin governs, and the diagnostic says why the override was passed over.
    let gone = scratch / "d" / "gone"
    let goneRecipe = makeConsumer(gone / "consumer", upstream, pinnedRevision)
    cloneAt(upstream, gone / "reprobuild-packages", staleRevision)
    createDir(gone / "consumer" / ".repro")
    writeFile(gone / "consumer" / ".repro" / "develop-overrides.toml",
      "schema = \"reprobuild.workspace.develop-overrides.v1\"\n\n" &
      "[[override]]\npackage = \"reprobuild-packages\"\n" &
      "local_path = \"../missing-checkout\"\nstate = \"editable\"\n")
    let gonePinned = materialized(gone / "consumer", pinnedRevision)
    check ensureLockPinnedCatalog(goneRecipe, gone / "consumer") == gonePinned
    let goneSearch = reprobuildPackagesSearch("rppinnedfixture", goneRecipe)
    let goneDescribed = describeReprobuildPackagesSearch(goneSearch)
    checkpoint(goneDescribed)
    check goneSearch.module == moduleIn(gonePinned, "rppinnedfixture")
    check "missing-checkout: passed over, the develop override in" in
      goneDescribed
    check catalogSelectionIdentity(goneRecipe) == "catalog-locked:" &
      pinnedRevision

  test "e: with no pin, an ambient checkout is still the catalog":
    let src = scratch / "e" / "src"
    let recipe = makeConsumer(src / "consumer")
    cloneAt(upstream, src / "reprobuild-packages", staleRevision)
    check reprobuildPackagesSearch("rpambientonly", recipe).module ==
      moduleIn(src / "reprobuild-packages", "rpambientonly")
    check catalogSelectionIdentity(recipe) == ""
    check ensureLockPinnedCatalog(recipe, src / "consumer") == ""

  test "f: a catalog inside the consumer's repository still wins per interface":
    let src = scratch / "f" / "src"
    let consumer = src / "consumer"
    discard makeConsumer(consumer, upstream, pinnedRevision)
    let fixtures = consumer / "tests" / "reprobuild-packages"
    writeInterface(fixtures, "rprepolocal", "1.0")
    writeInterface(fixtures, "rppinnedfixture", "local")
    let testFile = consumer / "tests" / "integration" / "t_consumer.nim"
    createDir(testFile.parentDir)
    writeFile(testFile, "discard\n")
    cloneAt(upstream, src / "reprobuild-packages", staleRevision)
    let pinned = materialized(consumer, pinnedRevision)
    check ensureLockPinnedCatalog(testFile, consumer) == pinned
    # The repository's own fixture catalog first, for each interface it has.
    check reprobuildPackagesSearch("rprepolocal", testFile).module ==
      moduleIn(fixtures, "rprepolocal")
    check reprobuildPackagesSearch("rppinnedfixture", testFile).module ==
      moduleIn(fixtures, "rppinnedfixture")
    # One it lacks comes from the pin, never from the stale checkout.
    check reprobuildPackagesSearch("rppinnedsecond", testFile).module ==
      moduleIn(pinned, "rppinnedsecond")
    check reprobuildPackagesSearch("rpambientonly", testFile).module == ""
    check catalogSelectionIdentity(testFile) == "catalog-locked:" &
      pinnedRevision

  test "h: one compile never resolves interfaces from two catalog revisions":
    let root = scratch / "h"
    # The consumer, pinned at R; it imports a module of another project.
    let consumer = root / "a" / "consumer"
    discard makeConsumer(consumer, upstream, pinnedRevision)
    writeFile(consumer / "main.nim",
      "import repro_project_dsl\n" &
      "import \"../../b/producer/other\"\n\n" &
      "package mainConsumer:\n" &
      "  defaultToolProvisioning \"tarball\"\n" &
      "  uses:\n    \"rppinnedfixture\"\n")
    check ensureLockPinnedCatalog(consumer / "main.nim", consumer) ==
      materialized(consumer, pinnedRevision)
    let producer = root / "b" / "producer"
    discard makeConsumer(producer, upstream, staleRevision)
    writeFile(producer / "other.nim",
      "import repro_project_dsl\n\n" &
      "package otherConsumer:\n" &
      "  defaultToolProvisioning \"tarball\"\n" &
      "  uses:\n    \"rpambientonly\"\n")
    check ensureLockPinnedCatalog(producer / "other.nim", producer) ==
      materialized(producer, staleRevision)

    let (output, exitCode) = nimCheck(consumer / "main.nim")
    checkpoint(output)
    check exitCode != 0
    check "two catalogs" in output
    check materialized(consumer, pinnedRevision) in output
    check materialized(producer, staleRevision) in output
    check (consumer / "main.nim") in output
    check (producer / "other.nim") in output

    # Positive control: the other project pins R as well. Its own
    # materialized copy is the same catalog revision, and the compile passes,
    # so the refusal above is the two revisions and not a broken setup.
    writeLock(producer, upstream, pinnedRevision)
    writeFile(producer / "other.nim",
      "import repro_project_dsl\n\n" &
      "package otherConsumer:\n" &
      "  defaultToolProvisioning \"tarball\"\n" &
      "  uses:\n    \"rppinnedsecond\"\n")
    check ensureLockPinnedCatalog(producer / "other.nim", producer) ==
      materialized(producer, pinnedRevision)
    let control = nimCheck(consumer / "main.nim")
    checkpoint(control.output)
    check control.exitCode == 0

removeDir(scratch)
