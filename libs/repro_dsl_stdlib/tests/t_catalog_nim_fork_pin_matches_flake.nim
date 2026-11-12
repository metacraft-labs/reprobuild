## The catalog's `nim-fork` recipe is pinned to the fork this repository's
## flake builds.
##
## reprobuild-pm Distribution-And-Packaging.md §5.3, decision N and its
## amendment N1: an installed prefix ships the catalog's `nim-fork`, and
## `.#prefix` refuses it (`reprobuild_dist.nimForkGuardScript`) unless its
## recorded revision is `flake.lock`'s `nim-fork-src`. The two pins live in
## two repositories, and nothing compared them before a prefix build ran:
## reprobuild `02459dc40` moved `nim-fork-src` to `8384ff3f` while the
## catalog stayed at `197089cd`, and every armv7 `.#prefix` build refused
## until both moved (measured 2026-11-12 at reprobuild `7928e5a0f`, catalog
## `2c58192`). This check fails at the commit that moves one pin alone.
##
## What it reads, and why those: `flake.lock`'s `nim-fork-src` is the fork
## the dev shell builds; the catalog revision is the one this repository's
## committed `repro.lock` pins (the revision CI clones the sibling at, and
## the one `stage_release_catalog.sh` ships); the recipe is read out of git
## at that revision, not from the sibling's working tree, which may have
## moved.
##
## NO MOCKS: the real lock files and the real catalog checkout. Without a
## checkout holding the pinned revision ($REPROBUILD_PACKAGES_ROOT, else
## ../reprobuild-packages) the case skips with the reason, and fails in a
## gate run.

import std/[json, os, osproc, strutils, unittest]

import repro_test_support/reasoned_skip

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir

proc flakeForkRevision(): string =
  parseFile(RepoRoot / "flake.lock")["nodes"]["nim-fork-src"]["locked"][
    "rev"].getStr

proc hex40After(text, marker: string; start = 0): string =
  ## The 40-hex value that immediately follows `marker` at or after `start`,
  ## or "" when there is none. Plain string scanning, not `std/re`: that
  ## module loads libpcre at run time, which no other test here needs and
  ## which a host without it (the stock-compiler Windows build, or any run
  ## outside the dev shell) does not have, so the case would crash instead
  ## of reporting.
  let at = text.find(marker, start)
  if at < 0:
    return ""
  let value = text.substr(at + marker.len, at + marker.len + 39)
  if value.len == 40 and value.allCharsInSet(HexDigits - {'A' .. 'F'}):
    value
  else:
    ""

proc lockedCatalogRevision(): string =
  ## The `reprobuild-packages` deps entry's revision, read the way
  ## `scripts/release/stage_release_catalog.sh` reads it: the one inline
  ## table that names the catalog and carries a 40-hex revision (the
  ## `packages` entry of the same name carries none).
  let text = readFile(RepoRoot / "repro.lock").replace("\r", "")
  const head = "{ name = \"reprobuild-packages\","
  var found: seq[string]
  var at = text.find(head)
  while at >= 0:
    let close = text.find('}', at)
    let entry = if close < 0: text.substr(at) else: text.substr(at, close)
    for marker in ["{ revision = \"", " revision = \"", ",revision = \""]:
      let rev = entry.hex40After(marker)
      if rev.len > 0:
        found.add(rev)
        break
    at = text.find(head, at + head.len)
  doAssert found.len == 1,
    "repro.lock pins " & $found.len & " reprobuild-packages revisions"
  found[0]

proc catalogCheckout(): string =
  for candidate in [getEnv("REPROBUILD_PACKAGES_ROOT"),
                    RepoRoot.parentDir / "reprobuild-packages"]:
    if candidate.len > 0 and dirExists(candidate):
      return candidate
  ""

suite "the catalog's nim-fork is the fork the flake builds":
  test "the recipe at the locked catalog revision pins flake.lock's nim-fork-src":
    let flakeRev = flakeForkRevision()
    let catalogRev = lockedCatalogRevision()
    let root = catalogCheckout()
    let show = if root.len == 0: (output: "no catalog checkout", exitCode: 1)
               else: execCmdEx("git -C " & quoteShell(root) & " show " &
                 catalogRev & ":packages/source/nim-fork/repro.nim")
    if show.exitCode != 0:
      let reason = "cannot read packages/source/nim-fork/repro.nim at " &
        "reprobuild-packages " & catalogRev & " (set REPROBUILD_PACKAGES_ROOT " &
        "or clone ../reprobuild-packages): " & show.output
      if getEnv("REPROBUILD_GATE_RUN") == "1":
        checkpoint(reason)
        check false
      else:
        skip(reason)
    else:
      let recipeRev = show.output.hex40After("NimForkRevision* = \"")
      check recipeRev.len == 40
      checkpoint("flake.lock nim-fork-src is " & flakeRev &
        "; reprobuild-packages " & catalogRev & " pins nim-fork " & recipeRev &
        ". Move the recipe's NimForkRevision and sha256 to the flake's " &
        "revision, then `repro lock update reprobuild-packages`.")
      check recipeRev == flakeRev
