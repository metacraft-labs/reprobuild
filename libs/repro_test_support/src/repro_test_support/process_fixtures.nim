## Fixtures a test file acquires are released by the PROCESS that acquired
## them, whichever of the file's cases that process ran.
##
## WHY THIS EXISTS. The suite runner spends one process per case
## (``--run "<suite>::<test>"``) and one more for its ``--list-json`` probe,
## and every one of those processes executes the file's module-level code.
## A file that acquired a fixture at module scope (or lazily, from any case)
## and released it only in a final "teardown" CASE therefore leaked it from
## every process but the teardown's own: one ``repro-f2-<pid>-vol<N>``
## directory per discovered volume per process, a ``runquotad`` re-parented
## to init per process, and so on — 144 directories from one runner-alone
## run of ``t_fs_facts_conformance`` (36 cases x 4 volumes, measured at
## reprobuild 6aa91f75). A teardown that exists only as a case cannot run in
## most of the processes that need it.
##
## So release is attached to the process, not to a case:
##
## * ``releaseDirAtProcessExit(path)`` removes ``path`` (recursively) when
##   this process exits. Register BEFORE creating the directory, so there is
##   no window in which it is on disk and nobody owns it.
## * ``terminateAtProcessExit(pid)`` (POSIX) stops a child this process
##   started — ``SIGTERM``, then ``SIGKILL`` if it has not exited within two
##   seconds — and reaps it. It signals nothing once the child has been
##   reaped, so a recycled pid is never hit.
##
## A ``fork``ed child that exits releases nothing: the fixtures belong to the
## process that registered them.
##
## Releases run last-registered-first, at most once, however the process
## ends — passing, failing a ``check``, an unhandled exception, ``quit`` —
## anything that reaches ``exit``. Pair them with LAZY acquisition (create
## the fixture on first use from inside a case, not at module scope), so the
## ``--list-json`` probe and the cases that never touch the fixture create
## nothing at all.
##
## WHY THE STATE IS NOT IN NIM-MANAGED MEMORY. Under ``--mm:orc`` the
## compiler destroys EVERY module's heap-backed globals — strings, seqs,
## refs, closures — at the end of the main module's top-level code, which is
## BEFORE any exit hook runs. Read in the generated C at reprobuild 6aa91f75
## (the CodeTracer Nim fork 2.3.1): the main module's init ends with
## ``eqdestroy`` calls for its own globals and for this module's. The
## destructors free the payload without clearing the variable, so a hook
## that reads such a global usually SEES the old value and only sometimes
## crashes, which is what made the hazard easy to measure wrongly: the first
## version of this module kept its releases in a ``seq`` of closures, passed
## a simple experiment, and then died with ``SIGSEGV`` at exit in 23 cases of
## the CAS-store suites once their allocations reused the freed buffer.
## (Several test files carried a comment saying the same thing about their
## own ``addExitProc`` closures; that comment was right.) The registry below
## is therefore a C-heap array of plain values: a ``ptr``, ``int``s and C
## string copies, none of which has a destructor, so all of it is still
## there when the hook runs.
##
## WHY THE HOOK IS THE C RUNTIME'S ``atexit``, NOT ``std/exitprocs``. Both
## unittest implementations in this tree install a protocol exit hook, and
## the ``ct_test_unittest_parallel`` shim ``quit``s from inside it.
## ``std/exitprocs`` runs every Nim exit proc from ONE ``atexit`` entry, so
## a ``quit`` inside one of them abandons the rest of that list: measured at
## reprobuild 6aa91f75 on Linux, an ``addExitProc`` registered at module
## scope did NOT run under the shim in ``--list-json`` or ``--run`` mode. A
## separate ``atexit`` entry is not part of that list, and the nested
## ``exit`` goes on to run it (the same measurement: it ran in every mode,
## under both the shim and the protocol-carrying ``std/unittest``). So a
## release registered here runs whether the fixture was acquired at module
## scope or in a case body, under either unittest.
##
## WHAT THIS CANNOT COVER. A process killed outright (``SIGKILL``, the
## runner's per-case timeout escalation) runs no exit handler of any kind.
##
## ``tests/integration/t_when_each_case_runs_alone_no_fixture_outlives_its_process``
## checks the outcome from outside, the way the runner runs a test file.

import std/os

when defined(posix):
  import std/posix
  from std/sysrand import urandom

from repro_core/paths import extendedPath

type
  ReleaseKind = enum
    rkRemoveDir
    rkTerminate

  Release = object
    ## Plain values only: see the module header.
    kind: ReleaseKind
    pid: int
    path: cstring      ## a C-heap copy, never freed

proc c_malloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc c_realloc(p: pointer; size: csize_t): pointer {.
  importc: "realloc", header: "<stdlib.h>".}
proc c_atexit(handler: proc () {.noconv.}): cint {.
  importc: "atexit", header: "<stdlib.h>".}

var releases: ptr UncheckedArray[Release] = nil
var releaseCount = 0
var releaseCapacity = 0
var hookInstalled = false
var ownerPid = 0      ## the process that installed the hook; see below

proc cCopy(s: string): cstring =
  let p = cast[ptr UncheckedArray[char]](c_malloc(csize_t(s.len + 1)))
  if p == nil:
    raise newException(OutOfMemDefect, "malloc failed for a fixture path")
  if s.len > 0:
    copyMem(addr p[0], unsafeAddr s[0], s.len)
  p[s.len] = '\0'
  cast[cstring](p)

when defined(posix):
  proc terminateAndReap(pid: int) =
    ## Signal ``pid`` only while it is provably this process's UNREAPED
    ## child. A child that exited but was not reaped is a zombie and keeps
    ## its pid reserved; once it has been reaped (here, by ``osproc``, or by
    ## a case), the kernel may hand the number to an unrelated process, and
    ## signalling it would kill a stranger. ``waitpid`` answers ``ECHILD``
    ## for any pid that is not an unreaped child of this process, so that
    ## question comes before every signal.
    let child = Pid(pid)
    var status: cint
    if waitpid(child, status, WNOHANG) != 0:
      return                          # reaped just now, or not ours
    if posix.kill(child, SIGTERM) != 0:
      return
    for _ in 0 ..< 100:
      if waitpid(child, status, WNOHANG) != 0:
        return                        # reaped
      sleep(20)
    # Still our unreaped child after two seconds, so the pid is still its.
    discard posix.kill(child, SIGKILL)
    discard waitpid(child, status, 0)

proc runRelease(r: Release) =
  case r.kind
  of rkRemoveDir:
    removeDir(extendedPath($r.path))
  of rkTerminate:
    when defined(posix):
      terminateAndReap(r.pid)

proc releaseProcessFixtures*() =
  ## Run every release registered so far, last-registered-first, and forget
  ## them. Called at process exit; callable earlier, and idempotent — each
  ## release runs once.
  while releaseCount > 0:
    dec releaseCount
    let r = releases[releaseCount]
    try:
      runRelease(r)
    except CatchableError as err:
      # Keep going: one stubborn fixture must not strand the others. Say so
      # on stderr, because at exit there is no case left to fail.
      try:
        stderr.writeLine("repro_test_support/process_fixtures: releasing " &
          (if r.kind == rkRemoveDir: $r.path else: "pid " & $r.pid) &
          " at process exit failed: " & err.msg)
      except CatchableError:
        discard

when compileOption("exceptions", "goto"):
  proc nimErrorFlag(): ptr bool {.importc: "nimErrorFlag", nodecl.}
    ## The goto-exceptions runtime's "an exception is in flight" flag (see
    ## ``system/excpt.nim``). ``nodecl``: every module that can raise already
    ## carries the C definition, and this one can.

proc releaseAtExitHandler() {.noconv.} =
  # AN UNHANDLED EXCEPTION EXITS WITH THE ERROR FLAG STILL SET. Under goto
  # exceptions (the C backend's default) the runtime reports the exception
  # and calls ``exit(1)`` without clearing it, and every Nim call checks that
  # flag on return: ``removeDir`` would bail out at its first internal call
  # and remove nothing. Measured at reprobuild 6aa91f75: a directory
  # registered here survived an unhandled exception at module scope until
  # the flag was cleared for the duration of the release.
  when compileOption("exceptions", "goto"):
    let flag = nimErrorFlag()
    let pending = flag[]
    flag[] = false
  # A ``fork``ed child inherits both this ``atexit`` entry and the list. Its
  # exit must not remove its parent's directories or signal its parent's
  # children, so only the process that registered them releases them.
  if getCurrentProcessId() == ownerPid:
    releaseProcessFixtures()
  when compileOption("exceptions", "goto"):
    flag[] = pending

proc register(r: Release) =
  if not hookInstalled:
    if c_atexit(releaseAtExitHandler) != 0:
      raise newException(OSError,
        "atexit refused to register the fixture release hook")
    hookInstalled = true
    ownerPid = getCurrentProcessId()
  if releaseCount == releaseCapacity:
    let capacity = max(8, releaseCapacity * 2)
    let grown = c_realloc(releases, csize_t(capacity * sizeof(Release)))
    if grown == nil:
      raise newException(OutOfMemDefect, "realloc failed for the release list")
    releases = cast[ptr UncheckedArray[Release]](grown)
    releaseCapacity = capacity
  releases[releaseCount] = r
  inc releaseCount

proc releaseDirAtProcessExit*(path: string) =
  ## Remove ``path`` (recursively) when this process exits. Call it before
  ## creating ``path``; a directory that was never created is not an error.
  if path.len == 0:
    return
  register(Release(kind: rkRemoveDir, path: cCopy(path)))

when defined(posix):
  proc terminateAtProcessExit*(pid: int) =
    ## Stop and reap child ``pid`` when this process exits, unless it has
    ## exited already. Register it right after starting the child.
    if pid <= 0:
      return
    register(Release(kind: rkTerminate, pid: pid))

when defined(posix):
  proc shortSocketDirAtProcessExit*(tag: string): string =
    ## A fresh owner-only (mode 0700) directory DIRECTLY under
    ## ``/tmp``, for the Unix-domain sockets a test binds or hands to a
    ## process it starts, removed when this process exits.
    ##
    ## WHY NOT UNDER THE TEST'S OWN SCRATCH TREE. A socket address must fit
    ## ``sockaddr_un.sun_path`` with its NUL: 108 bytes on Linux, 104 on
    ## macOS — and only 92 where Nim's ``std/net`` binds or dials it, since
    ## ``std/posix`` declares a shorter array on macOS. A scratch tree under
    ## the suite TMPDIR (``~/.cache/reprobuild-test-tmp/<slot>``, ~50 bytes)
    ## or under the checkout's ``build/`` has used most of that before the
    ## test's own nesting and file name, and the bind then fails with
    ## ``socket path too long`` having asserted nothing. Fixture IPC paths
    ## must fit independently of the checkout and TMPDIR length (reprobuild
    ## ``6210412a``). The result here is ``/tmp/<tag><12 hex>``: keep ``tag``
    ## short (a few bytes) so the caller's socket name has the rest.
    ##
    ## It is ``mkdtemp``'s contract, written out: an unpredictable name
    ## (12 hex digits from the OS CSPRNG), created by ``mkdir(2)`` with mode
    ## 0700 — which the umask can only narrow — and a fresh name on
    ## ``EEXIST``, so the directory is owner-only from the instant it exists
    ## and is never one somebody else made. (Not ``mkdtemp`` itself: Nim's
    ## binding names ``<stdlib.h>``, where Darwin does not declare it under
    ## the feature set these binaries compile with.) RunQuota endpoints do NOT
    ## use this — they have their own trust-checked rendezvous,
    ## ``runquotaRendezvousDir``.
    const Hex = "0123456789abcdef"
    for _ in 0 ..< 64:
      var suffix = ""
      for b in urandom(6):
        suffix.add Hex[int(b) shr 4]
        suffix.add Hex[int(b) and 0xf]
      let candidate = "/tmp" / (tag & suffix)
      if posix.mkdir(candidate.cstring, Mode(0o700)) == 0:
        # Ours, by construction: we just created it.
        releaseDirAtProcessExit(candidate)
        return candidate
      if errno != EEXIST:
        raiseOSError(osLastError(), "mkdir " & candidate)
    raise newException(OSError,
      "could not create a fresh /tmp/" & tag & "* directory in 64 attempts")
