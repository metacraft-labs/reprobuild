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
## The fifth and sixth tests are the EGRESS FORWARDER (both platforms; M7
## defect fixed 2026-10-27): a lease's probe runs small interactive rounds,
## a request followed by a half-close, and thirty streams it abandons (half
## of them with a reset) through the supervisor's forwarders, then the
## half-close exchange again; and the forwarder (`startEgressForwarder`) is
## driven into the round that used to kill the worker daemon — data in
## flight in one direction while the other end closes, both seen in one
## dispatcher round. Neuters: closing both sockets on the first EOF loses
## the response; a buffered read stalls the interactive rounds; base's
## `splice` dies of an AssertionDefect (macOS) or loses the response
## (Linux).
##
## The last test is the REPORT of a denied connect, end to end into
## `LeaseOutcome.reports`. On macOS the kernel's Seatbelt report is the
## only witness and the channel is lossy (threat model G41), so what is
## asserted is that every kernel network denial the supervisor RECEIVED
## (its raw `sandbox-log.ndjson`) became an `egress-denied` report (up to
## five leases until one is received); every lease's denial is asserted.
##
## MOCK POLICY — none. The "daemon" is the shipped `repro daemon serve`
## process; its control socket and state directory are the real ones.

import std/[asyncdispatch, asyncnet, nativesockets, net, os, osproc, posix, streams,
            strtabs, strutils, times,
            unittest]

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

const DenyProbeSource = """
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
/* argv[1]: a loopback port no egress rule allows. */
int main(int argc, char **argv) {
  if (argc < 2) return 2;
  struct sockaddr_in a; memset(&a, 0, sizeof a);
  a.sin_family = AF_INET; a.sin_port = htons((unsigned short)atoi(argv[1]));
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int s = socket(AF_INET, SOCK_STREAM, 0);
  puts(s >= 0 && connect(s, (struct sockaddr *)&a, sizeof a) == 0 ?
    "EXFIL-OPEN" : "EXFIL-DENIED");
  return 0;
}
"""

const ForwarderProbeSource = """
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
/* argv: ECHO REQ STREAM, each "ip:port" (the lease's forwarder addresses).
   Every read waits at most 5 s (10 s for a whole response): a forwarder
   that stalls makes this print a failure, never hang the test. */
static int dial(const char *hp) {
  char host[64]; const char *colon = strrchr(hp, ':');
  if (!colon || colon - hp >= (int)sizeof host) return -1;
  memcpy(host, hp, (size_t)(colon - hp)); host[colon - hp] = 0;
  struct sockaddr_in a; memset(&a, 0, sizeof a);
  a.sin_family = AF_INET; a.sin_port = htons((unsigned short)atoi(colon + 1));
  if (inet_pton(AF_INET, host, &a.sin_addr) != 1) return -1;
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) return -1;
  if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { close(s); return -1; }
  return s;
}
static int wait_readable(int s, int ms) {
  struct pollfd p = { s, POLLIN, 0 };
  return poll(&p, 1, ms) > 0;
}
/* Reads until EOF (or `cap`, or the deadline); returns the byte count. */
static int read_to_eof(int s, char *buf, int cap, int ms) {
  int n = 0;
  while (n < cap - 1 && wait_readable(s, ms)) {
    ssize_t r = recv(s, buf + n, (size_t)(cap - 1 - n), 0);
    if (r <= 0) break;
    n += (int)r;
  }
  buf[n] = 0;
  return n;
}
static void half_close_exchange(const char *hp, const char *label) {
  char req[1000], resp[256] = "";
  memset(req, 'r', sizeof req);
  int s = dial(hp);
  if (s >= 0) {
    if (send(s, req, sizeof req, 0) == (ssize_t)sizeof req &&
        shutdown(s, SHUT_WR) == 0)
      read_to_eof(s, resp, sizeof resp, 10000);
    close(s);
  }
  char *nl = strchr(resp, '\n'); if (nl) *nl = 0;
  printf("%s %s\n", label, resp); fflush(stdout);
}
int main(int argc, char **argv) {
  if (argc < 4) return 2;
  signal(SIGPIPE, SIG_IGN);
  /* 1. Small interactive rounds. */
  int ok = 0, s = dial(argv[1]);
  for (int i = 0; s >= 0 && i < 20; i++) {
    char msg[32], got[32]; int len = snprintf(msg, sizeof msg, "ping-%d\n", i), n = 0;
    if (send(s, msg, (size_t)len, 0) != len) break;
    while (n < len && wait_readable(s, 5000)) {
      ssize_t r = recv(s, got + n, (size_t)(len - n), 0);
      if (r <= 0) break;
      n += (int)r;
    }
    if (n != len || memcmp(msg, got, (size_t)len) != 0) break;
    ok++;
  }
  if (s >= 0) close(s);
  printf(ok == 20 ? "INTERACTIVE-OK %d\n" : "INTERACTIVE-STALL %d\n", ok); fflush(stdout);
  /* 2. Request, half-close, response. */
  half_close_exchange(argv[2], "HALFCLOSE-RESPONSE");
  /* 3. Abandon streams mid-flight (every other one with a reset). */
  int done = 0;
  for (int k = 0; k < 30; k++) {
    int t = dial(argv[3]);
    if (t < 0) continue;
    char b[100];
    if (wait_readable(t, 5000) && recv(t, b, sizeof b, 0) > 0) done++;
    if (k % 2) { struct linger l = { 1, 0 }; setsockopt(t, SOL_SOCKET, SO_LINGER, &l, sizeof l); }
    close(t);
  }
  printf("ABANDON-DONE %d\n", done); fflush(stdout);
  usleep(200000);
  /* 4. The forwarder still serves. */
  half_close_exchange(argv[2], "AFTER-RESPONSE");
  return 0;
}
"""

proc coreToolDir(): string =
  ## The directory the lease scripts take `true`, `cp` and `chmod` from: the
  ## host's own, followed through PATH symlinks until it lies under a
  ## closure root (`/usr/bin`, `/bin`, `/nix/store`). A fixed `/bin/true`
  ## and a PATH of `/usr/bin:/bin` exist on an FHS host only; NixOS has
  ## neither, and its PATH entries (`/run/current-system/sw/bin`, a user
  ## profile) are symlink farms outside every lease root.
  var p = findExe("true")
  doAssert p.len > 0, "no `true` on PATH"
  for _ in 0 ..< 16:
    let dir = p.parentDir
    if dir in ["/usr/bin", "/bin"] or dir.startsWith("/nix/store/"):
      return dir
    if not symlinkExists(p): break
    let target = expandSymlink(p)
    p = if target.isAbsolute: target else: dir / target
  p.parentDir

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

# A preloaded library in the WORKER must not reach the lease's environment.
#
# The suite runs this binary directly, so it never sees the build monitor.
# This test recreates what the monitor does instead, with its own preload
# library. The library interposes execve(3) and adds a marker variable to
# every child it starts, which is how io-mon's shim hands `LD_PRELOAD` to its
# children. The case re-runs this binary under that library in the child mode
# below. The child starts one lease that dumps its environment, and, as a
# positive control, one ordinary fork+execve child that dumps its own.
const InterposeChildEnv = "REPRO_LEASE_EXEC_INTERPOSE_CHILD"
const InterposeMarker = "REPRO_INTERPOSED_BY_PRELOAD=1"
const InterposerSource = """
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>
typedef int (*execve_fn)(const char *, char *const[], char *const[]);
static execve_fn real_execve;
__attribute__((constructor)) static void resolve(void) {
  real_execve = (execve_fn)dlsym(RTLD_NEXT, "execve");
}
int execve(const char *path, char *const argv[], char *const envp[]) {
  size_t n = 0;
  while (envp && envp[n]) n++;
  char **e = malloc((n + 2) * sizeof *e);
  if (!e) return real_execve(path, argv, envp);
  for (size_t i = 0; i < n; i++) e[i] = envp[i];
  e[n] = "REPRO_INTERPOSED_BY_PRELOAD=1";
  e[n + 1] = NULL;
  return real_execve(path, argv, e);
}
"""

when defined(linux):
  if getEnv(InterposeChildEnv).len > 0:
    # CHILD MODE (the case below starts this binary like this, under the
    # interposer). `dir` is the parent's scratch directory.
    let dir = getEnv(InterposeChildEnv)
    # The control: an ordinary execve child, which the interposer reaches.
    let pid = posix.fork()
    if pid == 0:
      var argv = allocCStringArray(["sh", "-c", "env > \"$1\"", "sh",
        dir / "control-env.txt"])
      var envp = allocCStringArray(["PATH=" & coreToolDir() & ":/usr/bin:/bin"])
      discard posix.execve("/bin/sh", argv, envp)
      quit(127)
    var status: cint
    discard posix.waitpid(pid, status, 0)
    # The lease.
    let leaseRoot = dir / "leases"
    let leaseDir = leaseRoot / "interposed"
    createDir(leaseDir / "wt" / "out")
    let spec = LeaseSpec(leaseId: "interposed", leaseRoot: leaseRoot,
      leaseDir: leaseDir, metaDir: dir / "lease-meta" / "interposed",
      cwd: leaseDir / "wt", argv: @["/bin/sh", "-c", "env > out/env.txt"],
      env: @[("PATH", coreToolDir() & ":/usr/bin:/bin"),
        ("HOME", leaseDir / "home"),
        ("TMPDIR", leaseDir / "tmp")],
      readRoots: @["/usr", "/bin", "/lib", "/lib64", "/etc", "/nix/store"],
      closureRoots: @["/usr/bin", "/bin", "/usr/lib", "/lib", "/lib64",
        "/nix/store"],
      outputDirs: @[leaseDir / "wt" / "out"],
      layers: DefaultLeaseLayers, timeoutMs: 60_000)
    let outcome = waitFor runLease(spec)
    writeFile(dir / "lease-outcome.txt", "started=" & $outcome.started &
      " exit=" & $outcome.exitCode & " error=" & outcome.error &
      "\nstderr: " & outcome.stderr & "\nreports: " & $outcome.reports)
    if fileExists(leaseDir / "wt" / "out" / "env.txt"):
      copyFile(leaseDir / "wt" / "out" / "env.txt", dir / "lease-env.txt")
    discard cleanupLease(spec)
    quit(0)

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
          env: @[("PATH", parentDir(cc) & ":" & coreToolDir() &
              ":/usr/bin:/bin"), ("CC", cc),
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
        proc runWritten(layers: set[LeaseLayer]; id: string):
            tuple[output: string; outcome: LeaseOutcome] =
          let leaseDir = leaseRoot / id
          createDir(leaseDir / "wt" / "out")
          # The written binary goes into the DECLARED OUTPUT directory: the
          # closure check and Landlock's EXECUTE rule both allow executing
          # from there, so only the mount's noexec flag can stop it.
          # `/bin/sh -c` works under the copied name. A multi-call `true`
          # may fail solely because argv[0] changed, even on an exec mount.
          # Fail setup errors directly rather than mistaking them for denial.
          let script = "set -eu; cp /bin/sh out/written-sh; " &
            "chmod +x out/written-sh; " &
            "if ./out/written-sh -c 'exit 0'; then echo WRITTEN-RAN; " &
            "else echo WRITTEN-BLOCKED; fi > out/result.txt; " &
            "if \"$TRUE\"; then echo TOOLCHAIN-RAN >> out/result.txt; fi"
          let spec = LeaseSpec(leaseId: id, leaseRoot: leaseRoot,
            leaseDir: leaseDir, metaDir: base / "lease-meta" / id,
            cwd: leaseDir / "wt", argv: @["/bin/sh", "-c", script],
            env: @[("PATH", coreToolDir() & ":/usr/bin:/bin"),
              ("TRUE", coreToolDir() / "true"), ("HOME", leaseDir / "home"),
              ("TMPDIR", leaseDir / "tmp")],
            readRoots: @["/usr", "/bin", "/lib", "/lib64", "/etc", "/nix/store"],
            closureRoots: @["/usr/bin", "/bin", "/usr/lib", "/lib", "/lib64",
              "/nix/store"],
            outputDirs: @[leaseDir / "wt" / "out"],
            layers: layers, timeoutMs: 60_000)
          result.outcome = waitFor runLease(spec)
          let outcome = result.outcome
          let resultPath = leaseDir / "wt" / "out" / "result.txt"
          result.output = if fileExists(resultPath): readFile(resultPath) else: ""
          let observed = result.output
          checkpoint(id & " lease: started=" & $outcome.started & " exit=" &
            $outcome.exitCode & " error=" & outcome.error & "\n  result: " &
            observed & "\n  stderr: " & outcome.stderr & "\n  reports: " &
            $outcome.reports)
          check outcome.started
          check outcome.exitCode == 0
          check fileExists(leaseDir / "wt" / "out" / "written-sh")
          check "TOOLCHAIN-RAN" in observed
          for r in outcome.reports:
            check not (r.kind == "exec-outside-closure" and
              "written-sh" in r.detail)
          discard cleanupLease(spec)
        # Identical payload, with the namespace's noexec mounts absent:
        # a renamed multi-call `true` must not make the denial vacuous.
        let executable = runWritten(DefaultLeaseLayers - {llNamespace},
          "exec-control")
        check "WRITTEN-RAN" in executable.output
        check "WRITTEN-BLOCKED" notin executable.output
        let blocked = runWritten(DefaultLeaseLayers, "noexec")
        check blocked.outcome.isolation == "linux-namespace+landlock+floor"
        check "WRITTEN-BLOCKED" in blocked.output
        check "WRITTEN-RAN" notin blocked.output
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
          "if cp /bin/sh /root-sh 2>/dev/null; then echo ROOT-WRITTEN; " &
          "else echo ROOT-WRITE-BLOCKED; fi > result.txt; " &
          "if /root-sh -c 'exit 0' 2>/dev/null; then echo ROOT-RAN >> result.txt; fi; " &
          "if cp /bin/sh /dev/dev-sh 2>/dev/null && /dev/dev-sh -c 'exit 0'; " &
          "then echo DEV-RAN >> result.txt; fi; " &
          "if \"$TRUE\"; then echo TOOLCHAIN-RAN >> result.txt; fi"
        let rootSpec = LeaseSpec(leaseId: "noexec-root", leaseRoot: leaseRoot,
          leaseDir: rootDir, metaDir: base / "lease-meta" / "noexec-root",
          cwd: rootDir / "wt", argv: @["/bin/sh", "-c", rootScript],
          env: @[("PATH", coreToolDir() & ":/usr/bin:/bin"),
            ("TRUE", coreToolDir() / "true"), ("HOME", rootDir / "home"),
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

  test "a library preloaded into the worker does not reach the lease's environment":
    when not defined(linux):
      skip("the Linux lease's raw exec is what is under test")
    else:
      let cc = ccPath()
      let available = leaseConfinementAvailable()
      check available.ok
      check cc.len > 0
      if available.ok and cc.len > 0:
        let base = m7TestBase("repro-m7-interpose")
        defer: removeDir(base)
        createDir(base)
        writeFile(base / "interposer.c", InterposerSource)
        check execCmdEx(quoteShellCommand([cc, "-shared", "-fPIC", "-o",
          base / "interposer.so", base / "interposer.c", "-ldl"])).exitCode == 0
        var env = newStringTable(modeCaseSensitive)
        for k, v in envPairs(): env[k] = v
        env["LD_PRELOAD"] = base / "interposer.so"
        env[InterposeChildEnv] = base
        let child = startProcess(getAppFilename(), env = env,
          options = {poStdErrToStdOut})
        let childOut = child.outputStream.readAll()
        let code = child.waitForExit()
        child.close()
        checkpoint("child exit " & $code & ":\n" & childOut)
        check code == 0
        let control = if fileExists(base / "control-env.txt"):
            readFile(base / "control-env.txt") else: ""
        let leased = if fileExists(base / "lease-env.txt"):
            readFile(base / "lease-env.txt") else: ""
        checkpoint("lease: " & (if fileExists(base / "lease-outcome.txt"):
          readFile(base / "lease-outcome.txt") else: "<no outcome>"))
        checkpoint("lease env:\n" & leased)
        # The control: the interposer reaches an ordinary execve child, so
        # the lease assertion below cannot pass because nothing interposed.
        check InterposeMarker in control
        # The lease ran, and its environment is what its spec names: no
        # marker and no preload.
        check "PATH=" in leased
        check InterposeMarker notin leased
        check "LD_PRELOAD" notin leased

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

  test "egress forwarder: half-close, interactive traffic, one-sided close":
    # The supervisor's egress forwarder (macOS: `lease.nim`, in THIS
    # process; Linux: `c/repro_lease_linux.c`, the lease supervisor) carries
    # a TCP connection end to end. Three servers outside the lease:
    #   ECHO   echoes whatever arrives, at once;
    #   REQ    reads the request to EOF, then answers and closes;
    #   STREAM streams until its peer goes away.
    # The lease's probe (a closure tool) runs, through the forwarders:
    #   1. 20 small request/reply rounds with ECHO, each with a 5 s limit — a
    #      forwarder that waits for a fuller read stalls here;
    #   2. a request to REQ followed by shutdown(SHUT_WR) — a forwarder that
    #      closes both sockets on the first EOF loses the response;
    #   3. 30 connections to STREAM that each read a little and close
    #      (every other one with a reset) — one-sided closes with data in
    #      flight, the traffic that used to kill the worker daemon on macOS
    #      (an AssertionDefect in `splice`; the deterministic form of that
    #      crash is the next test);
    #   4. the half-close exchange of (2) again: the forwarder still serves.
    # This test process surviving to its assertions is part of the claim
    # on macOS, where the forwarder runs here.
    let cc = ccPath()
    let available = leaseConfinementAvailable()
    check available.ok
    check cc.len > 0
    if available.ok and cc.len > 0:
      let base = m7TestBase("repro-m7-forwarder")
      defer: removeDir(base)
      let tools = base / "tools"
      createDir(tools)
      writeFile(tools / "egress_probe.c", ForwarderProbeSource)
      check execCmdEx(quoteShellCommand([cc, "-o", tools / "egress_probe",
        tools / "egress_probe.c"])).exitCode == 0

      proc listenLoopback(): tuple[sock: AsyncSocket; port: int] =
        let l = newAsyncSocket(buffered = false)
        l.setSockOpt(OptReuseAddr, true)
        l.bindAddr(Port(0), "127.0.0.1")
        l.listen()
        (l, int(getLocalAddr(l.getFd(), Domain.AF_INET)[1]))

      let echoL = listenLoopback()
      let reqL = listenLoopback()
      let streamL = listenLoopback()
      let serving = new(bool)
      serving[] = true
      let streamConns = new(int)

      proc echoConn(c: AsyncSocket) {.async.} =
        try:
          while true:
            let d = await c.recv(4096, flags = {})
            if d.len == 0: break
            await c.send(d, flags = {})
        except CatchableError: discard
        try: c.close() except CatchableError: discard

      proc reqConn(c: AsyncSocket) {.async.} =
        var got = 0
        try:
          while true:
            let d = await c.recv(4096, flags = {})
            if d.len == 0: break
            got += d.len
          await c.send("GOT " & $got & " bytes\n", flags = {})
        except CatchableError: discard
        try: c.close() except CatchableError: discard

      proc streamConn(c: AsyncSocket) {.async.} =
        inc streamConns[]
        let chunk = repeat('s', 16384)
        try:
          # Bounded (64 MiB) so a forwarder that keeps reading for a lease
          # that went away cannot keep this task alive for ever.
          for _ in 0 ..< 4096:
            await c.send(chunk, flags = {})
        except CatchableError: discard
        try: c.close() except CatchableError: discard

      proc serve(l: AsyncSocket; kind: int) {.async.} =
        while serving[]:
          var c: AsyncSocket
          try: c = await l.accept()
          except CatchableError: break
          case kind
          of 0: asyncCheck echoConn(c)
          of 1: asyncCheck reqConn(c)
          else: asyncCheck streamConn(c)

      asyncCheck serve(echoL.sock, 0)
      asyncCheck serve(reqL.sock, 1)
      asyncCheck serve(streamL.sock, 2)

      let leaseRoot = base / "worker-state" / "leases"
      let leaseDir = leaseRoot / "forwarder"
      createDir(leaseDir / "wt")
      let roots = (when defined(macosx):
          (@["/usr", "/bin", "/System", "/Library", "/private/etc",
             "/private/var/db/timezone", "/nix/store"],
           @["/usr/bin", "/bin", "/usr/libexec", "/nix/store"])
        else:
          (@["/usr", "/bin", "/lib", "/lib64", "/etc", "/nix/store"],
           @["/usr/bin", "/bin", "/usr/lib", "/lib", "/lib64", "/nix/store"]))
      let spec = LeaseSpec(leaseId: "forwarder", leaseRoot: leaseRoot,
        leaseDir: leaseDir, metaDir: base / "lease-meta" / "forwarder",
        cwd: leaseDir / "wt",
        argv: @["/bin/sh", "-c", "\"$TOOL\" \"$REPRO_LEASE_EGRESS_ECHO\" " &
          "\"$REPRO_LEASE_EGRESS_REQ\" \"$REPRO_LEASE_EGRESS_STREAM\" > out.txt"],
        env: @[("PATH", "/usr/bin:/bin"), ("TOOL", tools / "egress_probe"),
          ("HOME", leaseDir / "home"), ("TMPDIR", leaseDir / "tmp")],
        readRoots: roots[0] & @[tools],
        closureRoots: roots[1] & @[tools],
        egress: @[
          EgressDestination(name: "ECHO", host: "127.0.0.1", port: echoL.port),
          EgressDestination(name: "REQ", host: "127.0.0.1", port: reqL.port),
          EgressDestination(name: "STREAM", host: "127.0.0.1",
            port: streamL.port)],
        layers: availableLeaseLayers().layers, timeoutMs: 120_000)
      let outcome = waitFor runLease(spec)
      let outPath = leaseDir / "wt" / "out.txt"
      let output = if fileExists(outPath): readFile(outPath) else: ""
      checkpoint("forwarder lease: started=" & $outcome.started & " exit=" &
        $outcome.exitCode & " signal=" & $outcome.signal & " error=" &
        outcome.error & " isolation=" & outcome.isolation & "\n  out: " &
        output & "\n  stderr: " & outcome.stderr & "\n  reports: " &
        $outcome.reports)
      discard cleanupLease(spec)
      serving[] = false
      for l in [echoL.sock, reqL.sock, streamL.sock]:
        try: l.close() except CatchableError: discard
      check outcome.started
      check outcome.exitCode == 0
      check "INTERACTIVE-OK 20" in output
      check "HALFCLOSE-RESPONSE GOT 1000 bytes" in output
      check "ABANDON-DONE 30" in output
      check streamConns[] == 30          # every abandon reached the server
      check "AFTER-RESPONSE GOT 1000 bytes" in output

  test "egress forwarder: a close in the same poll as data in flight does not kill the process":
    # The worker daemon used to die here (macOS, 2026-10-25/27: 6 of 35
    # loaded runs of `t_daemon_listener_and_lease_egress_surface` on base
    # 76982f2fa): each direction closed BOTH sockets at its EOF, and the
    # other direction, woken in the SAME dispatcher round with data, read
    # the closed socket again — an AssertionDefect from std/asyncnet, which
    # `except CatchableError` does not catch. This drives exactly that
    # round: with the dispatcher stopped, one end writes and the other
    # closes (a FIN, or a reset), and only then does the dispatcher run, so
    # both readinesses arrive together — in both orders (client closes /
    # server closes). The forwarder is the one `runLeaseSeatbelt` starts
    # (`startEgressForwarder`; it is posix code, exercised on Linux too,
    # where production leases forward in the C supervisor). Afterwards the
    # same forwarder still carries a half-closed request/response.
    when not defined(posix):
      skip("the egress forwarder is posix code")
    else:
      let srv = newSocket()
      srv.setSockOpt(OptReuseAddr, true)
      srv.bindAddr(Port(0), "127.0.0.1")
      srv.listen()
      let srvPort = int(getLocalAddr(srv.getFd(), Domain.AF_INET)[1])
      let running = new(bool)
      running[] = true
      let (fwd, fwdPort) = startEgressForwarder(EgressDestination(name: "X",
        host: "127.0.0.1", port: srvPort), running)

      proc readable(fd: SocketHandle): bool =
        var p = TPollfd(fd: cint(fd), events: POLLIN)
        posix.poll(addr p, 1, 0) > 0

      proc spin(rounds: int) =
        for _ in 0 ..< rounds:
          if hasPendingOperations(): poll(10)

      proc connectedPair(): tuple[cli, srvSide: Socket; ok: bool] =
        ## A client connected through the forwarder and the server's side
        ## of the forwarded connection, both pumps of the forwarder running.
        let cli = newSocket()
        cli.connect("127.0.0.1", Port(fwdPort))
        var waited = 0
        while not readable(srv.getFd()) and waited < 500:
          spin(1)
          inc waited
        if not readable(srv.getFd()):
          return (cli, nil, false)
        var s: Socket
        srv.accept(s)
        spin(10)     # the forwarder's connect completes; both pumps start
        (cli, s, true)

      proc recvPumping(s: Socket; deadlineMs: int): string =
        ## Everything up to EOF, running the dispatcher while waiting.
        var buf: array[4096, char]
        s.getFd().setBlocking(false)
        let start = epochTime()
        while (epochTime() - start) * 1000 < float(deadlineMs):
          spin(1)
          let n = posix.recv(s.getFd(), addr buf[0], buf.len, 0)
          if n == 0: break
          if n > 0:
            let old = result.len
            result.setLen(old + n)
            copyMem(addr result[old], addr buf[0], n)

      var rounds = 0
      for round in 0 ..< 24:
        let (cli, srvSide, ok) = connectedPair()
        check ok
        if not ok: break
        # Dispatcher stopped: one end writes, the other goes away.
        let reset = round mod 4 >= 2
        let (writer, closer) =
          if round mod 2 == 0: (srvSide, cli) else: (cli, srvSide)
        writer.send(repeat('d', 100))
        if reset:
          var l = TLinger(l_onoff: 1, l_linger: 0)
          discard setsockopt(closer.getFd(), SOL_SOCKET, SO_LINGER, addr l,
            SockLen(sizeof(l)))
        closer.close()
        spin(20)     # both readinesses are handled in the same round
        writer.close()
        spin(5)
        inc rounds
      check rounds == 24
      # Still alive (an escaped Defect would have ended this process), and
      # the forwarder still serves a half-closed request/response.
      let (cli, srvSide, ok) = connectedPair()
      check ok
      if ok:
        cli.send("request")
        check posix.shutdown(cli.getFd(), SHUT_WR) == 0
        check recvPumping(srvSide, 10_000) == "request"
        srvSide.send("response")
        srvSide.close()
        check recvPumping(cli, 10_000) == "response"
        cli.close()
      running[] = false
      fwd.close()
      srv.close()

  test "denied egress is reported by the lease supervisor":
    # The end-to-end report path for a denied connect, from the kernel (or
    # the Linux supervisor) to `LeaseOutcome.reports`, as `egress-denied`
    # naming the destination port. Linux: the supervisor refuses the connect
    # itself (seccomp) and reports it — every lease, asserted on the first.
    # macOS: the only witness is the kernel's Seatbelt report in the unified
    # log, a channel shared with every sandboxed process on the host and
    # LOSSY under report load (threat model G8, G41; measured 2026-10-27:
    # with another process producing Sandbox reports, 8 of 30 tagged leases
    # lost every network report, and under a sustained flood all five leases
    # of one run can lose theirs — the losses are correlated). So the macOS
    # assertion is about what the supervisor RECEIVED: it keeps the raw
    # stream it read (`<metaDir>/sandbox-log.ndjson`), and every kernel
    # network denial in it must have become an `egress-denied` report naming
    # the port. Up to five leases run until one's kernel report arrives; if
    # none does, that is printed, not failed (the channel, not the code).
    # The DENIAL is asserted in every lease.
    let cc = ccPath()
    let available = leaseConfinementAvailable()
    check available.ok
    check cc.len > 0
    if available.ok and cc.len > 0:
      let base = m7TestBase("repro-m7-egress-report")
      defer: removeDir(base)
      let tools = base / "tools"
      createDir(tools)
      writeFile(tools / "deny_probe.c", DenyProbeSource)
      check execCmdEx(quoteShellCommand([cc, "-o", tools / "deny_probe",
        tools / "deny_probe.c"])).exitCode == 0
      let exfil = newAsyncSocket(buffered = false)
      exfil.setSockOpt(OptReuseAddr, true)
      exfil.bindAddr(Port(0), "127.0.0.1")
      exfil.listen()
      let exfilPort = int(getLocalAddr(exfil.getFd(), Domain.AF_INET)[1])
      let exfilHits = new(int)
      proc countHits() {.async.} =
        while true:
          var c: AsyncSocket
          try: c = await exfil.accept()
          except CatchableError: break
          inc exfilHits[]
          try: c.close() except CatchableError: discard
      asyncCheck countHits()
      let leaseRoot = base / "worker-state" / "leases"
      let roots = (when defined(macosx):
          (@["/usr", "/bin", "/System", "/Library", "/private/etc",
             "/private/var/db/timezone", "/nix/store"],
           @["/usr/bin", "/bin", "/usr/libexec", "/nix/store"])
        else:
          (@["/usr", "/bin", "/lib", "/lib64", "/etc", "/nix/store"],
           @["/usr/bin", "/bin", "/usr/lib", "/lib", "/lib64", "/nix/store"]))
      let attempts = when defined(macosx): 5 else: 1
      var reportedIn = 0
      var kernelDelivered = 0
      for attempt in 1 .. attempts:
        let id = "deny-" & $attempt
        let leaseDir = leaseRoot / id
        createDir(leaseDir / "wt")
        let spec = LeaseSpec(leaseId: id, leaseRoot: leaseRoot,
          leaseDir: leaseDir, metaDir: base / "lease-meta" / id,
          cwd: leaseDir / "wt",
          argv: @["/bin/sh", "-c", "\"$TOOL\" \"$1\" > out.txt", "sh",
            $exfilPort],
          env: @[("PATH", "/usr/bin:/bin"), ("TOOL", tools / "deny_probe"),
            ("HOME", leaseDir / "home"), ("TMPDIR", leaseDir / "tmp")],
          readRoots: roots[0] & @[tools],
          closureRoots: roots[1] & @[tools],
          layers: availableLeaseLayers().layers, timeoutMs: 60_000)
        let outcome = waitFor runLease(spec)
        let outPath = leaseDir / "wt" / "out.txt"
        let output = if fileExists(outPath): readFile(outPath) else: ""
        checkpoint(id & ": started=" & $outcome.started & " error=" &
          outcome.error & " out=" & output.strip & " reports=" &
          $outcome.reports)
        discard cleanupLease(spec)
        check outcome.started
        check "EXFIL-DENIED" in output        # the denial, every lease
        var reported = false
        for r in outcome.reports:
          if r.kind == "egress-denied" and r.detail.endsWith(":" & $exfilPort):
            reported = true
        when defined(macosx):
          # What the supervisor received from the kernel for this lease.
          let rawPath = base / "lease-meta" / id / "sandbox-log.ndjson"
          var delivered = false
          if fileExists(rawPath):
            for line in readFile(rawPath).splitLines:
              if "network-outbound" in line and (":" & $exfilPort) in line:
                delivered = true
          if delivered:
            kernelDelivered = attempt
            check reported      # every received kernel denial is reported
            if reported: reportedIn = attempt
            break
          echo "[lossy channel G41] lease " & id & ": the denial held, the " &
            "kernel's report never reached the supervisor"
        else:
          check reported        # Linux: the supervisor's own refusal
          if reported: reportedIn = attempt
      when defined(macosx):
        if kernelDelivered == 0:
          echo "[lossy channel G41] no kernel report in " & $attempts &
            " leases; the report path was not exercised in this run"
        else:
          check reportedIn == kernelDelivered
      else:
        check reportedIn == 1
      waitFor sleepAsync(50)
      check exfilHits[] == 0                  # denied below the server
      exfil.close()
