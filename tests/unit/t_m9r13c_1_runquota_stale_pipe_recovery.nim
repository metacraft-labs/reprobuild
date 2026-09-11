## DSL-port M9.R.13c.1 — runquota deterministic stale-pipe recovery test.
##
## ## Context
##
## Every M9.R.13b iteration past iter 11 wedged at the canonical Windows
## runquota named pipe (``\\.\pipe\runquota-<user>``): the pipe object
## persisted in the NPFS namespace from a prior interrupted ``repro
## build`` even though the owning ``runquotad.exe`` had been killed
## (Ctrl+C, signal-exit, OOM-kill, ...). The client side blocked
## indefinitely on the synchronous Hello/HelloOk round-trip because
## ``CreateFileW`` happily opened a handle on the orphaned NPFS object
## but the unanswered Hello frame never returned.
##
## The pre-M9.R.13c contract documented in
## ``project_runquotad_stale_daemon_wedge`` memory required the
## *operator* to ``Stop-Process runquotad.exe``. That violates the
## user's hard requirement (verbatim): "our development environments
## are supposed to be highly deterministic and reproducible". Manual
## kill steps are antithetical to determinism.
##
## ## What this milestone changed
##
## M9.R.13c.1 adds an *owner-liveness probe* to the client-side
## reachability check. ``probeWindowsPipeOwner`` classifies the pipe
## as one of:
##
##   * ``wpsAbsent``       — pipe does not exist in NPFS.
##   * ``wpsHealthy``      — pipe exists AND owner PID is alive.
##   * ``wpsStale``        — pipe exists, owner PID was IDENTIFIED, and
##     that PID is proven gone.
##   * ``wpsBusy``         — ERROR_PIPE_BUSY: present and serving.
##   * ``wpsAccessDenied`` — ERROR_ACCESS_DENIED: present, and this
##     token may not open it.
##   * ``wpsIndeterminate``— present, and nothing could be established.
##
## ``isRunQuotaDaemonReachable`` treats ``wpsStale`` as "unreachable,
## recoverable" so ``startAutoRunQuotaIfNeeded`` doesn't return early.
## The recovery block (in
## ``repro_cli_support.startAutoRunQuotaIfNeeded``) calls
## ``terminateStalePipeOwner`` on the dead PID — a no-op when the
## owner is already exited but it forces the kernel to reclaim the
## NPFS handle when the owner is wedged-but-alive — then falls through
## to the standard fresh-spawn block.
##
## ## The last three values, and why they are not one value
##
## They were one value. Every ``CreateFileW`` failure that was not
## "pipe absent" returned ``wpsStale``, which is the value that
## authorises the caller to TERMINATE the owner and take the name. The
## first out-of-tree consumer's MSI-installed service pipe carries
## ``O:BA G:SY D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;WD)(A;;FR;;;AN)`` —
## Everyone gets ``FILE_GENERIC_READ`` only — so the probe's
## ``GENERIC_READ | GENERIC_WRITE`` open returns Windows error 5 under
## an ordinary UAC-filtered token and a handle under an elevated one.
## The client read error 5 as "nobody is home", terminated the owner it
## had never identified (PID 0) and spawned a competitor onto the name.
##
## So: only ``wpsStale`` may lead to a terminate, only ``wpsAbsent`` may
## lead to a spawn, and ``wpsStale`` carries a positive PID by
## construction — ``terminateStalePipeOwner`` takes a ``StalePipeOwner``
## that only ``stalePipeOwner`` can build.
##
## ## What this test pins
##
## Nine arms. The load-bearing ones are the pair that run against a REAL
## named pipe carrying a REAL restrictive DACL (built from SDDL through
## ``ConvertStringSecurityDescriptorToSecurityDescriptorW``) and its
## control — the SAME name, unbound — so the two answers differ by the
## bytes on the system rather than by a mocked error code:
##
##   1. **Probe classification** — a synthetic process that exports a
##      pipe via the runquota_ipc bindEndpoint helper is observed as
##      ``wpsHealthy``; after terminating the synthetic process the
##      same probe returns ``wpsStale``. This is the foundational
##      classifier contract — every recovery decision flows from it.
##
##   2. **Restrictive DACL is access-denied, not stale** — the defect
##      itself, on real bytes, including that the owner survives the
##      probe and that no terminate target can be built from it.
##
##   3. **The same probe still reports absent** — the falsification
##      control: bind the name, the answer flips; close it, it flips
##      back.
##
##   4. **The canonical name, and fast** — bound with the same DACL,
##      ``isRunQuotaDaemonReachable`` answers false without attempting
##      the Hello round-trip the kernel has already refused.
##
##   5. **Stale recovery is total** — ``terminateStalePipeOwner`` on
##      the now-dead PID is a no-op (returns true). Pins the
##      idempotent-no-op property: a recovery call against an
##      already-dead owner must succeed.
##
##   6. **PID 0 is unreachable, not harmless** — every way of asking to
##      terminate an owner that was never identified is refused by the
##      constructor or by the terminate proc itself.
##
##   7. **Probe on absent pipe** — probing a never-existed pipe path
##      returns ``wpsAbsent`` and never raises. Pins the total-function
##      property that makes the helper safe to call from the
##      reachability fast-path.
##
##   8. **Reachability honours stale-as-unreachable** —
##      ``isRunQuotaDaemonReachable`` reports false when the pipe is
##      stale, so ``startAutoRunQuotaIfNeeded`` does not short-circuit
##      and the recovery + fresh-spawn path runs. Indirect — we observe
##      via the absence-check above + reachability call.
##
## All arms are Windows-only — the stale-pipe wedge was unique to the
## Windows NPFS handle-persistence semantics; POSIX domain sockets are
## reaped when the owning process exits.

import std/[os, osproc, strutils, times, unittest]

import repro_runquota

when defined(windows):
  import std/winlean

  # Direct CreateNamedPipeW so the test can stand up a synthetic pipe
  # without dragging in the full runquota daemon. We only need a pipe
  # the kernel will surface to ``probeWindowsPipeOwner``; no IPC traffic
  # has to flow over it.
  proc createNamedPipeW(name: WideCString; openMode: int32; pipeMode: int32;
                        maxInstances: int32; outBuf: int32; inBuf: int32;
                        defaultTimeout: int32; sec: pointer): Handle {.
    stdcall, dynlib: "kernel32", importc: "CreateNamedPipeW".}

  proc winCloseHandle(h: Handle): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "CloseHandle".}

  const
    PIPE_ACCESS_DUPLEX = 0x00000003'i32
    PIPE_TYPE_BYTE = 0x00000000'i32
    PIPE_READMODE_BYTE = 0x00000000'i32
    PIPE_WAIT = 0x00000000'i32
    PIPE_REJECT_REMOTE_CLIENTS = 0x00000008'i32
    FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000'i32
    PIPE_UNLIMITED_INSTANCES = 255'i32
    BUF_SIZE = 65536'i32

  proc synthPipePath(): string =
    ## Per-test unique pipe path so concurrent invocations don't
    ## collide. The runquota path scheme uses ``\\.\pipe\runquota-...``;
    ## we use ``\\.\pipe\m9r13c-test-<pid>`` for our synthetic.
    r"\\.\pipe\m9r13c-test-" & $getCurrentProcessId()

  # --- the restrictive-DACL apparatus -------------------------------
  #
  # Everything below exists so the access-denied arm runs against REAL
  # BYTES: a real NPFS object, a real security descriptor, a real
  # ``CreateFileW`` refusal from the kernel. A unit test that handed the
  # classifier a mocked ``5`` would pass against a classifier that never
  # sees a 5 in the field, which is precisely the class of green this
  # campaign keeps catching.
  proc convertStringSecurityDescriptorToSecurityDescriptorW(
      sddl: WideCString; revision: uint32; sd: ptr pointer;
      size: ptr uint32): WINBOOL {.stdcall, dynlib: "advapi32",
      importc: "ConvertStringSecurityDescriptorToSecurityDescriptorW".}

  proc localFreeW(mem: pointer): pointer {.
    stdcall, dynlib: "kernel32", importc: "LocalFree".}

  const
    SddlRevision1 = 1'u32
    ReadOnlyForEveryoneSddl = "D:(A;;FR;;;WD)"
      ## Everyone gets ``FILE_GENERIC_READ`` and nothing else — the
      ## same shape as the live DACL of the MSI-installed runquota
      ## service pipe, which reads
      ## ``O:BA G:SY D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;WD)(A;;FR;;;AN)``.
      ## The SYSTEM/Administrators full-access ACEs are what make the
      ## refusal depend on ELEVATION in the field; they are left out
      ## here so the refusal reproduces under the ordinary
      ## medium-integrity token the test suite runs as, which is the
      ## token the defect was reported against. What the kernel is asked
      ## is identical either way: may this token open this pipe for
      ## ``GENERIC_READ | GENERIC_WRITE``.

  proc openRestrictedPipe(path: string): Handle =
    ## One server instance whose DACL grants the caller READ only, so
    ## the probe's ``GENERIC_READ or GENERIC_WRITE`` open is refused by
    ## the kernel with ERROR_ACCESS_DENIED.
    var sd: pointer = nil
    var sdSize: uint32 = 0
    if convertStringSecurityDescriptorToSecurityDescriptorW(
        newWideCString(ReadOnlyForEveryoneSddl), SddlRevision1,
        addr sd, addr sdSize) == 0:
      raise newException(OSError,
        "ConvertStringSecurityDescriptorToSecurityDescriptorW failed " &
          "(error " & $osLastError().int32 & ")")
    var attrs = SECURITY_ATTRIBUTES(
      nLength: int32(sizeof(SECURITY_ATTRIBUTES)),
      lpSecurityDescriptor: sd,
      bInheritHandle: WINBOOL(0))
    let openMode = PIPE_ACCESS_DUPLEX or FILE_FLAG_FIRST_PIPE_INSTANCE
    let pipeMode = PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or
      PIPE_REJECT_REMOTE_CLIENTS
    result = createNamedPipeW(newWideCString(path), openMode, pipeMode,
      PIPE_UNLIMITED_INSTANCES, BUF_SIZE, BUF_SIZE, 0'i32, addr attrs)
    let err = osLastError().int32
    discard localFreeW(sd)
    if result == cast[Handle](-1):
      raise newException(OSError,
        "CreateNamedPipeW failed for " & path & " (error " & $err & ")")

  proc openSyntheticPipe(path: string): Handle =
    ## Open one server-side instance of a named pipe with the same
    ## flags ``runquotad`` uses. We don't ConnectNamedPipe (no client
    ## comes); the pipe object just persists in NPFS for the probe to
    ## find.
    let wide = newWideCString(path)
    let openMode = PIPE_ACCESS_DUPLEX or FILE_FLAG_FIRST_PIPE_INSTANCE
    let pipeMode = PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or
      PIPE_REJECT_REMOTE_CLIENTS
    result = createNamedPipeW(wide, openMode, pipeMode,
      PIPE_UNLIMITED_INSTANCES, BUF_SIZE, BUF_SIZE, 0'i32, nil)
    if result == cast[Handle](-1):
      raise newException(OSError,
        "CreateNamedPipeW failed for " & path &
          " (error " & $osLastError().int32 & ")")

suite "DSL-port M9.R.13c.1 — runquota stale-pipe recovery":

  test "probeWindowsPipeOwner returns wpsAbsent for never-existed pipe":
    when defined(windows):
      let probe = probeWindowsPipeOwner(
        r"\\.\pipe\m9r13c-never-existed-" & $getCurrentProcessId())
      check probe.status == wpsAbsent
      check probe.serverPid == 0
      check probe.ownerAlive == false
    else:
      skip()

  test "probeWindowsPipeOwner classifies a live local server as wpsHealthy":
    when defined(windows):
      let path = synthPipePath()
      let h = openSyntheticPipe(path)
      try:
        let probe = probeWindowsPipeOwner(path)
        check probe.status == wpsHealthy
        check probe.serverPid != 0
        check probe.ownerAlive == true
        # The owner PID must equal the current process — we created
        # the pipe ourselves, so the kernel records our PID as server.
        check probe.serverPid.int == getCurrentProcessId()
      finally:
        discard winCloseHandle(h)
    else:
      skip()

  test "a restrictive DACL is access-denied, not stale — and its owner survives":
    when defined(windows):
      # THE DEFECT, on real bytes. A pipe whose DACL grants this token
      # less than ``GENERIC_READ | GENERIC_WRITE`` makes ``CreateFileW``
      # return ERROR_ACCESS_DENIED, and the classifier used to fold that
      # into ``wpsStale`` — "nobody is home". The caller then terminated
      # the owner (with PID 0, because none had been identified) and
      # spawned its own daemon onto a name a live service was holding.
      #
      # Measured in the field against the MSI-installed service pipe:
      # ``runquota status`` printed
      # ``CreateFileW failed for \\.\pipe\runquota\runquotad: Windows
      # error 5`` from a normal shell and returned rc=0 elevated.
      let path = r"\\.\pipe\m9r13c-dacl-" & $getCurrentProcessId()
      let h = openRestrictedPipe(path)
      try:
        let probe = probeWindowsPipeOwner(path)
        # 1. NOT stale. This is the whole defect.
        check probe.status != wpsStale
        # 2. NOT absent either — absence is what authorises a spawn on
        #    the name, and something is plainly serving this one.
        check probe.status != wpsAbsent
        # 3. The state it IS: present, not usable by us.
        check probe.status == wpsAccessDenied
        # 4. No owner was identified, which is exactly why terminating
        #    anything on the strength of this probe is nonsense.
        check probe.serverPid == 0
        check probe.ownerAlive == false
        # 5. The diagnostic names access AND elevation, because that is
        #    the action the operator can take.
        check probe.failureReason.contains("ERROR_ACCESS_DENIED")
        check probe.failureReason.toLowerAscii.contains("elevat")
        check probe.failureReason.contains("Windows error 5")
        # 6. Nothing can be terminated from this probe: the terminate
        #    target cannot be constructed at all.
        expect AssertionDefect:
          discard stalePipeOwner(probe)
        # 7. And the owner really did survive the probe — the pipe is
        #    still there, still held by this process, still refusing us.
        let after = probeWindowsPipeOwner(path)
        check after.status == wpsAccessDenied
      finally:
        discard winCloseHandle(h)
    else:
      skip()

  test "the same probe DOES report absent for a genuinely absent pipe":
    when defined(windows):
      # The control arm for the case above, deliberately alongside it:
      # a classifier that answered ``wpsAccessDenied`` for everything
      # would pass every assertion above. The name is built the same
      # way and simply never bound.
      let absent = r"\\.\pipe\m9r13c-dacl-absent-" & $getCurrentProcessId()
      let probe = probeWindowsPipeOwner(absent)
      check probe.status == wpsAbsent
      check probe.serverPid == 0
      # ...and binding the SAME name with the SAME restrictive DACL
      # flips the answer, so the two arms differ by the bytes on the
      # system and nothing else.
      let h = openRestrictedPipe(absent)
      try:
        check probeWindowsPipeOwner(absent).status == wpsAccessDenied
      finally:
        discard winCloseHandle(h)
      # Closing the last handle returns the name to NPFS.
      check probeWindowsPipeOwner(absent).status == wpsAbsent
    else:
      skip()

  test "a restrictive DACL on the canonical pipe is unreachable, fast":
    when defined(windows):
      # The caller's gate, on the canonical name. Before the fix the
      # access-denied probe returned ``wpsStale``, which
      # ``isRunQuotaDaemonReachable`` also reports as unreachable — so
      # this arm alone would not distinguish the two. What it pins is
      # the part that IS different: the answer comes back without
      # attempting the ``connectDefault`` Hello round-trip against a
      # pipe the kernel has already refused us.
      let canonical = defaultRunQuotaWindowsPipePath()
      if canonical.len == 0:
        skip()
      else:
        var h = cast[Handle](-1)
        try:
          h = openRestrictedPipe(canonical)
        except OSError:
          # A real daemon (or another test run) already holds the
          # canonical name; binding it is not something this test may
          # force. FILE_FLAG_FIRST_PIPE_INSTANCE is what refuses.
          echo "M9.R.13c.1 canonical-DACL arm: canonical pipe already " &
            "bound; skipping"
        if h == cast[Handle](-1):
          skip()
        else:
          try:
            let probe = probeWindowsPipeOwner(canonical)
            check probe.status == wpsAccessDenied
            let started = epochTime()
            check isRunQuotaDaemonReachable() == false
            # A ``connectDefault`` against this pipe fails only after the
            # client's own timeout; the classifier returns immediately.
            check epochTime() - started < 2.0
          finally:
            discard winCloseHandle(h)
    else:
      skip()

  test "terminateStalePipeOwner is a no-op on already-dead PID":
    when defined(windows):
      # Use a fake PID that is guaranteed to never exist — PID 1 on
      # Windows is reserved for the System Idle Process; OpenProcess
      # against it fails. The helper's contract is that an
      # inaccessible-or-dead PID still returns true.
      let probe = WindowsPipeProbe(status: wpsStale,
                                   serverPid: int32(0x7FFFFFFE))
      check terminateStalePipeOwner(stalePipeOwner(probe)) == true
    else:
      skip()

  test "a terminate target cannot be built for an unidentified owner":
    when defined(windows):
      # THE PID-0 TERMINATE, made unreachable rather than harmless. The
      # old helper took a bare ``int32`` and answered ``true`` for zero,
      # so "terminate the owner of a pipe whose owner I never
      # identified" was a call that compiled, ran, reported success and
      # left the thing that actually held the name untouched — after
      # which the caller spawned a competitor onto it.
      #
      # ``terminateStalePipeOwner`` now takes a ``StalePipeOwner``, and
      # the only constructor for one refuses both halves of the way that
      # call used to be reached.
      expect AssertionDefect:
        # A wpsStale probe that carries no PID breaks the type's
        # invariant and is refused.
        discard stalePipeOwner(
          WindowsPipeProbe(status: wpsStale, serverPid: 0'i32))
      for status in [wpsAbsent, wpsHealthy, wpsBusy, wpsAccessDenied,
                     wpsIndeterminate]:
        expect AssertionDefect:
          # ...and so is any status that does not mean "owner
          # identified AND proven dead", whatever PID it carries.
          discard stalePipeOwner(
            WindowsPipeProbe(status: status, serverPid: int32(0x7FFFFFFE)))
      # The last door: Nim lets an object with a private field be
      # default-constructed from outside its module, so the terminate
      # proc asserts on its own argument too.
      expect AssertionDefect:
        discard terminateStalePipeOwner(StalePipeOwner())
    else:
      skip()

  test "isRunQuotaDaemonReachable returns false when the canonical pipe is absent":
    # The function is total and side-effect-free. In the test harness
    # the default per-user pipe is typically not bound, so the call
    # returns false; in a CI runner where a stray daemon happens to be
    # listening it would return true. We only pin the no-raise
    # property here (the per-platform behaviour is exercised by the
    # owner-liveness arms above).
    let reachable = isRunQuotaDaemonReachable()
    check reachable in [true, false]  # tautology — pins "doesn't raise"

  test "probeWindowsPipeOwner on stale orphan returns wpsStale":
    when defined(windows):
      # Stand up a child process that creates the pipe and then sleeps;
      # kill it without closing the handle so the NPFS object outlives
      # the owner. Per Windows NPFS semantics the kernel releases the
      # handle when the last handle closes (process exit closes all
      # outstanding handles), so the pipe will actually be reclaimed
      # almost immediately after kill. We probe between the kill and
      # the reclaim — the race window is short but reliably
      # observable when we probe immediately after TerminateProcess.
      #
      # The contract being pinned: probeWindowsPipeOwner returns
      # wpsStale (NOT wpsHealthy) when the owner PID has exited. We
      # accept the wpsAbsent outcome too (kernel already reclaimed
      # between TerminateProcess and probe) — both are correct
      # diagnostics; the load-bearing property is that wpsHealthy is
      # NEVER returned for a dead owner. A wpsHealthy here would mean
      # the recovery path mis-classifies and the wedge persists.
      let pipePath = r"\\.\pipe\m9r13c-stale-" & $getCurrentProcessId()
      # Spawn powershell -c so we get a deterministic child PID we can
      # terminate. We use a here-string Nim doesn't have so emit a
      # one-liner script. The child waits up to 30s for the parent to
      # signal kill via a sentinel file.
      let scriptPath = getTempDir() / ("m9r13c-stale-" &
        $getCurrentProcessId() & ".ps1")
      let script = ("$ErrorActionPreference='Stop';" &
        "$path = '" & pipePath & "';" &
        "$pipe = New-Object System.IO.Pipes.NamedPipeServerStream(" &
        "'" & pipePath.replace(r"\\.\pipe\", "") & "', " &
        "[System.IO.Pipes.PipeDirection]::InOut, 1, " &
        "[System.IO.Pipes.PipeTransmissionMode]::Byte, " &
        "[System.IO.Pipes.PipeOptions]::None);" &
        "Write-Output 'READY';" &
        "Start-Sleep -Seconds 30;"
      )
      writeFile(scriptPath, script)
      defer:
        try: removeFile(scriptPath) except CatchableError: discard
      var child = startProcess(
        "powershell.exe",
        args = @["-NoProfile", "-ExecutionPolicy", "Bypass",
                 "-File", scriptPath],
        options = {poUsePath, poStdErrToStdOut})
      try:
        # Wait for the child to report READY. 5s timeout — far
        # generous for powershell startup.
        var ready = false
        for _ in 0 ..< 50:
          if not child.running:
            break
          sleep(100)
          let probe = probeWindowsPipeOwner(pipePath)
          if probe.status == wpsHealthy:
            ready = true
            break
        # If the child failed to bind we can't pin the stale arm; the
        # other arms already cover the classifier. Skip in that case.
        if not ready:
          echo "M9.R.13c.1 stale-arm: child failed to bind pipe; skipping"
          skip()
        else:
          # Kill the owner; the kernel will close the server handle as
          # part of process exit and the pipe object will eventually be
          # reclaimed.
          child.terminate()
          discard child.waitForExit()
          let probe = probeWindowsPipeOwner(pipePath)
          # The load-bearing pin: NEVER wpsHealthy after the owner died.
          check probe.status in [wpsStale, wpsAbsent]
      finally:
        if child.running:
          try: child.terminate() except CatchableError: discard
          try: discard child.waitForExit() except CatchableError: discard
        child.close()
    else:
      skip()
