## A recipe compile takes its lock-pinned catalog revision from the
## environment its launcher declares (`LockedCatalogEnv`), and reads no
## `repro.lock` for it.
##
## Before, the compile walked up to the nearest `repro.lock` and read it at
## macro time. Inside the monitored compile edge that made the whole lock an
## input, so every `repro lock refresh` -- which rewrites the lock -- re-ran
## the recipe's interface and provider compiles
## (`t_lock_refresh_reuses_monitored_provider_metadata`). The compile only
## needs the catalog revision, and its identity already carries that.
##
## Negative control: with the declaration absent, or naming another file,
## the same lookup reads the lock and sees the edit; that is what shows the
## declared case is not reading it.

import std/[os, tempfiles, unittest]

import repro_project_dsl/reprobuild_packages_catalog

proc lockPinning(revision: string): string =
  "deps = [\n" &
    "  { name = \"" & ReprobuildPackagesRepositoryName & "\", revision = \"" &
    revision & "\" },\n" &
  "]\n"

suite "the lock-pinned catalog is declared to the compile, not read by it":

  test "a declared answer stands while the lock changes; undeclared, the lock is read":
    let root = createTempDir("repro-locked-catalog-", "")
    defer: removeDir(root)
    let project = root / "project"
    createDir(project / "sub")
    let recipe = project / "repro.nim"
    writeFile(recipe, "import repro_project_dsl\n")
    writeFile(project / CommittedLockFileName, lockPinning("aaaa1111"))
    let previous = getEnv(LockedCatalogEnv)
    defer:
      if previous.len > 0: putEnv(LockedCatalogEnv, previous)
      else: delEnv(LockedCatalogEnv)

    # What the launcher declares: the recipe dir, the lock dir, the revision.
    let declared = lockedCatalogDeclaration(recipe)
    let dir = normalizedPath(absolutePath(project))
    check declared == dir & "\t" & dir & "\taaaa1111"

    # The compile is launched with it, and the lock then changes.
    putEnv(LockedCatalogEnv, declared)
    writeFile(project / CommittedLockFileName, lockPinning("bbbb2222"))
    let fromDeclaration = findEnclosingLockPinnedCatalog(recipe)
    check fromDeclaration.revision == "aaaa1111"
    check fromDeclaration.consumerRoot == normalizedPath(project)
    check catalogSelectionIdentity(recipe) == "catalog-locked:aaaa1111"
    # A module beside the recipe (its `uses:` resolve from there) as well.
    let beside = project / "constraints.nim"
    writeFile(beside, "")
    check findEnclosingLockPinnedCatalog(beside).revision == "aaaa1111"

    # Negative controls. A file deeper in the tree walks and reads the lock...
    let other = project / "sub" / "other.nim"
    writeFile(other, "")
    check findEnclosingLockPinnedCatalog(other).revision == "bbbb2222"
    # ...and with no declaration the recipe does too.
    delEnv(LockedCatalogEnv)
    check findEnclosingLockPinnedCatalog(recipe).revision == "bbbb2222"

  test "a declaration that no lock pins the catalog reads no lock either":
    let root = createTempDir("repro-unlocked-catalog-", "")
    defer: removeDir(root)
    let recipe = root / "repro.nim"
    writeFile(recipe, "import repro_project_dsl\n")
    let previous = getEnv(LockedCatalogEnv)
    defer:
      if previous.len > 0: putEnv(LockedCatalogEnv, previous)
      else: delEnv(LockedCatalogEnv)
    let declared = lockedCatalogDeclaration(recipe)
    check declared == normalizedPath(absolutePath(root)) & "\t\t"
    putEnv(LockedCatalogEnv, declared)
    # A lock appears after the launch: the declared answer still holds.
    writeFile(root / CommittedLockFileName, lockPinning("cccc3333"))
    check findEnclosingLockPinnedCatalog(recipe).revision == ""
    delEnv(LockedCatalogEnv)
    check findEnclosingLockPinnedCatalog(recipe).revision == "cccc3333"
