## Declaring a sibling producer whose recipe states a stricter toolchain floor
## than the consumer's committed lock pins is refused with a diagnostic that
## names the producer as a cross-repo producer and names the targeted re-pin;
## ``repro lock refresh --repin=<package>`` then clears the conflict by
## re-solving ONLY that package.
##
## Issue: reprobuild-pm/issues/2026-10-14-declaring-a-sibling-producer-imports-
## its-toolchain-floor-into-the-consumers-committed-lock-solve.md.
## Spec: reprobuild-pm/spec/Locking-And-Solver.md §"Targeted re-pin";
## Cross-Repo-Source-Consumption.md §6 ("A source-consumed producer's ranges
## bind the consumer's lock").
##
## THE DEFECT. The consumer's lock was written before the producer was
## declared, so it pins ``nim`` at the consumer's own floor (``1.6.0``). Adding
## ``uses: "producer >=0"`` folds the producer's ``nim >=2.2 <3.0`` into the
## consumer's solve, and the build refuses with ``ELockConflict``. That refusal
## is correct (the consumer's compiler builds the producer's modules); what was
## wrong is everything around it:
##
##   * the only remedies named were a WHOLE-LOCK ``repro lock refresh`` (every
##     version pin and every sibling revision pin re-solved and published) or
##     editing the producer to drop a floor it states correctly;
##   * the lock records no pin for the producer's package, so the message took
##     its partial-solve branch and claimed the lock "was regenerated where
##     that recipe was not reachable" — the wrong story for a dependency that
##     was simply declared after the lock was written;
##   * nothing said the constraint lives in ANOTHER repo's recipe.
##
## Fixture (built ``./build/bin/repro``, black-box), two git repos side by side:
##
##   <scratch>/
##     consumer/  package consumer   variant releaseBuild; uses: "nim >=1.6
##                <3.0", "bash >=4"; one ``nim.c`` edge compiling src/app.nim
##     producer/  package producer_pkg   library producer (pure-Nim src/);
##                uses: "nim >=2.2 <3.0"
##
## The producer is reached through a develop override
## (``.repro/develop-overrides.toml``), the SC-11 develop-mode shape. The
## consumer's variant makes its module-init solve run eagerly, which is what
## exposes the conflict before any compile (codetracer's ``buildType`` variant
## plays the same role in the issue).
##
## Asserts:
##   1. Baseline: ``repro lock refresh`` writes a lock with several pins
##      (``bash``, ``consumer``, ``nim = 1.6.0``), a variant and a ``deps``
##      entry.
##   2. Producer declared: ``repro build`` refuses with ``ELockConflict``,
##      naming ``producer_pkg`` as a cross-repo producer, naming
##      ``repro lock refresh --repin=nim``, and covering "declared after the
##      lock was written". The lock is byte-identical.
##   3. ``--repin=nosuch`` (a package the solve does not have): exit 2, lock
##      byte-identical.
##   4. A HELD pin also conflicting (producer additionally declares
##      ``bash >=5`` while the lock pins ``bash = 4.0.0``): ``--repin=nim``
##      fails with ``bash``'s ``ELockConflict`` (naming ``--repin=bash``),
##      lock byte-identical. The flag never silently widens.
##   4b. Control: the same held-pin conflict declared by the CONSUMER's own
##      recipe (``bash >=5`` in ``consumer``'s ``uses:``) is not called a
##      cross-repo producer by ``--repin`` (here) nor by ``repro build`` (6b,
##      after the re-pin). The site is decided by the ``package`` macro
##      (``isMainModule``), so this is the end-to-end check that the recipe
##      being built counts as its own.
##   5. ``--repin=nim``: exit 0; the written lock differs from the committed
##      one ONLY in the ``nim`` entry plus ADDED entries; every other package
##      entry, every variant, every committed sibling ``deps`` entry and the
##      certificate-policy snapshot are unchanged. The producer, which the
##      committed lock did not pin, gains a ``deps`` entry at its checkout's
##      HEAD.
##   6. ``repro build`` against the re-pinned lock no longer raises
##      ``ELockConflict`` and succeeds; ``repro lock validate`` accepts it.
##   6b. The build half of the 4b control.
##   7. No committed lock: ``--repin=nim`` exits 2 and creates none.
##
## Falsifiability: on the unfixed code (measured at reprobuild 739969b005)
## (2) prints the partial-solve wording with no ``--repin`` and no
## cross-repo statement, and (3)-(7) exit 2 with "unknown flag --repin".
##
## Test-double policy: NO mocks, doubles, or fakes — real git repositories,
## the real built ``repro`` binary, real provider compiles, real solves and a
## real ``nim c``. The develop override file is the real on-disk contract a
## ``repro develop`` writes, authored directly with each local Git repository
## as its fetch origin.
##
## Hermetic: every repo lives in a fresh tempdir; nothing touches $HOME.
## Skip rule: ``git`` or ``nim`` missing on PATH, repro unbuilt, or no
## ``reprobuild-packages`` checkout to resolve the plain tool uses against.

import std/[os, osproc, strutils, unittest]
import repro_lock
import repro_test_support/reasoned_skip

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  ## From THIS SOURCE FILE's path rather than the working directory (see
  ## t_lock_refresh_folds_uses_sibling_producer_deps for why).
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const UsageExitCode = 2
  ## `repro lock refresh`'s usage error: the spec's answer for a `--repin`
  ## without a committed lock or naming a package the solve does not have.

const consumerRecipe = """
import repro_project_dsl

package consumer:
  defaultToolProvisioning "path"
  config:
    ## Build the app with -d:release.
    releaseBuild: variant bool = false
  uses:
    "nim >=1.6 <3.0"
    "bash >=4"
$1
  build:
    let app = nim.c(
      source = "src/app.nim",
      output = "build/app",
      defines = if releaseBuild.value: @["release"] else: @[],
      actionId = "consumer.build.app",
      extraInputs = @["src"])
    discard collect("default", @[app])
"""

const producerRecipe = """
import repro_project_dsl

package producer_pkg:
  library producer
  defaultToolProvisioning "path"
  uses:
    "nim >=2.2 <3.0"
$1
  build:
    discard aggregate("producer-aggregate", actions = @[])
"""

const developOverrides = """
schema = "reprobuild.workspace.develop-overrides.v1"

[[override]]
package = "producer"
local_path = "../producer"
state = "editable"
created_at = "2026-10-16T00:00:00Z"
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(gitBin, repo, rest: string): tuple[code: int; output: string] =
  run(q(gitBin) & " -C " & q(repo) & " " & rest)

proc commitAll(gitBin, repo, message: string) =
  check git(gitBin, repo, "add -A").code == 0
  check git(gitBin, repo, "commit -q --allow-empty -m " & q(message)).code == 0

proc initRepo(gitBin, dir: string) =
  createDir(dir)
  check git(gitBin, "", "init -q -b main " & q(dir)).code == 0
  check git(gitBin, dir, "config user.email t@example.invalid").code == 0
  check git(gitBin, dir, "config user.name Tester").code == 0
  check git(gitBin, dir, "remote add origin " & q(dir)).code == 0
  # The build's own output tree is not source; keeping it out of the commits
  # keeps the root dep's integrity about the recipe, not about build products.
  writeFile(dir / ".gitignore", ".repro/build/\nbuild/\n")

proc writeProducer(dir: string; extraUses = "") =
  writeFile(dir / "repro.nim", producerRecipe % [extraUses])

proc packagesOf(lockBody: string): seq[LockedPackage] =
  parseLockedDependencies(lockBody).packages

proc packageVersion(lockBody, name: string): string =
  for p in packagesOf(lockBody):
    if p.name == name: return p.version
  ""

proc rendered(p: LockedPackage): string =
  ## One package entry as the lock writer renders it. Compared as text because
  ## the record carries case-object fields Nim's generic `==` cannot walk, and
  ## the rendering is what a reader of the lock diff sees anyway.
  serializeLockedDependencies(LockedDependencies(
    schema: SolvedGraphLockSchemaV2, packages: @[p]))

proc rendered(deps: seq[LockedDep]): string =
  serializeLockedDependencies(LockedDependencies(
    schema: SolvedGraphLockSchemaV2, deps: deps))

proc packagesRoot(): string =
  ## A ``reprobuild-packages`` checkout for the plain tool uses: the caller's
  ## ``REPROBUILD_PACKAGES_ROOT`` when set, else the workspace sibling of this
  ## reprobuild checkout. "" when neither exists.
  let fromEnv = getEnv("REPROBUILD_PACKAGES_ROOT")
  if fromEnv.len > 0 and dirExists(fromEnv): return fromEnv
  let sibling = ReprobuildRepoRoot.parentDir() / "reprobuild-packages"
  if dirExists(sibling): return sibling
  ""

suite "lock refresh --repin clears a conflict from a newly declared producer":

  test "t_lock_refresh_repin_clears_a_conflict_from_a_newly_declared_producer":
    let gitBin = findExe("git")
    let catalog = packagesRoot()
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real sibling repositories")
    elif findExe("nim").len == 0:
      skip("nim not on PATH; the consumer's build edge is a real `nim c`")
    elif not fileExists(reproBinary):
      skip("build/bin/repro is not built; this case drives the real CLI")
    elif catalog.len == 0:
      skip("no reprobuild-packages checkout (set REPROBUILD_PACKAGES_ROOT); " &
        "the refresh resolves the plain `nim` / `bash` tool uses against it")
    else:
      let hadCatalogEnv = existsEnv("REPROBUILD_PACKAGES_ROOT")
      let oldCatalogEnv = getEnv("REPROBUILD_PACKAGES_ROOT")
      putEnv("REPROBUILD_PACKAGES_ROOT", catalog)
      defer:
        if hadCatalogEnv: putEnv("REPROBUILD_PACKAGES_ROOT", oldCatalogEnv)
        else: delEnv("REPROBUILD_PACKAGES_ROOT")
      # Resolved so the paths the CLI prints (macOS realpaths /var to
      # /private/var) and the ones asserted against agree.
      let scratch = expandFilename(getTempDir()) /
        ("lock-repin-producer-floor-" & $getCurrentProcessId())
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      let consumer = scratch / "consumer"
      let producer = scratch / "producer"
      initRepo(gitBin, producer)
      writeProducer(producer)
      createDir(producer / "src")
      writeFile(producer / "src" / "producer.nim",
        "proc hello*(): string = \"hello from the producer\"\n")
      commitAll(gitBin, producer, "producer")

      initRepo(gitBin, consumer)
      writeFile(consumer / "repro.nim", consumerRecipe % [""])
      createDir(consumer / "src")
      writeFile(consumer / "src" / "app.nim", "echo \"app\"\n")
      commitAll(gitBin, consumer, "consumer")
      let lockPath = consumer / "repro.lock"
      let refresh = q(reproBinary) & " lock refresh " & q(consumer)
      let build = q(reproBinary) & " build " & q(consumer)

      # ---- (1) baseline lock, written before the producer is declared. -----
      let baseline = run(refresh, consumer)
      checkpoint("baseline refresh exit=" & $baseline.code)
      checkpoint(baseline.output)
      require baseline.code == 0
      let committed = readFile(lockPath)
      check packageVersion(committed, "nim") == "1.6.0"
      check packageVersion(committed, "bash").len > 0
      check packageVersion(committed, "consumer").len > 0
      check packageVersion(committed, "producer_pkg").len == 0
      check parseLockedDependencies(committed).variants.len == 1
      check parseLockedDependencies(committed).deps.len > 0
      commitAll(gitBin, consumer, "lock")

      # ---- (2) the producer declared after the lock was written. -----------
      writeFile(consumer / "repro.nim",
        consumerRecipe % ["    \"producer >=0\""])
      writeFile(consumer / "src" / "app.nim",
        "import producer\necho hello()\n")
      createDir(consumer / ".repro")
      writeFile(consumer / ".repro" / "develop-overrides.toml",
        developOverrides)
      commitAll(gitBin, consumer, "declare the producer")
      let refused = run(build, consumer)
      checkpoint("build with the producer declared exit=" & $refused.code)
      checkpoint(refused.output)
      check refused.code != 0
      check "ELockConflict" in refused.output
      check "'producer_pkg'" in refused.output
      check "nim >=2.2 <3.0" in refused.output
      # The first remedy is the targeted re-pin, with the package filled in.
      check "repro lock refresh --repin=nim" in refused.output
      # The declaring package is another repo's.
      check "cross-repo producer" in refused.output
      # And the partial-solve story covers the ordinary case.
      check "declared after the lock was written" in refused.output
      check readFile(lockPath) == committed

      # ---- (3) a package the solve does not have is a usage error. ---------
      let unknown = run(refresh & " --repin=nosuch", consumer)
      checkpoint("unknown --repin exit=" & $unknown.code)
      checkpoint(unknown.output)
      check unknown.code == UsageExitCode
      # The refusal is about the package, not about an unrecognised flag.
      check "unknown flag" notin unknown.output
      check "nosuch" in unknown.output
      check readFile(lockPath) == committed

      # ---- (4) a held pin that also conflicts is reported, not widened. ----
      writeProducer(producer, "    \"bash >=5\"")
      let held = run(refresh & " --repin=nim", consumer)
      checkpoint("held-pin conflict exit=" & $held.code)
      checkpoint(held.output)
      check held.code != 0
      check held.code != UsageExitCode
      check "ELockConflict" in held.output
      check "'bash'" in held.output
      check "--repin=bash" in held.output
      # The declarer is the producer, reported through the provider's
      # declaration-site sidecar rather than the build's registry.
      check "package 'producer_pkg' declares `uses: bash >=5`" in held.output
      check "cross-repo producer" in held.output
      check readFile(lockPath) == committed
      writeProducer(producer)

      # ---- (4b) control: the consumer's OWN constraint is not cross-repo. --
      writeFile(consumer / "repro.nim",
        consumerRecipe % ["    \"producer >=0\"\n    \"bash >=5\""])
      let ownRepin = run(refresh & " --repin=nim", consumer)
      checkpoint("held-pin conflict from the consumer exit=" & $ownRepin.code)
      checkpoint(ownRepin.output)
      check ownRepin.code != 0
      check ownRepin.code != UsageExitCode
      check "package 'consumer' declares `uses: bash >=5`" in ownRepin.output
      check "--repin=bash" in ownRepin.output
      check "cross-repo producer" notin ownRepin.output
      check readFile(lockPath) == committed
      writeFile(consumer / "repro.nim",
        consumerRecipe % ["    \"producer >=0\""])

      # ---- (5) the targeted re-pin. ----------------------------------------
      let repin = run(refresh & " --repin=nim", consumer)
      checkpoint("--repin=nim exit=" & $repin.code)
      checkpoint(repin.output)
      require repin.code == 0
      let repinned = readFile(lockPath)
      checkpoint(repinned)
      let before = parseLockedDependencies(committed)
      let after = parseLockedDependencies(repinned)
      check packageVersion(repinned, "nim") == "2.2.0"
      # Every unnamed committed entry is held byte-for-byte (as a record).
      for p in before.packages:
        var found = false
        for a in after.packages:
          if a.name == p.name:
            found = true
            if p.name != "nim":
              check rendered(a) == rendered(p)
        check found
      # Anything new is an ADDITION, and the newly declared producer's package
      # is among them (it had no pin to hold).
      var added: seq[string]
      for a in after.packages:
        var known = false
        for p in before.packages:
          if p.name == a.name: known = true
        if not known: added.add(a.name)
      checkpoint("added: " & added.join(", "))
      check "producer_pkg" in added
      check after.variants == before.variants
      # Every sibling revision pin the committed lock records is carried
      # forward byte-for-byte, and the policy snapshot with them.
      var carriedSiblings, beforeSiblings: seq[LockedDep]
      var addedSiblings: seq[LockedDep]
      for d in before.deps:
        if d.path != ".": beforeSiblings.add(d)
      for a in after.deps:
        if a.path == ".": continue
        var known = false
        for d in beforeSiblings:
          if d.name == a.name or d.path == a.path: known = true
        if known: carriedSiblings.add(a)
        else: addedSiblings.add(a)
      check rendered(carriedSiblings) == rendered(beforeSiblings)
      check after.certificatePolicySection == before.certificatePolicySection
      # The newly declared producer had no revision pin to hold, so the re-pin
      # ADDS one, at the revision its checkout is at. Without it a lock-pinned
      # build has no revision to fetch the producer at. It is the only
      # addition: nothing else became a sibling.
      check addedSiblings.len == 1
      let producerHead = git(gitBin, producer, "rev-parse HEAD")
      check producerHead.code == 0
      for a in addedSiblings:
        check a.name == "producer"
        check a.path == "../producer"
        check a.coordinates.kind == ckVcs
        check a.coordinates.revision == producerHead.output.strip()

      # ---- (6) the build accepts the re-pinned lock. -----------------------
      commitAll(gitBin, consumer, "repin nim")
      let accepted = run(build, consumer)
      checkpoint("build against the re-pinned lock exit=" & $accepted.code)
      checkpoint(accepted.output)
      check "ELockConflict" notin accepted.output
      check accepted.code == 0
      let validate = run(q(reproBinary) & " lock validate " & q(consumer),
        consumer)
      checkpoint("validate exit=" & $validate.code)
      checkpoint(validate.output)
      check validate.code == 0

      # ---- (6b) control, build half: the consumer's own conflict. ----------
      # After the re-pin, so `nim` no longer conflicts: the build checks edges
      # in registration order, and the producer's (imported, so registered
      # first) would otherwise be the one reported.
      writeFile(consumer / "repro.nim",
        consumerRecipe % ["    \"producer >=0\"\n    \"bash >=5\""])
      let ownBuild = run(build, consumer)
      checkpoint("build with the consumer's own conflict exit=" &
        $ownBuild.code)
      checkpoint(ownBuild.output)
      check ownBuild.code != 0
      check "ELockConflict" in ownBuild.output
      check "package 'consumer' declares `uses: bash >=5`" in ownBuild.output
      check "--repin=bash" in ownBuild.output
      check "cross-repo producer" notin ownBuild.output
      writeFile(consumer / "repro.nim",
        consumerRecipe % ["    \"producer >=0\""])

      # ---- (7) no committed lock: nothing to hold. -------------------------
      removeFile(lockPath)
      let noLock = run(refresh & " --repin=nim", consumer)
      checkpoint("no-lock --repin exit=" & $noLock.code)
      checkpoint(noLock.output)
      check noLock.code == UsageExitCode
      check "unknown flag" notin noLock.output
      check "committed lock" in noLock.output
      check not fileExists(lockPath)
