## `repro home apply` refuses a package of an applied concern that has no
## realization on this host BEFORE it changes anything, and names every such
## package -- the answer `repro home apply --plan` gives, from the same
## package previews (CLI/home/apply.md §Concerns Applied On This Host).
##
## Through the real `build/bin/repro`, a profile names one realizable package
## (bound by the `REPRO_TEST_PACKAGE_SOURCE` path seam) ordered ahead of two
## packages no definition in scope realizes:
##
## * `e2e_apply_refuses_every_unrealizable_package_before_the_commit_marker`
##   -- the apply exits 1 naming BOTH unrealizable packages, each with its
##   reason, and leaves no trace: no `apply.in-progress` marker, no
##   generation directory, nothing realized into the store for the package
##   ordered ahead of them, no `current` generation. `--plan` names the same
##   two packages. Positive control: with the two removed, the same apply
##   succeeds and realizes the remaining package into the store, so the
##   store check above can see a realization when there is one.
## * `e2e_unrealizable_package_of_a_concern_not_applied_does_not_refuse_the_
##   apply` -- on a host whose `applies:` leaves out `packages`, the same
##   profile applies (exit 0): the refusal is only for an applied concern.
##
## Before the fix the apply wrote the marker and the generation directory,
## realized the realizable package into the store, and then failed naming
## only the first unrealizable package.
##
## No mocks: the real `build/bin/repro`, the real profile compile edge and the
## real planner, in the harness's isolated sandbox (its own HOME, state and
## store). The path seam is the apply's own test-only package binding; it
## stands in for a realizer whose side effect (a `scoop install`, a download)
## this test must be able to observe without performing one. Platforms: every
## host.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_home_generations

import ../m83/profile_compile_edge_harness

const
  Ahead = "aa-repro-realizable-fixture"
    ## Bound by the path seam; ordered (by name and by declaration) ahead of
    ## the two unrealizable packages.
  UnrealizableOne = "zz-repro-unrealizable-one"
  UnrealizableTwo = "zz-repro-unrealizable-two"
    ## Defined by nothing in scope: no host inventory realizes them.
  FixtureLeaf = "aa-repro-realizable-fixture-tool"
    ## The seam's source file name; a realization copies it into the store.
  RefusalMessage = "package(s) of an applied concern have no realization " &
    "on this host"

proc profileWith(packages: seq[string]; applies = ""): string =
  result = "import repro_profile\n\nprofile \"refuseUnrealizable\":\n" &
    "  activity default:\n"
  for p in packages:
    result.add("    `" & p & "`\n")
  if applies.len > 0:
    result.add("\n  hosts:\n    \"" & DefaultSandboxHost & "\":\n" &
      "      activities: [default]\n      applies: [" & applies & "]\n")

proc show(label: string; r: ReproRun) =
  checkpoint(label & " -> exit " & $r.exitCode & "\n--- stdout\n" &
    r.stdout & "\n--- stderr\n" & r.stderr)

proc both(r: ReproRun): string = r.stdout & r.stderr

proc writeFixture(sb: ProfileSandbox): string =
  ## An executable for the path seam to realize.
  result = sb.root / "fixtures" / addFileExt(FixtureLeaf,
    when defined(windows): "cmd" else: "")
  createDir(extendedPath(result.parentDir))
  when defined(windows):
    writeFile(extendedPath(result), "@echo fixture\r\n")
  else:
    writeFile(extendedPath(result), "#!/bin/sh\necho fixture\n")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc storeHolds(sb: ProfileSandbox; leaf: string): bool =
  ## Whether anything under the store root carries the fixture's file name:
  ## the path seam copies the source into a store prefix under that name.
  if not dirExists(extendedPath(sb.storeRoot)):
    return false
  for path in walkDirRec(sb.storeRoot):
    if extractFilename(path) == leaf:
      return true

proc generationDirs(sb: ProfileSandbox): seq[string] =
  ## Entries under `<state>/generations/`, `.aborted` included.
  let dir = sb.stateDir / "generations"
  if not dirExists(extendedPath(dir)):
    return
  for kind, path in walkDir(dir):
    result.add(extractFilename(path))

suite "home apply: an unrealizable package is refused before the commit":

  test "e2e_apply_refuses_every_unrealizable_package_before_the_commit_" &
      "marker":
    let sb = newProfileSandbox("refuse-unrealizable",
      profileWith(@[Ahead, UnrealizableOne, UnrealizableTwo]))
    defer: sb.dispose()
    let seam = [("REPRO_TEST_PACKAGE_SOURCE", Ahead & "=" & writeFixture(sb))]

    let plan = sb.runRepro(["home", "apply", "--plan"], extraEnv = seam)
    show("apply --plan", plan)
    check plan.exitCode == 1
    check ("2 " & RefusalMessage) in plan.stderr
    check UnrealizableOne in plan.stderr
    check UnrealizableTwo in plan.stderr

    let applied = sb.runRepro(["home", "apply"], extraEnv = seam)
    show("apply", applied)
    check applied.exitCode == 1
    # Every unrealizable package is named, each with its reason.
    check ("2 " & RefusalMessage) in applied.stderr
    for id in [UnrealizableOne, UnrealizableTwo]:
      check (id & ": unknown-package") in applied.stderr
    check Ahead notin applied.stderr
    # Nothing changed: no marker, no generation directory, nothing realized.
    check not fileExists(extendedPath(sb.stateDir / "apply.in-progress"))
    checkpoint("generations/: " & sb.generationDirs().join(", "))
    check sb.generationDirs().len == 0
    check not sb.storeHolds(FixtureLeaf)
    check readCurrentGenerationId(sb.stateDir).len == 0

    # A second apply refuses the same way and has nothing to quarantine.
    let again = sb.runRepro(["home", "apply"], extraEnv = seam)
    show("apply again", again)
    check again.exitCode == 1
    check ("2 " & RefusalMessage) in again.stderr
    check sb.generationDirs().len == 0

    # Positive control: without the two, the same apply realizes the package
    # ahead of them into the store, which `storeHolds` sees.
    writeFile(extendedPath(sb.profilePath), profileWith(@[Ahead]))
    let accepted = sb.runRepro(["home", "apply"], extraEnv = seam)
    show("apply, realizable package only", accepted)
    check accepted.exitCode == 0
    check RefusalMessage notin accepted.both
    check sb.storeHolds(FixtureLeaf)
    check readCurrentGenerationId(sb.stateDir).len > 0
    check not fileExists(extendedPath(sb.stateDir / "apply.in-progress"))

  test "e2e_unrealizable_package_of_a_concern_not_applied_does_not_" &
      "refuse_the_apply":
    let sb = newProfileSandbox("refuse-unrealizable-not-applied",
      profileWith(@[Ahead, UnrealizableOne, UnrealizableTwo],
        applies = "files"))
    defer: sb.dispose()
    let seam = [("REPRO_TEST_PACKAGE_SOURCE", Ahead & "=" & writeFixture(sb))]
    let applied = sb.runRepro(["home", "apply"], extraEnv = seam)
    show("apply, applies: [files]", applied)
    check applied.exitCode == 0
    check RefusalMessage notin applied.both
    check readCurrentGenerationId(sb.stateDir).len > 0
