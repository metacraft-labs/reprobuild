## A build whose lock-pinned cross-repo producer is read from a checkout that
## is NOT at the revision the consumer's lock pins, where that checkout's
## recipe declares a range the lock contradicts, is refused with a diagnostic
## that names the checkout and both revisions and leads with bringing the
## checkout to the pin. It does not tell the reader to re-pin a correct lock.
##
## THE DEFECT. codetracer's lock pinned codetracer-ruby-recorder at `faf4e08`,
## whose recipe no longer declares `ruby >=3.1`. The build read the producer's
## recipe from a checkout 36 commits BEHIND that pin, which still declared it,
## and the provider's range check refused with "the committed lock … pins
## 'ruby' to 0.0.0 …" and `--repin=ruby` as the first remedy: a remedy that
## changes a correct lock to fit a stale checkout. The check that names the
## real cause (the producer source-revision mismatch) runs only later, once
## the producer is admitted to the build.
##
## Fixture (built ``./build/bin/repro``, black-box), two git repos side by side:
##
##   <scratch>/
##     consumer/  package consumer   variant releaseBuild; uses: "nim >=1.6
##                <3.0", "bash >=4", "producer >=0"; one ``nim.c`` edge
##     producer/  package producer_pkg (deliberately not the repo's name)
##                commit OLDER: uses "nim >=2.2 <3.0"
##                commit PINNED: no nim floor
##
## The producer is LOCK-PINNED (no develop override): ``repro lock refresh``
## with the producer at PINNED writes ``nim = 1.6.0`` and a ``deps`` entry for
## ``producer`` at PINNED. The checkout is then moved back to OLDER.
##
## Asserts:
##   1. Baseline refresh pins ``nim = 1.6.0`` and ``producer`` at PINNED.
##   2. With the checkout at OLDER, ``repro build`` refuses with
##      ``ELockConflict``, names the checkout directory, OLDER and PINNED, says
##      the lock is not shown to be wrong, and names
##      ``git -C <checkout> checkout --detach PINNED`` BEFORE
##      ``repro lock refresh --repin=nim``. The lock is byte-identical.
##   3. ``repro lock refresh --repin=bash`` is refused by the sibling
##      pin-regression gate (exit 4), which names the checkout and the pin,
##      before any held pin is checked; it writes nothing. (A refresh
##      re-observes every sibling, so a checkout AHEAD of its pin is one the
##      refresh moves the pin to, and its ranges rightly bind.)
##   4. With the checkout back at PINNED, ``repro build`` raises no
##      ``ELockConflict`` and succeeds.
##
## Falsifiability: on the unfixed code (2) names only the lock, with
## ``--repin=nim`` and the whole-lock refresh as the remedies, and never the
## checkout or its revisions. (3) holds on the unfixed code too; it pins down
## that the re-pin path needs no annotation of its own.
##
## Test-double policy: NO mocks, doubles, or fakes — real git repositories,
## the real built ``repro`` binary, real provider compiles, real solves and a
## real ``nim c``.
##
## Hermetic: every repo lives in a fresh tempdir; nothing touches $HOME.
## Skip rule: ``git`` or ``nim`` missing on PATH, repro unbuilt, or no
## ``reprobuild-packages`` checkout to resolve the plain tool uses against.

import std/[os, osproc, strutils, unittest]
import repro_lock
import repro_test_support/reasoned_skip

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

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
    "producer >=0"
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
$1
  build:
    discard aggregate("producer-aggregate", actions = @[])
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

proc head(gitBin, repo: string): string =
  let r = git(gitBin, repo, "rev-parse HEAD")
  check r.code == 0
  r.output.strip()

proc initRepo(gitBin, dir: string) =
  createDir(dir)
  check git(gitBin, "", "init -q -b main " & q(dir)).code == 0
  check git(gitBin, dir, "config user.email t@example.invalid").code == 0
  check git(gitBin, dir, "config user.name Tester").code == 0
  check git(gitBin, dir, "remote add origin " & q(dir)).code == 0
  writeFile(dir / ".gitignore", ".repro/build/\nbuild/\n")

proc packageVersion(lockBody, name: string): string =
  for p in parseLockedDependencies(lockBody).packages:
    if p.name == name: return p.version
  ""

proc depRevision(lockBody, name: string): string =
  for d in parseLockedDependencies(lockBody).deps:
    if d.name == name: return d.coordinates.revision
  ""

proc packagesRoot(): string =
  let fromEnv = getEnv("REPROBUILD_PACKAGES_ROOT")
  if fromEnv.len > 0 and dirExists(fromEnv): return fromEnv
  let sibling = ReprobuildRepoRoot.parentDir() / "reprobuild-packages"
  if dirExists(sibling): return sibling
  ""

suite "a lock conflict from a producer checkout behind its pin":

  test "t_lock_conflict_from_a_producer_checkout_behind_its_pin_names_the_checkout":
    let gitBin = findExe("git")
    let catalog = packagesRoot()
    if gitBin.len == 0:
      skip("git not on PATH; this case needs real sibling repositories")
    elif findExe("nim").len == 0:
      skip("nim not on PATH; the consumer's build edge is a real `nim c`")
    elif not fileExists(reproBinary):
      skip("build/bin/repro is not built; this case drives the real CLI")
    elif catalog.len == 0:
      skip("no reprobuild-packages checkout (set REPROBUILD_PACKAGES_ROOT); the refresh resolves the plain `nim` / `bash` tool uses against it")
    else:
      let hadCatalogEnv = existsEnv("REPROBUILD_PACKAGES_ROOT")
      let oldCatalogEnv = getEnv("REPROBUILD_PACKAGES_ROOT")
      putEnv("REPROBUILD_PACKAGES_ROOT", catalog)
      defer:
        if hadCatalogEnv: putEnv("REPROBUILD_PACKAGES_ROOT", oldCatalogEnv)
        else: delEnv("REPROBUILD_PACKAGES_ROOT")
      let scratch = expandFilename(getTempDir()) /
        ("lock-conflict-stale-producer-" & $getCurrentProcessId())
      removeDir(scratch)
      createDir(scratch)
      defer: removeDir(scratch)

      let consumer = scratch / "consumer"
      let producer = scratch / "producer"
      initRepo(gitBin, producer)
      createDir(producer / "src")
      writeFile(producer / "src" / "producer.nim",
        "proc hello*(): string = \"hello from the producer\"\n")
      writeFile(producer / "repro.nim", producerRecipe % ["    \"nim >=2.2 <3.0\""])
      commitAll(gitBin, producer, "producer with a nim floor")
      let older = head(gitBin, producer)
      writeFile(producer / "repro.nim", producerRecipe % ["    \"bash >=4\""])
      commitAll(gitBin, producer, "drop the nim floor")
      let pinned = head(gitBin, producer)
      check older != pinned

      initRepo(gitBin, consumer)
      writeFile(consumer / "repro.nim", consumerRecipe)
      createDir(consumer / "src")
      writeFile(consumer / "src" / "app.nim", "echo \"app\"\n")
      commitAll(gitBin, consumer, "consumer")
      let lockPath = consumer / "repro.lock"
      let refresh = q(reproBinary) & " lock refresh " & q(consumer)
      let build = q(reproBinary) & " build " & q(consumer)

      # ---- (1) baseline: the lock is written with the producer at PINNED. --
      let baseline = run(refresh, consumer)
      checkpoint("baseline refresh exit=" & $baseline.code)
      checkpoint(baseline.output)
      require baseline.code == 0
      let committed = readFile(lockPath)
      checkpoint(committed)
      check packageVersion(committed, "nim") == "1.6.0"
      require depRevision(committed, "producer") == pinned
      commitAll(gitBin, consumer, "lock")

      # ---- (2) the producer checkout falls behind its pin. ----------------
      check git(gitBin, producer, "checkout -q --detach " & older).code == 0
      let refused = run(build, consumer)
      checkpoint("build with the checkout behind its pin exit=" &
        $refused.code)
      checkpoint(refused.output)
      check refused.code != 0
      check "ELockConflict" in refused.output
      check "'producer_pkg'" in refused.output
      check "nim >=2.2 <3.0" in refused.output
      # The checkout and both revisions.
      check producer in refused.output
      check older in refused.output
      check pinned in refused.output
      check "does not show the lock is wrong" in refused.output
      # Bringing the checkout to the pin is the first remedy.
      let checkoutRemedy = "checkout --detach " & pinned
      check checkoutRemedy in refused.output
      check "repro lock refresh --repin=nim" in refused.output
      check refused.output.find(checkoutRemedy) <
        refused.output.find("repro lock refresh --repin=nim")
      check readFile(lockPath) == committed

      # ---- (3) the re-pin refuses it too, naming the checkout. -----------
      # A refresh re-observes every sibling, so a checkout behind its pin is
      # refused by the pin-regression gate before any held pin is checked; it
      # names the checkout and the pin, and does not reach `ELockConflict`.
      let held = run(refresh & " --repin=bash", consumer)
      checkpoint("--repin=bash with the checkout behind exit=" & $held.code)
      checkpoint(held.output)
      check held.code == 4
      check "BACKWARD" in held.output
      check producer in held.output
      check pinned in held.output
      check "ELockConflict" notin held.output
      check readFile(lockPath) == committed

      # ---- (4) the checkout at its pin: no conflict. ----------------------
      check git(gitBin, producer, "checkout -q --detach " & pinned).code == 0
      let accepted = run(build, consumer)
      checkpoint("build with the checkout at its pin exit=" & $accepted.code)
      checkpoint(accepted.output)
      check "ELockConflict" notin accepted.output
      check accepted.code == 0
      check readFile(lockPath) == committed
