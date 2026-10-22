## Distributed-Execution M7: `t_execution_lease_confinement_layer_by_layer`.
##
## A goal whose action attempts to READ ANOTHER LEASE'S WORKTREE, WRITE
## OUTSIDE ITS OWN, or REACH THE DAEMON is contained under the full stack;
## then each layer is removed alone and the one breach it stops appears:
##
##   without the namespace layer  -> it reads the neighbour's worktree
##   without Landlock             -> it writes outside the lease
##   without the floor            -> it CONNECTS TO THE DAEMON'S CONTROL
##                                   SOCKET (`BREACH-daemon-socket`); and on
##                                   Linux it also reads a daemon-owned 0600
##                                   file, because it shares the daemon's
##                                   uid (`BREACH-uid-file`)
##
## Each reddens separately (each case asserts its breach and only it), and
## the daemon's STATE (its keys) stays unreadable in every configuration,
## because two layers cover it. Positive control: in every configuration a
## legitimate build in the lease still compiles (a real C compile, inside
## the lease) and publishes its output — the confinement is not a lease
## that cannot do anything. DET-1: an exec of a binary written into the
## lease's TMPDIR (outside the closure) is refused and REPORTED by the
## lease supervisor under the full stack. And in EVERY configuration, a
## descriptor the worker process holds without close-on-exec does not reach
## the action (`BREACH-fd`): the lease closes everything it inherits.
##
## Linux: the layers are `c/repro_lease_linux.c` (namespaces, Landlock,
## subordinate-uid floor + seccomp). macOS: the same three layers as
## Seatbelt rule groups (`lease.nim`), with the macOS deviation recorded in
## the threat model.
##
## TRUST PROFILES (2026-10-20). Lease confinement is kept in BOTH profiles
## (the trusted profile's sandbox is the Nix-style one: correctness). Since
## then the Linux namespace layer is a NEW ROOT holding only the read roots,
## the closure and the lease, with every writable mount noexec. Two
## consequences, stated rather than hidden:
##
##   * the probe is an approved TOOL (compiled by the test into a closure
##     root), not a binary the lease built: a binary written into the lease
##     cannot execute any more. The lease still compiles the same source
##     (the positive control: a legitimate build publishes its output);
##   * on Linux, removing Landlock ALONE no longer lets a write out — the
##     new root mounts nothing writable outside the lease. Landlock's write
##     rule is load-bearing where the namespace layer is gone, so its breach
##     is asserted in the configuration without BOTH (`no-ns-no-landlock`),
##     and the `no-landlock` case asserts the new root still contains it.
##     The daemon's socket lives under a READ root here (read-only mounts
##     do not stop `connect`, and a PATHNAME unix socket is not scoped by
##     the lease's network namespace), so the floor is still the only thing
##     between the lease and the daemon: it refuses a connect to any unix
##     socket that EXISTS in the lease's view and reports it
##     (`egress-denied`, `unix:<the daemon's socket>`), and without the
##     floor the supervisor still checks and reports the connect
##     (`unix-socket-connect`) — asserted in both configurations.
##
## G38 (coordinator decision 2026-10-20): an attempt that cannot reach
## anything is not reported. The positive control's compile makes the C
## library's nscd probe (a connect to /var/run/nscd/socket, which does not
## exist in the new root); the full stack's reports must name NO unix
## destination but the daemon's socket, and no `socket family 1` denial
## (creating a unix socket grants nothing; reaching one is what is refused).
##
## The second test is the noexec control: a plain binary written into the
## lease's declared output directory — a directory the closure check and
## Landlock both allow executing from — does NOT run, because the mount is
## noexec; an approved toolchain binary does (Linux; macOS leases are the
## Seatbelt isolation level, which allows executing declared outputs). And
## without the floor (and Landlock) — the lease is then the namespace's root
## and owns the new root's top level — it cannot write a binary there: the
## new root's own tmpfs is read-only once entered (and noexec), so "every
## writable mount is noexec" does not lean on the floor's different uid. (A
## copy it runs from `/dev` is refused both by the noexec mount and by the
## closure check, so that line is defence in depth.)
##
## The third test is the HARDENED memfd policy (Linux 6.3+): with
## `LeaseSpec.memfdNoexec` a `memfd_create` without `MFD_NOEXEC_SEAL` is
## refused and reported (`syscall-denied`) and the lease's isolation level
## carries `+memfd-noexec`; a sealed (non-executable) memfd is still created
## (positive control), and the same lease without the policy creates both
## (the policy, not the kernel, refused the first).
##
## MOCK POLICY — none. The "daemon" is the shipped `repro daemon serve`
## process; its control socket and state directory are the real ones.

import std/[asyncdispatch, os, osproc, posix, strtabs, strutils, times, unittest]

import repro_test_support
import repro_distributed_worker

import repro_test_support/reasoned_skip
import ./m7_worker_fixture

const ProbeSource = """
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
int main(int argc, char **argv) {
  /* argv: neighbour-secret canary-path daemon-key daemon-socket
     daemon-private-file fd. The floor refuses a connect to any unix socket
     that exists in the lease's view, so the daemon's control socket cannot
     be reached; and it runs the lease as a DIFFERENT
     uid, so a daemon-owned 0600 file that is otherwise visible (under a
     read root) cannot be read. Without the floor both succeed. */
  char buf[256];
  int fd = open(argv[1], O_RDONLY);
  if (fd >= 0 && read(fd, buf, sizeof buf) > 0) puts("BREACH-neighbour");
  if (fd >= 0) close(fd);
  fd = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd >= 0) { if (write(fd, "x", 1) == 1) puts("BREACH-write"); close(fd); }
  fd = open(argv[3], O_RDONLY);
  if (fd >= 0 && read(fd, buf, sizeof buf) > 0) puts("BREACH-state");
  if (fd >= 0) close(fd);
  /* argv[4]: the daemon's control SOCKET. A connect is a breach. */
  { int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s >= 0) {
      struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
      strncpy(a.sun_path, argv[4], sizeof a.sun_path - 1);
      if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) puts("BREACH-daemon-socket");
      close(s);
    } }
  /* argv[5]: a daemon-owned 0600 FILE under a visible root (Linux; "" on
     macOS, whose lease shares the daemon's uid by design). A read is a
     breach of the floor's different uid. */
  if (argv[5][0]) {
    fd = open(argv[5], O_RDONLY);
    if (fd >= 0 && read(fd, buf, sizeof buf) > 0) puts("BREACH-uid-file");
    if (fd >= 0) close(fd);
  }
  /* argv[6]: a descriptor the worker process holds WITHOUT close-on-exec.
     Reading it from inside the lease means it crossed execve. */
  if (argc > 6) {
    int inherited = atoi(argv[6]);
    if (read(inherited, buf, sizeof buf) > 0) puts("BREACH-fd");
  }
  puts("probe-ran");
  return 0;
}
"""

proc socketExists(path: string): bool =
  ## `fileExists` is false for a socket; any directory entry will do here.
  try:
    discard getFileInfo(path, followSymlink = false)
    true
  except OSError:
    false

proc startPlainDaemon(d: var WorkerDaemon) =
  try: removeFile(d.endpoint) except OSError: discard
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  for (key, value) in daemonEnv(d): env[key] = value
  d.process = startProcess(publicReproBin(),
    args = @["daemon", "serve", "--foreground", "--endpoint", d.endpoint,
             "--state-dir", d.stateDir, "--log", d.logPath],
    workingDir = repoRootDir(), env = env,
    options = {poUsePath, poStdErrToStdOut, poParentStreams})
  let deadline = epochTime() + 60.0
  while epochTime() < deadline and not socketExists(d.endpoint):
    sleep(50)

suite "Distributed-Execution M7: execution-lease confinement, layer by layer":

  test "t_execution_lease_confinement_layer_by_layer":
    let cc = ccPath()
    let available = leaseConfinementAvailable()
    checkpoint("lease confinement on this host: " & $available)
    check available.ok
    check cc.len > 0
    if available.ok and cc.len > 0:
      let base = m7TestBase("repro-m7-confine")
      let leaseRoot = base / "worker-state" / "leases"
      let metaRoot = base / "lease-meta"
      # A neighbour lease with a worktree another lease must never see.
      createDir(leaseRoot / "neighbour" / "wt")
      writeFile(leaseRoot / "neighbour" / "wt" / "secret.c", "neighbour-secret\n")
      # A world-writable directory OUTSIDE every lease: if a lease can write
      # here, only Landlock stood in its way (the floor's lease user is not
      # the daemon's user, so a user-owned directory would test DAC instead).
      let outside = base / "outside"
      createDir(outside)
      setFilePermissions(outside, {fpUserRead, fpUserWrite, fpUserExec,
        fpGroupRead, fpGroupWrite, fpGroupExec, fpOthersRead, fpOthersWrite,
        fpOthersExec})
      # The daemon: a real one, its state dir holding a key.
      var daemon = newWorkerDaemon(base, newTestNode(base, "daemon"))
      daemon.stateDir = base / "worker-state"
      daemon.logPath = base / "daemon.log"
      createDir(daemon.stateDir)
      writeFile(daemon.stateDir / "host-ca.key", "daemon-private-key\n")
      # The probe TOOL, compiled outside the lease into a closure root.
      let tools = base / "tools"
      createDir(tools)
      writeFile(tools / "probe.c", ProbeSource)
      check execCmdEx(quoteShellCommand([cc, "-o", tools / "probe",
        tools / "probe.c"])).exitCode == 0
      when defined(linux):
        createDir(base / "run")
        daemon.endpoint = base / "run" / "daemon.sock"
      startPlainDaemon(daemon)
      # Linux: a daemon-owned 0600 file under a VISIBLE read root, beside
      # the control socket: only the floor's different uid keeps it unread.
      # macOS: none (the Seatbelt lease runs as the daemon's uid by design;
      # its floor is the unix-socket rule, asserted through the socket).
      let daemonPrivate =
        when defined(linux):
          let f = base / "run" / "daemon-private"
          writeFile(f, "daemon-only\n")
          setFilePermissions(f, {fpUserRead, fpUserWrite})
          f
        else:
          ""
      # A descriptor this (worker) process holds WITHOUT close-on-exec, the
      # way a library or a careless opener leaves one. Whatever the layers,
      # it must not reach the action: an inherited socket would bypass the
      # network namespace and the floor, a file the hidden state.
      writeFile(base / "fd-secret", "inherited-secret\n")
      let leakedFd = posix.open(cstring(base / "fd-secret"), O_RDONLY)
      check leakedFd >= 0
      defer:
        discard posix.close(leakedFd)
        stopWorkerDaemon(daemon)
        removeDir(base)
      check socketExists(daemon.endpoint)

      proc runCase(layers: set[LeaseLayer]; tag: string): tuple[output: string;
          built: bool; outcome: LeaseOutcome] =
        let id = "L-" & tag
        let leaseDir = leaseRoot / id
        createDir(leaseDir / "wt")
        writeFile(leaseDir / "wt" / "probe.c", ProbeSource)
        let canary = outside / ("canary-" & tag)
        let script = "set -u; \"$CC\" -o out/probe probe.c && " &
          "\"$PROBE\" \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" > out/probe.txt; " &
          "cp /bin/sh \"$TMPDIR/sh-copy\" && \"$TMPDIR/sh-copy\" -c true; true"
        let roots = (when defined(macosx):
            (@["/usr", "/bin", "/System", "/Library", "/private/etc",
               "/private/var/db/timezone", "/nix/store",
               "/Applications/Xcode.app"],
             @["/usr/bin", "/bin", "/usr/libexec", "/nix/store",
               "/Library/Developer/CommandLineTools", "/Applications/Xcode.app"])
          else:
            (@["/usr", "/bin", "/lib", "/lib64", "/etc", "/nix/store", "/opt"],
             @["/usr/bin", "/bin", "/usr/lib", "/nix/store"]))
        let spec = LeaseSpec(leaseId: id, leaseRoot: leaseRoot,
          leaseDir: leaseDir, metaDir: metaRoot / id, cwd: leaseDir / "wt",
          argv: @["/bin/sh", "-c", script, "sh",
            leaseRoot / "neighbour" / "wt" / "secret.c", canary,
            daemon.stateDir / "host-ca.key", daemon.endpoint, daemonPrivate,
            $leakedFd],
          env: @[("PATH", parentDir(cc) & ":/usr/bin:/bin"), ("CC", cc),
            ("PROBE", tools / "probe"),
            ("HOME", leaseDir / "home"), ("TMPDIR", leaseDir / "tmp")],
          readRoots: roots[0] & @[tools, base / "run"],
          closureRoots: roots[1] & @[tools],
          outputDirs: @[leaseDir / "wt" / "out"],
          extraWritable: (when defined(linux): @[base / "run"] else: @[]),
          hidePaths: @[daemon.stateDir], layers: layers, timeoutMs: 180_000)
        let outcome = waitFor runLease(spec)
        let probeOut = leaseDir / "wt" / "out" / "probe.txt"
        result.outcome = outcome
        result.output = if fileExists(probeOut): readFile(probeOut) else: ""
        result.built = fileExists(leaseDir / "wt" / "out" / "probe")
        checkpoint(tag & ": started=" & $outcome.started & " exit=" &
          $outcome.exitCode & " error=" & outcome.error & "\n  probe: " &
          result.output.replace("\n", " ") & "\n  stderr: " & outcome.stderr &
          "\n  reports: " & $outcome.reports)
        # Remove the canary (it may belong to the floor's lease user) and the
        # lease itself.
        if fileExists(canary):
          var c = spec
          c.leaseDir = canary
          discard cleanupLease(c)
        discard cleanupLease(spec)

      let full = runCase(DefaultLeaseLayers, "full")
      check full.outcome.started
      check full.built                                   # positive control
      check "probe-ran" in full.output
      for breach in ["BREACH-neighbour", "BREACH-write", "BREACH-state",
                     "BREACH-daemon-socket", "BREACH-uid-file", "BREACH-fd"]:
        check breach notin full.output
      when defined(linux):
        # The floor's refusal of the daemon-socket connect is REPORTED
        # (DET-2), not silent, and names the socket.
        var unixDenied = false
        for r in full.outcome.reports:
          if r.kind == "egress-denied" and
              r.detail == "unix:" & daemon.endpoint:
            unixDenied = true
        check unixDenied
        # G38: the compile's unreachable unix attempts (the libc's nscd
        # probe) are not reported, and creating a unix socket is not a
        # denial: the only unix destination reported is the daemon's.
        for r in full.outcome.reports:
          check not (r.kind == "syscall-denied" and
            "socket family 1" in r.detail)
          if r.detail.startsWith("unix:"):
            check r.detail == "unix:" & daemon.endpoint
      var execReported = false
      for r in full.outcome.reports:
        if r.kind == "exec-outside-closure" and "sh-copy" in r.detail:
          execReported = true
      check execReported                                 # DET-1

      let noNamespace = runCase(DefaultLeaseLayers - {llNamespace}, "no-ns")
      check noNamespace.built
      check "BREACH-neighbour" in noNamespace.output
      check "BREACH-write" notin noNamespace.output
      check "BREACH-daemon-socket" notin noNamespace.output
      check "BREACH-uid-file" notin noNamespace.output
      check "BREACH-state" notin noNamespace.output
      check "BREACH-fd" notin noNamespace.output

      let noLandlock = runCase(DefaultLeaseLayers - {llLandlock}, "no-landlock")
      check noLandlock.built
      when defined(linux):
        # The new root mounts nothing writable outside the lease.
        check "BREACH-write" notin noLandlock.output
        let neither = runCase(DefaultLeaseLayers - {llNamespace, llLandlock},
          "no-ns-no-landlock")
        check neither.built
        check "BREACH-write" in neither.output      # Landlock's breach
        check "BREACH-daemon-socket" notin neither.output
        check "BREACH-uid-file" notin neither.output
        # (BREACH-state is not asserted here: the two layers that keep the
        # daemon's state unreadable are exactly the two removed.)
        check "BREACH-fd" notin neither.output
      else:
        check "BREACH-write" in noLandlock.output
      check "BREACH-neighbour" notin noLandlock.output
      check "BREACH-daemon-socket" notin noLandlock.output
      check "BREACH-uid-file" notin noLandlock.output
      check "BREACH-state" notin noLandlock.output
      check "BREACH-fd" notin noLandlock.output

      let noFloor = runCase(DefaultLeaseLayers - {llFloor}, "no-floor")
      check noFloor.built
      check "BREACH-daemon-socket" in noFloor.output    # the floor's breach
      when defined(linux):
        check "BREACH-uid-file" in noFloor.output       # …and its uid
        # Without the floor the connect is still CHECKED and REPORTED.
        var unixReported = false
        for r in noFloor.outcome.reports:
          if r.kind == "unix-socket-connect" and daemon.endpoint in r.detail:
            unixReported = true
        check unixReported
      check "BREACH-neighbour" notin noFloor.output
      check "BREACH-write" notin noFloor.output
      check "BREACH-state" notin noFloor.output
      check "BREACH-fd" notin noFloor.output

  test "noexec: a binary written into the lease does not run; the closure's do":
    when not defined(linux):
      echo "[platform N/A] noexec writable mounts are the Linux namespace " &
        "layer; a macOS lease is the Seatbelt isolation level, which " &
        "allows executing declared outputs"
      skip("platform N/A: noexec writable mounts are Linux-only")
    else:
      let available = leaseConfinementAvailable()
      check available.ok
      if available.ok:
        let base = m7TestBase("repro-m7-noexec")
        defer: removeDir(base)
        let leaseRoot = base / "worker-state" / "leases"
        let leaseDir = leaseRoot / "noexec"
        createDir(leaseDir / "wt" / "out")
        # The written binary goes into the DECLARED OUTPUT directory: the
        # closure check and Landlock's EXECUTE rule both allow executing
        # from there, so only the mount's noexec flag can stop it.
        let script = "set -u; cp /bin/true out/written-true; " &
          "chmod +x out/written-true; " &
          "if ./out/written-true; then echo WRITTEN-RAN; " &
          "else echo WRITTEN-BLOCKED; fi > out/result.txt; " &
          "if /bin/true; then echo TOOLCHAIN-RAN >> out/result.txt; fi"
        let spec = LeaseSpec(leaseId: "noexec", leaseRoot: leaseRoot,
          leaseDir: leaseDir, metaDir: base / "lease-meta" / "noexec",
          cwd: leaseDir / "wt", argv: @["/bin/sh", "-c", script],
          env: @[("PATH", "/usr/bin:/bin"), ("HOME", leaseDir / "home"),
            ("TMPDIR", leaseDir / "tmp")],
          readRoots: @["/usr", "/bin", "/lib", "/lib64", "/etc", "/nix/store"],
          closureRoots: @["/usr/bin", "/bin", "/usr/lib", "/lib", "/lib64",
            "/nix/store"],
          outputDirs: @[leaseDir / "wt" / "out"],
          layers: DefaultLeaseLayers, timeoutMs: 60_000)
        let outcome = waitFor runLease(spec)
        let resultPath = leaseDir / "wt" / "out" / "result.txt"
        let observed = if fileExists(resultPath): readFile(resultPath) else: ""
        checkpoint("noexec lease: started=" & $outcome.started & " exit=" &
          $outcome.exitCode & " error=" & outcome.error & "\n  result: " &
          observed & "\n  stderr: " & outcome.stderr & "\n  reports: " &
          $outcome.reports)
        check outcome.started
        check outcome.isolation == "linux-namespace+landlock+floor"
        check fileExists(leaseDir / "wt" / "out" / "written-true")  # written
        check "WRITTEN-BLOCKED" in observed     # the mount stopped it
        check "WRITTEN-RAN" notin observed
        check "TOOLCHAIN-RAN" in observed       # positive control
        # Not the closure check: the supervisor saw nothing to refuse.
        for r in outcome.reports:
          check not (r.kind == "exec-outside-closure" and
            "written-true" in r.detail)
        discard cleanupLease(spec)
        # Without the floor (and without Landlock) the lease is the
        # namespace's root and owns the top level of its new root: that
        # tmpfs is READ-ONLY once entered (and noexec), so nothing can be
        # written there — the load-bearing assertion here (neuter `rootro`
        # reddens exactly it). Running a copy from `/` or `/dev` is refused
        # twice over — the mounts are noexec AND the supervisor refuses an
        # execve outside the closure — so those two lines are defence in
        # depth, not a test of noexec alone (the declared-output case above
        # is). Positive control: the toolchain still runs.
        let rootDir = leaseRoot / "noexec-root"
        createDir(rootDir / "wt")
        let rootScript = "set -u; " &
          "if cp /bin/true /root-true 2>/dev/null; then echo ROOT-WRITTEN; " &
          "else echo ROOT-WRITE-BLOCKED; fi > result.txt; " &
          "if /root-true 2>/dev/null; then echo ROOT-RAN >> result.txt; fi; " &
          "if cp /bin/true /dev/dev-true 2>/dev/null && /dev/dev-true; " &
          "then echo DEV-RAN >> result.txt; fi; " &
          "if /bin/true; then echo TOOLCHAIN-RAN >> result.txt; fi"
        let rootSpec = LeaseSpec(leaseId: "noexec-root", leaseRoot: leaseRoot,
          leaseDir: rootDir, metaDir: base / "lease-meta" / "noexec-root",
          cwd: rootDir / "wt", argv: @["/bin/sh", "-c", rootScript],
          env: @[("PATH", "/usr/bin:/bin"), ("HOME", rootDir / "home"),
            ("TMPDIR", rootDir / "tmp")],
          readRoots: @["/usr", "/bin", "/lib", "/lib64", "/etc", "/nix/store"],
          closureRoots: @["/usr/bin", "/bin", "/usr/lib", "/lib", "/lib64",
            "/nix/store"],
          # Namespace layer only: no Landlock (whose write rule would refuse
          # the copy first) and no floor — exactly a trusted worker on a host
          # without Landlock or a subordinate uid range.
          layers: {llNamespace}, timeoutMs: 60_000)
        let rootOutcome = waitFor runLease(rootSpec)
        let rootResult =
          if fileExists(rootDir / "wt" / "result.txt"):
            readFile(rootDir / "wt" / "result.txt")
          else: ""
        checkpoint("no-floor root lease: started=" & $rootOutcome.started &
          " error=" & rootOutcome.error & "\n  result: " & rootResult &
          "\n  stderr: " & rootOutcome.stderr)
        check rootOutcome.started
        check rootOutcome.isolation == "linux-namespace"
        check "ROOT-WRITE-BLOCKED" in rootResult
        check "ROOT-RAN" notin rootResult
        check "DEV-RAN" notin rootResult
        check "TOOLCHAIN-RAN" in rootResult
        discard cleanupLease(rootSpec)

  test "hardened memfd policy: no executable memfd; a sealed one still works":
    when not defined(linux):
      echo "[platform N/A] the memfd policy is a Linux lease control " &
        "(hardened profile; macOS and Windows workers are trusted-only)"
      skip("platform N/A: Linux-only")
    else:
      if not memfdNoexecSupported():
        echo "[platform N/A] this kernel has no MFD_NOEXEC_SEAL (Linux 6.3+); " &
          "a hardened lease runs without the memfd policy and its level says so"
        skip("kernel without MFD_NOEXEC_SEAL")
      else:
        let cc = ccPath()
        check cc.len > 0
        let base = m7TestBase("repro-m7-memfd")
        defer: removeDir(base)
        let tools = base / "tools"
        createDir(tools)
        writeFile(tools / "memfd.c", """
#define _GNU_SOURCE
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>
int main(void) {
  int a = (int)syscall(SYS_memfd_create, "repro-exec", 0);
  puts(a >= 0 ? "MEMFD-EXEC-CREATED" : "MEMFD-EXEC-REFUSED");
  int b = (int)syscall(SYS_memfd_create, "repro-sealed", 0x0008U);
  puts(b >= 0 ? "MEMFD-SEALED-CREATED" : "MEMFD-SEALED-REFUSED");
  return 0;
}
""")
        check execCmdEx(quoteShellCommand([cc, "-o", tools / "memfd",
          tools / "memfd.c"])).exitCode == 0
        let leaseRoot = base / "worker-state" / "leases"
        proc runMemfd(id: string; policy: bool): tuple[output: string;
            outcome: LeaseOutcome] =
          let leaseDir = leaseRoot / id
          createDir(leaseDir / "wt")
          let spec = LeaseSpec(leaseId: id, leaseRoot: leaseRoot,
            leaseDir: leaseDir, metaDir: base / "lease-meta" / id,
            cwd: leaseDir / "wt",
            argv: @["/bin/sh", "-c", "\"$TOOL\" > out.txt"],
            env: @[("PATH", "/usr/bin:/bin"), ("TOOL", tools / "memfd"),
              ("HOME", leaseDir / "home"), ("TMPDIR", leaseDir / "tmp")],
            readRoots: @["/usr", "/bin", "/lib", "/lib64", "/etc", "/nix/store",
              tools],
            closureRoots: @["/usr/bin", "/bin", "/usr/lib", "/lib", "/lib64",
              "/nix/store", tools],
            layers: DefaultLeaseLayers, memfdNoexec: policy, timeoutMs: 60_000)
          result.outcome = waitFor runLease(spec)
          let outPath = leaseDir / "wt" / "out.txt"
          result.output = if fileExists(outPath): readFile(outPath) else: ""
          checkpoint(id & ": started=" & $result.outcome.started & " error=" &
            result.outcome.error & " isolation=" & result.outcome.isolation &
            "\n  out: " & result.output & "\n  reports: " &
            $result.outcome.reports)
          discard cleanupLease(spec)
        let hard = runMemfd("memfd-policy", true)
        check hard.outcome.started
        check hard.outcome.isolation ==
          "linux-namespace+landlock+floor+memfd-noexec"
        check "MEMFD-EXEC-REFUSED" in hard.output
        check "MEMFD-SEALED-CREATED" in hard.output     # positive control
        var reported = false
        for r in hard.outcome.reports:
          if r.kind == "syscall-denied" and "MFD_NOEXEC_SEAL" in r.detail:
            reported = true
        check reported
        let plain = runMemfd("memfd-plain", false)
        check plain.outcome.started
        check plain.outcome.isolation == "linux-namespace+landlock+floor"
        check "MEMFD-EXEC-CREATED" in plain.output      # the policy refused it
        check "MEMFD-SEALED-CREATED" in plain.output
