## M73 Phase 4 — Install-audit module.
##
## Walks every hookTable entry from ``windows_interpose.nim`` after
## ``installAllHooks`` returns and verifies that the first five bytes of
## each ``kernel32!<spec.name>`` target now contain an inline-hook
## signature — either the 5-byte ``E9 ?? ?? ?? ??`` overwrite-mode JMP
## rel32, or the two-short-jump hot-patch sequence ``EB F9`` at the
## target with ``E9 ?? ?? ?? ??`` in the 5 bytes upstream of the target.
##
## A target whose first five bytes don't match either inline shape is
## by definition either:
##   (a) on the IAT-fallback path (the kernel32 body was never patched,
##       so dynlib-resolved callers like Nim's ``{.importc, dynlib:
##       "kernel32".}`` bypass the shim — exactly the M73 bypass class),
##       or
##   (b) was uninstalled by a co-resident party.
##
## Either case is an acceptance issue. The Phase-4 contract is that
## ``repro_monitor_shim_audit_failures()`` returns zero on every
## supported Windows version exercised by CI.
##
## Pattern decoding rationale, cross-referenced against
## ``codetracer-native-recorder/ct_inline_hook/install_windows.c``:
##
##   Overwrite mode (CT_INSTALL_MODE_OVERWRITE, the common path) writes
##   exactly one 5-byte instruction at ``target``:
##
##     E9 disp32   ; jmp rel32 to the hook
##
##   See ``install_windows.c`` around the ``CT_INSTALL_MODE_OVERWRITE``
##   tag for the byte layout.
##
##   Hot-patch mode (CT_INSTALL_MODE_HOTPATCH, used when the prologue
##   begins with ``8B FF`` `mov edi, edi` preceded by 5x ``CC`` NOP
##   padding) writes:
##
##     target - 5 : E9 disp32     ; jmp rel32 to the hook
##     target + 0 : EB F9          ; jmp -7 back to the long jump
##
##   The two bytes at ``target+2..target+4`` are left unchanged from the
##   original prologue. See ``install_windows.c`` around
##   ``CT_INSTALL_MODE_HOTPATCH`` for the layout (lines that write
##   ``0xE9`` upstream then ``0xEB`` + ``back_disp`` at target).
##
## Why a separate module:
##
##   The Phase-1/2/3 install backend (``windows_interpose.nim``) is
##   already 1700+ lines. Isolating the audit pass in its own module
##   keeps the per-API trampoline + snoop callback wiring uncluttered,
##   matches the milestone-document directive to live in
##   ``install_audit.nim``, and lets Phase 5's hookTable extensions
##   add new specs without touching audit logic.
##
## Lock discipline:
##
##   The audit pass is invoked synchronously during
##   ``repro_monitor_shim_init`` (before that proc returns), under the
##   shim-init mutex that ``windows_interpose`` already holds. The
##   module-level state ``gAuditFailureCount`` / ``gAuditFailingNames``
##   is written exactly once during that critical section and read
##   without a lock by ``repro_monitor_shim_audit_failures`` /
##   ``repro_monitor_shim_audit_failing_names`` afterwards. This is the
##   read-after-init pattern Monitor-Hook-Shim.md §"Install Backend
##   Requirement" mandates: the accessor MUST NOT contend with the
##   snoop hot-path, so it takes no lock at all. Callers from a thread
##   other than the init thread observe a fully-written snapshot
##   because the init thread released the shim-init mutex before
##   returning from ``repro_monitor_shim_init`` (acquire-release
##   semantics flush the writes).

when not defined(windows):
  {.error: "repro_monitor_shim/install_audit is Windows-only".}

{.push raises: [].}

# ---------------------------------------------------------------------------
# Module-level state. Written once by ``runInstallAudit`` (called
# synchronously during shim init). Read by the two accessors after init
# completes. No lock is taken on the read path — see "Lock discipline"
# in the module header.
#
# The "G" prefix mirrors ct_interpose convention ("gMcrXxx") so a
# reader can grep for "g[A-Z]" to find module-global state.

var gAuditFailureCount {.global.}: int = 0
  ## Total number of hookTable entries whose first-five-bytes audit did
  ## NOT match an inline-hook signature. Zero is the expected post-init
  ## value on every supported Windows version.

var gAuditFailingNames {.global.}: seq[string] = @[]
  ## Names of the failing hooks, in hookTable iteration order. Diagnostic-
  ## only: the snoop chain's correctness does not depend on this list.

var gAuditRan {.global.}: bool = false
  ## Set to ``true`` once ``runInstallAudit`` has been called. The
  ## accessors below use this to distinguish "no failures because audit
  ## already ran and everything passed" from "no failures because audit
  ## hasn't run yet". For diagnostic UI only; the accessor return value
  ## isn't conditioned on it.

# ---------------------------------------------------------------------------
# Pattern classification.
#
# The classifier inspects ``target[0..4]`` (the 5 bytes at the function
# entry) and, for the hot-patch shape, also ``target[-5..-1]`` (the
# upstream padding region). Returns ``true`` if the bytes match either
# inline shape ct_inline_hook can produce.

type
  InstallShape = enum
    isOverwrite,    ## target[0..4] == E9 ?? ?? ?? ??
    isHotpatch,     ## target[0..1] == EB F9; target[-5..-1] == E9 ?? ?? ?? ??
    isNeither       ## first five bytes don't match either inline shape

proc classifyInstallShape*(target: pointer): InstallShape =
  ## Read the first 5 bytes at ``target`` (and, for the hot-patch
  ## detection arm, the 5 bytes upstream) and classify which inline-hook
  ## shape — if any — is currently in place.
  ##
  ## SAFETY: every kernel32 export resolved via ``GetProcAddress`` lives
  ## inside kernel32's mapped image and the bytes around it are part of
  ## the same executable section, so reading 5 bytes upstream is in-
  ## bounds. We do not need to guard with VirtualQuery for the audit's
  ## current scope (kernel32 exports only). If a future caller hands us
  ## a target near a page boundary outside kernel32's text section,
  ## extending the audit to query page protections becomes necessary.
  if target == nil:
    return isNeither
  let p = cast[ptr UncheckedArray[uint8]](target)

  # Overwrite mode: first byte is E9 (5-byte JMP rel32 opcode). Bytes
  # 1..4 are the 32-bit signed displacement — any value is acceptable
  # because the install primitive will have chosen disp = (hook -
  # (target + 5)).
  if p[0] == 0xE9'u8:
    return isOverwrite

  # Hot-patch mode: first byte is EB (2-byte short JMP opcode), second
  # byte is F9 (signed -7 displacement — back to the start of the
  # upstream 5-byte JMP). The upstream 5 bytes must also begin with
  # E9 so the short-jump lands on the long-jump rather than data.
  #
  # The 5-byte upstream check defends against false positives: a target
  # whose original prologue happened to begin with EB F9 (uncommon but
  # theoretically possible) without the E9 long-jump upstream would
  # NOT be a hot-patch install.
  if p[0] == 0xEB'u8 and p[1] == 0xF9'u8:
    let upstream = cast[ptr UncheckedArray[uint8]](
      cast[uint](target) - 5)
    if upstream[0] == 0xE9'u8:
      return isHotpatch

  isNeither

# ---------------------------------------------------------------------------
# Audit entry point. Called from ``windows_interpose.nim`` directly
# after ``installAllHooks`` returns. The caller has already resolved
# each hookTable spec's kernel32 address (so it can use the same
# ``GetModuleHandleA`` + ``GetProcAddress`` pair already imported there)
# and passes us the ``(name, address)`` pairs.
#
# We accept a ``dbgFn`` callback so the audit's log lines route through
# the existing shim-debug channel (OutputDebugStringA + the
# REPRO_MONITOR_SHIM_DEBUG_LOG file) without us importing those
# primitives here.

type AuditDbgFn* = proc (msg: cstring) {.nimcall, raises: [].}

proc runInstallAudit*(targets: openArray[(string, pointer)];
                      dbgFn: AuditDbgFn) =
  ## Walk ``targets`` (the post-install ``(name, kernel32-address)``
  ## pairs from windows_interpose's hookTable) and classify each. On
  ## failure, append the name to ``gAuditFailingNames`` and increment
  ## ``gAuditFailureCount``. Emit one per-failure log line plus a
  ## final summary line per Monitor-Hook-Shim.milestones.org §"M73
  ## Phase 4".
  ##
  ## Idempotent on re-entry: a second call clears the prior state
  ## before re-walking. This matters for the test harness which can
  ## call ``repro_monitor_shim_init`` twice in a single process (the
  ## second call is otherwise a no-op, so the audit also no-ops if
  ## ``gAuditRan`` is already true — but we re-run to keep the test's
  ## post-init invariant intact regardless).
  gAuditFailureCount = 0
  gAuditFailingNames.setLen(0)

  let total = targets.len
  var passed = 0
  for (name, addr0) in targets:
    if addr0 == nil:
      # GetProcAddress returned nil. The install backend would already
      # have logged the failure; we count it as an audit failure too
      # so the count reflects the install-backend's actual coverage.
      inc gAuditFailureCount
      gAuditFailingNames.add(name)
      dbgFn(cstring("[repro_monitor_shim] install-audit FAIL " &
        name & "\n"))
      continue
    let shape = classifyInstallShape(addr0)
    case shape
    of isOverwrite, isHotpatch:
      inc passed
    of isNeither:
      inc gAuditFailureCount
      gAuditFailingNames.add(name)
      dbgFn(cstring("[repro_monitor_shim] install-audit FAIL " &
        name & "\n"))

  if gAuditFailureCount == 0:
    dbgFn(cstring("[repro_monitor_shim] install-audit OK: " &
      $passed & "/" & $total & " hooks confirmed inline\n"))
  else:
    dbgFn(cstring("[repro_monitor_shim] install-audit FAIL summary: " &
      $gAuditFailureCount & " hook(s) not in inline state\n"))

  gAuditRan = true

# ---------------------------------------------------------------------------
# Control-ABI exports. C-callable so test fixtures can ``LoadLibraryW``
# the shim DLL and ``GetProcAddress`` these by name.

proc repro_monitor_shim_audit_failures*(): cint
    {.exportc, dynlib, cdecl.} =
  ## Returns the count of hookTable entries whose first-5-bytes audit
  ## did NOT find an inline-hook signature (overwrite or hot-patch).
  ## Zero is the expected value on every supported Windows version
  ## exercised by CI. A non-zero value indicates either (a) a kernel32
  ## function's prologue was not relocatable by ct_inline_hook (the
  ## install fell through to the IAT fallback) or (b) the function was
  ## uninstalled by another party. Diagnostic-only; the snoop chain's
  ## correctness does not depend on this accessor.
  cint(gAuditFailureCount)

proc repro_monitor_shim_audit_failing_names*(buf: ptr char;
                                             bufLen: cint): cint
    {.exportc, dynlib, cdecl.} =
  ## Writes a NUL-separated list of failing hook names into ``buf``
  ## (capacity ``bufLen``), terminated by a final NUL. Returns the
  ## total bytes that WOULD have been written had ``bufLen`` been
  ## sufficient (snprintf-style). Returns 0 when no failures.
  ##
  ## On-wire format: ``"NameA\0NameB\0NameC\0\0"``. Two trailing NULs
  ## mark end-of-list (the same convention Windows uses for
  ## ``REG_MULTI_SZ`` and the environment block, so callers familiar
  ## with the Win32 idiom can parse it without a separate length
  ## parameter). When there are zero failures the function returns 0
  ## and writes nothing — callers should special-case that with a
  ## ``repro_monitor_shim_audit_failures() == 0`` check before reading
  ## the buffer.
  ##
  ## SAFETY: the names live in ``gAuditFailingNames``, a module-global
  ## populated once during init. After init no one mutates it, so
  ## reading the strings here without a lock is safe (see "Lock
  ## discipline" in the module header).
  if gAuditFailingNames.len == 0:
    return 0
  # Compute total required bytes first (snprintf shape: return the
  # would-have-been-written length, possibly truncated in the actual
  # write).
  var needed = 0
  for name in gAuditFailingNames:
    needed += name.len + 1  # +1 for the NUL after each name
  needed += 1               # +1 for the final NUL list terminator

  if buf == nil or bufLen <= 0:
    return cint(needed)

  # Write up to bufLen bytes, leaving room for the trailing NUL.
  let cap = int(bufLen)
  var pos = 0
  let dst = cast[ptr UncheckedArray[char]](buf)
  block writeOut:
    for name in gAuditFailingNames:
      # Write name bytes
      for i in 0 ..< name.len:
        if pos >= cap - 1:
          break writeOut
        dst[pos] = name[i]
        inc pos
      # Write trailing NUL after name
      if pos >= cap - 1:
        break writeOut
      dst[pos] = '\0'
      inc pos
    # Write final NUL list terminator
    if pos < cap:
      dst[pos] = '\0'
      inc pos
  # Always NUL-terminate the buffer (even on truncation) so callers
  # using strlen-style reads don't run off the end.
  if cap > 0:
    dst[cap - 1] = '\0'
  cint(needed)

{.pop.}
