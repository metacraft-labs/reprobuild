## A daemon-hosted build runs under the resource limits of the process that
## asked for it.
##
## THE DEFECT THIS EXISTS FOR: the daemon ran a routed build's actions
## outside the caller's memory cap. On Linux a
## caller caps a build by running it in a cgroup --
## ``systemd-run --user --scope -p MemoryMax=16G -- repro build …`` -- and the
## cap binds every process in that cgroup and below it. A build routed to the
## per-user daemon did not run there: the daemon forks a worker per request
## (``spawnDetachedDaemonWorker``) and the worker, its actions and their
## compilers all stayed in the DAEMON's cgroup, usually its own transient
## service with ``MemoryMax=infinity``. The caller's unit peaked at 1.1 GB
## while its build used tens of gigabytes uncapped, and on a host where the
## daemon was started from inside one session's capped unit, every later
## session's builds ran under that first session's limit instead of their own.
##
## WHAT THIS DOES. The daemon reads the caller's cgroup from the kernel's
## record of the connected peer (``SO_PEERCRED`` gives its pid, and
## ``/proc/<pid>/cgroup`` its cgroup v2 path), never from anything the client
## sends. The forked worker, before it runs anything, moves ITSELF into that
## cgroup by writing ``0`` to its ``cgroup.procs``
## (https://docs.kernel.org/admin-guide/cgroup-v2.html#processes). Every
## action is a descendant of the worker and starts after the move, so each
## one inherits the caller's cgroup and is governed by every limit on it and
## on its ancestors -- exactly what a direct build in the caller's process
## would have been governed by. Memory the worker inherited copy-on-write
## from the daemon stays charged where it was first touched (cgroup v2 does
## not move charges on migration); everything allocated after the move is
## charged to the caller.
##
## WHEN THE MOVE IS NOT POSSIBLE. Migration needs write access to the
## destination's ``cgroup.procs`` and to that of the common ancestor of the
## two cgroups. Under the user's systemd manager (``user@<uid>.service``,
## delegated to the user) both hold. A caller in a cgroup the user cannot
## write -- a login session's ``session-N.scope``, say, which systemd owns as
## root -- cannot be joined. The worker then compares the limits that govern
## the caller with those that govern itself, ancestors included:
##
##   * the same set (both trees unlimited, or every limit on a shared
##     ancestor) -> the build runs where it is, governed exactly as the
##     caller is;
##   * any difference, in either direction -> the request is DECLINED as
##     unsupported with a fallback allowed, and the client builds in its own
##     process, under its own cgroup. A build is never run under limits the
##     caller did not ask for, nor without limits it did ask for.
##
## Non-Linux platforms have no caller cgroup to honour, and every proc here
## reports ``cpkNotApplicable`` there.

import std/[os, strutils]

type
  CgroupLimit* = object
    ## One limit that governs a cgroup: ``file`` (``memory.max``…) of the
    ## cgroup at ``cgroup`` (a path relative to the cgroup v2 hierarchy root,
    ## ``/user.slice/…``) holds ``value``, which is not ``max``.
    cgroup*: string
    file*: string
    value*: string

  CallerPlacementKind* = enum
    cpkNotApplicable
      ## No cgroup v2 hierarchy, or the caller's cgroup is unknown (another
      ## platform, a peer whose pid the kernel did not report, a caller that
      ## exited before its cgroup was read). Nothing can be honoured or
      ## compared; the build runs where it is, as it did before.
    cpkAlreadyThere
      ## The worker was already in the caller's cgroup.
    cpkMoved
      ## The worker moved itself into the caller's cgroup.
    cpkSameLimits
      ## The move failed, but the caller and the worker are governed by the
      ## same limits, so running here changes nothing the caller asked for.
    cpkRefused
      ## The move failed and the limits differ: the build must not run here.

  CallerPlacement* = object
    kind*: CallerPlacementKind
    callerCgroup*: string
    workerCgroup*: string
    detail*: string
      ## Why the move failed and, for ``cpkRefused``, which limits differ.

const
  CgroupLimitFiles* = ["memory.max", "memory.high", "memory.swap.max",
    "pids.max", "cpu.max"]
    ## The interface files whose value is a limit on the cgroup's subtree.
    ## ``max`` (for ``cpu.max``, a quota of ``max``) means unlimited. These
    ## are the ones ``systemd-run -p MemoryMax= / MemoryHigh= /
    ## MemorySwapMax= / TasksMax= / CPUQuota=`` write.

proc cgroupV2Root*(mountInfoPath = "/proc/self/mountinfo"): string =
  ## Where the cgroup v2 (unified) hierarchy is mounted, from the mount
  ## table, or "" when it is not mounted. Format:
  ## https://docs.kernel.org/filesystems/proc.html#proc-pid-mountinfo-information-about-mounts
  ## -- field 5 is the mount point, and the filesystem type follows the
  ## ``-`` separator.
  ## Portable to read; on a host without that file the answer is "".
  let text =
    try: readFile(mountInfoPath)
    except IOError, OSError: return ""
  for line in text.splitLines():
    let sep = line.find(" - ")
    if sep < 0:
      continue
    let fsType = line[sep + 3 .. ^1].splitWhitespace()
    if fsType.len == 0 or fsType[0] != "cgroup2":
      continue
    let fields = line[0 ..< sep].splitWhitespace()
    if fields.len >= 5:
      # The kernel escapes space, tab, newline and backslash as octal.
      return fields[4].multiReplace(("\\040", " "), ("\\011", "\t"),
        ("\\012", "\n"), ("\\134", "\\"))
  ""

proc cgroupV2PathOf*(procCgroupPath: string): string =
  ## The cgroup v2 path recorded in a ``/proc/<pid>/cgroup`` file: the
  ## ``0::<path>`` line, or "" when there is none (cgroup v1 only, an
  ## unreadable file, a process that is gone).
  ## https://docs.kernel.org/admin-guide/cgroup-v2.html#processes
  let text =
    try: readFile(procCgroupPath)
    except IOError, OSError: return ""
  for line in text.splitLines():
    if line.startsWith("0::"):
      return line[3 .. ^1].strip(leading = false)
  ""

proc cgroupV2PathOfPid*(pid: int): string =
  ## ``cgroupV2PathOf`` for process ``pid``; "" for a pid that is not
  ## positive.
  when defined(linux):
    if pid <= 0:
      return ""
    cgroupV2PathOf("/proc/" & $pid & "/cgroup")
  else:
    discard pid
    ""

proc ownCgroupV2Path*(): string =
  when defined(linux): cgroupV2PathOf("/proc/self/cgroup")
  else: ""

proc ancestorsOrSelf(path: string): seq[string] =
  ## ``/a/b`` -> ``/a/b``, ``/a``, ``/``.
  var current = path
  if current.len == 0 or current[0] != '/':
    current = "/" & current
  while current.len > 1 and current.endsWith("/"):
    current.setLen(current.len - 1)
  result.add(current)
  while current != "/":
    let slash = current.rfind('/')
    current = if slash <= 0: "/" else: current[0 ..< slash]
    result.add(current)

proc isUnlimited(file, value: string): bool =
  if file == "cpu.max":
    # "<quota> <period>"; a quota of "max" is no limit.
    value.splitWhitespace().len == 0 or value.splitWhitespace()[0] == "max"
  else:
    value == "max"

proc effectiveCgroupLimits*(root, cgroup: string): seq[CgroupLimit] =
  ## Every limit that governs a process in ``cgroup``: the limit files of
  ## the cgroup itself and of each ancestor, under the hierarchy mounted at
  ## ``root``. A file that does not exist (the root cgroup has none, and a
  ## controller that is not enabled has none) or cannot be read is no limit.
  for path in ancestorsOrSelf(cgroup):
    let dir = if path == "/": root else: root & path
    for file in CgroupLimitFiles:
      let value =
        try: readFile(dir / file).strip()
        except IOError, OSError: continue
      if not isUnlimited(file, value):
        result.add(CgroupLimit(cgroup: path, file: file, value: value))

proc `$`*(limit: CgroupLimit): string =
  limit.file & "=" & limit.value & " on " & limit.cgroup

proc limitDifference(callerLimits, workerLimits: seq[CgroupLimit]): string =
  ## "" when both sets are equal; otherwise names what differs.
  var parts: seq[string] = @[]
  for limit in callerLimits:
    if limit notin workerLimits:
      parts.add("the caller is limited by " & $limit &
        ", which does not govern the daemon's worker")
  for limit in workerLimits:
    if limit notin callerLimits:
      parts.add("the daemon's worker is limited by " & $limit &
        ", which does not govern the caller")
  parts.join("; ")

proc joinCgroup(root, cgroup: string): string =
  ## Move this process into ``cgroup``. "" on success, else why not. The
  ## result is checked against ``/proc/self/cgroup`` rather than trusted
  ## from the write: a write that lands somewhere other than a live cgroup's
  ## ``cgroup.procs`` must not count as a move.
  when defined(linux):
    let procsPath = (if cgroup == "/": root else: root & cgroup) / "cgroup.procs"
    try:
      var f: File
      if not open(f, procsPath, fmAppend):
        return "cannot open " & procsPath & " for writing: " &
          osErrorMsg(osLastError())
      try:
        # "0" is the writing process; for cgroup.procs, its whole thread
        # group.
        f.write("0\n")
        f.flushFile()
      finally:
        f.close()
    except IOError, OSError:
      return "writing " & procsPath & " failed: " & getCurrentExceptionMsg()
    let now = ownCgroupV2Path()
    if now != cgroup:
      return "after writing " & procsPath & " this process is in " &
        (if now.len > 0: now else: "an unknown cgroup") & ", not " & cgroup
    ""
  else:
    discard root
    discard cgroup
    "cgroups are a Linux facility"

proc placeInCallerCgroup*(callerCgroup: string;
                          root = cgroupV2Root();
                          workerCgroup = ownCgroupV2Path()): CallerPlacement =
  ## Put THIS process -- the daemon's worker for one request -- under the
  ## caller's limits; see the module header for the decision. Call it before
  ## the worker starts any process, so that every action inherits the
  ## result.
  ##
  ## ``root`` and ``workerCgroup`` default to this host's hierarchy and this
  ## process's cgroup; they are parameters so the decision can be exercised
  ## against a prepared tree.
  result = CallerPlacement(callerCgroup: callerCgroup,
    workerCgroup: workerCgroup)
  if root.len == 0 or callerCgroup.len == 0 or workerCgroup.len == 0:
    result.kind = cpkNotApplicable
    return
  if callerCgroup == workerCgroup:
    result.kind = cpkAlreadyThere
    return
  let failure = joinCgroup(root, callerCgroup)
  if failure.len == 0:
    result.kind = cpkMoved
    result.workerCgroup = callerCgroup
    return
  let difference = limitDifference(effectiveCgroupLimits(root, callerCgroup),
    effectiveCgroupLimits(root, workerCgroup))
  if difference.len == 0:
    result.kind = cpkSameLimits
    result.detail = failure
  else:
    result.kind = cpkRefused
    result.detail = failure & "; " & difference

proc declineMessage*(placement: CallerPlacement): string =
  ## What the client is told when the daemon declines a request because it
  ## cannot run it under the caller's limits.
  "daemon-hosted build declined: the daemon cannot run it under the " &
    "caller's resource limits (caller cgroup " & placement.callerCgroup &
    ", daemon worker cgroup " & placement.workerCgroup & "): " &
    placement.detail & "; build in the caller's process instead"

proc logText*(placement: CallerPlacement): string =
  ## One ``key=value`` fragment for the daemon log.
  "cgroupPlacement=" & ($placement.kind)[3 .. ^1] &
    " callerCgroup=" & placement.callerCgroup &
    " workerCgroup=" & placement.workerCgroup &
    (if placement.detail.len > 0: " detail=" & placement.detail else: "")
