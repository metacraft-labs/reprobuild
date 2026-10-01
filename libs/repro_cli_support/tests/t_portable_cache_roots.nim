## The CLI's portable roots name the REPOSITORY a recipe lives in, so a
## dependency provisioned into a sibling recipe
## (`<repo>/packages/source/<dep>/.repro/output/install`) is named the same
## way from two checkouts of the repository.

import std/[os, tempfiles, unittest]

import repro_local_store
import repro_cli_support/portable_cache

proc checkoutAt(base: string; worktree: bool): string =
  let repo = base / "reprobuild-packages"
  createDir(repo / "packages" / "source" / "gemini-cli")
  createDir(repo / "packages" / "source" / "node" / ".repro" / "output" /
    "install")
  if worktree:
    writeFile(repo / ".git", "gitdir: elsewhere\n")   # a worktree's .git
  else:
    createDir(repo / ".git")
  repo / "packages" / "source" / "gemini-cli"

suite "portable cache roots":

  test "a sibling recipe's prefix is named the same from two checkouts":
    let a = createTempDir("repro-roots-a-", "")
    let b = createTempDir("repro-roots-bbbbbb-", "")
    defer:
      removeDir(a)
      removeDir(b)
    let pa = checkoutAt(a, worktree = false)
    let pb = checkoutAt(b / "deeper", worktree = true)
    let ra = portableCacheRoots(pa, pa / ".repro" / "build", storeRoot = "")
    let rb = portableCacheRoots(pb, pb / ".repro" / "build", storeRoot = "")
    proc nodePrefix(project: string): string =
      project.parentDir / "node" / ".repro" / "output" / "install" / "bin"
    check logicalizeText(ra, nodePrefix(pa)) ==
      logicalizeText(rb, nodePrefix(pb))
    check logicalizeText(ra, nodePrefix(pa)) ==
      "${repository}/packages/source/node/.repro/output/install/bin"
    # The project's own paths still resolve to the project, the longer root.
    check logicalizeText(ra, pa / "src") == "${project}/src"

  test "no repository, no repository root":
    let c = createTempDir("repro-roots-c-", "")
    defer: removeDir(c)
    for root in portableCacheRoots(c, "", storeRoot = ""):
      check root.label != "repository"
