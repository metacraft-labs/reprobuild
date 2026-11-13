## `repro lock refresh` of a committed lock solved for ANOTHER platform than
## the host's keeps that solve and every pin it carries, and only advances the
## sibling revisions that are stale (Locking-And-Solver.md §"Generating a lock
## file under a strategy" — the platform is a deliberate axis of the lock;
## Unified-Locking-And-Hooks.md §13.2/§13.3 — the sibling re-pin is an
## observation, not a solve).
##
## WHY. A committed `repro.lock` solved for amd64-linux was refreshed on an
## amd64-windows host to clear a `committed_lock_sibling_pin_stale` pre-push
## refusal (the refusal's own remedy). The refresh re-solved for the HOST:
## `platform` became amd64-windows, `inputs_digest` changed, the package list
## shrank 40 -> 26, and — because that workspace's manifest checkout no longer
## declared the repo's `depends` — the sibling pins shrank 49 -> 5. The same
## defect was recorded for macOS (issue 2026-10-23). The commit-time re-pin
## the refusal also names never had the problem: it splices only the `deps`
## line and never removes an entry. A refresh on a host that cannot redo the
## lock's solve now does exactly that re-pin.
##
## Fixture: `committed_lock_siblings_fixture.nim` — a real manifest workspace
## (app → lib-b → lib-c, lib-d unrelated) of real git repositories cloned from
## real bare origins, refreshed and published with the built `repro`. The
## committed lock is given the recorder's shape: a platform other than the
## host's, and a sibling pin (lib-d) the CURRENT manifest's develop set no
## longer names, as a stale workspace manifest leaves it.
##
## Cases:
##   * the regression: the refresh exits 0, keeps `platform`, `packages`,
##     `inputs_digest` and every other non-`deps` line byte-identical, keeps
##     the dep set (lib-d included) and the lock's own entry, advances exactly
##     the two stale siblings, and says why it did not re-solve;
##   * falsifier: `--platform=<host>` is the deliberate re-solve and does
##     re-target the lock to the host (so the platform assertion above can
##     fail);
##   * falsifier: a lock solved for THIS host is still re-solved (the
##     interception is limited to a foreign platform);
##   * a sibling BEHIND its pin still refuses (exit 4, nothing written), and
##     `--allow-pin-regression` still allows it, platform kept;
##   * `--repin`, `--provisioning`, `--strategy` / `--lowest` / `--highest`,
##     `--inputs` and `--registry` shape a solve, so each refuses by name
##     (exit 2, nothing written) and names `--platform`;
##   * through the real `pre-commit` hook: the commit-time re-pin of the same
##     foreign-platform lock keeps the solve and the dep set too.
##
## NO MOCKS. The hook file is written by hand rather than by
## `repro hooks ensure --vcs` so that it names the built binary by absolute
## path (a `repro` on PATH cannot stand in for the one under test); its body
## is the managed body's dispatch line.

import std/[algorithm, envvars, os, strutils, unittest]
import repro_test_support
import ./committed_lock_siblings_fixture

const AllowEnv = "REPRO_ALLOW_PIN_REGRESSION"

const HostPlatform = hostCPU & "-" & hostOS
  ## What `repro_lock/identity.currentPlatformId` records for this host.

const ForeignPlatform =
  if HostPlatform == "amd64-linux": "arm64-macosx" else: "amd64-linux"
  ## A platform this host is not: the recorder's amd64-linux, unless this
  ## host IS amd64-linux.

proc field(entry, key: string): string =
  let k = key & " = \""
  let at = entry.find(k)
  if at < 0: return "<absent>"
  let stop = entry.find('"', at + k.len)
  entry[at + k.len ..< stop]

proc pinOf(lockBody, name: string): string =
  field(depEntry(lockBody, name), "revision")

proc platformOf(lockBody: string): string =
  field(linePrefixed(lockBody, "platform = "), "platform")

proc depNames(lockBody: string): seq[string] =
  ## Every sibling `deps` entry's name, sorted. The lock's own entry (marked
  ## `self = "true"`, named after its origin) is compared separately.
  let line = linePrefixed(lockBody, "deps = [")
  var i = 0
  while true:
    let at = line.find("{ name = \"", i)
    if at < 0: break
    let start = at + "{ name = \"".len
    let stop = line.find('"', start)
    let close = line.find('}', stop)
    if "self = \"true\"" notin line[at .. close]:
      result.add(line[start ..< stop])
    i = close
  result.sort()

proc nonDepsLines(lockBody: string): seq[string] =
  ## The lock with its `deps` line taken out: the solve, the platform and
  ## everything else a sibling re-pin must leave byte-identical.
  for line in lockBody.splitLines():
    if not line.startsWith("deps = ["): result.add(line)

proc clearAllowEnv() =
  ## `REPRO_ALLOW_PIN_REGRESSION` unset in this process, so a value exported
  ## in the suite's environment cannot leak into a child. Set in-process
  ## rather than as a `VAR=value cmd` prefix, which `cmd.exe` does not run.
  delEnv(AllowEnv)

proc refresh(fx: SiblingFixture; extra = ""): tuple[code: int; output: string] =
  ## `repro lock refresh <app> [extra]`.
  clearAllowEnv()
  runCmd(q(fx.repro) & " lock refresh " & q(fx.app) &
    (if extra.len > 0: " " & extra else: ""))

type Started = object
  fx: SiblingFixture
  committed: string ## the lock as HEAD carries it, foreign platform
  libBSeed: string  ## lib-b's first commit
  libBPin, libCPin, libDPin: string

proc startWithLock(label: string; platform: string): Started =
  ## A published lock pinning lib-b, lib-c and lib-d, with `platform` set to
  ## ``platform``; then the manifest stops naming lib-d (a stale manifest's
  ## develop set), so only the committed lock still records it.
  var fx = setupSiblingFixture(label)
  result.libBSeed = fx.headOf(fx.ws / "lib-b")
  discard fx.advance("lib-b")
  fx.setAppDepends(@["lib-b", "lib-d"])
  fx.refreshAndPublishLock()
  var body = readFile(fx.app / "repro.lock")
  doAssert platformOf(body) == HostPlatform,
    "the fixture's refresh did not solve for this host:\n" & body
  if platform != HostPlatform:
    let hostLine = "platform = \"" & HostPlatform & "\""
    doAssert hostLine in body
    body = body.replace(hostLine, "platform = \"" & platform & "\"")
    writeFile(fx.app / "repro.lock", body)
    discard fx.git(fx.app, "add repro.lock")
    discard fx.git(fx.app, "commit -q -m retarget-lock")
    discard fx.git(fx.app, "push -q origin main")
  fx.setAppDepends(@["lib-b"])
  result.committed = fx.git(fx.app, "show HEAD:repro.lock")
  doAssert platformOf(result.committed) == platform
  doAssert depNames(result.committed) == @["lib-b", "lib-c", "lib-d"],
    "the baseline lock does not carry the expected deps:\n" & result.committed
  result.libBPin = pinOf(result.committed, "lib-b")
  result.libCPin = pinOf(result.committed, "lib-c")
  result.libDPin = pinOf(result.committed, "lib-d")
  result.fx = fx

proc hookPath(fx: SiblingFixture): string =
  fx.app / ".git" / "hooks" / "pre-commit"

proc installHook(fx: SiblingFixture) =
  let hook = fx.hookPath()
  createDir(hook.parentDir)
  writeFile(hook,
    "#!/usr/bin/env sh\nset -eu\n" &
    "REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)\n" &
    "cd \"$REPO_ROOT\"\nREPRO_STATUS=0\n" &
    "'" & fx.repro.replace('\\', '/') & "'" &
      " hooks dispatch pre-commit --repo-root \"$REPO_ROOT\" " &
      "-- \"$@\" || REPRO_STATUS=$?\nexit $REPRO_STATUS\n")
  var perms = getFilePermissions(hook)
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(hook, perms)

suite "repro lock refresh keeps a lock solved for another platform":

  test "t_a_refresh_on_another_platforms_lock_advances_only_the_stale_pins":
    var s = startWithLock("foreign-refresh", ForeignPlatform)
    let libB = s.fx.advance("lib-b")
    let libD = s.fx.advance("lib-d")
    let r = s.fx.refresh()
    checkpoint(r.output)
    check r.code == 0
    let after = readFile(s.fx.app / "repro.lock")
    checkpoint(after)
    # The solve and the platform: every line but `deps`, byte for byte.
    check platformOf(after) == ForeignPlatform
    check nonDepsLines(after) == nonDepsLines(s.committed)
    # The dep set, including the pin the current manifest no longer names.
    check depNames(after) == depNames(s.committed)
    # Only the stale revisions moved.
    check pinOf(after, "lib-b") == libB
    check pinOf(after, "lib-d") == libD
    check pinOf(after, "lib-c") == s.libCPin
    # The lock's own entry is not re-observed by a re-pin.
    check depEntry(after, ".") == depEntry(s.committed, ".")
    # And the refresh said why it did not re-solve, and how to.
    check ForeignPlatform in r.output
    check ("--platform=" & HostPlatform) in r.output
    check "re-pin" in r.output
    # Idempotent: a second refresh over unmoved siblings writes nothing.
    let again = s.fx.refresh()
    checkpoint(again.output)
    check again.code == 0
    check readFile(s.fx.app / "repro.lock") == after
    check "up to date" in again.output

  test "t_an_explicit_platform_re_solves_for_this_host":
    # Falsifier for the case above: the platform assertion CAN fail, and the
    # deliberate re-target is still available.
    var s = startWithLock("foreign-explicit", ForeignPlatform)
    let r = s.fx.refresh("--platform=" & HostPlatform)
    checkpoint(r.output)
    check r.code == 0
    let after = readFile(s.fx.app / "repro.lock")
    checkpoint(after)
    check platformOf(after) == HostPlatform
    check "entry point repro lock refresh" in r.output

  test "t_a_lock_solved_for_this_host_is_still_re_solved":
    # Falsifier: only a FOREIGN platform is intercepted. On the lock's own
    # platform the refresh is the ordinary re-solve, which drops the pin the
    # current manifest no longer names (and says so).
    var s = startWithLock("host-refresh", HostPlatform)
    let r = s.fx.refresh()
    checkpoint(r.output)
    check r.code == 0
    let after = readFile(s.fx.app / "repro.lock")
    checkpoint(after)
    check platformOf(after) == HostPlatform
    check "entry point repro lock refresh" in r.output
    check "sibling re-pin" notin r.output
    check "lib-d" notin depNames(after)
    check "dropping sibling 'lib-d'" in r.output

  test "t_a_behind_sibling_still_refuses_on_another_platforms_lock":
    var s = startWithLock("foreign-behind", ForeignPlatform)
    let libB = s.fx.ws / "lib-b"
    discard s.fx.git(libB, "checkout -q " & s.libBSeed)
    let refused = s.fx.refresh()
    checkpoint(refused.output)
    check refused.code == 4
    check readFile(s.fx.app / "repro.lock") == s.committed
    check "lib-b" in refused.output
    check "behind by 1" in refused.output
    check "--allow-pin-regression=lib-b" in refused.output
    let allowed = s.fx.refresh("--allow-pin-regression=lib-b")
    checkpoint(allowed.output)
    check allowed.code == 0
    let after = readFile(s.fx.app / "repro.lock")
    check pinOf(after, "lib-b") == s.libBSeed
    check platformOf(after) == ForeignPlatform
    check nonDepsLines(after) == nonDepsLines(s.committed)
    check depNames(after) == depNames(s.committed)

  test "t_solve_shaping_flags_need_a_solve_this_host_cannot_do":
    # Each flag asks for a solve the sibling re-pin does not do, so it is
    # refused by name rather than silently ignored. `--inputs` names a file
    # that exists, so the refusal cannot be a missing-file error.
    var s = startWithLock("foreign-repin", ForeignPlatform)
    discard s.fx.advance("lib-b")
    let inputs = s.fx.scratch / "solver-inputs.txt"
    writeFile(inputs, "package app\nversions: 0.1.0\n")
    for (arg, flag) in [("--repin=nim", "--repin"),
        ("--provisioning", "--provisioning"),
        ("--lowest", "--lowest"), ("--highest", "--highest"),
        ("--strategy=lowest", "--strategy"),
        ("--inputs " & q(inputs), "--inputs"),
        ("--registry=https://registry.invalid/index", "--registry")]:
      let r = s.fx.refresh(arg)
      checkpoint(arg & ":\n" & r.output)
      check r.code == 2
      check readFile(s.fx.app / "repro.lock") == s.committed
      check ForeignPlatform in r.output
      check (flag & " shapes a solve") in r.output
      check ("--platform=" & HostPlatform) in r.output

  test "t_the_commit_time_re_pin_keeps_another_platforms_solve":
    var s = startWithLock("foreign-hook", ForeignPlatform)
    let libB = s.fx.advance("lib-b")
    s.fx.installHook()
    writeFile(s.fx.app / "work.txt", "work\n")
    discard s.fx.git(s.fx.app, "add work.txt")
    clearAllowEnv()
    let c = runCmd(q(s.fx.gitBin) & " -C " & q(s.fx.app) &
      " commit -m work")
    checkpoint(c.output)
    check c.code == 0
    let after = s.fx.git(s.fx.app, "show HEAD:repro.lock")
    checkpoint(after)
    check platformOf(after) == ForeignPlatform
    check nonDepsLines(after) == nonDepsLines(s.committed)
    check depNames(after) == depNames(s.committed)
    check pinOf(after, "lib-b") == libB
    check pinOf(after, "lib-d") == s.libDPin
    check pinOf(after, "lib-c") == s.libCPin
