## What the daemon's worker does when it cannot join the caller's cgroup
## (``repro_daemon_core/caller_cgroup``), which keeps a daemon-hosted build
## under the memory cap and other limits its caller runs under.
##
## A worker that cannot move into the caller's cgroup may run the build where
## it is only when the same limits govern both places; any difference, in
## either direction, declines the request so that the client builds in its
## own process under its own limits.
##
## MOCK POLICY. The cgroup hierarchy here is a PREPARED DIRECTORY TREE, not
## the kernel's. Justification: the arms under test are the ones where the
## move FAILS, which on a real hierarchy needs a caller in a cgroup this user
## cannot write (a root-owned session scope) and a second, differently limited
## cgroup for the worker -- neither of which an unprivileged test can create.
## The tree stands in for the hierarchy only; the move itself is real: it
## writes the prepared ``cgroup.procs`` and then checks ``/proc/self/cgroup``,
## which a prepared tree can never satisfy, so it fails exactly as a
## permission refusal would. The arm where the move SUCCEEDS runs against the
## real hierarchy with a real daemon and build in
## ``tests/integration/t_daemon_hosted_build_runs_under_the_callers_cgroup``.

import std/[os, strutils, tempfiles, unittest]

import repro_daemon_core/caller_cgroup
import repro_test_support/reasoned_skip

proc makeCgroup(root, path: string;
                limits: openArray[(string, string)] = []) =
  createDir(root & path)
  for (file, value) in limits:
    writeFile(root & path / file, value & "\n")

suite "daemon worker cgroup placement":
  test "no hierarchy or no caller cgroup: nothing to honour":
    check placeInCallerCgroup("/a/caller", root = "",
      workerCgroup = "/a/worker").kind == cpkNotApplicable
    check placeInCallerCgroup("", root = "/sys/fs/cgroup",
      workerCgroup = "/a/worker").kind == cpkNotApplicable

  test "already in the caller's cgroup":
    check placeInCallerCgroup("/a/caller", root = "/nonexistent",
      workerCgroup = "/a/caller").kind == cpkAlreadyThere

  test "an unjoinable caller under a cap the worker lacks is refused":
    let root = createTempDir("repro-cg-refuse-", "")
    defer: removeDir(root)
    makeCgroup(root, "/a")
    makeCgroup(root, "/a/caller", [("memory.max", "17179869184"),
      ("pids.max", "4096")])
    makeCgroup(root, "/a/worker", [("memory.max", "max"),
      ("pids.max", "max"), ("cpu.max", "max 100000")])
    let placement = placeInCallerCgroup("/a/caller", root = root,
      workerCgroup = "/a/worker")
    check placement.kind == cpkRefused
    check "memory.max=17179869184 on /a/caller" in placement.detail
    check "pids.max=4096 on /a/caller" in placement.detail
    check "/a/caller" in declineMessage(placement)

  test "a worker under a cap the caller lacks is refused too":
    # The other half of the issue: a daemon started inside one session's
    # capped unit must not impose that cap on another session's build.
    let root = createTempDir("repro-cg-foreign-", "")
    defer: removeDir(root)
    makeCgroup(root, "/a")
    makeCgroup(root, "/a/caller")
    makeCgroup(root, "/a/worker", [("memory.high", "8589934592")])
    let placement = placeInCallerCgroup("/a/caller", root = root,
      workerCgroup = "/a/worker")
    check placement.kind == cpkRefused
    check "the daemon's worker is limited by memory.high=8589934592 on " &
      "/a/worker" in placement.detail

  test "limits on a shared ancestor govern both, so the build may stay":
    let root = createTempDir("repro-cg-shared-", "")
    defer: removeDir(root)
    makeCgroup(root, "/a", [("memory.max", "34359738368"),
      ("cpu.max", "400000 100000")])
    makeCgroup(root, "/a/caller", [("memory.max", "max")])
    makeCgroup(root, "/a/worker")
    let placement = placeInCallerCgroup("/a/caller", root = root,
      workerCgroup = "/a/worker")
    check placement.kind == cpkSameLimits
    # Why it could not move is still recorded.
    check placement.detail.len > 0

  test "the limits of every ancestor are collected":
    let root = createTempDir("repro-cg-limits-", "")
    defer: removeDir(root)
    makeCgroup(root, "/u", [("pids.max", "10000")])
    makeCgroup(root, "/u/s", [("memory.swap.max", "0")])
    makeCgroup(root, "/u/s/leaf", [("memory.max", "1073741824"),
      ("cpu.max", "max 100000")])
    let limits = effectiveCgroupLimits(root, "/u/s/leaf")
    check limits.len == 3
    check CgroupLimit(cgroup: "/u/s/leaf", file: "memory.max",
      value: "1073741824") in limits
    check CgroupLimit(cgroup: "/u/s", file: "memory.swap.max",
      value: "0") in limits
    check CgroupLimit(cgroup: "/u", file: "pids.max", value: "10000") in limits

  test "the cgroup v2 mount and a process's v2 path are read":
    let dir = createTempDir("repro-cg-proc-", "")
    defer: removeDir(dir)
    writeFile(dir / "mountinfo",
      "24 1 0:22 / /proc rw,nosuid shared:5 - proc proc rw\n" &
      "30 24 0:26 / /sys/fs/cgroup rw,nosuid shared:9 - cgroup2 cgroup2 " &
      "rw,nsdelegate\n")
    check cgroupV2Root(dir / "mountinfo") == "/sys/fs/cgroup"
    writeFile(dir / "cgroup",
      "12:pids:/legacy\n0::/user.slice/user-1000.slice/app.slice/x.scope\n")
    check cgroupV2PathOf(dir / "cgroup") ==
      "/user.slice/user-1000.slice/app.slice/x.scope"
    check cgroupV2PathOf(dir / "missing") == ""

  test "this process's own cgroup is the kernel's answer":
    when defined(linux):
      if cgroupV2Root().len == 0:
        skip("no cgroup v2 hierarchy is mounted")
      else:
        check ownCgroupV2Path().startsWith("/")
        check ownCgroupV2Path() == cgroupV2PathOfPid(getCurrentProcessId())
    else:
      skip("cgroups are a Linux facility")
