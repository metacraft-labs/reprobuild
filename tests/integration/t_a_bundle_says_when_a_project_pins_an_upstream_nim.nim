## `repro bundle create`, `repro store closure` and `repro store export` say
## so when a project they carry pins the Nim compiler of its recipe to an
## upstream Nim release.
##
## WHY. An upstream Nim release starts the C compiler, the linker and every
## compile-time command through `/bin/sh -c`, so the recipe compiles of a
## project that pins one are keyed on the exporting machine's `/bin/sh`
## (the Nim reprobuild ships starts them without a shell). Restored on a
## machine whose `/bin/sh` is another program, such a recipe is compiled
## again. That is a documented limit of the pin, not something the bundle
## can repair, so the maker of the bundle is told which project and which
## pin, on stderr, without failing the command.
##
## ASSERTS, in a workspace of three repositories (`bundle_selection_fixture`)
## where `alpha`'s committed lock pins `nim ==2.2.10` from the store (the
## pin `repro lock refresh` writes for `packageSource "nim", "store"`) and
## `beta`'s names Nim without pinning it (the bare entry every lock
## carries):
##   * `store closure --root`, `store closure --selection`, `store export`
##     and `bundle create` each exit 0 and print one warning for `alpha`,
##     naming its lock, the pinned version and `/bin/sh`;
##   * none of them warns about `beta` or `gamma` (a control: an unpinned
##     Nim entry, and no lock at all);
##   * a selection that leaves `alpha` out prints no warning at all.
##
## NO MOCKS: the built `repro`, real Git checkouts, locks written by the
## real `repro_lock` writer (what `repro lock refresh` writes, without its
## network fetch of the archive digest), a real store and action cache.

import std/[os, strutils, tables, unittest]

import repro_lock
import repro_lock/identity
import repro_test_support/reasoned_skip

import bundle_selection_fixture

proc lockBytes(packages: openArray[(string, string, string)]): string =
  ## (name, version, source) -> committed lock bytes for this platform.
  let platform = currentPlatformId()
  var sol = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    optimal: true)
  for (name, version, _) in packages:
    sol.packages[name] = version
  var ld = lockedDepsFromSolved(solutionToLock(sol, platform, ""))
  for i in 0 ..< ld.packages.len:
    for (name, _, source) in packages:
      if ld.packages[i].name == name:
        ld.packages[i].source = source
  ld.deps = lockedDepsFromPackages(ld.packages, platform)
  serializeLockedDependencies(ld)

const Warning = ": warning: "

proc warningsIn(output: string): seq[string] =
  for line in output.splitLines():
    if Warning in line and " pins Nim " in line:
      result.add(line)

proc requireOnlyAlpha(output, ws, command: string) =
  let warnings = warningsIn(output)
  checkpoint(command & " warnings: " & $warnings)
  check warnings.len == 1
  if warnings.len == 1:
    let w = warnings[0]
    check w.startsWith("repro " & command & Warning)
    check (ws / "alpha" / "repro.lock") in w
    check "pins Nim 2.2.10" in w
    check "/bin/sh" in w
  for w in warnings:
    check (ws / "beta") notin w
    check (ws / "gamma") notin w

suite "a bundle says when a project pins an upstream Nim":
  test "closure, export and bundle create warn about the pinned project only":
    when defined(windows):
      skip("store bundles are not supported on Windows")
    else:
      var host = newSharedHost("repro-bundle-nim-pin-")
      defer: cleanup(host)
      let ws = host.scratch / "ws"
      writeWorkspace(ws)
      writeFile(ws / "alpha" / "repro.lock",
        lockBytes([("nim", "2.2.10", "store")]))
      writeFile(ws / "beta" / "repro.lock",
        lockBytes([("nim", "2.2.10", "nim")]))
      let roots = @["--store-root=" & host.storeRoot,
        "--action-cache-root=" & host.actionCacheRoot]

      let byRoot = host.repro(@["store", "closure", "--root=" & ws] & roots, ws)
      checkpoint("store closure --root, exit " & $byRoot.code & ":\n" &
        byRoot.output)
      require byRoot.code == 0
      requireOnlyAlpha(byRoot.output, ws, "store closure")

      let bySelection = host.repro(@["store", "closure",
        "--selection=" & PairProject, "--workspace-root=" & ws] & roots, ws)
      checkpoint("store closure --selection, exit " & $bySelection.code &
        ":\n" & bySelection.output)
      require bySelection.code == 0
      requireOnlyAlpha(bySelection.output, ws, "store closure")

      let exported = host.repro(@["store", "export", "--root=" & ws,
        "--out=" & host.scratch / "export"] & roots, ws)
      checkpoint("store export, exit " & $exported.code & ":\n" &
        exported.output)
      require exported.code == 0
      requireOnlyAlpha(exported.output, ws, "store export")

      let created = host.repro(@["bundle", "create", PairProject,
        "--no-nix", "--no-sources", "--out=" & host.scratch / "bundles",
        "--workspace-root=" & ws] & roots, ws)
      checkpoint("bundle create, exit " & $created.code & ":\n" &
        created.output)
      require created.code == 0
      requireOnlyAlpha(created.output, ws, "bundle create")

      # A selection without alpha carries no pinned project.
      writeFile(ws / "projects" / "bg.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "member_repos = [\"beta\", \"gamma\"]\n\n[project]\nname = \"bg\"\n")
      let without = host.repro(@["store", "closure", "--selection=bg",
        "--workspace-root=" & ws] & roots, ws)
      checkpoint("store closure --selection=bg, exit " & $without.code &
        ":\n" & without.output)
      require without.code == 0
      check warningsIn(without.output).len == 0
