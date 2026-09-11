## DA-4 — a DECLARED daemon is trusted only when a CHECK establishes that the
## peer really is what was declared; everything else still downgrades.
##
## WHAT THIS FILE EXISTS FOR, AND WHY IT IS NOT DA-2 AGAIN. DA-2 trusts a
## daemon THIS PROCESS SPAWNED, which is DERIVED attribution and cannot lie.
## Measured, that reaches only an unprovisioned Linux host: where the shipped
## unit owns the host-wide `/run/runquota/runquotad.sock`, `repro` ADOPTS the
## daemon, registers nothing, and DA-2 is entirely inert — on precisely the
## topology a shared lease coordinator exists for. Closing that means trusting
## a daemon this process did not start, which is DECLARED attribution, and
## `Dependency-Observation-Attribution.md` rule 5 says a declared attribution
## has a CHECK. **The check is the milestone. The declaration is the easy
## half.**
##
## So the cases below are weighted accordingly: one positive, and the rest are
## the ways a claim must fail to become trust.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## The daemons are real processes listening on real sockets; the peer pid, uid,
## start time and executable image every assertion turns on are the KERNEL's
## answers, obtained by the production code through `SO_PEERCRED` and `/proc`;
## the client is a real C program performing a real `connect(2)`; the
## observation the exemption is applied to is produced by the real io-mon shim
## inside a real monitored tree; and the grading is the real `runBuild`
## scheduler against the real per-edge action cache. A harness that supplied
## its own peer credential would assert nothing about a mechanism whose entire
## soundness argument is "the kernel said so".
##
## THE DAEMON EVERY DECLARED CASE TRUSTS IS NOT A CHILD OF THIS PROCESS, and
## that is arranged rather than asserted: `startDetachedDaemon` starts it
## through a shell that exits immediately, so the daemon is reparented and this
## process never holds an `osproc.Process` for it. `trustDaemonWeSpawned` is
## therefore not a call that could be written for it even by accident, which is
## what makes the positive a measurement of DECLARED trust and not of DA-2
## reached by another name. The positive case additionally asserts
## `derivedTrustedDaemonRegistry()` is EMPTY while it publishes, and its
## control arm — the identical edge and the identical out-of-band daemon with
## no declaration in force — does not publish and re-runs. That pair is "DA-2
## is inert here, DA-4 is not", measured end to end.
##
## `startDaemon` (a direct child, whose `Process` this file does hold) is used
## by exactly one case: the class-4 arm, which has to register a peer through
## DA-2's derived API in order to show that doing so changes nothing for an
## INET socket.
##
## THREE SHAPES, DRIVEN AS FIVE PERTURBATIONS OF ONE RECORDED TRUST FACT, ARE
## BUILT BY HAND — AND THAT IS NOT A MOCK. Nothing is substituted for a
## collaborator; `revalidatedTrustedDaemons` is the real one and what is
## supplied is the INPUT it reads. It is supplied because the shapes cannot be
## produced from outside the peer process on this host:
##
##   * "the pid was recycled" needs the SAME pid alive across the check and the
##     grading with a DIFFERENT kernel start time. A fixture daemon cannot be
##     both, so the peer is THIS PROCESS — whose start time is the kernel's
##     real answer — and only the RECORDED identity is perturbed. ONE
##     perturbation.
##   * "the peer exec'd in place since it was checked" needs a live process
##     whose pid and start time are unchanged and whose image and `comm` are
##     not. `execve` preserves the first two and only the process itself can
##     perform it, so it cannot be arranged from here; the recorded expectation
##     is perturbed instead. TWO perturbations, one per re-checked assertion,
##     because either alone would leave the other's re-check ungraded. This
##     shape is the one a start-time-only re-validation misses, which is
##     exactly why it must be graded at all.
##   * "the peer acquired privileges in place" needs a live process whose
##     effective uid rises without its pid or start time changing. Only the
##     process itself can do that — by exec'ing a setuid image, or by restoring
##     a saved set-user-ID with no exec at all — so it is the recorded
##     expectation that is perturbed. TWO perturbations: a uid that no longer
##     matches, and a recorded uid the kernel would not supply (-1), because
##     the second is the fail-closed arm and the first would not reach it.
##     MEASURED that this shape is real: sampling `/proc` across an `execve`
##     into setuid-root `sudo` shows the same pid and the same field 22 with
##     euid 1007 → 0.
##
## WHICH UID FIELD THE RE-CHECK READS IS GRADED ON A REAL DIVERGENT PEER, and
## that one is not constructed at all. Every daemon above runs with
## `ruid == euid`, so the perturbations say nothing about whether
## `processEffectiveUid` reads `Uid:`'s real field or its effective one —
## MEASURED (2026-09-11), the mutation reading the real one left all 16 cases
## green. "The uid re-check reads the EFFECTIVE uid" therefore `execve`s a
## SETUID-ROOT program from a closed allowlist, on an argument that does not
## exist so it fails at once, and reads the kernel's own `Uid:` line for it:
## real still ours, effective root. Nothing is substituted for anything; the
## divergence is the kernel's, and an unprivileged process has no other way to
## produce it.
##
## All five share one UNPERTURBED control built by the same function
## (`selfAsCheckedPeer`), which carries ALL THREE assertions and is asserted to
## re-validate — so a green in any of them is not a green produced by a harness
## that has stopped re-validating anything. The remaining way a peer can be
## replaced — the socket re-bound by a different process — needs no
## construction and is driven live.
##
## WHAT IS GRADED
## ---------------------------------------------------------------------
##
## 1. THE POSITIVE, on a provisioned-host shape, measured as "publishes AND is
##    reused on the warm run without launching" rather than at the completeness
##    enum — the enum is not what rebuilt forever.
##
## 2. A DECLARATION WHOSE CHECK FAILS IS NOT TRUSTED. This is the whole point
##    of the milestone, so it is graded at both altitudes: once per assertion
##    kind at the check (`daImage`, `daProgram`, `daUid` — the check's scope is
##    a `set[DaemonAssertion]` and rule 8 says a guard scoped to a set is
##    graded on every member, because the member list is what a later
##    contributor edits), and once end to end, where an edge talking to a
##    daemon whose declaration fails still does not publish and still re-runs.
##
## 3. AN UNDECLARED PEER STILL DOWNGRADES. The undeclared daemon is THE SAME
##    BINARY serving THE SAME protocol, alive at the same time, differing in
##    exactly one respect: no declaration names it.
##
## 4. CLASS 4 IS UNEXEMPTIBLE (rule 4), from both directions. An action talking
##    to an INET daemon downgrades even with that daemon's pid registered
##    outright, because `SO_PEERCRED` yields 0 for INET and io-mon's exemption
##    requires `peer != 0` (io-mon `src/io_mon/writer.nim:1992`) — the
##    guarantee is held there and not by anything reprobuild chooses to
##    honour, which is why it is asserted rather than assumed. And a
##    declaration whose endpoint is not a unix-socket path is refused at the
##    surface rather than connected to and found unattributable later — graded
##    on a relative path (which needs no quoting) and on a quoted `host:port`,
##    because an UNQUOTED `host:port` does not survive `std/parsecfg`'s lexer
##    and would grade the config parser instead of the check.
##
## 5. A CHECKED PEER THAT IS REPLACED — OR THAT CHANGES UNDER ITS OWN PID —
##    DOES NOT INHERIT TRUST, in every way that can happen: the socket re-bound
##    by a different process (live — daemon A checked, killed, daemon B bound
##    to the same path), the pid recycled, the peer exec'd in place, and the
##    peer's effective uid raised in place. Every assertion the check verified
##    is re-verified at grading time, `daUid` included — and against the
##    EFFECTIVE uid, which is graded separately on a real setuid-root peer
##    because no fixture with `ruid == euid` can tell the two fields apart.
##
## 6. THE DECLARATION SURFACE IS BOUNDED BY WHAT THE CHECK CAN VERIFY. A
##    declaration that asserts nothing about the peer is refused, because
##    "something is listening at this path" is not a check; and so is one that
##    asserts only a `uid`, because the §Class 3 branch is a property of the
##    PROGRAM and a check that identifies no program has not established what
##    the branch is about. Both are refused BEFORE the connect, and that
##    ORDERING is asserted AT THE DAEMON rather than inferred from the
##    outcome: the fixture daemon logs every `accept(2)`, both refusals assert
##    the log is still empty afterwards, and the passing control asserts it is
##    not. The class-3
##    branch is not declarable at all — asserted with `compiles`, with a
##    positive control. An unknown daemon name and an unknown key are refused
##    rather than ignored, so a typo cannot rot into a silent no-op, and the
##    "unknown daemon" sentence is asserted to be DERIVED from the vocabulary
##    rather than restated beside it.
##
## 7. A DECLARATION NAMING A PEER THAT NEVER APPEARS IS REPORTED — the
##    milestone's third named test. A stale declaration nobody is told about is
##    a permanent exemption waiting for a pid collision.
##
## 8. A CHECK RESULT CANNOT BE FABRICATED, AND A REFUSED ONE IS REFUSED AT THE
##    REGISTRATION AND NOT ONLY BY ITS CALLER. `DaemonIdentityCheck`'s fields
##    are private to the engine module, so the zero value is the only one an
##    outside caller can build and `trustDaemonWeChecked` refuses it — asserted
##    with `compiles` and a positive control, the same device DA-2 used for
##    `trustDaemonWeSpawned`'s `Process` argument. Separately, a REAL check
##    that refused while satisfying every other clause of that guard (a correct
##    `image` with a wrong `program`: `pid > 0`, non-empty `identity`,
##    `verified == {daImage}`) is handed to it directly, so the `outcome`
##    clause is graded on the one shape that isolates it.
##
## 9. THE PRODUCTION WIRING. Every other case registers through the engine API,
##    so they grade the mechanism and never the wire. The wiring case drives
##    `startAutoRunQuotaIfNeeded` on arms that return BEFORE any spawn and
##    asserts the declared peer is registered while the derived registry stays
##    empty. The BYPASS arm runs on every host. The ADOPT arm — the one DA-2's
##    own reach note names as unreachable for it — needs a `runquotad` binary
##    to spawn first, so on a host without one the case says so in a checkpoint
##    and grades the bypass arm alone.
##
## 10. ONE PEER PID SERVING TWO ENDPOINTS — the topology this milestone is for,
##     and the one that produced its blocker. A uid-only declaration of one
##     endpoint used to register a pid that forgave the OTHER; it is now
##     refused, and the undeclared endpoint's edge downgrades end to end.
##     The second arm then states THE RESIDUAL rather than implying it: with
##     the program identified, an undeclared endpoint of the SAME PROGRAM is
##     still forgiven, because the exemption is keyed on the peer pid. That arm
##     asserts today's semantics deliberately, so narrowing it later is a red
##     case rather than a silent change of meaning.
##
## 11. THE GRADED CAPTURE STILL HOLDS THE EVIDENCE. The `.iomon` the engine
##     graded is read back off disk after the verdict and the `mrIpcConnect`
##     and io-mon's own loss text are both still there while the edge
##     publishes — §"Attribution, not suppression" checked against the bytes
##     rather than against the diagnostic that quotes them. This is also the
##     only case in this file that reaches the SECOND fold site (the
##     recognized-`.iomon`-report arm), with its own negative on the same arm.
##
## 12. WHAT THE CHECK CANNOT DO, MEASURED RATHER THAN CONCEDED IN PROSE.
##     `/proc/<pid>/exe` is unreadable across a uid boundary, so the strongest
##     assertion is unavailable for the root-owned daemon DA-4 mainly exists
##     for; and an image unlinked since exec no longer names the bytes the peer
##     runs. The second is graded on every host. The first is graded on an
##     UNPRIVILEGED one — as root every image is readable and the arm would be
##     vacuous, so the case asserts the opposite reading and says in a
##     checkpoint that it could not exercise the boundary. Both refuse rather
##     than degrade.
##
## HAZARD THIS FIXTURE HAS TO RESPECT. `sockaddr_un.sun_path` is 108 bytes.
## A fixture root under a long `TMPDIR` pushes the socket path past it and the
## daemon fails to bind — which looks exactly like a real red. `makeFixture`
## refuses such a root loudly instead of producing one.

import std/[options, os, osproc, posix, sequtils, strutils, tempfiles, unittest]

# `io_mon` is imported for `streamMonitorDepFileRecords`: the graded `.iomon`
# is read back with io-mon's OWN reader, so "the record is still there" is
# asserted against the same decoder production uses rather than against a
# restatement of the format.
import io_mon
import repro_build_engine
import repro_cli_support
import repro_core
import repro_hash
import repro_local_store
import repro_test_support

const RepoRootMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

var cachedMonitorTools: MonitorTools
var cachedMonitorToolsReady = false

proc monitorTools(repoRoot: string): MonitorTools =
  if not cachedMonitorToolsReady:
    cachedMonitorTools = prepareMonitorTools(repoRoot,
      repoRoot / "build" / "test-monitor-decltrust", "decltrust-monitor")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("declared-daemon-ipc-trust." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

const ReuseDecisions = {cdHit, cdHybridCutoff}

proc ccPath(): string =
  result = findExe("cc")
  if result.len == 0:
    result = findExe("gcc")

## The daemon. `argv[1]` selects the transport, so the AF_UNIX and AF_INET arms
## differ ONLY in the address family — the thing `SO_PEERCRED` answers
## differently — and not in the program, the protocol, or the timing. It writes
## its own pid into the ready file so a fixture that is deliberately NOT its
## parent can still identify it and tear it down.
##
## AN OPTIONAL `argv[4]` BINDS A SECOND UNIX SOCKET IN THE SAME PROCESS, which
## is the activator/multiplexer shape the two-endpoint case needs: ONE peer
## pid, TWO endpoints, and `SO_PEERCRED` answering the same pid on both. The
## accept loop polls both listeners so neither endpoint starves the other, and
## a single-socket run is byte-identical in behaviour to the pre-existing one.
##
## IT ALSO KEEPS AN ACCEPT LOG, WHICH IS WHAT MAKES "REFUSED BEFORE IT
## CONNECTS" AN OBSERVATION RATHER THAN A NAME. One line is appended to
## `<readyPath>.contacts` for every `accept(2)` that returns, BEFORE the byte
## is written, so the log counts "how many times anything reached this daemon
## at all" and not "how many conversations completed". Without it the ordering
## claim in that case's own name was ungraded: moving the declaration gate to
## after the connect preserves every outcome exactly, and MEASURED
## (2026-09-11) left all 16 cases of this file green.
##
## The log path is derived from the ready path and fixed BEFORE the ready file
## is written, so a client that has seen the ready file cannot race a daemon
## that has not yet decided where to record.
const DaemonSource = """
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static char contactLog[4096];

static void recordContact(void) {
  FILE *log = fopen(contactLog, "a");
  if (!log) return;
  fputs("contacted\n", log);
  fclose(log);
}

static int bindUnix(const char *path) {
  struct sockaddr_un addr;
  int fd;
  memset(&addr, 0, sizeof addr);
  addr.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof addr.sun_path) return -65;
  strcpy(addr.sun_path, path);
  unlink(path);
  fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -66;
  if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0) return -67;
  if (listen(fd, 16) != 0) return -68;
  return fd;
}

int main(int argc, char **argv) {
  if (argc != 4 && argc != 5) return 64;
  struct pollfd fds[2];
  int nfds = 1;
  int listenFd;
  int port = 0;
  if (strcmp(argv[1], "unix") == 0) {
    listenFd = bindUnix(argv[2]);
    if (listenFd < 0) return -listenFd;
    if (argc == 5 && argv[4][0] != 0) {
      int second = bindUnix(argv[4]);
      if (second < 0) return -second;
      fds[1].fd = second;
      fds[1].events = POLLIN;
      nfds = 2;
    }
  } else {
    struct sockaddr_in addr;
    socklen_t addrLen = sizeof addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (listenFd < 0) return 66;
    if (bind(listenFd, (struct sockaddr *)&addr, sizeof addr) != 0) return 67;
    if (getsockname(listenFd, (struct sockaddr *)&addr, &addrLen) != 0)
      return 70;
    if (listen(listenFd, 16) != 0) return 68;
    port = (int)ntohs(addr.sin_port);
  }
  fds[0].fd = listenFd;
  fds[0].events = POLLIN;
  if (snprintf(contactLog, sizeof contactLog, "%s.contacts", argv[3]) >=
      (int)sizeof contactLog)
    return 71;
  {
    FILE *ready = fopen(argv[3], "w");
    if (!ready) return 69;
    fprintf(ready, "%d %d\n", (int)getpid(), port);
    fclose(ready);
  }
  for (;;) {
    int i;
    if (poll(fds, nfds, -1) < 0) continue;
    for (i = 0; i < nfds; i++) {
      int c;
      if ((fds[i].revents & POLLIN) == 0) continue;
      c = accept(fds[i].fd, 0, 0);
      if (c < 0) continue;
      recordContact();
      if (write(c, "x", 1) != 1) { close(c); continue; }
      close(c);
    }
  }
}
"""

## The client — the whole monitored action. It connects, consumes one byte and
## appends a line to its log so "what ran" and "how many times" are observable
## out of band. It opens no file of its own besides that log.
const ClientSource = """
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>

int main(int argc, char **argv) {
  if (argc != 4) return 64;
  int fd;
  if (strcmp(argv[1], "unix") == 0) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(argv[2]) >= sizeof addr.sun_path) return 65;
    strcpy(addr.sun_path, argv[2]);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 66;
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) return 67;
  } else {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)atoi(argv[2]));
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 66;
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) return 67;
  }
  char b = 0;
  if (read(fd, &b, 1) != 1) return 68;
  close(fd);
  FILE *log = fopen(argv[3], "a");
  if (!log) return 69;
  fprintf(log, "talked to %s\n", argv[1]);
  fclose(log);
  return 0;
}
"""

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string
  binDir: string
  daemonPath: string
  clientPath: string
  logDir: string

type LiveDaemon = object
  pid: int
  process: Process
    ## Held ONLY by `startDaemon`. `startDetachedDaemon` leaves it nil, which
    ## is what makes DA-2's registration API unusable for those daemons.
  address: string
    ## The socket path for the AF_UNIX arm, the decimal port for the INET one.
  secondAddress: string
    ## The SECOND unix socket this same process listens on, when it was started
    ## with one. Empty otherwise.
  imagePath: string
    ## The binary the daemon was started from — what an `image` assertion has
    ## to name for the check to pass.
  stopped: bool

proc isVolatilePrefix(path: string): bool =
  ## Mirrors the engine's `isVolatileMonitorPath`. A fixture under one of these
  ## has every recorded path dropped before any arm sees it, which makes the
  ## whole suite vacuous in the quietest possible way.
  for prefix in ["/run", "/proc", "/sys", "/dev"]:
    if path == prefix or path.startsWith(prefix & "/"):
      return true
  false

proc nonVolatileTempBase(): string =
  result = getTempDir()
  if result.isVolatilePrefix():
    result = "/tmp"

proc compileC(source, output, workRoot, name: string) =
  let cc = ccPath()
  writeFile(workRoot / name, source)
  let res = execProcess(cc, args = ["-o", output, workRoot / name],
    options = {poStdErrToStdOut, poUsePath})
  if not fileExists(output):
    raise newException(OSError, "helper " & name & " was not produced: " & res)

proc makeFixture(): Fixture =
  let root = createTempDir("repro-decltrust-", "", dir = nonVolatileTempBase())
  if root.isVolatilePrefix():
    raise newException(IOError,
      "fixture root " & root & " is under a volatile prefix the engine drops " &
      "from evidence; this suite cannot assert anything from there")
  let workRoot = root / "work"
  createDir(workRoot)
  let binDir = workRoot / "b"
  createDir(binDir)
  let logDir = workRoot / "o"
  createDir(logDir)
  result = Fixture(
    root: root,
    workRoot: workRoot,
    cacheRoot: root / "cache",
    binDir: binDir,
    daemonPath: binDir / "decl_daemon",
    clientPath: binDir / "decl_client",
    logDir: logDir)
  # `sockaddr_un.sun_path` is 108 bytes and a long `TMPDIR` silently exceeds
  # it. Refuse here, where the reason is legible, rather than in a `bind`
  # failure that reads like a real red.
  # 24 bytes of headroom, not 6: the longest fixture socket basename in this
  # file is the two-endpoint case's, and a probe sized for `d.sock` would let a
  # marginal TMPDIR through and fail at `bind` instead of here.
  let probeSocket = workRoot / "0123456789012345.sock"
  if probeSocket.len >= 108:
    raise newException(IOError,
      "fixture socket path is " & $probeSocket.len & " bytes, which will not " &
      "fit sockaddr_un.sun_path (108); use a shorter TMPDIR")
  compileC(DaemonSource, result.daemonPath, workRoot, "dmn.c")
  compileC(ClientSource, result.clientPath, workRoot, "cli.c")

proc logPath(f: Fixture; name: string): string = f.logDir / (name & ".log")

proc runCount(f: Fixture; name: string): int =
  let p = f.logPath(name)
  if not fileExists(p):
    return 0
  p.readFile.splitLines.countIt(it.strip().len > 0)

proc contactLogPath(f: Fixture; name: string): string =
  ## Where the daemon started as `name` appends one line per `accept(2)`.
  f.workRoot / (name & ".ready.contacts")

proc contactCount(f: Fixture; name: string): int =
  ## HOW MANY TIMES ANYTHING HAS REACHED THIS DAEMON. The daemon logs after
  ## `accept(2)` returns and before it writes its byte, so a connection that
  ## was closed the instant the peer credential was taken still counts —
  ## which is precisely the connection a check makes.
  let p = f.contactLogPath(name)
  if not fileExists(p):
    return 0
  p.readFile.splitLines.countIt(it.strip().len > 0)

proc contactsWithin(f: Fixture; name: string; atLeast, timeoutMs: int): int =
  ## Poll the accept log until it shows at least `atLeast` contacts or the
  ## timeout expires, and return the count either way.
  ##
  ## POLLING IS WHAT MAKES "NOT CONTACTED" A FACT RATHER THAN A RACE. The
  ## daemon accepts asynchronously and `checkDeclaredDaemon` closes its socket
  ## the moment the kernel has named the peer, so a contact that DID happen
  ## may not be on disk yet when the call returns. Waiting out a window and
  ## still finding nothing is the negative; the early exit is what keeps the
  ## positive arm from paying for that window.
  var waited = 0
  while true:
    result = f.contactCount(name)
    if result >= atLeast or waited >= timeoutMs:
      return
    sleep(20)
    waited += 20

proc awaitReady(f: Fixture; readyPath, mode, image, address,
                name: string): LiveDaemon =
  ## The ready file is written AFTER `listen(2)` returns, so a client that sees
  ## it cannot race the bind. It carries the daemon's own pid because a fixture
  ## that is not the parent cannot ask `osproc` for it.
  var waited = 0
  while waited < 10_000:
    if fileExists(readyPath):
      let fields = readFile(readyPath).strip().splitWhitespace()
      if fields.len == 2:
        result.pid = parseInt(fields[0])
        result.imagePath = image
        result.address = if mode == "unix": address else: fields[1]
        return
    sleep(20)
    waited += 20
  raise newException(OSError, "daemon " & name & " (" & mode &
    ") never became ready")

proc startDetachedDaemon(f: Fixture; mode, name: string;
                         imageOverride = "";
                         secondSocketName = ""): LiveDaemon =
  ## Start one daemon as a GRANDCHILD and wait until it is listening.
  ##
  ## The shell that starts it exits immediately, so the daemon is reparented
  ## and this process never holds an `osproc.Process` for it. That is what
  ## makes the declared cases measurements of DECLARED trust: DA-2's
  ## registration API takes the live `Process`, so for these daemons the
  ## derived route is not merely unused, it is unavailable.
  ##
  ## `secondSocketName`, when given, makes ONE process listen on TWO endpoints
  ## — the shape the two-endpoint case needs, and the shape a socket activator
  ## has on a provisioned host.
  let readyPath = f.workRoot / (name & ".ready")
  removeFile(readyPath)
  removeFile(readyPath & ".contacts")
  let image = if imageOverride.len > 0: imageOverride else: f.daemonPath
  let address = if mode == "unix": f.workRoot / (name & ".sock") else: ""
  let second =
    if mode == "unix" and secondSocketName.len > 0:
      f.workRoot / (secondSocketName & ".sock")
    else:
      ""
  let shell = findExe("sh")
  if shell.len == 0:
    raise newException(OSError, "no sh on PATH")
  let command = quoteShell(image) & " " & quoteShell(mode) & " " &
    quoteShell(address) & " " & quoteShell(readyPath) &
    (if second.len > 0: " " & quoteShell(second) else: "") &
    " </dev/null >/dev/null 2>&1 &"
  let starter = startProcess(shell, args = ["-c", command],
    options = {poStdErrToStdOut})
  discard starter.waitForExit()
  starter.close()
  result = f.awaitReady(readyPath, mode, image, address, name)
  result.secondAddress = second

proc startDaemon(f: Fixture; mode, name: string): LiveDaemon =
  ## Start one daemon as a DIRECT child, so this process holds its `Process`
  ## and can register it through DA-2's derived API. Used only by the class-4
  ## case, which needs the most favourable possible configuration for breaking
  ## the guarantee.
  let readyPath = f.workRoot / (name & ".ready")
  removeFile(readyPath)
  removeFile(readyPath & ".contacts")
  let address = if mode == "unix": f.workRoot / (name & ".sock") else: ""
  let process = startProcess(f.daemonPath,
    args = [mode, address, readyPath], options = {poStdErrToStdOut})
  result = f.awaitReady(readyPath, mode, f.daemonPath, address, name)
  result.process = process

proc stopDaemon(daemon: var LiveDaemon) =
  if daemon.stopped or daemon.pid <= 0:
    return
  daemon.stopped = true
  if daemon.process != nil:
    try:
      daemon.process.terminate()
      discard daemon.process.waitForExit()
      daemon.process.close()
    except CatchableError:
      discard
    return
  discard kill(Pid(daemon.pid), SIGKILL)
  # Reaped by init, not by us — so wait for the KERNEL to forget the pid rather
  # than for a child status that will never arrive here. Waiting matters: the
  # "socket re-bound" case asserts the stale registration stops re-validating,
  # and that is a statement about `/proc`.
  for _ in 0 ..< 250:
    if processStartIdentity(daemon.pid).len == 0:
      return
    sleep(20)

proc monitoredConfig(repoRoot, cacheRoot: string): BuildEngineConfig =
  let tools = monitorTools(repoRoot)
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.fallbackToRunQuotaBypass = true
  result.maxParallelism = 1'u32
  result.monitorCliPath = tools.monitorCliPath
  result.monitorCliArgs = tools.monitorCliArgs

proc clientEdge(f: Fixture; id, mode, address, logName: string): BuildAction =
  ## NOTE what is NOT here: no declared inputs, no tool ref. Under
  ## `dgAutomaticMonitor` this edge's evidence — and therefore its
  ## completeness — comes from the monitor and nowhere else.
  action(id, [f.clientPath, mode, address, f.logPath(logName)],
    cwd = f.workRoot,
    inputs = [],
    outputs = [],
    env = ["PATH=" & getEnv("PATH")],
    cacheable = true,
    weakFingerprint = weak(id),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = automaticMonitorGatheringPolicy(),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc reportEdge(f: Fixture; repoRoot, id, address, logName,
                capturePath: string): BuildAction =
  ## An edge whose OWN COMMAND produces the `.iomon` capture the engine grades,
  ## declared as a recognized dependency report — the SECOND of `collectEvidence`'s
  ## two fold sites, and the only one that leaves the graded evidence on disk
  ## where a case can read it back after the verdict.
  ##
  ## The command is the real io-mon CLI over the same client binary every other
  ## case uses, so the capture is produced by the same shim, the same
  ## `SO_PEERCRED` answer and the same synthetic-loss injection — nothing here
  ## is constructed. `dgRecognizedFormat` is not in the engine's
  ## `MonitorPolicyKinds`, so this edge is not additionally wrapped and the
  ## capture the engine grades is unambiguously the one the command wrote.
  let tools = monitorTools(repoRoot)
  var argv = @[tools.monitorCliPath]
  argv.add(tools.monitorCliArgs)
  argv.add(["--depfile", capturePath, "--",
    f.clientPath, "unix", address, f.logPath(logName)])
  action(id, argv,
    cwd = f.workRoot,
    inputs = [],
    outputs = [],
    env = ["PATH=" & getEnv("PATH"),
           "REPRO_MONITOR_SHIM_LIB=" & tools.shim],
    cacheable = true,
    weakFingerprint = weak(id),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = DependencyGatheringPolicy(
      kind: dgRecognizedFormat,
      completeness: decComplete,
      recognizedReports: @[
        RecognizedDependencyReportSpec(
          formatName: DependencyFormatName(IomonFormatName),
          outputs: @[ExpectedDependencyFile(
            logicalName: "iomon", path: capturePath, required: true)],
          completeness: decComplete)]),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc publishedRecordExists(f: Fixture; edge: BuildAction): bool =
  var cache = openActionCache(f.cacheRoot / "action-cache")
  cache.readHotRecord(edge.weakFingerprint).found

proc attributionDiagnostics(res: ActionResult): seq[string] =
  res.evidence.diagnostics.filterIt(it.contains("ipc peer attributed"))

# ---------------------------------------------------------------------------
# The declaration surface, driven exactly as production reads it.
# ---------------------------------------------------------------------------

proc declare(f: Fixture; body: string): string {.discardable.} =
  ## Write a `daemons.conf` and point the production loader at it.
  ##
  ## `REPRO_DAEMONS_CONFIG` selects a FILE and asserts nothing by itself — the
  ## file still has to declare and the declaration still has to pass its check
  ## — which is why a test may set it without weakening what is being graded.
  ## The ordinary system/user precedence is graded separately, by the last case
  ## in this file, with this variable unset.
  result = f.workRoot / "daemons.conf"
  writeFile(result, body)
  putEnv("REPRO_DAEMONS_CONFIG", result)

proc runquotadSection(endpoint, keys: string): string =
  "[runquotad]\nsocket = " & endpoint & "\n" & keys & "\n"

proc applyDeclarationsNow(): seq[DaemonCheckReport] =
  ## The production path minus the CLI's own logging: load this machine's
  ## declarations and check every one.
  applyDeclaredDaemonTrust(loadDeclaredDaemons())

proc reset() =
  forgetDerivedTrustedDaemons()
  forgetMachineDeclaredDaemonTrust()
  putEnv("REPRO_DAEMONS_CONFIG", "")

proc declaredPids(): seq[int] =
  ## The declared peers that STILL re-validate against the kernel, asked
  ## through the same two calls `initMonitorPeerAttribution` makes rather than
  ## through an accessor of its own, so nothing exists here that production
  ## does not use.
  revalidatedTrustedDaemons(declaredTrustedDaemonRegistry()).mapIt(it.pid)

proc outcomeFor(reports: seq[DaemonCheckReport];
                kind: DeclarableDaemonKind): DaemonCheckOutcome =
  for report in reports:
    if report.kind == kind:
      return report.outcome
  raise newException(ValueError, "no report for " & daemonKindName(kind))

# ---------------------------------------------------------------------------
# A perturbable trust fact — see the MOCK POLICY note in the header for why the
# recycled-pid and exec-in-place shapes cannot be produced from outside the
# peer process.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# A PEER WHOSE REAL AND EFFECTIVE UIDS GENUINELY DIFFER — and it is not a
# mock either. See "the uid re-check reads the EFFECTIVE uid" below for why
# nothing weaker can grade that field, and why an unprivileged process cannot
# manufacture the divergence in any other way.
# ---------------------------------------------------------------------------

const SetuidSearchDirs = ["/run/wrappers/bin", "/usr/bin", "/bin",
                          "/usr/local/bin", "/usr/sbin", "/sbin"]

const SetuidRootProbeArgv = [
  @["newgrp", "repro-no-such-group"],
  @["sg", "repro-no-such-group", "true"],
  @["su", "repro-no-such-user"]]
  ## A CLOSED allowlist, each entry invoked on a group or user name that does
  ## not exist. Every one of them resolves its argument before it does
  ## anything at all, so the helper's whole run is: the kernel raises the
  ## effective uid at the setuid `execve`, the program looks the name up,
  ## fails, and exits. Nothing on the host is read, written or changed.
  ##
  ## The list is an allowlist and not a scan of the setuid bits on this host
  ## precisely because a test may not run an arbitrary privileged program to
  ## see what happens.

proc isSetuidRootExecutable(path: string): bool =
  ## Owned by root AND carrying the set-user-ID bit — both halves, because
  ## either alone raises nothing. Read through `stat(2)` and not through
  ## `getFilePermissions`, whose `FilePermission` set has no member for the
  ## setuid bit.
  var info: Stat
  if stat(path.cstring, info) != 0:
    return false
  if info.st_uid.int != 0:
    return false
  (info.st_mode.uint and S_ISUID.uint) != 0

proc setuidRootBinary(name: string): string =
  for dir in SetuidSearchDirs:
    let candidate = dir / name
    if fileExists(candidate) and isSetuidRootExecutable(candidate):
      return candidate
  ""

proc kernelReportedUids(pid: int): tuple[real, effective: int] =
  ## `/proc/<pid>/status`'s `Uid:` line — real first, effective second —
  ## PARSED HERE and deliberately not through `processEffectiveUid`.
  ##
  ## That function is the thing under test, and an expectation derived from it
  ## would agree with it whichever of the four fields it read. This parse is
  ## the independent reading the comparison needs.
  result = (-1, -1)
  let path = "/proc/" & $pid & "/status"
  if not fileExists(path):
    return
  var raw = ""
  try:
    raw = readFile(path)
  except CatchableError:
    return
  for line in raw.splitLines():
    if line.startsWith("Uid:"):
      let fields = line["Uid:".len .. ^1].splitWhitespace()
      if fields.len < 2:
        return
      try:
        return (parseInt(fields[0]), parseInt(fields[1]))
      except ValueError:
        return

proc startDivergentUidPeer(): tuple[process: Process; pid, real,
                                    effective: int] =
  ## Run a setuid-root helper and hand back its pid together with the REAL and
  ## EFFECTIVE uids the kernel recorded for it, or `(nil, 0, -1, -1)` when this
  ## host offers no helper from the allowlist.
  ##
  ## The returned `Process` is NOT reaped — the caller owns it — because the
  ## helper is expected to have exited already and `/proc` only keeps
  ## answering for an unreaped child. The credentials it answers with are the
  ## ones the kernel stamped at the setuid `execve`, which is all this fixture
  ## is for.
  result = (nil, 0, -1, -1)
  for argv in SetuidRootProbeArgv:
    let binary = setuidRootBinary(argv[0])
    if binary.len == 0:
      continue
    var process: Process
    try:
      process = startProcess(binary, args = argv[1 .. ^1],
        options = {poStdErrToStdOut})
    except CatchableError:
      continue
    let pid = processID(process)
    var waited = 0
    while waited < 2_000:
      let uids = kernelReportedUids(pid)
      if uids.real >= 0 and uids.effective >= 0 and
          uids.real != uids.effective:
        return (process, pid, uids.real, uids.effective)
      sleep(20)
      waited += 20
    try:
      process.terminate()
      discard process.waitForExit()
      process.close()
    except CatchableError:
      discard

proc selfAsCheckedPeer(): TrustedDaemonPeer =
  ## A DECLARED-shaped trust fact naming a process that is certainly alive and
  ## whose kernel readings certainly re-validate: this one. Every field carries
  ## the kernel's real answer, so a case built on it grades the re-validation
  ## rule rather than the fixture's ability to keep a daemon alive.
  ##
  ## ALL THREE assertions are in `checked`, so the control exercises all three
  ## re-checks and each perturbation below is measured against a control that
  ## really did run the one it perturbs.
  ##
  ## `checkedUid` is the EFFECTIVE uid (`geteuid`) and not the real one,
  ## because that is what `SO_PEERCRED` reports and therefore what
  ## `checkDeclaredDaemon` records — a fixture that recorded the real uid would
  ## grade a comparison production never makes.
  let pid = getCurrentProcessId()
  TrustedDaemonPeer(
    pid: pid,
    identity: processStartIdentity(pid),
    name: "runquotad",
    contribution: tdcNoContent,
    origin: tdoDeclaredAndChecked,
    declaredSocket: "/run/runquota/runquotad.sock",
    checked: {daImage, daProgram, daUid},
    checkedImage: processImagePath(pid),
    checkedProgram: processCommName(pid),
    checkedUid: int(geteuid()))

suite "declared IPC trust: the check is what makes it a claim":

  test "a declared, checked daemon this build did not spawn publishes and warm-hits":
    ## THE POSITIVE, on a provisioned-host shape: the daemon is out of band
    ## (started through a shell that exited, so no `Process` handle exists for
    ## it here) and the ONLY route to trust is the declaration plus its check.
    ##
    ## Measured as "publishes AND is reused without launching", not at the
    ## completeness enum, because the enum is not what rebuilt forever. The
    ## CONTROL arm is the same edge and the same out-of-band daemon with no
    ## declaration in force: that is the state of a provisioned host under DA-2
    ## alone, and it must not publish.
    if ccPath().len == 0:
      skip()
    else:
      reset()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDetachedDaemon("unix", "declared")
      defer: stopDaemon(daemon)
      let config = monitoredConfig(repoRoot, f.cacheRoot)

      # ---- the control: DA-2's world. Nothing declared, nothing spawned. ----
      let controlEdge = f.clientEdge("decltrust/control", "unix",
        daemon.address, "control")
      let controlCold = runBuild(graph([controlEdge]), config)
      let c0 = controlCold.byId(controlEdge.id)
      checkpoint("control cold: status=" & $c0.status &
        " diagnostics=" & $c0.evidence.diagnostics)
      check c0.status == asSucceeded
      check c0.launched
      check attributionDiagnostics(c0).len == 0
      check not f.publishedRecordExists(controlEdge)
      let controlWarm = runBuild(graph([controlEdge]), config)
      check controlWarm.byId(controlEdge.id).cacheDecision notin ReuseDecisions
      check f.runCount("control") == 2

      # ---- DA-4: declare the same daemon, and check it. --------------------
      f.declare(runquotadSection(daemon.address,
        "image = " & daemon.imagePath & "\nuid = " & $int(geteuid())))
      let reports = applyDeclarationsNow()
      check reports.len == 1
      check reports.outcomeFor(ddkRunQuota) == dcoTrusted
      # The trust is DECLARED and nothing else: nothing was spawned here, so
      # DA-2's registry is empty and cannot be what publishes the edge.
      check derivedTrustedDaemonRegistry().len == 0
      check declaredPids() == @[daemon.pid]

      let edge = f.clientEdge("decltrust/positive", "unix", daemon.address,
        "positive")
      let first = runBuild(graph([edge]), config)
      let r0 = first.byId(edge.id)
      checkpoint("first: status=" & $r0.status & " reason=" & r0.reason &
        " diagnostics=" & $r0.evidence.diagnostics)
      check r0.status == asSucceeded
      check r0.launched
      check f.runCount("positive") == 1
      # Rule 3 — the exemption is COUNTED and NAMED, and the name says the
      # trust was DECLARED rather than derived, WHERE it was declared, and WHAT
      # the check verified. Asserted on the real line, not on its length.
      let attributed = attributionDiagnostics(r0)
      check attributed.len >= 1
      if attributed.len >= 1:
        checkpoint("diagnostic=" & attributed[0])
        check "ipc peer attributed to daemon 'runquotad'" in attributed[0]
        check ("(pid " & $daemon.pid & ")") in attributed[0]
        check ("declared at " & daemon.address & " and checked (daImage, " &
          "daUid), re-validated against the kernel at grading time") in
          attributed[0]
        check ("Dependency-Observation-Attribution.md §Class 3 branch (a), " &
          "contributes no content to the action (DA-4); forgave: ") in
          attributed[0]
        # The forgiven loss is quoted VERBATIM, so the line an operator reads
        # carries the evidence as well as the verdict.
        check "forgave: ipc peer outside monitored tree pid=" in attributed[0]
        check ("peer=" & $daemon.pid) in attributed[0]
      check f.publishedRecordExists(edge)

      let warm = runBuild(graph([edge]), config)
      let r1 = warm.byId(edge.id)
      checkpoint("warm: decision=" & $r1.cacheDecision &
        " launched=" & $r1.launched)
      check r1.cacheDecision in ReuseDecisions
      check not r1.launched
      check f.runCount("positive") == 1

  test "a declaration whose check fails is not trusted — one arm per assertion":
    ## THE MILESTONE'S POINT. The declaration is identical in every arm but one
    ## field, and that field is the one the kernel disagrees with.
    ##
    ## One arm per member of `DaemonAssertion`, because the check's scope is a
    ## `set[DaemonAssertion]` and rule 8 says a guard scoped to a set is graded
    ## on every member — the member list is what a later contributor edits.
    ## Each arm carries its own positive control, so a refusal is not a refusal
    ## produced by a fixture that could never have passed.
    if ccPath().len == 0:
      skip()
    else:
      reset()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDetachedDaemon("unix", "checkfail")
      defer: stopDaemon(daemon)
      # The EFFECTIVE uid: `SO_PEERCRED` reports `euid`, so that is what a
      # `uid` declaration is compared against and what the grading-time
      # re-check re-reads. Declaring the real uid would pass here only because
      # the two happen to coincide for this process.
      let myUid = int(geteuid())

      template outcomeOf(keys: string): DaemonCheckOutcome =
        reset()
        f.declare(runquotadSection(daemon.address, keys))
        applyDeclarationsNow().outcomeFor(ddkRunQuota)

      # daImage — the strongest assertion, and available here because the
      # fixture's daemon runs as us, so `/proc/<pid>/exe` really is readable.
      check outcomeOf("image = " & daemon.imagePath) == dcoTrusted
      check declaredPids() == @[daemon.pid]
      check outcomeOf("image = " & f.clientPath) == dcoImageMismatch
      check declaredPids().len == 0

      # daProgram — `comm` is the executable's basename, truncated to 15 bytes.
      check outcomeOf("program = " & daemon.imagePath.extractFilename) ==
        dcoTrusted
      check declaredPids() == @[daemon.pid]
      check outcomeOf("program = runquotad") == dcoProgramMismatch
      check declaredPids().len == 0

      # daUid — the only one of the three the kernel answers across a uid
      # boundary, and the only one no userspace end can influence. It is never
      # declared ALONE (that is `dcoNoProgramAssertion`, graded by its own case
      # below), so both arms carry the program assertion the check now requires
      # and the field under test is still the only thing that differs.
      let programKey = "program = " & daemon.imagePath.extractFilename & "\n"
      check outcomeOf(programKey & "uid = " & $myUid) == dcoTrusted
      check declaredPids() == @[daemon.pid]
      check outcomeOf(programKey & "uid = " & $(myUid + 1)) == dcoUidMismatch
      check declaredPids().len == 0

      # The assertions are a CONJUNCTION: one mismatch refuses the whole
      # declaration rather than trusting the part that held.
      check outcomeOf("image = " & daemon.imagePath & "\nuid = " &
        $(myUid + 1)) == dcoUidMismatch
      check declaredPids().len == 0

  test "an edge talking to a daemon whose declaration fails its check still downgrades":
    ## The same refusal, end to end. The declaration names the right endpoint
    ## and the wrong program, the daemon is live and answering, and the edge
    ## must still rebuild forever rather than publish — which is the property
    ## the enum-level arms above cannot show.
    if ccPath().len == 0:
      skip()
    else:
      reset()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDetachedDaemon("unix", "e2efail")
      defer: stopDaemon(daemon)
      f.declare(runquotadSection(daemon.address, "program = runquotad"))
      check applyDeclarationsNow().outcomeFor(ddkRunQuota) == dcoProgramMismatch
      check declaredPids().len == 0

      let edge = f.clientEdge("decltrust/e2e-fail", "unix", daemon.address,
        "e2e")
      let config = monitoredConfig(repoRoot, f.cacheRoot)
      let first = runBuild(graph([edge]), config)
      let r0 = first.byId(edge.id)
      checkpoint("first: status=" & $r0.status &
        " diagnostics=" & $r0.evidence.diagnostics)
      check r0.status == asSucceeded
      check r0.launched
      check attributionDiagnostics(r0).len == 0
      check not f.publishedRecordExists(edge)
      let warm = runBuild(graph([edge]), config)
      check warm.byId(edge.id).cacheDecision notin ReuseDecisions
      check f.runCount("e2e") == 2

  test "an UNDECLARED peer still downgrades while a declared one is trusted":
    ## The guarantee, intact, and what keeps DA-4 from being a suppression in
    ## disguise. Both daemons are THE SAME BINARY serving THE SAME protocol,
    ## alive at the same time; one is named by the declaration and the other is
    ## not, and that is the only difference between them. The declared one is
    ## really trusted, so every DA-4 code path is live while this happens.
    if ccPath().len == 0:
      skip()
    else:
      reset()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      var declared = f.startDetachedDaemon("unix", "named")
      defer: stopDaemon(declared)
      var stranger = f.startDetachedDaemon("unix", "stranger")
      defer: stopDaemon(stranger)
      f.declare(runquotadSection(declared.address,
        "image = " & declared.imagePath))
      check applyDeclarationsNow().outcomeFor(ddkRunQuota) == dcoTrusted
      check declaredPids() == @[declared.pid]

      let edge = f.clientEdge("decltrust/stranger", "unix", stranger.address,
        "stranger")
      let config = monitoredConfig(repoRoot, f.cacheRoot)
      let first = runBuild(graph([edge]), config)
      let r0 = first.byId(edge.id)
      checkpoint("first: status=" & $r0.status &
        " diagnostics=" & $r0.evidence.diagnostics)
      check r0.status == asSucceeded
      check r0.launched
      check attributionDiagnostics(r0).len == 0
      check not f.publishedRecordExists(edge)
      let warm = runBuild(graph([edge]), config)
      check warm.byId(edge.id).cacheDecision notin ReuseDecisions
      check f.runCount("stranger") == 2

  test "an INET peer is never trusted, however hard it is declared or registered":
    ## CLASS 4, UNEXEMPTIBLE (rule 4), from both directions.
    ##
    ## The DECLARATION arm shows the surface refuses a non-unix endpoint before
    ## it ever connects, so a network peer is not merely unattributable later —
    ## it is not declarable now.
    ##
    ## The ACTION arm registers the INET daemon's pid outright, through DA-2's
    ## derived API and therefore with no check to fail, and the edge downgrades
    ## anyway: `SO_PEERCRED` yields no pid for INET (io-mon `recordIpcConnect`)
    ## so io-mon records `peer=0`, and its exemption requires `peer != 0`
    ## (io-mon `src/io_mon/writer.nim:1992`). The guarantee is held THERE, not
    ## by anything reprobuild chooses to honour, which is why the case measures
    ## it under the most favourable configuration for breaking it.
    if ccPath().len == 0:
      skip()
    else:
      reset()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      var inet = f.startDaemon("inet", "inet")
      defer: stopDaemon(inet)

      # A relative path first, because it needs no quoting and therefore grades
      # the SHAPE refusal on its own.
      f.declare(runquotadSection("relative/runquotad.sock", "uid = 0"))
      check applyDeclarationsNow().outcomeFor(ddkRunQuota) ==
        dcoEndpointNotAbsolute
      check declaredPids().len == 0

      # And then the network shape. MEASURED: a bare `socket = 127.0.0.1:PORT`
      # does not even LEX — `std/parsecfg` reads `:` as a key/value separator
      # and the load raises before any check runs. That is a second and
      # entirely accidental line of defence, so it is not what this arm rests
      # on: the value is quoted here, which is what an operator determined to
      # declare a network peer would have to write, and the refusal that
      # answers is `checkDeclaredDaemon`'s own.
      reset()
      f.declare(runquotadSection("\"127.0.0.1:" & inet.address & "\"",
        "uid = 0"))
      let reports = applyDeclarationsNow()
      check reports.outcomeFor(ddkRunQuota) == dcoEndpointNotAbsolute
      check declaredPids().len == 0
      check renderDaemonCheckReport(reports[0]).contains("NOT trusted")

      trustDaemonWeSpawned(inet.process, "runquotad", tdcNoContent)
      check revalidatedTrustedDaemons(
        derivedTrustedDaemonRegistry()).anyIt(it.pid == inet.pid)

      let edge = f.clientEdge("decltrust/inet", "inet", inet.address, "inet")
      let config = monitoredConfig(repoRoot, f.cacheRoot)
      let first = runBuild(graph([edge]), config)
      let r0 = first.byId(edge.id)
      checkpoint("first: status=" & $r0.status &
        " diagnostics=" & $r0.evidence.diagnostics)
      check r0.status == asSucceeded
      check r0.launched
      check attributionDiagnostics(r0).len == 0
      check not f.publishedRecordExists(edge)
      let warm = runBuild(graph([edge]), config)
      check warm.byId(edge.id).cacheDecision notin ReuseDecisions
      check f.runCount("inet") == 2
      reset()

  test "a checked peer that is REPLACED does not inherit trust":
    ## Every way a peer can be replaced after its check passed, and none of
    ## them may carry the trust across. The arms are numbered in the body; no
    ## count is stated here, because the last one to state a count was written
    ## when there were three and was still saying so when there were four.
    ##
    ## The first is live: daemon A is checked at socket S, killed, and daemon B
    ## binds the same S. The declaration still names S; the action's peer pid is
    ## B's; B is in no trust set. That is the case a path-shaped check — one
    ## that concluded "the daemon is at this socket" — would have got wrong.
    ##
    ## The rest perturb a recorded trust fact (see the header for why they
    ## cannot be arranged from outside the peer process), and share the
    ## unperturbed control immediately above them. The `daUid` arm's own
    ## question — WHICH uid field the re-check reads — needs a peer whose real
    ## and effective uids differ, which no fixture here is; that is the case
    ## immediately below.
    if ccPath().len == 0:
      skip()
    else:
      reset()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)

      # (1) the socket is re-bound by a different process.
      var first = f.startDetachedDaemon("unix", "rebind")
      defer: stopDaemon(first)
      f.declare(runquotadSection(first.address, "image = " & first.imagePath))
      check applyDeclarationsNow().outcomeFor(ddkRunQuota) == dcoTrusted
      check declaredPids() == @[first.pid]
      let checkedPid = first.pid
      let checkedAddress = first.address
      stopDaemon(first)
      var second = f.startDetachedDaemon("unix", "rebind")
      defer: stopDaemon(second)
      checkpoint("rebound: checked=" & $checkedPid & " now=" & $second.pid)
      check second.pid != checkedPid
      check second.address == checkedAddress
      # The registration is now stale, and re-validation is what notices — the
      # declaration is unchanged and still names the same socket.
      check declaredPids().len == 0

      let edge = f.clientEdge("decltrust/rebound", "unix", second.address,
        "rebound")
      let config = monitoredConfig(repoRoot, f.cacheRoot)
      let cold = runBuild(graph([edge]), config)
      let r0 = cold.byId(edge.id)
      checkpoint("rebound cold: status=" & $r0.status &
        " diagnostics=" & $r0.evidence.diagnostics)
      check r0.status == asSucceeded
      check attributionDiagnostics(r0).len == 0
      check not f.publishedRecordExists(edge)

      # (2) the pid was recycled — same number, different incarnation. The
      # control is the same fact unperturbed, so the drop below is the identity
      # re-check and not an unbuildable fixture.
      let control = selfAsCheckedPeer()
      check control.identity.len > 0
      check control.checkedImage.len > 0
      check control.checkedProgram.len > 0
      check revalidatedTrustedDaemons([control]).len == 1
      var recycled = control
      recycled.identity = $(parseInt(control.identity) + 1)
      check revalidatedTrustedDaemons([recycled]).len == 0

      # (3) the peer exec'd in place — pid AND start time unchanged, program
      # not. This is the arm a start-time-only re-validation misses, so it is
      # graded on EVERY re-checked assertion rather than on whichever one
      # happens to run first.
      var reExeced = control
      reExeced.checkedProgram = control.checkedProgram & "-x"
      check revalidatedTrustedDaemons([reExeced]).len == 0
      var reImaged = control
      reImaged.checkedImage = control.checkedImage & "-x"
      check revalidatedTrustedDaemons([reImaged]).len == 0

      # (4) THE PEER ACQUIRED PRIVILEGES IN PLACE. `daUid` had no re-check,
      # on the argument that a surviving (pid, start-time) is the same process
      # and "a process can drop privileges but cannot acquire them", so
      # re-checking could only reject and never protect. MEASURED FALSE
      # (2026-09-11), sampling /proc across an execve into setuid-root sudo:
      #
      #   t=0.000 pid=1183970 comm=execprobe2 starttime=4661947 euid=1007
      #   t=0.158 pid=1183970 comm=sudo       starttime=4661947 euid=0
      #
      # Same pid, same field 22, euid raised. The general form needs no exec at
      # all — a daemon that dropped from root keeps root in its saved
      # set-user-ID and may `seteuid(0)` back with an unchanged image AND an
      # unchanged `comm`, which is the shape neither of the other two
      # re-checks can stand in for. So `daUid` is re-checked like everything
      # else, against the EFFECTIVE uid, which is what `SO_PEERCRED` reports.
      check daUid in control.checked
      check control.checkedUid == int(geteuid())
      check processEffectiveUid(getCurrentProcessId()) == int(geteuid())
      var reUided = control
      reUided.checkedUid = control.checkedUid + 1
      check revalidatedTrustedDaemons([reUided]).len == 0
      # TWO DIFFERENT SUBJECTS, and this comment used to name only the first.
      #
      # (i) THE ACCESSOR: a pid the kernel will not answer for reads as -1
      # rather than as some uid.
      check processEffectiveUid(0) == -1
      # (ii) THE RECORD: a peer whose RECORDED uid is -1 — a value
      # `SO_PEERCRED` never supplies — is dropped rather than treated as
      # matching. Note what is actually perturbed here: the peer is `control`,
      # which the kernel answers for perfectly well. This arm is about the
      # recording, not about an unanswerable peer.
      #
      # AND THE HONEST LIMIT OF IT, because the two halves of the guard are
      # not equally graded. The guard is
      # `checkedUid < 0 or processEffectiveUid(pid) != checkedUid`, and it is
      # the SECOND disjunct that drops this input (-1 against our real euid).
      # The first is UNREACHABLE here on Linux: reaching it needs
      # `processEffectiveUid` to answer -1 for a pid whose
      # `processStartIdentity` has just re-validated, and `/proc/<pid>/status`
      # exists exactly when `/proc/<pid>/stat` does. MEASURED (2026-09-11):
      # deleting the `checkedUid < 0` disjunct leaves all 17 cases of this
      # file green. It is kept as defence in depth against a future caller
      # that records a uid it never read — not because anything here grades
      # it, and this note is here so the next sweep does not mistake the
      # assertion below for a case that does.
      var unreadableUid = control
      unreadableUid.checkedUid = -1
      check revalidatedTrustedDaemons([unreadableUid]).len == 0

  test "the uid re-check reads the EFFECTIVE uid, on a peer whose two differ":
    ## ARM (4) OF THE CASE ABOVE, ON A PEER THE TWO UIDS ACTUALLY COME APART
    ## FOR — which no fixture in this file was, and which is why the field the
    ## re-check reads was ungraded. Every daemon here runs with
    ## `ruid == euid`, so `/proc/<pid>/status`'s first and second `Uid:` fields
    ## hold the same number and reading either one gives the same answer.
    ## MEASURED (2026-09-11): making `processEffectiveUid` return the REAL uid
    ## left all 16 cases of this file green.
    ##
    ## `processEffectiveUid`'s own docstring carries the argument — the
    ## effective uid is the field `SO_PEERCRED` reports, so it is the field
    ## `checkedUid` was recorded from and the only one the re-check may compare
    ## against. This case is what stands behind it.
    ##
    ## WHY IT MATTERS MORE THAN TIDINESS. The `daUid` re-check exists for a
    ## daemon that dropped from root: root stays in its SAVED set-user-ID and
    ## it may `seteuid(0)` back at any moment, with no exec, an unchanged image
    ## and an unchanged `comm` — invisible to the other two re-checks. A
    ## re-check reading the REAL uid would see 0 throughout and miss exactly
    ## that; a re-check reading the EFFECTIVE uid sees the raise.
    ##
    ## THE FIXTURE IS A REAL SETUID-ROOT PROGRAM, AND IT IS NOT A MOCK.
    ## Nothing is substituted for a collaborator: the KERNEL raises the
    ## effective uid in place at a setuid `execve` and leaves the real uid
    ## alone, and `/proc/<pid>/status` is the kernel's own rendering of both.
    ## The divergence cannot be produced any other way from an unprivileged
    ## process — an unprivileged `setresuid` may only choose among the uids the
    ## process already holds, and for this one all four are the same number.
    ## The helper is run on a group/user name that does not exist, so it
    ## resolves, fails and exits without touching anything; it stays UNREAPED
    ## until the readings are taken, which is what keeps `/proc` answering.
    ##
    ## GRADED AT BOTH ALTITUDES, because grading the accessor alone would leave
    ## the comparison `revalidatedTrustedDaemons` actually makes untested: the
    ## accessor returns the effective field, AND the production re-validation
    ## KEEPS a peer whose recorded uid is the effective one while DROPPING the
    ## same peer with the real one recorded.
    if getuid() == 0:
      # As root a setuid-root `execve` raises nothing — `ruid == euid == 0` —
      # so the divergence this case is about cannot exist here. Say what this
      # host is instead of passing quietly.
      #
      # `echo` AND NOT `checkpoint`, because a checkpoint is flushed ONLY when
      # a case FAILS. MEASURED on this toolchain: a checkpoint on a passing
      # case and a checkpoint before `skip()` both print nothing whatsoever.
      # A checkpoint here would have been precisely the quiet pass this arm
      # exists to avoid.
      echo "NOT GRADED HERE (loudly): running as root, so ruid == euid and " &
        "no peer on this host can show the divergence this case grades"
      check processEffectiveUid(getCurrentProcessId()) == 0
    else:
      let peer = startDivergentUidPeer()
      defer:
        if peer.process != nil:
          try:
            peer.process.terminate()
            discard peer.process.waitForExit()
            peer.process.close()
          except CatchableError:
            discard
      if peer.pid == 0:
        # Loud, for the reason given on the root arm above and in this
        # suite's existing idiom for it (see
        # `t_a_behind_only_refusal_names_a_pasteable_command`): `[SKIPPED]`
        # with nothing but a checkpoint behind it is a SILENT skip, and a
        # skip proves nothing — so WHY it skipped has to reach the run
        # output, where the zero-skip gate's reader will see it.
        echo "SKIPPED (loudly): no setuid-root helper from the allowlist (" &
          SetuidRootProbeArgv.mapIt(it[0]).join(", ") & ") on this host, so " &
          "the uid divergence cannot be produced and this case grades nothing"
        skip()
      else:
        checkpoint("setuid peer pid=" & $peer.pid & " real=" & $peer.real &
          " effective=" & $peer.effective)
        # The fixture is the shape the case needs, asserted rather than
        # assumed: a real uid that is still ours and an effective uid that is
        # root's.
        check peer.real == int(getuid())
        check peer.effective == 0
        check peer.real != peer.effective

        # THE ACCESSOR. Reading `Uid:`'s real field would answer `peer.real`
        # here, so the two assertions cannot both hold for the wrong field.
        check processEffectiveUid(peer.pid) == peer.effective
        check processEffectiveUid(peer.pid) != peer.real

        # THE PRODUCTION CALL, which is the property. `checkedUid` can only
        # ever hold the EFFECTIVE uid, because `SO_PEERCRED` reports no other
        # — so a peer recorded that way must survive re-validation, and the
        # same peer recorded with the real uid must not. Only `daUid` is in
        # `checked`, so this is the uid re-check on its own.
        let identity = processStartIdentity(peer.pid)
        check identity.len > 0
        template asRecordedUid(uid: int): TrustedDaemonPeer =
          TrustedDaemonPeer(
            pid: peer.pid, identity: identity, name: "runquotad",
            contribution: tdcNoContent, origin: tdoDeclaredAndChecked,
            declaredSocket: "/run/runquota/runquotad.sock",
            checked: {daUid}, checkedUid: uid)
        check revalidatedTrustedDaemons(
          [asRecordedUid(peer.effective)]).len == 1
        check revalidatedTrustedDaemons([asRecordedUid(peer.real)]).len == 0

  test "a declaration that identifies no program is refused before it connects":
    ## TWO REFUSALS AT THE DECLARATION SURFACE, in increasing order of
    ## subtlety, and one positive control that separates them from "the daemon
    ## is unreachable".
    ##
    ## `dcoNothingAsserted` — "something is listening at this path" proves
    ## nothing an attacker or an accident could not arrange, so it is not a
    ## check.
    ##
    ## `dcoNoProgramAssertion` — THE ONE THAT BLOCKED THIS MILESTONE. A `uid`
    ## assertion is un-forgeable and still identifies no PROGRAM, and the
    ## §Class 3 branch is a property of the program: `class3Contribution` is a
    ## table from program to branch, so a check that established only "a
    ## process with this uid is listening here" has not established what the
    ## branch is about. On a socket-activated host the peer of a daemon socket
    ## is the ACTIVATOR — pid 1, uid 0, `comm=systemd`, answering every socket
    ## it activates — so a uid-only declaration of one endpoint trusts a
    ## process that serves all of them. Refused, and refused BEFORE THE
    ## CONNECTION: an inadequate declaration must not even touch the daemon.
    ##
    ## THE ORDERING IS OBSERVED AT THE DAEMON, NOT INFERRED FROM THE OUTCOME,
    ## because the outcome does not distinguish the two. MEASURED
    ## (2026-09-11): moving the gate to AFTER the connect preserves every
    ## enum, every rendered line and every `declaredPids()` answer in this
    ## case exactly, and left all 16 cases of this file green — the ordering
    ## claim in this case's own NAME was the only thing asserting it. So the
    ## fixture daemon keeps an ACCEPT LOG (see `DaemonSource`) and both
    ## refusals assert it is still empty afterwards, with the passing control
    ## at the end asserting it is not — which is what stops an empty log from
    ## being a green produced by a recorder that never records.
    ##
    ## The property is not cosmetic: refusing before connecting is what keeps a
    ## declaration that cannot discharge rule 5 from opening a connection to an
    ## arbitrary path named by that same declaration.
    ##
    ## The refusal is asserted on a REACHABLE daemon, so it cannot be confused
    ## with `dcoUnreachable`; the control adds a program assertion to the same
    ## live daemon at the same endpoint and passes.
    if ccPath().len == 0:
      skip()
    else:
      reset()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDetachedDaemon("unix", "bare")
      defer: stopDaemon(daemon)
      # Nothing has reached the daemon yet, so every count below is a
      # difference this case caused.
      check f.contactCount("bare") == 0

      f.declare(runquotadSection(daemon.address, ""))
      check applyDeclarationsNow().outcomeFor(ddkRunQuota) == dcoNothingAsserted
      check declaredPids().len == 0
      check f.contactsWithin("bare", 1, 400) == 0

      reset()
      f.declare(runquotadSection(daemon.address, "uid = " & $int(geteuid())))
      let uidOnly = applyDeclarationsNow()
      check uidOnly.outcomeFor(ddkRunQuota) == dcoNoProgramAssertion
      check declaredPids().len == 0
      check f.contactsWithin("bare", 1, 400) == 0
      # The rendered line has to say what to do about it, because the operator
      # reading it wrote a declaration that used to work.
      let line = renderDaemonCheckReport(uidOnly[0])
      checkpoint("report=" & line)
      check line.contains("NOT trusted")
      check line.contains("identifies the peer's program")
      # The refusal is a property of the DECLARATION and not of the peer: the
      # predicate says so on the declaration alone, with no daemon in sight.
      check not declarationIdentifiesAProgram(
        DeclaredDaemon(kind: ddkRunQuota, endpoint: daemon.address,
          assertions: {daUid}, uid: 0))
      for assertion in ProgramIdentifyingAssertions:
        check declarationIdentifiesAProgram(
          DeclaredDaemon(kind: ddkRunQuota, endpoint: daemon.address,
            assertions: {assertion, daUid}, uid: 0))

      # The control: the SAME daemon at the SAME endpoint, with a program
      # assertion added, is trusted. So the two refusals above are about what
      # the declaration asserts and not about the daemon or the path.
      reset()
      f.declare(runquotadSection(daemon.address,
        "program = " & daemon.imagePath.extractFilename &
        "\nuid = " & $int(geteuid())))
      check applyDeclarationsNow().outcomeFor(ddkRunQuota) == dcoTrusted
      check declaredPids() == @[daemon.pid]
      # AND THE ACCEPT LOG'S OWN POSITIVE CONTROL. An ADEQUATE declaration
      # does connect, and the daemon records it — so the two empty counts
      # above are the gate refusing before the connect and not a log that
      # never fills.
      check f.contactsWithin("bare", 1, 5_000) >= 1

  test "a declaration naming a peer that never appears is reported":
    ## The milestone's third named test. A daemon that has moved, been renamed
    ## or stopped running leaves a line asserting a peer nobody will meet; if
    ## nothing reports it, it sits there until a pid collision makes it mean
    ## something. So the assertion is on the rendered line an operator actually
    ## sees, and not merely on the enum behind it.
    reset()
    let f = makeFixture()
    defer: removeDir(f.root)
    let absent = f.workRoot / "absent.sock"
    # A COMPLETE declaration — program-identifying, so the surface refusals do
    # not answer first and the outcome really is "nobody was there". That
    # ordering is load-bearing: `dcoNoProgramAssertion` is decided before the
    # connect, so a uid-only declaration of an absent socket would report the
    # declaration's inadequacy and never reach the staleness this case is for.
    f.declare(runquotadSection(absent, "program = runquotad\nuid = 0"))
    let reports = applyDeclarationsNow()
    check reports.len == 1
    check reports[0].outcome == dcoUnreachable
    check declaredPids().len == 0
    let line = renderDaemonCheckReport(reports[0])
    checkpoint("report=" & line)
    check line.contains("NOT trusted")
    check line.contains("runquotad")
    check line.contains(absent)
    check line.contains(f.workRoot / "daemons.conf")

  test "the declaration surface is closed: unknown daemons and unknown keys are refused":
    ## The class-3 branch is the one thing a check cannot establish, so it is
    ## the one thing nobody may assert: the vocabulary of declarable daemons is
    ## compiled in and each member carries its own branch. A section naming
    ## anything else is an ERROR rather than an ignored line, and so is an
    ## unknown key — a typo that silently declared nothing is the same rot as a
    ## declaration nobody checks, pointed the other way.
    reset()
    let f = makeFixture()
    defer: removeDir(f.root)

    # The three peers this milestone makes declarable, and the branch each one
    # satisfies. Pinned here because the branch is the part no runtime check
    # can defend, so a silent edit to it must be a red case.
    check class3Contribution(ddkRunQuota) == tdcNoContent
    check class3Contribution(ddkNixDaemon) == tdcContentAlreadyKeyed
    check class3Contribution(ddkReproStoreDaemon) == tdcContentAlreadyKeyed
    for kind in DeclarableDaemonKind:
      check parseDaemonKind(daemonKindName(kind)).get() == kind
    check parseDaemonKind("sshd").isNone

    f.declare("[sshd]\nsocket = /tmp/x.sock\nuid = 0\n")
    expect DaemonDeclarationError:
      discard loadDeclaredDaemons()
    f.declare("[runquotad]\nsocket = /tmp/x.sock\ncontribution = no-content\n")
    expect DaemonDeclarationError:
      discard loadDeclaredDaemons()

    # AND THE DIAGNOSTIC IS DERIVED FROM THE VOCABULARY, NOT RESTATED BESIDE
    # IT. The "unknown daemon" error used to carry the literal sentence
    # "runquotad, nix-daemon, repro-store-daemon", so a fourth
    # `DeclarableDaemonKind` would have left it telling an operator that a
    # valid section name is not declarable — with every case here green,
    # because nothing compared the sentence to the enum. Asserting membership
    # for EVERY member is what makes adding a kind red until the sentence
    # follows; asserting the length as well is what stops a "derivation" that
    # concatenates the enum onto a stale literal from passing.
    var listed: seq[string] = @[]
    for kind in DeclarableDaemonKind:
      listed.add(daemonKindName(kind))
    check declarableDaemonNames() == listed.join(", ")
    f.declare("[sshd]\nsocket = /tmp/x.sock\nuid = 0\n")
    var unknownMessage = ""
    try:
      discard loadDeclaredDaemons()
    except DaemonDeclarationError as exc:
      unknownMessage = exc.msg
    checkpoint("unknown-daemon error=" & unknownMessage)
    check unknownMessage.len > 0
    for kind in DeclarableDaemonKind:
      check daemonKindName(kind) in unknownMessage
    check declarableDaemonNames() in unknownMessage
    # And the positive control, so the two refusals are not a loader that
    # refuses everything.
    f.declare("[runquotad]\nsocket = /tmp/x.sock\nuid = 0\n")
    let loaded = loadDeclaredDaemons()
    check loaded.len == 1
    check loaded[0].kind == ddkRunQuota
    check loaded[0].assertions == {daUid}
    check loaded[0].uid == 0

  test "a check result cannot be fabricated, and neither can a branch":
    ## The structural half of rule 5, asserted the way DA-2 asserted its own:
    ## by showing the call that would bypass the check does not COMPILE, with
    ## positive controls so the `compiles` results are not vacuously false.
    reset()
    var fabricated = DaemonIdentityCheck()
    # The zero value is the only one an outside caller can build, and it is
    # refused: `pid = 0` is no peer at all.
    check not trustDaemonWeChecked(ddkRunQuota, fabricated)
    check declaredTrustedDaemonRegistry().len == 0
    # Its fields are private to the engine module, so nothing here can read one
    # — and therefore nothing here can fill one in either.
    check not compiles(fabricated.pid)
    check not compiles(fabricated.outcome)
    check not compiles(fabricated.verified)
    # The positive controls: the accessors that ARE public do compile, so the
    # two refusals above are about the fields being private and not about the
    # names being wrong.
    check compiles(checkedDaemonPid(fabricated))
    check compiles(checkedDaemonOutcome(fabricated))
    check checkedDaemonPid(fabricated) == 0
    # The class-3 branch is not a parameter of the registration at all.
    check not compiles(
      trustDaemonWeChecked(ddkRunQuota, fabricated, tdcNoContent))
    check compiles(trustDaemonWeChecked(ddkRunQuota, fabricated))

  test "the check refuses an image it cannot verify rather than degrading":
    ## WHAT THE CHECK CANNOT DO, MEASURED.
    ##
    ## `/proc/<pid>/exe` needs `PTRACE_MODE_READ_FSCREDS`, so an unprivileged
    ## `repro` cannot read it for a root-owned daemon — which is the shipped
    ## host-wide `runquotad` and the Nix daemon, i.e. exactly the peers DA-4
    ## mainly exists for. On that topology the strongest assertion is
    ## UNAVAILABLE and the check rests on `uid` (un-forgeable) plus `program`
    ## (kernel-recorded but process-settable via `prctl(PR_SET_NAME)`). That is
    ## a real ceiling on a declared claim, and it is measured here rather than
    ## conceded in a comment.
    ##
    ## The second arm is the one a live daemon CAN produce: an image unlinked
    ## since exec. The kernel renders it `<path> (deleted)`, so the peer is
    ## running bytes the declared path no longer names, and the assertion is
    ## refused rather than matched against a mangled string.
    if ccPath().len == 0:
      skip()
    else:
      reset()
      let f = makeFixture()
      defer: removeDir(f.root)
      if getuid() == 0:
        # As root every image is readable, so the permission arm would be
        # vacuous. Say what this host actually is instead of passing quietly.
        checkpoint("running as root: the cross-uid arm cannot be exercised")
        check processImagePath(1).len > 0
      else:
        check processImagePath(1).len == 0
      # The control: our own image IS readable, so the line above is about the
      # uid boundary and not about `/proc` being unavailable.
      check processImagePath(getCurrentProcessId()).len > 0

      # `decl_daemon2` and not `decl_daemon_copy`: `comm` is the basename
      # TRUNCATED TO 15 BYTES, so a 16-byte name would make the `program`
      # control below compare against a silently shortened string and grade
      # the truncation instead of the assertion.
      let copied = f.binDir / "decl_daemon2"
      copyFile(f.daemonPath, copied)
      setFilePermissions(copied, getFilePermissions(f.daemonPath))
      var daemon = f.startDetachedDaemon("unix", "unlinked", copied)
      defer: stopDaemon(daemon)
      # Control first: while the image exists, the assertion passes.
      f.declare(runquotadSection(daemon.address, "image = " & copied))
      check applyDeclarationsNow().outcomeFor(ddkRunQuota) == dcoTrusted
      reset()
      removeFile(copied)
      check processImagePath(daemon.pid).len == 0
      f.declare(runquotadSection(daemon.address, "image = " & copied))
      check applyDeclarationsNow().outcomeFor(ddkRunQuota) == dcoImageUnreadable
      check declaredPids().len == 0
      # `program` + `uid` over the SAME peer still passes, so the refusal is
      # scoped to what could not be verified rather than to the peer — and it
      # is the fallback the refusal's own detail tells the operator to use,
      # which is the shape a cross-uid daemon is left with.
      reset()
      f.declare(runquotadSection(daemon.address,
        "program = " & copied.extractFilename & "\nuid = " & $int(geteuid())))
      check applyDeclarationsNow().outcomeFor(ddkRunQuota) == dcoTrusted
      check declaredPids() == @[daemon.pid]

  test "the real CLI applies declared trust on arms that never spawn":
    ## THE PRODUCTION WIRING, which every case above deliberately does not
    ## touch: they all apply the declarations by hand, so they grade the
    ## MECHANISM and never the one call site that uses it.
    ##
    ## Two arms, and both return BEFORE any spawn — which is the class of arm
    ## DA-2 cannot reach at all, and the reason the DA-4 call sits above every
    ## early return in `startAutoRunQuotaIfNeeded`:
    ##
    ##   * the BYPASS arm, which is deterministic on any host;
    ##   * the ADOPT arm, driven the way `t_derived_daemon_ipc_trust` drives it
    ##     — spawn once so a daemon is reachable on the socket that call
    ##     published, then call again. DA-2's own reach note says an adopted
    ##     daemon is not registered; this asserts that it is not, AND that the
    ##     declared peer is registered on that same call.
    if ccPath().len == 0:
      skip()
    else:
      reset()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDetachedDaemon("unix", "wiring")
      defer: stopDaemon(daemon)
      f.declare(runquotadSection(daemon.address,
        "image = " & daemon.imagePath & "\nuid = " & $int(geteuid())))

      # ---- the bypass arm ---------------------------------------------------
      var bypassed = startAutoRunQuotaIfNeeded(bypassRunQuota = true)
      check bypassed == nil
      check derivedTrustedDaemonRegistry().len == 0
      check declaredPids() == @[daemon.pid]
      let peer = declaredTrustedDaemonRegistry()[0]
      check peer.origin == tdoDeclaredAndChecked
      check peer.name == "runquotad"
      check peer.contribution == tdcNoContent
      check peer.declaredSocket == daemon.address
      check peer.checked == {daImage, daUid}

      # ---- the adopt arm ----------------------------------------------------
      if findRunQuotaDaemonBin().len == 0:
        checkpoint("no runquotad binary: the adopt arm is not driven here")
      else:
        let scratch = createTempDir("repro-declwire-", "",
          dir = nonVolatileTempBase())
        defer: removeDir(scratch)
        let priorSocket = getEnv("RUNQUOTA_SOCKET", "")
        putEnv("RUNQUOTA_SOCKET", scratch / "no-such-runquota.sock")
        putEnv("REPROBUILD_AUTO_RUNQUOTA", "1")
        reset()
        f.declare(runquotadSection(daemon.address,
          "image = " & daemon.imagePath & "\nuid = " & $int(geteuid())))
        var spawned = startAutoRunQuotaIfNeeded(false)
        defer:
          releaseAutoRunQuotaProcess(spawned)
          putEnv("RUNQUOTA_SOCKET", priorSocket)
          reset()
        check spawned != nil
        # Now forget everything and take the ADOPT arm: the daemon the call
        # above spawned is reachable on the socket it published, so this call
        # returns early without spawning.
        reset()
        f.declare(runquotadSection(daemon.address,
          "image = " & daemon.imagePath & "\nuid = " & $int(geteuid())))
        var adopted = startAutoRunQuotaIfNeeded(false)
        defer: releaseAutoRunQuotaProcess(adopted)
        check adopted == nil
        # DA-2 registers nothing for an adopted daemon — and DA-4 does.
        check derivedTrustedDaemonRegistry().len == 0
        check declaredPids() == @[daemon.pid]

  test "the user config file is read, and a system declaration it repeats is replaced":
    ## WHERE THE DECLARATION LIVES. `Dependency-Observation-Attribution.md`
    ## §"Where each declaration lives" puts machine facts at the
    ## workspace/machine layer and lets the project recipe declare NOTHING
    ## about monitoring, so the surface is a system file plus a per-user file
    ## that extends and overrides it by name — the shape `caches_config.nim`
    ## already uses one problem over.
    ##
    ## The system path is `/etc/repro/daemons.conf` and a test may not write
    ## it, so what is graded here is the USER arm and the by-name replacement
    ## rule, through `XDG_CONFIG_HOME`, with `REPRO_DAEMONS_CONFIG` UNSET so
    ## the ordinary precedence really is what answers.
    reset()
    let f = makeFixture()
    defer: removeDir(f.root)
    let previousXdg = getEnv("XDG_CONFIG_HOME", "")
    let configHome = f.root / "xdgconfig"
    createDir(configHome / "repro")
    let userFile = configHome / "repro" / "daemons.conf"
    writeFile(userFile,
      "[nix-daemon]\nsocket = /nix/var/nix/daemon-socket/socket\nuid = 0\n" &
      "[repro-store-daemon]\nsocket = " & f.workRoot / "store.sock" &
      "\nimage = " & f.daemonPath & "\n")
    putEnv("XDG_CONFIG_HOME", configHome)
    delEnv("REPRO_DAEMONS_CONFIG")
    defer:
      putEnv("XDG_CONFIG_HOME", previousXdg)
      reset()
    let loaded = loadDeclaredDaemons()
    checkpoint("loaded=" & $loaded.len)
    check loaded.anyIt(it.kind == ddkNixDaemon)
    check loaded.anyIt(it.kind == ddkReproStoreDaemon)
    for decl in loaded:
      case decl.kind
      of ddkNixDaemon:
        check decl.source == userFile
        check decl.endpoint == "/nix/var/nix/daemon-socket/socket"
        check decl.assertions == {daUid}
        check decl.uid == 0
      of ddkReproStoreDaemon:
        check decl.source == userFile
        check decl.endpoint == f.workRoot / "store.sock"
        check decl.assertions == {daImage}
        check decl.image == f.daemonPath
      of ddkRunQuota:
        # This host may carry a real `/etc/repro/daemons.conf`; if it declares
        # runquotad, the user file above does not name it and the SYSTEM entry
        # survives, which is the extend half of the precedence rule. Nothing
        # here may assume the host declares nothing.
        check decl.source.len > 0
        check decl.source != userFile
    # A second load with the user file naming a daemon the system file also
    # names replaces it rather than adding a duplicate.
    writeFile(userFile,
      "[nix-daemon]\nsocket = " & f.workRoot / "user-nix.sock" & "\nuid = 1\n")
    let reloaded = loadDeclaredDaemons()
    check reloaded.countIt(it.kind == ddkNixDaemon) == 1
    for decl in reloaded:
      if decl.kind == ddkNixDaemon:
        check decl.endpoint == f.workRoot / "user-nix.sock"
        check decl.uid == 1

  test "a refused check is refused by the registration, not only by its caller":
    ## THE FLOOR UNDER THE CALLER'S GATE, graded on the one shape that can tell
    ## the two apart.
    ##
    ## `trustDaemonWeChecked` refuses on four clauses — `outcome`, `pid`,
    ## `identity`, `verified` — and MEASURED, deleting three of them and
    ## keeping only `pid <= 0` left all 13 cases of this file green. The reason
    ## is that every check the suite could reach that call with was either a
    ## pass or had `pid == 0`, and `applyDeclaredDaemonTrust` gates on
    ## `outcome == dcoTrusted` before calling at all. A guard whose only
    ## graded clause is the one the production caller makes redundant is a
    ## guard nothing measures.
    ##
    ## The shape that separates them: a CORRECT `image` with a WRONG `program`.
    ## `checkDeclaredDaemon` verifies the image first, so it returns with
    ## `pid > 0`, a non-empty `identity` and `verified == {daImage}` — three of
    ## the four clauses satisfied — and only `outcome` refuses it. The check is
    ## the REAL one against a REAL live daemon; nothing here constructs a
    ## result, which is precisely why the fields are private.
    if ccPath().len == 0:
      skip()
    else:
      reset()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDetachedDaemon("unix", "floor")
      defer: stopDaemon(daemon)

      let refused = checkDeclaredDaemon(DeclaredDaemon(
        kind: ddkRunQuota,
        endpoint: daemon.address,
        assertions: {daImage, daProgram},
        image: daemon.imagePath,
        program: "runquotad",
        uid: -1,
        source: "<case>"))
      checkpoint("refused: outcome=" & $checkedDaemonOutcome(refused) &
        " pid=" & $checkedDaemonPid(refused) &
        " verified=" & $checkedDaemonAssertions(refused) &
        " detail=" & checkedDaemonDetail(refused))
      # Every clause BUT `outcome` is satisfied, so `outcome` is the only thing
      # that can refuse this — which is what makes the mutation gradeable.
      check checkedDaemonOutcome(refused) == dcoProgramMismatch
      check checkedDaemonPid(refused) == daemon.pid
      check checkedDaemonIdentity(refused).len > 0
      check checkedDaemonAssertions(refused) == {daImage}
      check not trustDaemonWeChecked(ddkRunQuota, refused)
      check declaredTrustedDaemonRegistry().len == 0
      check declaredPids().len == 0

      # THE ZERO VALUE, refused three times over rather than once. It is the
      # only value an outside caller can build, and since `dcoNotChecked` is
      # the enum's first member it no longer claims a pass.
      let unchecked = DaemonIdentityCheck()
      check checkedDaemonOutcome(unchecked) == dcoNotChecked
      check checkedDaemonPid(unchecked) == 0
      check checkedDaemonAssertions(unchecked) == {}
      check not trustDaemonWeChecked(ddkRunQuota, unchecked)
      check declaredTrustedDaemonRegistry().len == 0
      # And a default `DaemonCheckReport` says "not checked" rather than
      # announcing the strongest thing this type can say. It rendered as
      # "checked and trusted" while `dcoTrusted` was the zero value.
      let blank = DaemonCheckReport()
      check blank.outcome == dcoNotChecked
      checkpoint("blank report=" & renderDaemonCheckReport(blank))
      check renderDaemonCheckReport(blank).contains("NOT trusted")
      check not renderDaemonCheckReport(blank).contains("checked and trusted")

      # The positive control, through the same entry point: the identical
      # declaration with the program corrected IS registered here. So the
      # refusals above are the guard and not a call that never registers.
      let passing = checkDeclaredDaemon(DeclaredDaemon(
        kind: ddkRunQuota,
        endpoint: daemon.address,
        assertions: {daImage},
        image: daemon.imagePath,
        uid: -1,
        source: "<case>"))
      check checkedDaemonOutcome(passing) == dcoTrusted
      check trustDaemonWeChecked(ddkRunQuota, passing)
      check declaredPids() == @[daemon.pid]

  test "one peer pid serving two endpoints: the activator is refused, and the residual is stated":
    ## THE CASE THAT WOULD HAVE CAUGHT THE BLOCKER, and the case that pins what
    ## shipping it still costs. One process, TWO unix sockets, so
    ## `SO_PEERCRED` answers the same pid on both — the topology of a socket
    ## activator, which on a provisioned host is what actually answers
    ## `/nix/var/nix/daemon-socket/socket` and `/run/dbus/system_bus_socket`
    ## alike.
    ##
    ## ARM 1 — THE BLOCKER. The declaration is the one the documentation used
    ## to prescribe for a privileged daemon: an endpoint and a `uid`, nothing
    ## that identifies a program. It passed, it registered the shared pid, and
    ## an edge talking to the OTHER, UNDECLARED endpoint was forgiven and
    ## published. It is now refused before the connect, and the undeclared
    ## endpoint's edge downgrades — measured end to end, not at the enum.
    ##
    ## ARM 2 — THE RESIDUAL, MEASURED RATHER THAN IMPLIED. With the program
    ## identified the declaration passes, and the undeclared endpoint of THE
    ## SAME PROGRAM is still forgiven, because io-mon keys the exemption on the
    ## peer pid and looks at no path (`src/io_mon/writer.nim:1992-1994`). That
    ## is sound only because the §Class 3 branch is a property of the PROGRAM
    ## and is therefore true of every channel that program serves — see the
    ## residual note in `repro_build_engine`'s DA-4 header, which also records
    ## why keying on `(pid, endpoint)` needs an io-mon change first.
    ##
    ## THIS ARM ASSERTS TODAY'S SEMANTICS ON PURPOSE. If a later change narrows
    ## the exemption to the declared endpoint, this arm goes red — which is the
    ## intended way to find out, rather than discovering that the meaning of a
    ## trust fact changed silently.
    if ccPath().len == 0:
      skip()
    else:
      reset()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDetachedDaemon("unix", "mux1",
        secondSocketName = "mux2")
      defer: stopDaemon(daemon)
      check daemon.secondAddress.len > 0
      check daemon.secondAddress != daemon.address
      let config = monitoredConfig(repoRoot, f.cacheRoot)

      # Both endpoints really are one process — asserted, because the whole
      # case is vacuous if the fixture forked.
      let declared = DeclaredDaemon(kind: ddkRunQuota,
        endpoint: daemon.address, assertions: {daImage},
        image: daemon.imagePath, uid: -1, source: "<case>")
      let onSecond = DeclaredDaemon(kind: ddkRunQuota,
        endpoint: daemon.secondAddress, assertions: {daImage},
        image: daemon.imagePath, uid: -1, source: "<case>")
      let checkA = checkDeclaredDaemon(declared)
      let checkB = checkDeclaredDaemon(onSecond)
      checkpoint("peer on A=" & $checkedDaemonPid(checkA) &
        " peer on B=" & $checkedDaemonPid(checkB))
      check checkedDaemonPid(checkA) == daemon.pid
      check checkedDaemonPid(checkB) == daemon.pid
      reset()

      # ---- ARM 1: the uid-only declaration the blocker used -----------------
      f.declare(runquotadSection(daemon.address, "uid = " & $int(geteuid())))
      let blocked = applyDeclarationsNow()
      check blocked.outcomeFor(ddkRunQuota) == dcoNoProgramAssertion
      check declaredPids().len == 0

      let undeclaredEdge = f.clientEdge("decltrust/mux-undeclared-refused",
        "unix", daemon.secondAddress, "muxrefused")
      let cold = runBuild(graph([undeclaredEdge]), config)
      let m0 = cold.byId(undeclaredEdge.id)
      checkpoint("arm1 cold: status=" & $m0.status &
        " diagnostics=" & $m0.evidence.diagnostics)
      check m0.status == asSucceeded
      check m0.launched
      check attributionDiagnostics(m0).len == 0
      check not f.publishedRecordExists(undeclaredEdge)
      let coldWarm = runBuild(graph([undeclaredEdge]), config)
      check coldWarm.byId(undeclaredEdge.id).cacheDecision notin ReuseDecisions
      check f.runCount("muxrefused") == 2

      # ---- ARM 2: the program identified, and the residual it leaves --------
      reset()
      f.declare(runquotadSection(daemon.address,
        "image = " & daemon.imagePath & "\nuid = " & $int(geteuid())))
      check applyDeclarationsNow().outcomeFor(ddkRunQuota) == dcoTrusted
      check declaredPids() == @[daemon.pid]
      check declaredTrustedDaemonRegistry()[0].declaredSocket == daemon.address

      let residualEdge = f.clientEdge("decltrust/mux-undeclared-forgiven",
        "unix", daemon.secondAddress, "muxresidual")
      let warmed = runBuild(graph([residualEdge]), config)
      let m1 = warmed.byId(residualEdge.id)
      checkpoint("arm2 cold: status=" & $m1.status &
        " diagnostics=" & $m1.evidence.diagnostics)
      check m1.status == asSucceeded
      check m1.launched
      # THE RESIDUAL, in one assertion: the endpoint the action used is NOT the
      # endpoint the declaration named, and the exemption is granted anyway
      # because the PEER is the declared program.
      let residualDiagnostics = attributionDiagnostics(m1)
      check residualDiagnostics.len >= 1
      if residualDiagnostics.len >= 1:
        checkpoint("residual diagnostic=" & residualDiagnostics[0])
        check ("declared at " & daemon.address) in residualDiagnostics[0]
        check ("peer=" & $daemon.pid) in residualDiagnostics[0]
        check daemon.secondAddress notin residualDiagnostics[0]
      check f.publishedRecordExists(residualEdge)
      let residualWarm = runBuild(graph([residualEdge]), config)
      check residualWarm.byId(residualEdge.id).cacheDecision in ReuseDecisions
      check not residualWarm.byId(residualEdge.id).launched
      check f.runCount("muxresidual") == 1

      # And the guarantee is still intact next to it: a DIFFERENT process on a
      # third endpoint is not forgiven by the registration above, so arm 2 is a
      # residual scoped to the declared peer and not a blanket exemption.
      var stranger = f.startDetachedDaemon("unix", "muxstranger")
      defer: stopDaemon(stranger)
      check stranger.pid != daemon.pid
      let strangerEdge = f.clientEdge("decltrust/mux-stranger", "unix",
        stranger.address, "muxstranger")
      let strangerRun = runBuild(graph([strangerEdge]), config)
      let m2 = strangerRun.byId(strangerEdge.id)
      checkpoint("stranger: status=" & $m2.status &
        " diagnostics=" & $m2.evidence.diagnostics)
      check m2.status == asSucceeded
      check attributionDiagnostics(m2).len == 0
      check not f.publishedRecordExists(strangerEdge)

  test "the graded .iomon still carries the connect and the loss the exemption forgave":
    ## ATTRIBUTION, NOT SUPPRESSION — CHECKED AGAINST THE BYTES.
    ## `Dependency-Observation-Attribution.md` §"Attribution, not suppression"
    ## says a class-3 exemption must EXPLAIN an observation, never remove it,
    ## and rule 3 says every elision is counted. Asserting that the loss text
    ## survives into the DIAGNOSTIC is weaker than that: it shows the engine
    ## quoted the loss, not that the capture it graded still holds the
    ## evidence. So this case reads the graded `.iomon` back off disk AFTER the
    ## verdict and finds the `mrIpcConnect` and io-mon's own loss text both
    ## still there while the edge publishes.
    ##
    ## It also reaches the SECOND fold site — the recognized-`.iomon`-report
    ## arm — which every other case in this file misses. Both sites share one
    ## `MonitorPeerAttribution`, so the risk is wiring rather than divergent
    ## logic, and wiring is what an edit drops. The negative on the same arm is
    ## what keeps "the arm is wired" from being indistinguishable from "the arm
    ## forgives everything".
    if ccPath().len == 0:
      skip()
    else:
      reset()
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      var daemon = f.startDetachedDaemon("unix", "reported")
      defer: stopDaemon(daemon)
      f.declare(runquotadSection(daemon.address,
        "image = " & daemon.imagePath & "\nuid = " & $int(geteuid())))
      check applyDeclarationsNow().outcomeFor(ddkRunQuota) == dcoTrusted
      check derivedTrustedDaemonRegistry().len == 0
      check declaredPids() == @[daemon.pid]

      let capturePath = f.workRoot / "rep.iomon"
      let edge = f.reportEdge(repoRoot, "decltrust/report", daemon.address,
        "report", capturePath)
      let config = monitoredConfig(repoRoot, f.cacheRoot)
      let res = runBuild(graph([edge]), config)
      let r0 = res.byId(edge.id)
      checkpoint("report: status=" & $r0.status & " reason=" & r0.reason &
        " stderr=" & r0.stderr &
        " diagnostics=" & $r0.evidence.diagnostics)
      check r0.status == asSucceeded
      check f.runCount("report") == 1
      check fileExists(capturePath)
      check attributionDiagnostics(r0).len >= 1
      check f.publishedRecordExists(edge)

      # The capture the engine GRADED, read back off disk after the verdict.
      var sawConnect = false
      var sawLoss = false
      if fileExists(capturePath):
        for record in streamMonitorDepFileRecords(capturePath,
            defaultMonitorDepFileReaderOptions()):
          if record.kind == mrIpcConnect and
              record.childOsPid == uint64(daemon.pid):
            sawConnect = true
          if record.kind == mrEventLoss and
              "ipc peer outside monitored tree" in record.detail and
              ("peer=" & $daemon.pid) in record.detail:
            sawLoss = true
      check sawConnect
      check sawLoss

      # THE NEGATIVE, on the SAME arm: a second daemon, same binary, same
      # protocol, alive at the same moment, named by no declaration.
      var stranger = f.startDetachedDaemon("unix", "repstranger")
      defer: stopDaemon(stranger)
      check declaredPids() == @[daemon.pid]
      let strangerCapture = f.workRoot / "str.iomon"
      let strangerEdge = f.reportEdge(repoRoot, "decltrust/report-undeclared",
        stranger.address, "repstranger", strangerCapture)
      let res2 = runBuild(graph([strangerEdge]), config)
      let r2 = res2.byId(strangerEdge.id)
      checkpoint("stranger: status=" & $r2.status & " reason=" & r2.reason &
        " diagnostics=" & $r2.evidence.diagnostics)
      check r2.status == asSucceeded
      check f.runCount("repstranger") == 1
      check attributionDiagnostics(r2).len == 0
      check not f.publishedRecordExists(strangerEdge)
