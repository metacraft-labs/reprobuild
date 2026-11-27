## The engine's observation of a workspace sibling tells a pin the sibling
## never fetched from one it is merely behind, and the stale-sibling report
## then says to fetch it.
##
## Spec: Unified-Locking-And-Hooks.md §13.5, "The sources a recipe compile
## reads" (amended 2026-11-27). The defect, observed 2026-11-26: the
## workspace's siblings were behind their pins AND did not hold them, and
## the remedy that worked was `git fetch` then a fast-forward. A sibling
## whose pin is absent cannot be at or ahead of it, so it is judged stale as
## before; what changes is that the report (`chooseSiblingSource`'s reason,
## which the engine's refusals and notices quote) names the missing fetch,
## where "check the sibling out at the pin" alone fails on an unknown
## revision.
##
## No mocks: real git repositories, the engine's real probe
## (`observeSiblingCheckout`) and the shared decision.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_core/sibling_source_policy

proc git(dir: string; args: string): string =
  let r = execCmdEx("env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE " &
    "-u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY " &
    "GIT_AUTHOR_NAME=f GIT_AUTHOR_EMAIL=f@example.invalid " &
    "GIT_COMMITTER_NAME=f GIT_COMMITTER_EMAIL=f@example.invalid git " & args,
    workingDir = dir)
  doAssert r.exitCode == 0, "git " & args & ":\n" & r.output
  r.output.strip()

suite "the engine's sibling observation names an unfetched pin":
  let root = createTempDir("repro-unfetched-pin-", "")
  let upstream = root / "upstream"
  createDir(upstream)
  discard git(upstream, "init -q")
  writeFile(upstream / "a.nim", "proc a*() = discard\n")
  discard git(upstream, "add -A")
  discard git(upstream, "commit -qm old")
  let oldRev = git(upstream, "rev-parse HEAD")
  writeFile(upstream / "a.nim", "proc a*() = discard\nproc b*() = discard\n")
  discard git(upstream, "commit -qam new")
  let pin = git(upstream, "rev-parse HEAD")

  # Behind the pin, and holding it: a full clone checked out at the old commit.
  let behind = root / "behind"
  discard git(root, "clone -q " & upstream & " behind")
  discard git(behind, "checkout -q " & oldRev)
  # Behind the pin, and NOT holding it: only the old commit was ever fetched.
  let unfetched = root / "unfetched"
  createDir(unfetched)
  discard git(unfetched, "init -q")
  discard git(unfetched, "fetch -q " & upstream & " " & oldRev)
  discard git(unfetched, "checkout -q " & oldRev)

  test "the fixture holds what its names say":
    check execCmdEx("git -C " & unfetched & " cat-file -e " & pin).exitCode != 0
    check git(behind, "cat-file -t " & pin) == "commit"

  test "a sibling that never fetched its pin is stale, and the report says fetch":
    let obs = observeSiblingCheckout(unfetched, pin, siblingPresent = true,
      envPinPresent = false)
    check obs.headRev == oldRev
    check not obs.atOrAhead
    check obs.pinMissing
    let choice = chooseSiblingSource(spAuto, obs)
    check choice.kind == sskStaleSibling
    check "never fetched" in choice.why
    check shortRevision(pin) in choice.why
    # With a pinned tree named, the same sibling gives way to it.
    var withPin = obs
    withPin.envPinPresent = true
    let replaced = chooseSiblingSource(spAuto, withPin)
    check replaced.kind == sskEnvPin
    check "never fetched" in replaced.why

  test "a sibling behind a pin it holds is stale, and the report does not say fetch":
    let obs = observeSiblingCheckout(behind, pin, siblingPresent = true,
      envPinPresent = false)
    check not obs.atOrAhead
    check not obs.pinMissing
    let choice = chooseSiblingSource(spAuto, obs)
    check choice.kind == sskStaleSibling
    check "never fetched" notin choice.why
    check "not at or ahead of" in choice.why

  test "a sibling at its pin is not probed for the pin's presence":
    discard git(behind, "checkout -q " & pin)
    let obs = observeSiblingCheckout(behind, pin, siblingPresent = true,
      envPinPresent = false)
    check obs.atOrAhead
    check not obs.pinMissing
    check chooseSiblingSource(spAuto, obs).kind == sskSibling

  removeDir(root)
