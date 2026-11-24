## The lease-layer probe reports the floor only where a floor lease can map
## its user.
##
## `availableLeaseLayers` used to report the floor whenever `newuidmap` and
## `newgidmap` were on `PATH` and `/etc/subuid`, `/etc/subgid` named the
## user. Inside a user namespace that does not map real root (an agent
## sandbox whose `/proc/self/uid_map` is `1004 1004 1`), the setuid helpers
## run without privilege and refuse every map, so the probe said "floor" and
## every floor lease then failed to start with `could not map the lease
## user`. Three cases:
##
## 1. In a NESTED user namespace that maps only the caller's own uid and gid
##    -- the sandbox's condition, recreated on any Linux host that has
##    unprivileged user namespaces, a subordinate range and the helpers --
##    the trusted profile's answer leaves the floor out and its reason
##    quotes the helper's refusal; the hardened profile is refused naming
##    the floor. Before the fix the floor was reported there.
## 2. On this host as it is, the probe's answer agrees with a real floor
##    lease: the floor is reported exactly when a lease with the floor
##    starts (and a lease that cannot start fails on the id mapping, naming
##    the helper). This pins the probe in BOTH directions: a probe that
##    reports the floor too eagerly fails here on a host like the sandbox,
##    and one that refuses it where it works fails here on every CI host.
## 3. The decision seam (pure): a probe that found the helpers but recorded
##    their refusal gets no floor in either profile, with the refusal in the
##    reason, and a probe without a refusal still gets it.
##
## MOCK POLICY -- none: the real helpers, the real `/etc/subuid`, a real
## user namespace and a real lease.

import std/[asyncdispatch, os, strutils, tempfiles, unittest]
when defined(posix):
  import std/posix

import repro_distributed_worker

import repro_test_support/reasoned_skip

when defined(linux):
  var CLONE_NEWUSER {.importc, header: "<sched.h>".}: cint
  proc c_unshare(flags: cint): cint {.importc: "unshare",
    header: "<sched.h>".}

  proc writeProcFile(path, content: string): bool =
    try:
      writeFile(path, content)
      true
    except IOError, OSError:
      false

  proc probeInsideOwnUidOnlyNamespace(dir: string): tuple[ran: bool;
      setup: string; ok: bool; floor: bool; reason: string;
      hardenedOk: bool; hardenedReason: string] =
    ## Forks a child that enters a new user namespace mapping only its own
    ## uid and gid (real root unmapped, as in the sandbox the issue was
    ## found in) and runs the host probe and both profile decisions there.
    let uid = getuid()
    let gid = getgid()
    let pid = posix.fork()
    if pid == 0:
      var setup = ""
      if c_unshare(CLONE_NEWUSER) != 0:
        setup = "unshare(CLONE_NEWUSER): " & $strerror(errno)
      elif not writeProcFile("/proc/self/setgroups", "deny"):
        setup = "could not write /proc/self/setgroups"
      elif not writeProcFile("/proc/self/uid_map", $uid & " " & $uid & " 1\n"):
        setup = "could not write /proc/self/uid_map"
      elif not writeProcFile("/proc/self/gid_map", $gid & " " & $gid & " 1\n"):
        setup = "could not write /proc/self/gid_map"
      if setup.len > 0:
        writeFile(dir / "setup", setup)
        quit(0)
      let probe = probeLinuxLeaseHost()
      let t = decideLinuxLeaseLayers(probe, hardened = false)
      let h = decideLinuxLeaseLayers(probe, hardened = true)
      writeFile(dir / "trusted", $t.ok & "\n" & $(llFloor in t.layers) &
        "\n" & t.reason)
      writeFile(dir / "hardened", $h.ok & "\n" & h.reason)
      quit(0)
    var status: cint
    discard posix.waitpid(pid, status, 0)
    result.ran = fileExists(dir / "trusted") or fileExists(dir / "setup")
    if fileExists(dir / "setup"):
      result.setup = readFile(dir / "setup")
      return
    if not fileExists(dir / "trusted"):
      return
    let t = readFile(dir / "trusted").split('\n', 2)
    result.ok = t[0] == "true"
    result.floor = t[1] == "true"
    result.reason = t[2]
    let h = readFile(dir / "hardened").split('\n', 1)
    result.hardenedOk = h[0] == "true"
    result.hardenedReason = h[1]

suite "the lease-layer probe reports the floor only where it can be mapped":

  test "inside a user namespace that does not map root, no floor":
    when not defined(linux):
      skip("platform N/A: the floor and its id-mapping helpers are Linux-only")
    else:
      let host = probeLinuxLeaseHost()
      checkpoint("this host: " & $host)
      if not (host.userNamespaces and host.subordinateIds and
          host.idMappingTools):
        skip("this host lacks unprivileged user namespaces, a subordinate " &
          "id range or newuidmap/newgidmap, so the floor is never reported " &
          "and the condition under test cannot arise: " & $host)
      else:
        let dir = createTempDir("lease-floor-probe-", "")
        defer: removeDir(dir)
        let r = probeInsideOwnUidOnlyNamespace(dir)
        checkpoint("inside the namespace: " & $r)
        check r.ran
        check r.setup.len == 0
        check r.ok                          # trusted still runs a worker
        check not r.floor                   # ... without the floor
        check "the floor" in r.reason
        check "newuidmap/newgidmap cannot map the lease user" in r.reason
        # The helper's own words are quoted after the name of the helper
        # that refused (newgidmap runs first).
        check "(newgidmap: " in r.reason or "(newuidmap: " in r.reason
        check not r.hardenedOk
        check "the floor" in r.hardenedReason

  test "on this host the probe agrees with a real floor lease":
    when not defined(linux):
      skip("platform N/A: the floor and its id-mapping helpers are Linux-only")
    else:
      let available = availableLeaseLayers()
      checkpoint("lease layers on this host: " & $available)
      check available.ok
      # Directly under /tmp, not $TMPDIR: the floor's subordinate uid must
      # search every ancestor of its lease, and the dev shell's TMPDIR is
      # owner-only, which would fail the traversal below for a reason that
      # has nothing to do with the id mapping.
      let base = createTempDir("lease-floor-agree-", "", "/tmp")
      defer: removeDir(base)
      let leaseRoot = base / "leases"
      let leaseDir = leaseRoot / "floor-agree"
      createDir(leaseDir / "wt" / "out")
      createDir(leaseDir / "tmp")
      createDir(leaseDir / "home")
      # The floor's subordinate uid must be able to reach its lease.
      let traversal = ensureLeaseTraversal(leaseRoot, base)
      checkpoint("traversal: " & $traversal)
      check traversal.ok
      for d in [leaseDir, leaseDir / "wt", leaseDir / "wt" / "out",
                leaseDir / "tmp", leaseDir / "home"]:
        setFilePermissions(d, {fpUserRead, fpUserWrite, fpUserExec,
          fpGroupRead, fpGroupWrite, fpGroupExec, fpOthersRead,
          fpOthersWrite, fpOthersExec})
      let spec = LeaseSpec(leaseId: "floor-agree", leaseRoot: leaseRoot,
        leaseDir: leaseDir, metaDir: base / "lease-meta" / "floor-agree",
        cwd: leaseDir / "wt", argv: @["/bin/sh", "-c", "exit 0"],
        env: @[("PATH", "/usr/bin:/bin"), ("HOME", leaseDir / "home"),
          ("TMPDIR", leaseDir / "tmp")],
        readRoots: @["/usr", "/bin", "/lib", "/lib64", "/etc", "/nix/store"],
        closureRoots: @["/usr/bin", "/bin", "/usr/lib", "/lib", "/lib64",
          "/nix/store"],
        outputDirs: @[leaseDir / "wt" / "out"],
        layers: {llNamespace, llFloor}, timeoutMs: 60_000)
      createDir(spec.metaDir)
      let outcome = waitFor runLease(spec)
      checkpoint("floor lease: started=" & $outcome.started & " exit=" &
        $outcome.exitCode & " error=" & outcome.error & " stderr=" &
        outcome.stderr)
      discard cleanupLease(spec)
      let reported = llFloor in available.layers
      check outcome.started == reported
      if reported:
        check outcome.exitCode == 0
      elif "could not map the lease user" in outcome.error:
        # A lease the helpers refused names the refusing helper.
        check "newgidmap: " in outcome.error or "newuidmap: " in outcome.error

  test "the decision drops the floor the helpers refuse, in both profiles":
    let refused = LinuxLeaseHostProbe(userNamespaces: true, pidfdGetfd: true,
      landlock: true, subordinateIds: true, idMappingTools: true,
      idMappingRefusal: "newgidmap: write to gid_map failed: Operation " &
        "not permitted")
    let t = decideLinuxLeaseLayers(refused, hardened = false)
    check t.ok
    check t.layers == {llNamespace, llLandlock}
    check "write to gid_map failed" in t.reason
    let h = decideLinuxLeaseLayers(refused, hardened = true)
    check not h.ok
    check "the floor" in h.reason
    check "write to gid_map failed" in h.reason
    # Positive control: the same host whose helpers mapped keeps the floor.
    var mapped = refused
    mapped.idMappingRefusal = ""
    check decideLinuxLeaseLayers(mapped, hardened = false).layers ==
      DefaultLeaseLayers
    check decideLinuxLeaseLayers(mapped, hardened = true).ok
