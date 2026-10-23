## Execution leases — Distributed-Execution M7 (deployment-security-architecture.md
## CONF-5, CONF-1, FLOW-3, DET-1, DET-2).
##
## A remote goal runs in an EXECUTION LEASE: a fresh directory under the
## worker's lease root (`<leaseRoot>/<leaseId>/{wt,tmp,home}`) and a process
## confined to it — never in the daemon's own process, user or home. The
## worktree-pool leases M1 adds are the enumerated writable set; nothing
## else is writable.
##
## THREE LAYERS, each switchable on its own so a test can remove exactly one
## and observe the one breach it stops (`LeaseLayer`). Production runs every
## layer the host supports (`availableLeaseLayers`): all three in the
## hardened profile (or no worker role); in the trusted profile on Linux the
## namespace layer always, Landlock and the floor when the host has them.
## The daemon and the CLI expose no knob:
##
## | layer       | Linux (`c/repro_lease_linux.c`)                     | macOS (Seatbelt)                                  | without it        |
## |-------------|-----------------------------------------------------|---------------------------------------------------|-------------------|
## | namespace   | user+mount+net+pid+ipc+uts namespaces; a NEW ROOT   | `file-read*`/`file-write*` denied beneath the     | reads a neighbour |
## |             | with only the read roots, the closure and this      | lease root and daemon state, own lease re-allowed |                   |
## |             | lease; every writable mount noexec; private /tmp    |                                                   |                   |
## | landlock    | writes only beneath the lease; reads only beneath   | `file-write*` denied except the lease; file       | writes outside    |
## |             | the read roots and the lease root; exec only        | content read only beneath the read roots and the  |                   |
## |             | beneath the closure and declared output dirs        | lease root; `process-exec*` only from the closure |                   |
## | floor       | a subordinate uid PER LEASE SLOT (newuidmap) +      | `network-outbound` to unix sockets denied;        | reaches the daemon|
## |             | derived seccomp allow-list, only AF_INET/AF_INET6/  | signals and process-info on others denied         |                   |
## |             | AF_UNIX sockets; a connect/send to a unix socket    |                                                   |                   |
## |             | that EXISTS in the lease's view refused + reported  |                                                   |                   |
## |             | (a pathname socket is not scoped by the network     |                                                   |                   |
## |             | namespace); one that reaches nothing fails with the |                                                   |                   |
## |             | kernel's error, unreported (G38)                    |                                                   |                   |
##
## Windows (trusted profile only): the action runs in a Job Object
## (kill-on-close, the whole process tree), with only its own stdio handles
## inherited, AS THE DAEMON'S OWN USER (no separate build user or restricted
## token yet — an M2 deliverable). That is lifecycle, not a boundary (the
## research behind the trust profiles: job objects give lifecycle and limits
## only): the filesystem and the network are unconfined and `hidePaths` is
## not enforced, so a goal can read the worker's host key. The isolation
## level `windows-job` recorded in every execution record says so. The hardened profile refuses macOS and Windows workers until a
## VM-grade boundary exists for them (M8 deliverable).
##
## ISOLATION LEVEL: every outcome names what confined it
## (`linux-namespace`, `macos-seatbelt`, `windows-job`; a test that removed
## a layer gets `linux-partial[...]`), and the receiver records it in the
## goal's execution record.
##
## EGRESS (FLOW-3) is not a layer: it is always on. Deny-by-default; each
## allow-listed destination is reachable only through a forwarder the
## supervisor runs outside the lease, so the allow-list lives below the
## daemon and no recipe can widen it. On Linux the lease has its own network
## namespace with loopback only (no route anywhere) and the supervisor also
## refuses and reports any connect/send naming another destination. On macOS
## Seatbelt allows only the forwarders' loopback ports and the kernel reports
## every denial to the unified log, tagged with the lease id, which the
## supervisor collects (`log stream`).
##
## DETECTION (DET-1, DET-2): every denied egress attempt, every exec outside
## the closure, every syscall the floor refuses, every file access the
## filesystem layer refuses, and every connect/send to a unix socket that
## exists in the lease's view comes back as a `LeaseReport` — handed to
## `onReport` AS IT HAPPENS and collected in `LeaseOutcome.reports`. (Code
## loaded from a written file WITHOUT an execve of its own is not detected:
## the noexec writable mounts stop it — executable mappings are not
## intercepted.) The receiver records each report in the goal's execution
## record and the local detection log in both profiles, and in the HARDENED
## profile also forwards it to the evidence sink at once (threat model
## G21); a trusted worker has no sink.
##
## THE CLOSURE (DET-1, the CONF-2 compensating control; threat model G25)
## is computed, not assumed: `computeLeaseClosure` takes the Nix store
## closure (`nix-store -qR`) of the system profile (NixOS), of every store
## path on the daemon's `PATH`, and of the daemon's own executable — plus
## the base system's executable directories on a host that is not NixOS —
## instead of all of `/nix/store`.
##
## RESOURCES (threat model G31): the daemon never reads more of a lease's
## stdout, stderr or report than it keeps (`MaxCapturedOutput`, read from
## the END of the file), and on Linux a lease runs under process and
## file-size limits, and in a cgroup of its own with memory and process
## limits when the worker's cgroup is delegated (`leaseCgroupFor`).
##
## macOS has no namespace or Landlock equivalent stronger than Seatbelt and
## no unprivileged way to run the lease as another user; that is a recorded
## deviation in `Distributed-Execution-Threat-Model.md` (exit condition: a
## VM-grade boundary through Virtualization.framework, or a dedicated lease
## user provisioned by M6).

import std/[algorithm, asyncdispatch, asyncnet, json, nativesockets, net, os,
            osproc, streams, strtabs, strutils, times]
when defined(posix):
  import std/posix

import repro_core/ambient_execution

# Every process this module starts is a fixed SYSTEM binary named by
# absolute path (`/bin/sh`, `/usr/bin/sandbox-exec`, `/usr/bin/log`) or the
# setuid id-mapping helpers (`newuidmap` / `newgidmap`, resolved on PATH
# because distributions install them in different places). None is chosen
# by a caller or a recipe; the action itself runs only through them, under
# confinement. Hence the explicit `uncontrolled*` wrappers.

type
  LeaseLayer* = enum
    llNamespace = "namespace"
    llLandlock = "landlock"
    llFloor = "floor"

  EgressDestination* = object
    name*: string
      ## Exposed to the action as `REPRO_LEASE_EGRESS_<NAME>=host:port`.
    host*: string
      ## The real destination (an IPv4 literal; DNS is not available inside
      ## a lease — FLOW-3 "including DNS").
    port*: int

  LeaseSpec* = object
    leaseId*: string
    leaseRoot*: string
      ## Parent of every lease on this worker.
    leaseDir*: string
      ## This lease: `<leaseRoot>/<leaseId>`.
    metaDir*: string
      ## Supervisor output (status, reports, stdout, stderr); OUTSIDE the
      ## lease root, so the lease never sees or edits it.
    cwd*: string
    argv*: seq[string]
      ## `argv[0]` must be absolute (no PATH search inside a lease).
    env*: seq[(string, string)]
      ## The complete environment (nothing is inherited from the daemon).
    readRoots*: seq[string]
      ## Toolchain / system roots the action may read.
    closureRoots*: seq[string]
      ## Where executables may come from (DET-1's known closure).
    outputDirs*: seq[string]
      ## Declared output directories inside the worktree: writable (as part
      ## of the lease) and executable (a test runs what the build produced).
    extraWritable*: seq[string]
      ## Writable roots OTHER than the lease (Linux: bound read-write and
      ## noexec in the new root; Landlock write rules). Used only by tests
      ## of the floor layer; a production goal's only writable tree is its
      ## lease.
    hidePaths*: seq[string]
      ## The daemon's state directory and anything else no lease may see.
    egress*: seq[EgressDestination]
    layers*: set[LeaseLayer]
    timeoutMs*: int
    cgroupPath*: string
      ## Linux: a cgroup directory (already created, limits written) the
      ## whole lease is placed in; empty = none.
    nprocLimit*: int
      ## Linux floor: RLIMIT_NPROC of the lease user (0 = the default).
    fsizeLimit*: int64
      ## Linux floor: RLIMIT_FSIZE (0 = the default).
    slot*: int
      ## Linux floor: the lease slot (0-based). Each concurrent lease runs
      ## as its own subordinate uid/gid — the first of the user's range plus
      ## the slot — so two leases never share a uid.
    inputsDir*: string
      ## The materialized input artifacts — the content-addressed outputs of
      ## the goal node's declared input nodes — inside the lease (never in
      ## the worktree); "" = none. The action reads and EXECUTES them but
      ## cannot change them: Linux binds the directory read-only without
      ## noexec over the noexec lease; macOS denies writes beneath it. Its
      ## path is exposed to the action as `REPRO_LEASE_INPUTS`.
    memfdNoexec*: bool
      ## HARDENED: the `vm.memfd_noexec = 2` policy (a memfd_create without
      ## MFD_NOEXEC_SEAL is refused and reported), enforced by the lease's
      ## seccomp filter on a kernel that supports it (Linux 6.3+).

  LeaseReport* = object
    kind*: string
      ## `egress-denied`, `exec-outside-closure`, `fs-denied`,
      ## `syscall-denied`, `reports-suppressed` (a flood summarized).
    detail*: string
    syscall*: string
    pid*: int
    count*: int
      ## For `reports-suppressed`: how many were folded.

  ReportSink* = proc(report: LeaseReport) {.gcsafe, closure.}

  LeaseOutcome* = object
    started*: bool
    exitCode*: int
    signal*: int
    timedOut*: bool
    error*: string
      ## Set when the lease could not be set up (then nothing ran).
    stdout*: string
    stderr*: string
    reports*: seq[LeaseReport]
    egressEnv*: seq[(string, string)]
    isolation*: string
      ## What confined the action: `linux-namespace`, `macos-seatbelt`,
      ## `windows-job` (or `linux-partial[...]` when a test removed a layer).

const
  DefaultLeaseLayers* = {llNamespace, llLandlock, llFloor}
  MaxCapturedOutput* = 1024 * 1024
    ## The most of a lease's stdout or stderr the daemon ever reads (the
    ## END of it — the useful part of a failing build).
  MaxLeaseReports* = 10_000
    ## Report lines kept per lease; the supervisor already folds floods.
  DefaultLeaseNprocLimit* = 4_096
  DefaultLeaseFsizeLimit* = 16'i64 * 1024 * 1024 * 1024

when defined(linux):
  {.compile: "../../c/repro_lease_linux.c".}
  proc c_repro_lease_memfd_noexec_supported(): cint {.importc:
    "repro_lease_memfd_noexec_supported".}

proc memfdNoexecSupported*(): bool =
  ## Whether the hardened memfd policy can be enforced here (Linux 6.3+).
  when defined(linux):
    c_repro_lease_memfd_noexec_supported() != 0
  else:
    false

proc isolationLevelOf*(spec: LeaseSpec): string =
  ## The isolation level a lease under `spec` runs at on this platform —
  ## exactly the layers that confined it. Linux: `linux-namespace` (the new
  ## root, noexec writable mounts, the namespaces) plus `+landlock` and
  ## `+floor` when those layers ran, plus `+memfd-noexec` when the hardened
  ## memfd policy was enforced — e.g. `linux-namespace+landlock+floor` vs
  ## `linux-namespace` on a trusted worker without Landlock or a
  ## subordinate uid range. A lease without the namespace layer (only a
  ## test removes it) is `linux-partial[...]`.
  when defined(linux):
    if llNamespace notin spec.layers:
      var names: seq[string] = @[]
      for l in spec.layers: names.add($l)
      return "linux-partial[" & names.join(",") & "]"
    result = "linux-namespace"
    if llLandlock in spec.layers: result.add("+landlock")
    if llFloor in spec.layers: result.add("+floor")
    if spec.memfdNoexec and memfdNoexecSupported(): result.add("+memfd-noexec")
  elif defined(macosx): "macos-seatbelt"
  elif defined(windows): "windows-job"
  else: "none"

type
  IsolationLevel* = object
    ## A parsed isolation level: its base (`linux-namespace`,
    ## `macos-seatbelt`, `windows-job`) and the SET of layers added to it
    ## (`landlock`, `floor`, `memfd-noexec`) — duplicates collapse.
    base*: string
    layers*: seq[string]
      ## Sorted, unique.
    known*: bool
      ## False for an unknown base, a `linux-partial[...]` lease, or an
      ## empty string.

const
  LinuxIsolationLayers* = ["landlock", "floor", "memfd-noexec"]
    ## The layers a `linux-namespace` level may name.

proc baseRank(base: string): int =
  ## How much a base confines on its own: `windows-job` (lifecycle only —
  ## no filesystem or network confinement) < `macos-seatbelt` <
  ## `linux-namespace` (a new root of only the closure and the lease).
  case base
  of "linux-namespace": 3
  of "macos-seatbelt": 2
  of "windows-job": 1
  else: 0

proc parseIsolationLevel*(level: string): IsolationLevel =
  let parts = level.split('+')
  result.base = parts[0]
  result.known = baseRank(result.base) > 0
  for part in parts[1 .. ^1]:
    if result.base != "linux-namespace" or part notin LinuxIsolationLayers:
      result.known = false
    if part notin result.layers:
      result.layers.add(part)
  result.layers.sort()

proc isolationSatisfies*(achieved, required: string): bool =
  ## Whether a result confined at `achieved` meets a requester's minimum
  ## `required` (`RequesterGoalContext.minIsolation`; empty = any). A SET
  ## comparison, not a count: the achieved base must confine at least as
  ## much as the required one (`windows-job` < `macos-seatbelt` <
  ## `linux-namespace`), and every layer the requirement names must have
  ## RUN — so `linux-namespace+floor+memfd-noexec` does not satisfy
  ## `linux-namespace+landlock` however many layers it has. An unknown or
  ## partial level satisfies nothing, and an unknown requirement is
  ## satisfied by nothing (fail closed).
  if required.len == 0:
    return true
  let a = parseIsolationLevel(achieved)
  let r = parseIsolationLevel(required)
  if not a.known or not r.known:
    return false
  if baseRank(a.base) < baseRank(r.base):
    return false
  for layer in r.layers:
    if layer notin a.layers:
      return false
  true

proc egressVarName*(name: string): string =
  result = "REPRO_LEASE_EGRESS_"
  for ch in name:
    result.add(if ch.isAlphaNumeric: ch.toUpperAscii else: '_')

proc readCapped*(path: string; cap = MaxCapturedOutput): string =
  ## At most the last `cap` bytes of `path`, never more in memory: a lease
  ## that writes gigabytes to stdout costs the daemon `cap` bytes (threat
  ## model G31; the whole file used to be read before it was capped).
  var f: File
  if not open(f, path, fmRead):
    return ""
  defer: f.close()
  let size = f.getFileSize()
  if size <= 0:
    return ""
  let take = int(min(size, int64(cap)))
  f.setFilePos(size - take)
  result = newString(take)
  let got = f.readBuffer(addr result[0], take)
  result.setLen(got)

proc parseReportLine*(line: string): tuple[ok: bool; report: LeaseReport] =
  if line.strip.len == 0:
    return
  try:
    let j = parseJson(line)
    var r = LeaseReport(kind: j{"kind"}.getStr, syscall: j{"syscall"}.getStr,
      pid: j{"pid"}.getInt, count: j{"count"}.getInt)
    for key in ["destination", "exe", "path", "detail"]:
      if j.hasKey(key): r.detail = j[key].getStr
    return (true, r)
  except CatchableError:
    return

type
  ReportTail = object
    ## Reads a supervisor's report file incrementally while the lease runs.
    path: string
    offset: int64
    partial: string

proc drainReports(t: var ReportTail; outcome: var LeaseOutcome;
                  onReport: ReportSink) =
  ## New complete lines since the last call, each parsed, kept and handed
  ## to `onReport` at once (threat model G21). Bounded per call.
  var f: File
  if not open(f, t.path, fmRead):
    return
  defer: f.close()
  let size = f.getFileSize()
  if size <= t.offset:
    return
  let take = int(min(size - t.offset, int64(4 * 1024 * 1024)))
  f.setFilePos(t.offset)
  var chunk = newString(take)
  let got = f.readBuffer(addr chunk[0], take)
  chunk.setLen(got)
  t.offset += int64(got)
  var text = t.partial & chunk
  let last = text.rfind('\n')
  if last < 0:
    t.partial = text
    return
  t.partial = text[last + 1 .. ^1]
  for line in text[0 ..< last].splitLines:
    let parsed = parseReportLine(line)
    if not parsed.ok:
      continue
    if outcome.reports.len < MaxLeaseReports:
      outcome.reports.add(parsed.report)
    if not onReport.isNil:
      try: onReport(parsed.report) except CatchableError: discard

proc prepareLeaseDirs*(spec: LeaseSpec) =
  for d in [spec.leaseDir, spec.leaseDir / "tmp", spec.leaseDir / "home",
            spec.metaDir]:
    createDir(d)
  for d in spec.outputDirs:
    createDir(d)

# ---------------------------------------------------------------------------
# Linux backend.
# ---------------------------------------------------------------------------

when defined(linux):
  proc c_repro_lease_spawn(buf: cstring; len: cint): cint {.importc:
    "repro_lease_spawn".}
  proc c_repro_lease_supported(): cint {.importc: "repro_lease_supported".}
  proc c_repro_lease_pidfd_supported(): cint {.importc:
    "repro_lease_pidfd_supported".}
  proc c_repro_lease_userns_supported(): cint {.importc:
    "repro_lease_userns_supported".}

  proc subordinateIds*(): tuple[ok: bool; uid, gid, count: int] =
    ## The first subordinate uid/gid range of the current user
    ## (/etc/subuid, /etc/subgid): lease slot `k` runs as `uid + k`,
    ## `gid + k`; `count` bounds the slots.
    let user = getEnv("USER", getEnv("LOGNAME"))
    let uidStr = $getuid()
    proc firstOf(path: string): tuple[start, count: int] =
      result = (-1, 0)
      if not fileExists(path): return
      for line in readFile(path).splitLines:
        let f = line.split(':')
        if f.len == 3 and (f[0] == user or f[0] == uidStr):
          try: return (parseInt(f[1]), parseInt(f[2])) except ValueError: discard
    let u = firstOf("/etc/subuid")
    let g = firstOf("/etc/subgid")
    (u.start > 0 and g.start > 0, u.start, g.start, min(u.count, g.count))

  proc landlockAbi*(): int = int(c_repro_lease_supported())

  proc kv(buf: var string; k, v: string) =
    buf.add(k); buf.add('\0'); buf.add(v); buf.add('\0')

  proc spawnLinux(spec: LeaseSpec; cleanup: bool;
                  outcome: var LeaseOutcome): int =
    let ids = subordinateIds()
    var buf = ""
    buf.kv("mode", if cleanup: "cleanup" else: "run")
    buf.kv("lease_id", spec.leaseId)
    buf.kv("lease_root", spec.leaseRoot)
    buf.kv("lease_dir", spec.leaseDir)
    buf.kv("cwd", spec.cwd)
    let tag = if cleanup: "cleanup-" else: ""
    buf.kv("status", spec.metaDir / (tag & "status"))
    buf.kv("stage", spec.metaDir / (tag & "root"))
    buf.kv("report", spec.metaDir / (tag & "report.jsonl"))
    buf.kv("stdout", spec.metaDir / "stdout")
    buf.kv("stderr", spec.metaDir / "stderr")
    for a in spec.argv: buf.kv("arg", a)
    var env = spec.env
    for i, d in spec.egress:
      let inner = "127.0.0." & $(10 + i) & ":" & $d.port
      env.add((egressVarName(d.name), inner))
      outcome.egressEnv.add((egressVarName(d.name), inner))
      buf.kv("dest", d.name & "|" & d.host & "|" & $d.port & "|127.0.0." &
        $(10 + i) & "|" & $d.port)
    if spec.inputsDir.len > 0:
      env.add(("REPRO_LEASE_INPUTS", spec.inputsDir))
    for (k, v) in env: buf.kv("env", k & "=" & v)
    for r in spec.readRoots: buf.kv("read", r)
    for r in spec.closureRoots:
      buf.kv("exec", r)
      buf.kv("closure", r)
    for r in spec.outputDirs:
      buf.kv("exec", r)
      buf.kv("closure", r)
    if spec.inputsDir.len > 0 and not cleanup:
      buf.kv("exec", spec.inputsDir)
      buf.kv("closure", spec.inputsDir)
      buf.kv("input", spec.inputsDir)
    if spec.memfdNoexec and memfdNoexecSupported():
      buf.kv("memfd_noexec", "1")
    buf.kv("write", spec.leaseDir)
    for r in spec.extraWritable: buf.kv("write", r)
    for h in spec.hidePaths: buf.kv("hide", h)
    buf.kv("layer_ns", if llNamespace in spec.layers: "1" else: "0")
    buf.kv("layer_landlock", if llLandlock in spec.layers: "1" else: "0")
    let floor = llFloor in spec.layers
    buf.kv("layer_floor", if floor: "1" else: "0")
    buf.kv("uid", $getuid())
    buf.kv("gid", $getgid())
    if floor:
      if not ids.ok:
        outcome.error = "the floor needs a subordinate uid/gid range " &
          "(/etc/subuid, /etc/subgid) for the lease user"
        return -1
      if spec.slot < 0 or spec.slot >= ids.count:
        outcome.error = "lease slot " & $spec.slot & " is outside the " &
          "subordinate id range (" & $ids.count & " ids)"
        return -1
      buf.kv("subuid", $(ids.uid + spec.slot))
      buf.kv("subgid", $(ids.gid + spec.slot))
    let nu = uncontrolledFindExe("newuidmap")
    let ng = uncontrolledFindExe("newgidmap")
    if nu.len > 0: buf.kv("newuidmap", nu)
    if ng.len > 0: buf.kv("newgidmap", ng)
    buf.kv("timeout_ms", $spec.timeoutMs)
    buf.kv("nproc_limit", $(if spec.nprocLimit > 0: spec.nprocLimit
                            else: DefaultLeaseNprocLimit))
    buf.kv("fsize_limit", $(if spec.fsizeLimit > 0: spec.fsizeLimit
                            else: DefaultLeaseFsizeLimit))
    if spec.cgroupPath.len > 0 and not cleanup:
      buf.kv("cgroup", spec.cgroupPath)
    let pid = c_repro_lease_spawn(buf.cstring, cint(buf.len))
    if pid < 0:
      outcome.error = "lease launcher refused its configuration (errno " &
        $(-pid) & ")"
      return -1
    int(pid)


  proc readStatus(path: string; outcome: var LeaseOutcome) =
    if not fileExists(path):
      outcome.error = "the lease supervisor wrote no status"
      return
    for line in readFile(path).splitLines:
      let eq = line.find('=')
      if eq < 0: continue
      let (k, v) = (line[0 ..< eq], line[eq + 1 .. ^1])
      case k
      of "exit": outcome.exitCode = parseInt(v)
      of "signal": outcome.signal = parseInt(v)
      of "timedout": outcome.timedOut = v == "1"
      of "error": outcome.error = v
      else: discard

  proc runLeaseLinux(spec: LeaseSpec;
                     onReport: ReportSink): Future[LeaseOutcome] {.async.} =
    var outcome = LeaseOutcome()
    prepareLeaseDirs(spec)
    let pid = spawnLinux(spec, cleanup = false, outcome)
    if pid < 0:
      return outcome
    var tail = ReportTail(path: spec.metaDir / "report.jsonl")
    # Wait for the supervisor, forwarding its reports as they appear.
    var status: cint = 0
    while true:
      let r = waitpid(Pid(pid), status, WNOHANG)
      drainReports(tail, outcome, onReport)
      if r == Pid(pid) or r < 0: break
      await sleepAsync(20)
    drainReports(tail, outcome, onReport)
    readStatus(spec.metaDir / "status", outcome)
    outcome.started = outcome.error.len == 0
    outcome.isolation = isolationLevelOf(spec)
    outcome.stdout = readCapped(spec.metaDir / "stdout")
    outcome.stderr = readCapped(spec.metaDir / "stderr")
    return outcome

# ---------------------------------------------------------------------------
# macOS backend.
# ---------------------------------------------------------------------------

proc sbplString(s: string): string =
  result = "\""
  for ch in s:
    if ch == '"' or ch == '\\': result.add('\\')
    result.add(ch)
  result.add('"')

proc realOrSelf(p: string): string =
  ## Seatbelt matches resolved paths (`/tmp` is `/private/tmp` on macOS).
  try: expandFilename(p) except OSError: p

proc seatbeltProfile*(spec: LeaseSpec; forwarderPorts: seq[int]): string =
  ## The SBPL for `spec`. Later rules take precedence over earlier ones, so
  ## each layer is a broad deny followed by its narrow re-allow, and the
  ## layers are ordered landlock, namespace, floor, egress.
  let tag = "(with message " & sbplString("repro-lease-" & spec.leaseId) & ")"
  let own = sbplString(realOrSelf(spec.leaseDir))
  # The action's own stdout/stderr files live in the supervisor's meta
  # directory (outside the lease root, often under hidden daemon state).
  # Tools look them up by path (clang does), so exactly those two files are
  # re-allowed; nothing else in the meta directory is.
  let stdio = " (literal " & sbplString(realOrSelf(spec.metaDir) / "stdout") &
    ") (literal " & sbplString(realOrSelf(spec.metaDir) / "stderr") & ")"
  var p = "(version 1)\n(allow default)\n"
  if llLandlock in spec.layers:
    p.add("; landlock layer: writes only to the lease; exec only from the closure\n")
    p.add("(deny file-write* " & tag & ")\n")
    p.add("(allow file-write* (subpath " & own & ")" & stdio &
      " (literal \"/dev/null\")" &
      " (literal \"/dev/zero\") (literal \"/dev/dtracehelper\")" &
      " (regex #\"^/dev/tty\"))\n")
    # Reads, as on Linux: file CONTENT only beneath the declared read and
    # tool roots, the lease root and this lease (metadata stays readable —
    # path resolution needs it, and it holds no content). The daemon's
    # state is therefore unreadable here even without the namespace group.
    p.add("(deny file-read-data " & tag & ")\n")
    var reads = " (subpath " & sbplString(realOrSelf(spec.leaseRoot)) & ")" &
      " (subpath " & own & ")" & stdio & " (subpath \"/dev\")" &
      # The root directory's own listing: shells and libc read it at start;
      # it names top-level directories and holds no content.
      " (literal \"/\")"
    for r in spec.readRoots & spec.closureRoots & spec.outputDirs:
      reads.add(" (subpath " & sbplString(realOrSelf(r)) & ")")
    if spec.inputsDir.len > 0:
      reads.add(" (subpath " & sbplString(realOrSelf(spec.inputsDir)) & ")")
    p.add("(allow file-read-data" & reads & ")\n")
    p.add("(deny process-exec* " & tag & ")\n")
    var execs = ""
    for r in spec.closureRoots & spec.outputDirs:
      execs.add(" (subpath " & sbplString(realOrSelf(r)) & ")")
    if spec.inputsDir.len > 0:
      execs.add(" (subpath " & sbplString(realOrSelf(spec.inputsDir)) & ")")
    if execs.len > 0:
      p.add("(allow process-exec*" & execs & ")\n")
  # The namespace group comes AFTER the landlock group and names
  # `file-read-data` explicitly: the landlock group re-allows content reads
  # beneath the whole lease root (as Linux Landlock does — on Linux the mount
  # namespace hides the neighbours independently of any rule), and Seatbelt
  # ranks a rule on the specific operation above one on `file-read*`.
  if llNamespace in spec.layers:
    p.add("; namespace layer: no other lease and no daemon state is visible\n")
    p.add("(deny file-read* file-read-data file-write* (subpath " &
      sbplString(realOrSelf(spec.leaseRoot)) & ") " & tag & ")\n")
    for h in spec.hidePaths:
      p.add("(deny file-read* file-read-data file-write* (subpath " &
        sbplString(realOrSelf(h)) & ") " & tag & ")\n")
    p.add("(allow file-read* file-read-data file-write* (subpath " & own & ")" & stdio &
      ")\n")
  if spec.inputsDir.len > 0 and llLandlock in spec.layers:
    # Last word on writes beneath the input artifacts (they lie inside the
    # lease, which the groups above re-allow): read and execute only.
    p.add("; input artifacts: read and execute, never write\n")
    p.add("(deny file-write* (subpath " &
      sbplString(realOrSelf(spec.inputsDir)) & ") " & tag & ")\n")
  if llFloor in spec.layers:
    p.add("; floor: no unix-socket peers (the daemon), no reach into other processes\n")
    p.add("(deny network-outbound (remote unix-socket) " & tag & ")\n")
    p.add("(deny signal (target others) " & tag & ")\n")
    p.add("(deny process-info* (target others))\n")
    p.add("(allow process-info* (target self))\n")
  p.add("; egress: deny by default; only the supervisor's forwarders\n")
  p.add("(deny network-outbound (remote ip) " & tag & ")\n")
  for port in forwarderPorts:
    p.add("(allow network-outbound (remote ip \"localhost:" & $port & "\"))\n")
  p

proc splice(a, b: AsyncSocket) {.async.} =
  try:
    while true:
      let data = await a.recv(16384)
      if data.len == 0: break
      await b.send(data)
  except CatchableError:
    discard
  try: b.close() except CatchableError: discard
  try: a.close() except CatchableError: discard

proc forwardLoop(listener: AsyncSocket; dest: EgressDestination;
                 running: ref bool) {.async.} =
  while running[]:
    var inner: AsyncSocket
    try:
      inner = await listener.accept()
    except CatchableError:
      break
    let outer = newAsyncSocket()
    try:
      await outer.connect(dest.host, Port(dest.port))
    except CatchableError:
      try: inner.close() except CatchableError: discard
      try: outer.close() except CatchableError: discard
      continue
    asyncCheck splice(inner, outer)
    asyncCheck splice(outer, inner)

proc parseSandboxLog(text, leaseId: string): seq[LeaseReport] =
  let marker = "repro-lease-" & leaseId
  for line in text.splitLines:
    if marker notin line: continue
    try:
      let msg = parseJson(line){"eventMessage"}.getStr
      # "Sandbox: <proc>(<pid>) deny(1) <operation> <target>\n<tag>"
      let first = msg.splitLines[0]
      let d = first.find("deny(")
      if d < 0: continue
      let rest = first[d .. ^1].splitWhitespace()
      if rest.len < 2: continue
      let op = rest[1]
      let target = if rest.len >= 3: rest[2 .. ^1].join(" ") else: ""
      var pid = 0
      let lp = first.find('(')
      let rp = first.find(')')
      if lp > 0 and rp > lp:
        try: pid = parseInt(first[lp + 1 ..< rp]) except ValueError: discard
      let kind =
        if op.startsWith("network-outbound"): "egress-denied"
        elif op.startsWith("process-exec"): "exec-outside-closure"
        else: "fs-denied"
      result.add(LeaseReport(kind: kind, detail: target, syscall: op, pid: pid))
    except CatchableError:
      discard

when defined(posix):
  proc readAvailable(fd: cint): string =
    ## Whatever the (non-blocking) descriptor holds now; never waits.
    var buf: array[16384, char]
    while true:
      let n = posix.read(fd, addr buf[0], buf.len)
      if n <= 0: break
      let old = result.len
      result.setLen(old + n)
      copyMem(addr result[old], addr buf[0], n)

when defined(posix):
 proc runLeaseSeatbelt(spec: LeaseSpec;
                      onReport: ReportSink): Future[LeaseOutcome] {.async.} =
   var outcome = LeaseOutcome()
   prepareLeaseDirs(spec)
   let running = new(bool)
   running[] = true
   var listeners: seq[AsyncSocket] = @[]
   var ports: seq[int] = @[]
   var env = spec.env
   for d in spec.egress:
     let l = newAsyncSocket()
     l.setSockOpt(OptReuseAddr, true)
     l.bindAddr(Port(0), "127.0.0.1")
     l.listen()
     let port = int(getLocalAddr(l.getFd(), Domain.AF_INET)[1])
     listeners.add(l)
     ports.add(port)
     env.add((egressVarName(d.name), "127.0.0.1:" & $port))
     outcome.egressEnv.add((egressVarName(d.name), "127.0.0.1:" & $port))
     asyncCheck forwardLoop(l, d, running)
   let profilePath = spec.metaDir / "lease.sb"
   writeFile(profilePath, seatbeltProfile(spec, ports))
   # Collect the kernel's Seatbelt denials for this lease (tagged) before the
   # action starts, so none is missed.
   let logPath = spec.metaDir / "sandbox-log.ndjson"
   let logger = uncontrolledStartProcess("/usr/bin/log", args = ["stream", "--style",
     "ndjson", "--predicate", "sender == \"Sandbox\" AND eventMessage " &
     "CONTAINS \"repro-lease-" & spec.leaseId & "\""],
     options = {poStdErrToStdOut})
   let logOut = open(logPath, fmWrite)
   var ready = false
   let readyBy = epochTime() + 5.0
   var logBuf = ""
   while not ready and epochTime() < readyBy:
     var line = ""
     if not logger.outputStream.readLine(line): break
     logBuf.add(line & "\n")
     if "Filtering the log data" in line: ready = true
   # From here on the log is read WHILE the action runs and every denial is
   # handed on at once (threat model G21), from the raw, non-blocking pipe.
   let logFd = cint(logger.outputHandle)
   discard fcntl(logFd, F_SETFL, fcntl(logFd, F_GETFL) or O_NONBLOCK)
   var partial = ""
   proc takeLog(text: string) =
     if text.len == 0: return
     logBuf.add(text)
     let all = partial & text
     let last = all.rfind('\n')
     if last < 0:
       partial = all
       return
     partial = all[last + 1 .. ^1]
     for rep in parseSandboxLog(all[0 ..< last], spec.leaseId):
       if outcome.reports.len < MaxLeaseReports:
         outcome.reports.add(rep)
       if not onReport.isNil:
         try: onReport(rep) except CatchableError: discard
   if spec.inputsDir.len > 0:
     env.add(("REPRO_LEASE_INPUTS", spec.inputsDir))
   var envTable = newStringTable(modeCaseSensitive)
   for (k, v) in env: envTable[k] = v
   # stdout/stderr go to files (a pipe the daemon does not drain while the
   # action runs would stall it). The redirecting shell runs OUTSIDE the
   # sandbox; `exec` replaces it with sandbox-exec, which applies the profile
   # before the action's first instruction. Before that it closes every
   # descriptor above stderr it inherited from the daemon: `startProcess`
   # passes on whatever the daemon holds without close-on-exec, and an
   # inherited socket (a peer connection, the control socket, a listener) is
   # a channel no Seatbelt network rule governs (review fix, 2026-10-19;
   # `t_execution_lease_confinement`, `BREACH-fd`).
   let child = uncontrolledStartProcess("/bin/sh", args = @["-c",
     "p=$1; o=$2; e=$3; shift 3; " &
     "for f in /dev/fd/*; do n=${f##*/}; " &
     "case $n in ''|*[!0-9]*) continue;; esac; " &
     "[ \"$n\" -gt 2 ] && eval \"exec $n>&-\"; done 2>/dev/null; " &
     "exec /usr/bin/sandbox-exec -f \"$p\" " &
     "\"$@\" >\"$o\" 2>\"$e\" </dev/null", "sh", profilePath,
     spec.metaDir / "stdout", spec.metaDir / "stderr"] & spec.argv,
     workingDir = spec.cwd, env = envTable, options = {})
   var waitedMs = 0
   while child.running:
     await sleepAsync(20)
     takeLog(readAvailable(logFd))
     waitedMs += 20
     if spec.timeoutMs > 0 and waitedMs > spec.timeoutMs:
       child.kill()
       outcome.timedOut = true
       break
   outcome.exitCode = child.waitForExit()
   child.close()
   outcome.stdout = readCapped(spec.metaDir / "stdout")
   outcome.stderr = readCapped(spec.metaDir / "stderr")
   running[] = false
   for l in listeners:
     try: l.close() except CatchableError: discard
   # Give the unified log time to deliver the last denials, then stop it.
   for _ in 0 ..< 75:
     await sleepAsync(20)
     takeLog(readAvailable(logFd))
   logger.terminate()
   discard logger.waitForExit()
   takeLog(readAvailable(logFd) & "\n")
   logger.close()
   logOut.write(logBuf)
   logOut.close()
   outcome.started = true
   outcome.isolation = isolationLevelOf(spec)
   return outcome

# ---------------------------------------------------------------------------
# Windows backend (trusted profile only): a Job Object.
# ---------------------------------------------------------------------------

when defined(windows):
  import std/winlean

  type
    JobBasicLimit {.pure.} = object
      perProcessUserTimeLimit: int64
      perJobUserTimeLimit: int64
      limitFlags: uint32
      minimumWorkingSetSize: uint
      maximumWorkingSetSize: uint
      activeProcessLimit: uint32
      affinity: uint
      priorityClass: uint32
      schedulingClass: uint32
    IoCounters {.pure.} = object
      a, b, c, d, e, f: uint64
    JobExtendedLimit {.pure.} = object
      basic: JobBasicLimit
      io: IoCounters
      processMemoryLimit: uint
      jobMemoryLimit: uint
      peakProcessMemoryUsed: uint
      peakJobMemoryUsed: uint
    StartupInfoExW {.pure.} = object
      si: STARTUPINFO
      attributeList: pointer

  const
    JobObjectExtendedLimitInformation = 9'i32
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000'u32
    JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION = 0x400'u32
    CREATE_SUSPENDED_FLAG = 0x4'i32
    CREATE_UNICODE_ENVIRONMENT_FLAG = 0x400'i32
    CREATE_NO_WINDOW_FLAG = 0x08000000'i32
    EXTENDED_STARTUPINFO_PRESENT_FLAG = 0x80000'i32
    PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x20002'u
    HANDLE_FLAG_INHERIT = 0x1'i32

  proc CreateJobObjectW(attrs: pointer; name: WideCString): Handle
    {.stdcall, dynlib: "kernel32", importc.}
  proc SetInformationJobObject(job: Handle; cls: int32; info: pointer;
                               len: int32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc.}
  proc AssignProcessToJobObject(job, process: Handle): WINBOOL
    {.stdcall, dynlib: "kernel32", importc.}
  proc TerminateJobObject(job: Handle; code: uint32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc.}
  proc ResumeThreadW(thread: Handle): int32
    {.stdcall, dynlib: "kernel32", importc: "ResumeThread".}
  proc InitializeProcThreadAttributeList(list: pointer; count: int32;
      flags: int32; size: ptr uint): WINBOOL
    {.stdcall, dynlib: "kernel32", importc.}
  proc UpdateProcThreadAttribute(list: pointer; flags: int32; attr: uint;
      value: pointer; size: uint; prev: pointer; retSize: pointer): WINBOOL
    {.stdcall, dynlib: "kernel32", importc.}
  proc DeleteProcThreadAttributeList(list: pointer)
    {.stdcall, dynlib: "kernel32", importc.}
  proc SetHandleInformation(h: Handle; mask, flags: int32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc.}
  proc CreateProcessExW(app: WideCString; cmd: WideCString;
      pattrs, tattrs: pointer; inherit: WINBOOL; flags: int32;
      env: pointer; cwd: WideCString; si: ptr StartupInfoExW;
      pi: var PROCESS_INFORMATION): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "CreateProcessW".}

  proc openForChild(path: string; write: bool): Handle =
    var sa = SECURITY_ATTRIBUTES(nLength: int32(sizeof(SECURITY_ATTRIBUTES)),
      lpSecurityDescriptor: nil, bInheritHandle: 1)
    if write:
      createFileW(newWideCString(path), GENERIC_WRITE, FILE_SHARE_READ,
        addr sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0)
    else:
      createFileW(newWideCString(path), GENERIC_READ, FILE_SHARE_READ or
        FILE_SHARE_WRITE, addr sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0)

  proc environmentBlock(env: seq[(string, string)]): seq[Utf16Char] =
    ## A sorted, double-NUL-terminated UTF-16 environment block holding
    ## exactly `env` (nothing is inherited from the daemon).
    var pairs = env
    pairs.sort(proc(a, b: (string, string)): int = cmpIgnoreCase(a[0], b[0]))
    for (k, v) in pairs:
      let w = newWideCString(k & "=" & v)
      for i in 0 ..< w.len: result.add(w[i])
      result.add(Utf16Char(0))
    result.add(Utf16Char(0))
    if pairs.len == 0: result.add(Utf16Char(0))

  proc runLeaseWindows(spec: LeaseSpec;
                       onReport: ReportSink): Future[LeaseOutcome] {.async.} =
    var outcome = LeaseOutcome(isolation: isolationLevelOf(spec))
    prepareLeaseDirs(spec)
    var env = spec.env
    for d in spec.egress:
      # No forwarder on Windows: the job object does not confine the
      # network (recorded by the isolation level); the action is told the
      # real destination it declared.
      env.add((egressVarName(d.name), d.host & ":" & $d.port))
      outcome.egressEnv.add((egressVarName(d.name), d.host & ":" & $d.port))
    if spec.inputsDir.len > 0:
      env.add(("REPRO_LEASE_INPUTS", spec.inputsDir))
    let job = CreateJobObjectW(nil, nil)
    if job == 0:
      outcome.error = "CreateJobObject failed: " & $osLastError()
      return outcome
    defer: discard closeHandle(job)
    var limit = JobExtendedLimit()
    limit.basic.limitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE or
      JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION
    if SetInformationJobObject(job, JobObjectExtendedLimitInformation,
        addr limit, int32(sizeof(limit))) == 0:
      outcome.error = "SetInformationJobObject failed: " & $osLastError()
      return outcome
    let hIn = openForChild("NUL", write = false)
    let hOut = openForChild(spec.metaDir / "stdout", write = true)
    let hErr = openForChild(spec.metaDir / "stderr", write = true)
    defer:
      for h in [hIn, hOut, hErr]:
        if h != INVALID_HANDLE_VALUE: discard closeHandle(h)
    if hIn == INVALID_HANDLE_VALUE or hOut == INVALID_HANDLE_VALUE or
        hErr == INVALID_HANDLE_VALUE:
      outcome.error = "cannot open the lease's stdio files"
      return outcome
    # Only these three handles cross into the action (the BREACH-fd rule of
    # the POSIX backends): an explicit inheritance list.
    var handles = [hIn, hOut, hErr]
    var attrSize: uint = 0
    discard InitializeProcThreadAttributeList(nil, 1, 0, addr attrSize)
    var attrBuf = newSeq[byte](int(attrSize))
    if InitializeProcThreadAttributeList(addr attrBuf[0], 1, 0,
        addr attrSize) == 0:
      outcome.error = "InitializeProcThreadAttributeList failed"
      return outcome
    defer: DeleteProcThreadAttributeList(addr attrBuf[0])
    if UpdateProcThreadAttribute(addr attrBuf[0], 0,
        PROC_THREAD_ATTRIBUTE_HANDLE_LIST, addr handles[0],
        uint(sizeof(handles)), nil, nil) == 0:
      outcome.error = "UpdateProcThreadAttribute failed"
      return outcome
    var si = StartupInfoExW()
    si.si.cb = int32(sizeof(StartupInfoExW))
    si.si.dwFlags = STARTF_USESTDHANDLES
    si.si.hStdInput = hIn
    si.si.hStdOutput = hOut
    si.si.hStdError = hErr
    si.attributeList = addr attrBuf[0]
    var pi: PROCESS_INFORMATION
    var cmd = newWideCString(quoteShellCommand(spec.argv))
    var envBlock = environmentBlock(env)
    let flags = CREATE_SUSPENDED_FLAG or CREATE_UNICODE_ENVIRONMENT_FLAG or
      CREATE_NO_WINDOW_FLAG or EXTENDED_STARTUPINFO_PRESENT_FLAG
    if CreateProcessExW(newWideCString(spec.argv[0]), cmd, nil, nil, 1, flags,
        addr envBlock[0], newWideCString(spec.cwd), addr si, pi) == 0:
      outcome.error = "CreateProcess failed: " & $osLastError()
      return outcome
    defer:
      discard closeHandle(pi.hThread)
      discard closeHandle(pi.hProcess)
    # Into the job BEFORE the first instruction: every process it starts is
    # in the job too, and all of them die when the job is closed.
    if AssignProcessToJobObject(job, pi.hProcess) == 0:
      discard terminateProcess(pi.hProcess, 1)
      outcome.error = "AssignProcessToJobObject failed: " & $osLastError()
      return outcome
    discard ResumeThreadW(pi.hThread)
    outcome.started = true
    var waited = 0
    while waitForSingleObject(pi.hProcess, 0) == WAIT_TIMEOUT:
      await sleepAsync(20)
      waited += 20
      if spec.timeoutMs > 0 and waited > spec.timeoutMs:
        outcome.timedOut = true
        break
    # The whole tree goes, the timed-out case and the finished one alike
    # (a daemonized grandchild must not outlive the lease).
    discard TerminateJobObject(job, 1)
    discard waitForSingleObject(pi.hProcess, 5_000)
    var code: int32
    if getExitCodeProcess(pi.hProcess, code) != 0:
      outcome.exitCode = int(code)
    outcome.stdout = readCapped(spec.metaDir / "stdout")
    outcome.stderr = readCapped(spec.metaDir / "stderr")
    return outcome

# ---------------------------------------------------------------------------
# The closure (DET-1, threat model G25).
# ---------------------------------------------------------------------------

const NixStore = "/nix/store/"

proc nixStoreEntryOf*(path: string): string =
  ## `/nix/store/<hash>-<name>` for a path inside the store, else "".
  if not path.startsWith(NixStore):
    return ""
  let slash = path.find('/', NixStore.len)
  if slash < 0: path else: path[0 ..< slash]

proc nixClosureOf*(storePaths: seq[string]): tuple[ok: bool;
                                                    paths: seq[string];
                                                    reason: string] =
  ## `nix-store -qR` of `storePaths` (every store path they reference,
  ## transitively). A fixed system tool, named by the operator's PATH.
  if storePaths.len == 0:
    return (true, @[], "")
  # Not resolved through symlinks: `nix-store` is a link to the multi-call
  # `nix` binary, which picks its mode from the name it was invoked by.
  let nixStore = uncontrolledFindExe("nix-store", followSymlinks = false)
  if nixStore.len == 0:
    return (false, @[], "nix-store is not on PATH: the closure of " &
      storePaths[0] & " cannot be computed")
  let res = uncontrolledExecCmdEx(quoteShellCommand(@[nixStore, "-qR"] &
    storePaths))
  if res.exitCode != 0:
    return (false, @[], "nix-store -qR failed: " & res.output.strip())
  for line in res.output.splitLines:
    let p = line.strip()
    if p.startsWith(NixStore) and p notin result.paths:
      result.paths.add(p)
  result.ok = true

proc computeLeaseClosure*(pathDirs: seq[string]; selfExe: string;
                          baseRoots: seq[string]):
    tuple[ok: bool; roots: seq[string]; reason: string] =
  ## The executable closure a lease may run code from:
  ##
  ## * on NixOS, `nix-store -qR /run/current-system`;
  ## * plus the closure of every store path on `pathDirs` (the toolchain
  ##   the operator put on the daemon's PATH) and of the daemon's own
  ##   executable;
  ## * plus `baseRoots` (the base system's executable directories, on a
  ##   host whose system is not in the store).
  ##
  ## Never the whole of `/nix/store`: anything a lease builds or fetches
  ## into the store is outside its closure.
  var seeds: seq[string] = @[]
  if dirExists("/run/current-system"):
    let sys = try: expandFilename("/run/current-system") except OSError: ""
    if sys.startsWith(NixStore): seeds.add(nixStoreEntryOf(sys))
  for dir in pathDirs:
    let real = try: expandFilename(dir) except OSError: dir
    let entry = nixStoreEntryOf(real)
    if entry.len > 0 and entry notin seeds: seeds.add(entry)
  let exeReal = try: expandFilename(selfExe) except OSError: selfExe
  let exeEntry = nixStoreEntryOf(exeReal)
  if exeEntry.len > 0 and exeEntry notin seeds: seeds.add(exeEntry)
  let closure = nixClosureOf(seeds)
  if not closure.ok:
    return (false, @[], closure.reason)
  result.roots = baseRoots
  for p in closure.paths:
    if p notin result.roots: result.roots.add(p)
  result.ok = true

# ---------------------------------------------------------------------------
# Per-lease cgroups (threat model G31).
# ---------------------------------------------------------------------------

type
  LeaseCgroups* = object
    ## The worker's delegated cgroup v2 subtree, when it has one.
    available*: bool
    base*: string
    reason*: string
    memoryMax*: int64
    pidsMax*: int

const
  DefaultLeaseMemoryMax* = 8'i64 * 1024 * 1024 * 1024
  DefaultLeasePidsMax* = 4_096

proc writeSmall(path, text: string): bool =
  ## One write(2) of `text` to a cgroup control file, reporting whether the
  ## KERNEL accepted it. The kernel refuses a cgroup write in write(2) itself
  ## (EBUSY enabling a controller in a cgroup that has processes, EACCES or
  ## EINVAL moving a process); `writeFile` buffers the text and its `close`
  ## discards fclose's error, so it reported every refused write as done and
  ## a cgroup that is not delegated passed for one that is.
  when defined(linux):
    let fd = posix.open(path.cstring, O_WRONLY or O_CLOEXEC)
    if fd < 0:
      return false
    let n = posix.write(fd, text.cstring, text.len)
    let closed = posix.close(fd)
    n == text.len and closed == 0
  else:
    try:
      writeFile(path, text)
      true
    except CatchableError:
      false

proc prepareLeaseCgroups*(memoryMax = DefaultLeaseMemoryMax;
                          pidsMax = DefaultLeasePidsMax): LeaseCgroups =
  ## Linux: when the worker runs in a DELEGATED cgroup v2 subtree (a unit
  ## with `Delegate=yes`), moves the daemon into a `daemon` child and turns
  ## on the memory and pids controllers for lease children, so each lease
  ## gets its own memory and process limit and a lease that exhausts them
  ## does not take the daemon with it. Otherwise `available = false` with
  ## the reason; the floor's rlimits still apply.
  result.memoryMax = memoryMax
  result.pidsMax = pidsMax
  when defined(linux):
    var rel = ""
    try:
      for line in readFile("/proc/self/cgroup").splitLines:
        if line.startsWith("0::"):
          rel = line[3 .. ^1]
    except CatchableError:
      return LeaseCgroups(reason: "no /proc/self/cgroup")
    if rel.len == 0:
      return LeaseCgroups(reason: "not on the cgroup v2 unified hierarchy")
    var base = "/sys/fs/cgroup" & rel
    if base.endsWith("/daemon"):
      base = base.parentDir   # a restarted role: already moved
    if not fileExists(base / "cgroup.subtree_control"):
      return LeaseCgroups(reason: "cgroup " & base & " is not a v2 cgroup")
    let daemonDir = base / "daemon"
    try:
      createDir(daemonDir)
    except CatchableError:
      return LeaseCgroups(reason: "the worker's cgroup " & base &
        " is not delegated to it (Delegate=yes)")
    if not writeSmall(daemonDir / "cgroup.procs", $getCurrentProcessId()):
      return LeaseCgroups(reason: "cannot move the daemon into " & daemonDir)
    if not writeSmall(base / "cgroup.subtree_control", "+memory +pids"):
      return LeaseCgroups(reason: "cannot enable the memory and pids " &
        "controllers in " & base)
    result.available = true
    result.base = base
  else:
    result.reason = "cgroups are Linux-only"

proc leaseCgroupFor*(cg: LeaseCgroups; leaseId: string): tuple[ok: bool;
                                                                path: string] =
  ## A fresh cgroup for one lease with the limits written; ("" when none).
  if not cg.available:
    return (true, "")
  let path = cg.base / ("lease-" & leaseId)
  try:
    createDir(path)
  except CatchableError:
    return (false, "")
  if not writeSmall(path / "memory.max", $cg.memoryMax) or
      not writeSmall(path / "pids.max", $cg.pidsMax):
    # Not left behind, one empty cgroup per refused lease.
    when defined(linux):
      discard posix.rmdir(path.cstring)
    return (false, "")
  discard writeSmall(path / "memory.swap.max", "0")
  (true, path)

proc removeLeaseCgroup*(path: string) =
  ## A cgroup directory is removed with rmdir(2) (its files cannot be
  ## unlinked); it succeeds once every process in it has exited.
  when defined(linux):
    if path.len > 0:
      discard posix.rmdir(path.cstring)

# ---------------------------------------------------------------------------
# Entry points.
# ---------------------------------------------------------------------------

proc ensureLeaseTraversal*(leaseRoot, ownedTop: string):
    tuple[ok: bool; reason: string] =
  ## Under the Linux floor a lease runs as a SUBORDINATE uid, which must be
  ## able to traverse (search, not list) every ancestor of its own lease
  ## directory. For the directories from `leaseRoot` up to `ownedTop` (the
  ## worker's own state, created owner-only) the search bit for others is
  ## added — names stay unlistable and files keep their own modes, so the
  ## daemon's 0600 keys remain unreadable (and hidden by the namespace and
  ## Landlock layers besides). An ancestor ABOVE `ownedTop` that others
  ## cannot search is not ours to change: the worker role refuses to start
  ## and names it. A no-op off Linux.
  when defined(linux):
    let top = normalizedPath(absolutePath(ownedTop))
    var dir = normalizedPath(absolutePath(leaseRoot))
    var insideOwned = true
    while true:
      var st: Stat
      if stat(dir.cstring, st) != 0:
        return (false, "cannot stat " & dir)
      if insideOwned:
        if st.st_uid != getuid():
          return (false, dir & " is inside the worker state but not owned " &
            "by the worker user")
        if (st.st_mode.cint and S_IXOTH) == 0:
          if chmod(dir.cstring, Mode(st.st_mode.cint or S_IXOTH)) != 0:
            return (false, "cannot make " & dir & " searchable by the lease user")
      elif (st.st_mode.cint and S_IXOTH) == 0:
        return (false, dir & " is not searchable by other users, so the " &
          "floor's lease user cannot reach the lease root beneath it; place " &
          "the worker state under a searchable directory")
      if dir == top:
        insideOwned = false
      let parent = dir.parentDir
      if parent.len == 0 or parent == dir:
        break
      dir = parent
    (true, "")
  else:
    (true, "")

type
  LinuxLeaseHostProbe* = object
    ## What a Linux host offers the lease (`probeLinuxLeaseHost`). Separate
    ## from the decision (`decideLinuxLeaseLayers`) so a test can drive
    ## every combination, including the ones the test host does not have.
    userNamespaces*: bool
    pidfdGetfd*: bool
    landlock*: bool
    subordinateIds*: bool
    idMappingTools*: bool
      ## newuidmap and newgidmap installed.

proc decideLinuxLeaseLayers*(probe: LinuxLeaseHostProbe; hardened: bool):
    tuple[ok: bool; layers: set[LeaseLayer]; reason: string] =
  ## The profile decision on a Linux host (see `availableLeaseLayers`):
  ## both profiles need the namespace layer and pidfd_getfd; TRUSTED runs
  ## Landlock and the floor when present and is never refused for lacking
  ## them; HARDENED refuses, naming every missing layer.
  if not probe.userNamespaces:
    return (false, {}, "unprivileged user namespaces are unavailable: " &
      "the lease's new root cannot be built")
  if not probe.pidfdGetfd:
    return (false, {}, "pidfd_getfd(2) is unavailable (Linux 5.6 or " &
      "later): the lease supervisor could not take its seccomp listener")
  var layers = {llNamespace}
  var missing: seq[string] = @[]
  if probe.landlock:
    layers.incl(llLandlock)
  else:
    missing.add("Landlock is unavailable (enable the landlock LSM)")
  if not probe.subordinateIds:
    missing.add("the floor: no subordinate uid/gid range for the lease user")
  elif not probe.idMappingTools:
    missing.add("the floor: newuidmap/newgidmap are not installed")
  else:
    layers.incl(llFloor)
  if hardened and missing.len > 0:
    return (false, layers, "the hardened profile requires Landlock and " &
      "the floor: " & missing.join("; "))
  (true, layers, missing.join("; "))

when defined(linux):
  proc probeLinuxLeaseHost*(): LinuxLeaseHostProbe =
    ## This host's answers for `decideLinuxLeaseLayers`.
    result.userNamespaces = c_repro_lease_userns_supported() != 0
    result.pidfdGetfd = c_repro_lease_pidfd_supported() != 0
    result.landlock = landlockAbi() >= 1
    result.subordinateIds = subordinateIds().ok
    result.idMappingTools = uncontrolledFindExe("newuidmap").len > 0 and
      uncontrolledFindExe("newgidmap").len > 0

proc availableLeaseLayers*(hardened = false):
    tuple[ok: bool; layers: set[LeaseLayer]; reason: string] =
  ## The lease layers this host can run, for a worker of the given profile.
  ## A worker that cannot confine a lease at all refuses the worker role
  ## rather than running goals unconfined (`ok = false`, the reason).
  ##
  ## Linux. Both profiles need the namespace layer (unprivileged user,
  ## mount, pid, net, ipc and uts namespaces: the new root of only the
  ## closure and the lease, every writable mount noexec) and pidfd_getfd(2)
  ## (Linux 5.6+: the supervisor takes the lease's seccomp listener, which
  ## carries the always-on egress/exec/filesystem detection).
  ##
  ## * TRUSTED: namespaces + noexec always; Landlock when the kernel has it
  ##   and the floor (a subordinate uid per slot + the derived seccomp
  ##   allow-list) when the user has a subordinate id range and
  ##   newuidmap/newgidmap. A missing one is NOT a refusal: the lease runs
  ##   without it and its isolation level says what it got
  ##   (`linux-namespace+landlock+floor` vs `linux-namespace`).
  ## * HARDENED: Landlock and the floor are REQUIRED; without either the
  ##   role is refused.
  ##
  ## macOS and Windows (trusted only): Seatbelt under the build user; a
  ## Job Object. The hardened profile refuses both until a VM-grade lease
  ## boundary exists (M8 deliverable, threat model §3a).
  when defined(linux):
    decideLinuxLeaseLayers(probeLinuxLeaseHost(), hardened)
  elif defined(macosx):
    if hardened:
      (false, {}, "the hardened profile refuses macOS workers until a " &
        "VM-grade lease boundary exists (Seatbelt under the build user is " &
        "the trusted profile's isolation)")
    elif fileExists("/usr/bin/sandbox-exec"): (true, DefaultLeaseLayers, "")
    else: (false, {}, "sandbox-exec is unavailable")
  elif defined(windows):
    if hardened:
      (false, {}, "the hardened profile refuses Windows workers until a " &
        "VM-grade lease boundary exists (a job object is the trusted " &
        "profile's isolation)")
    else: (true, DefaultLeaseLayers, "")
  else:
    (false, {}, "no execution-lease confinement on this platform")

proc leaseConfinementAvailable*(hardened = false):
    tuple[ok: bool; reason: string] =
  ## Whether this host can confine a lease at all for a worker of the given
  ## profile (`availableLeaseLayers`). In the trusted profile on Linux a
  ## host without Landlock or a subordinate uid range still qualifies; its
  ## leases run at the weaker isolation level they record.
  let a = availableLeaseLayers(hardened)
  (a.ok, a.reason)

proc runLease*(spec: LeaseSpec;
               onReport: ReportSink = nil): Future[LeaseOutcome] {.async.} =
  ## Runs `spec.argv` confined as described in the module doc; every
  ## report goes to `onReport` as it happens.
  if spec.argv.len == 0 or not spec.argv[0].isAbsolute:
    return LeaseOutcome(error: "argv[0] must be an absolute path")
  when defined(linux):
    return await runLeaseLinux(spec, onReport)
  elif defined(macosx):
    return await runLeaseSeatbelt(spec, onReport)
  elif defined(windows):
    return await runLeaseWindows(spec, onReport)
  else:
    return LeaseOutcome(error: "no execution-lease confinement on this platform")

proc cleanupLease*(spec: LeaseSpec): bool =
  ## Removes the lease directory. Under the Linux floor the lease's files
  ## belong to the subordinate user, so removal runs as that user's
  ## namespace root.
  when defined(linux):
    if llFloor in spec.layers:
      var outcome = LeaseOutcome()
      let pid = spawnLinux(spec, cleanup = true, outcome)
      if pid < 0: return false
      var status: cint
      discard waitpid(Pid(pid), status, 0)
  try:
    if dirExists(spec.leaseDir): removeDir(spec.leaseDir)
    true
  except OSError:
    false
