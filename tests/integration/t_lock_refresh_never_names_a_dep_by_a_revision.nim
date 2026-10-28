## `repro lock refresh` of a project whose catalog is the LOCK-PINNED cache
## never writes a dependency named by a commit id or one with no `url`, and
## keeps the committed catalog pin.
##
## A project whose workspace has no `reprobuild-packages` checkout beside it
## resolves its `uses:` packages from the lock-pinned catalog, which
## `fetchLockPinnedProducer` materializes at
## `<project>/.repro/cross-repo-producers/reprobuild-packages/<revision>`:
## a clone with no `origin`, named by the commit. Observing it like a sibling
## checkout named a dep by that revision with `url = ""`.
##
## What this adds to the fetched-catalog cases elsewhere in the suite is the
## shape of a real committed lock: the project's own self record, whose
## `depends` names `reprobuild-packages`, comes BEFORE the catalog's entry.
## The lock-pinned catalog lookup used to match the quoted name anywhere in an
## entry, so it read the self record as the catalog's and looked for the cache
## under the PROJECT's revision.
##
## Legs (built `build/bin/repro`, real git repositories, nothing mocked):
##   1b. the lookup reads the catalog's revision from the catalog's own entry,
##      not from the self record that precedes it;
##   1. PRIMARY — the refresh compiles against the cache, writes no dep named
##      by the cached revision and no `url = ""`, and keeps the committed
##      `reprobuild-packages` pin (its `url` and `revision`).
##
## Mutation-checked: restoring `findLockedCatalogRevision`'s match on the
## quoted name anywhere in an entry fails 1b on the revision; removing the
## cache recognition from `catalogLockedDep` fails leg 1.
##
## Hermetic: fresh temp dirs; `REPROBUILD_PACKAGES_ROOT` and
## `REPRO_WORKSPACE_CONFIG` are removed from the child environment so the
## catalog lookup's own walk is what finds the catalog.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_project_dsl/reprobuild_packages_catalog

const ReprobuildRepoRoot = currentSourcePath().parentDir.parentDir.parentDir
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const CatalogInterface = """
import repro_project_dsl

package rprevnamefixture:
  provisioning:
    tarball url = "https://example.invalid/rprevnamefixture-1.0.zip",
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
      archiveType = "zip",
      executablePath = "rprevnamefixture",
      packageId = "rprevnamefixture@1.0",
      lockIdentity = "tarball:rprevnamefixture@1.0:sha256:0000000000000000000000000000000000000000000000000000000000000000"
"""

const ConsumerRecipe = """
import repro_project_dsl

package consumer:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.0"
    "rprevnamefixture"
  build:
    discard aggregate("consumer-aggregate", actions = @[])
"""

const CatalogUrl =
  "https://example.invalid/metacraft-labs/reprobuild-packages.git"

proc childEnv(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.toUpperAscii() notin ["REPROBUILD_PACKAGES_ROOT",
                                 "REPRO_WORKSPACE_CONFIG"]:
      result[key] = value

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, options = {poStdErrToStdOut, poUsePath},
    workingDir = cwd, env = childEnv())
  (code: res.exitCode, output: res.output)

proc git(repo: string; args: varargs[string]): string =
  var command = "git"
  if repo.len > 0:
    command.add(" -C " & quoteShell(repo))
  for arg in args:
    command.add(" " & quoteShell(arg))
  let (code, output) = run(command)
  doAssert code == 0, command & "\n" & output
  output.strip()

proc initRepo(dir: string; origin = "") =
  createDir(dir)
  discard git(dir, "init", "-q", "-b", "main")
  discard git(dir, "config", "user.email", "t@example.invalid")
  discard git(dir, "config", "user.name", "Tester")
  discard git(dir, "config", "commit.gpgsign", "false")
  if origin.len > 0:
    discard git(dir, "remote", "add", "origin", origin)

proc refresh(project: string): tuple[code: int; output: string] =
  run(quoteShell(reproBinary) & " lock refresh " & quoteShell(project))

proc depEntry(lockBody, name: string): string =
  ## The `deps` inline table named `name`, or "".
  let start = lockBody.find("{ name = \"" & name & "\"")
  if start < 0:
    return ""
  lockBody[start .. lockBody.find(" }", start) + 1]

suite "lock refresh never names a dep by a revision":

  test "t_lock_refresh_never_names_a_dep_by_a_revision":
    require findExe("git").len > 0
    require fileExists(reproBinary)
    let scratch = createTempDir("repro-lock-revname-", "")
    defer: removeDir(scratch)

    # ---- leg 1 (PRIMARY): the catalog comes from the lock-pinned cache ----
    # A committed lock that pins the catalog, refreshed in a SEED project
    # while the catalog is a sibling checkout the lookup finds beside it.
    let catalog = scratch / "seed" / "reprobuild-packages"
    initRepo(catalog, CatalogUrl)
    let iface = catalog / "packages" / "interfaces" / "rprevnamefixture"
    createDir(iface)
    writeFile(iface / "repro.nim", CatalogInterface)
    discard git(catalog, "add", ".")
    discard git(catalog, "commit", "-q", "-m", "catalog")
    let pinned = git(catalog, "rev-parse", "HEAD")
    let seedProject = scratch / "seed" / "consumer"
    initRepo(seedProject, "https://example.invalid/acme/consumer.git")
    writeFile(seedProject / "repro.nim", ConsumerRecipe)
    discard git(seedProject, "add", "repro.nim")
    discard git(seedProject, "commit", "-q", "-m", "consumer")
    let first = refresh(seedProject)
    checkpoint(first.output)
    require first.code == 0
    let seedLock = readFile(seedProject / "repro.lock")
    require ("revision = \"" & pinned & "\"") in
      depEntry(seedLock, "reprobuild-packages")

    # The project under test lives where NO `reprobuild-packages` is beside it
    # or any ancestor, carries that committed lock, and reaches the catalog
    # only through the lock-pinned cache `fetchLockPinnedProducer` leaves: a
    # clone at the pin with no `origin`, in a directory named by the commit.
    # Its recipe carries this run's scratch path in a comment, so the provider
    # is compiled HERE, against the cache, rather than reused from a compile
    # that resolved the catalog somewhere else.
    let consumer = scratch / "under-test" / "consumer"
    initRepo(consumer, "https://example.invalid/acme/consumer.git")
    writeFile(consumer / "repro.nim",
      ConsumerRecipe & "# compiled for " & consumer & "\n")
    writeFile(consumer / ".gitignore", ".repro/\n")
    writeFile(consumer / "repro.lock", seedLock)
    discard git(consumer, "add", "repro.nim", ".gitignore", "repro.lock")
    discard git(consumer, "commit", "-q", "-m", "consumer with its lock")
    let cache = consumer / ".repro" / "cross-repo-producers" /
      "reprobuild-packages" / pinned
    createDir(cache.parentDir)
    discard git("", "clone", "-q", catalog, cache)
    discard git(cache, "remote", "remove", "origin")
    removeDir(scratch / "seed")
    check not dirExists(scratch / "under-test" / "reprobuild-packages")
    check not dirExists(scratch / "reprobuild-packages")

    # The lookup finds the pin in the committed lock: the catalog's own
    # entry, not the project's self record, whose `depends` names
    # `reprobuild-packages` and which comes first.
    check findEnclosingLockPinnedCatalog(consumer / "repro.nim").revision ==
      pinned

    let second = refresh(consumer)
    checkpoint(second.output)
    check second.code == 0
    # Precondition, so the assertions below are not vacuous: the provider was
    # compiled against the CACHE checkout. The compile includes each catalog
    # interface through a per-consumer shim under the temp dir naming the
    # module it read (`usesImportCode`); a refresh that never reached the
    # cache would carry the old pin forward and pass the checks below without
    # exercising the catalog observation at all.
    var readFromCache = false
    let cachedModule = (cache / "packages" / "interfaces" / "rprevnamefixture" /
      "repro.nim").replace('\\', '/')
    for shim in walkDirRec(getTempDir() / "repro-sibling-shims"):
      if shim.endsWith("repro_sib_rprevnamefixture.nim") and
          cachedModule in readFile(shim):
        readFromCache = true
    check readFromCache
    let lockBody = readFile(consumer / "repro.lock")
    checkpoint(lockBody)
    # No dependency is named by the revision...
    check ("name = \"" & pinned & "\"") notin lockBody
    # ...none lacks a url...
    check "url = \"\"" notin lockBody
    # ...and the committed pin is what the build read, kept.
    let entry = depEntry(lockBody, "reprobuild-packages")
    check entry.len > 0
    check ("url = \"" & CatalogUrl & "\"") in entry
    check ("revision = \"" & pinned & "\"") in entry
