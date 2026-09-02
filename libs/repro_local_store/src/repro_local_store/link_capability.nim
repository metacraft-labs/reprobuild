## Filesystem link-capability probe — Local-CAS-Hardlink-Materialization M0.
##
## Spec: ``reprobuild-specs/Local-Content-Addressed-Store.md``
##       §"Hardlink, Reflink, and Copy Policy" (normative).
##
## The store materializes a CAS blob into a destination by one of three
## mechanisms, and they are NOT interchangeable — they differ in exactly
## the property that decides whether sharing is safe:
##
## ==========  ==========================  ======================================
## mechanism   storage                     mutation through one name
## ==========  ==========================  ======================================
## reflink     shared extents until write  breaks sharing on write — SAFE
## hardlink    one inode, N names          visible through ALL names — THE HAZARD
## copy        independent                 independent
## ==========  ==========================  ======================================
##
## So the preference order is reflink → hardlink → copy, and it is driven
## by safety first and cost second: a reflink is both cheaper than a copy
## and safer than a hardlink. See ``preferredMechanisms``.
##
## **Availability is not a filesystem-name lookup.** This module never
## decides a PAIR's reachability from a mount-type string. It ATTEMPTS
## the operation once per filesystem pair and caches what actually
## happened, because prediction is wrong in ways that matter:
##
## * Same-device is necessary but not sufficient. On Btrfs ``link()``
##   across subvolumes fails ``EXDEV`` on a single device, because
##   subvolumes carry distinct ``st_dev``.
## * Reflink is an operation, not a filesystem property: ``FICLONE`` on
##   Linux (Btrfs, XFS with ``reflink=1``), ``clonefile(2)`` on APFS,
##   ``FSCTL_DUPLICATE_EXTENTS_TO_FILE`` on Windows ReFS. NTFS has none,
##   which is exactly why the spec says "Windows: NTFS hardlinks are used
##   by default".
## * Network filesystems may advertise hardlinks with weaker semantics
##   and generally offer no reflink; server-side copy offload is a copy.
## * Overlayfs interposes copy-up semantics that change what a write
##   through a link does; a bind mount does not.
##
## Two questions, and only one of them is the probe's
## ==================================================
##
## Platform-And-Filesystem-Facts **F3**. The paragraph above is about
## the question *does this operation work between THESE two paths?* — a
## question no table can answer, and the reason this module exists. It
## is not the only question in the room:
##
## ==========================================  ==================================
## question                                    answered by
## ==========================================  ==================================
## What can this filesystem do?                ``repro_fs_facts`` — the CONSTANTS
## Does it work between THESE two paths?       this module — the PROBE
## ==========================================  ==================================
##
## Since F3 this module reads the constants for one purpose and one
## only: **to skip an attempt whose failure they already determine.**
## There is no reason to issue ``FSCTL_DUPLICATE_EXTENTS_TO_FILE``
## against NTFS to discover something that has been true since NTFS
## shipped, and a reasoned answer beats a rediscovered one because it
## can say WHY. Everything else is unchanged: pair reachability is still
## established by attempting the operation, because the constants cannot
## know which Btrfs subvolume a path is in.
##
## The skip is deliberately one-directional. A definite ``tnNo`` removes
## an attempt; a ``tnYes`` does NOT add a capability, and neither does an
## advertised volume flag. A capability this module reports is always
## one an attempt produced — except where the tables say the attempt
## cannot produce one, in which case no capability is reported either.
## There is no path through this module by which a constant can turn a
## mechanism ON.
##
## **A disagreement is a bug, and it is surfaced.** When the table says a
## filesystem implements an operation and the operation answers "not
## implemented" — or, under ``setFactAudit``, when the table says it
## cannot and the operation succeeds — the capability record carries a
## ``FactDisagreement`` naming both values. Something is wrong with the
## table or with the detection, and the one thing that must not happen is
## for one side to be silently preferred. See ``disagreementKind``, which
## is the only place the two are compared.
##
## **A filesystem with no table row** degrades to probe-everything and is
## reported rather than assumed about; the rule is stated in
## ``repro_fs_facts/detect.nim`` §"The unknown-filesystem degradation
## rule" (**F4**) and implemented here by ``verdictFor`` answering
## ``fvNoTableEntry``, which no arm treats as a reason to skip.
##
## **What the probe deliberately does NOT answer.** NTFS caps a file at
## 1023 hardlinks. That limit is a property of an individual blob, not of
## the filesystem pair, so it cannot be cached here: a pair whose probe
## said ``hardlink = true`` can still fail ``ERROR_TOO_MANY_LINKS`` on a
## widely-shared blob. Callers MUST treat ``loLinkLimitExceeded`` from a
## real ``attemptHardlink`` as "fall back to copy for THIS file" and MUST
## NOT invalidate the cached capability. See ``isPerFileFallback``.
##
## This module is scoped to the filesystem primitives the policy needs: the
## model, the probe, and the per-file observations (``hardlinkCount``,
## ``fileIdentity``) that "one inode" makes meaningful. It has no opinion
## about ``casMaterialize`` (M1) or where path-based ingest stages its
## work (M2). The one policy statement it does carry is
## ``preferredMechanisms``' ``allowSharedInode`` lever, which M3 settled:
## see its doc comment.

import std/[atomics, locks, os, strutils, tables]

from repro_core/paths import extendedPath

# Platform-And-Filesystem-Facts F3. A leaf library whose only
# dependencies are ``std/[os, strutils]`` and the platform bindings, so
# importing it here adds no transitive weight and creates no cycle:
# ``repro_fs_facts`` is line 22 of ``libs/libraries.txt`` and
# ``repro_local_store`` is line 23, deliberately in that order.
import repro_fs_facts

when defined(windows):
  import std/winlean

when defined(posix):
  import std/posix

# ---------------------------------------------------------------------------
# Public model
# ---------------------------------------------------------------------------

type
  LinkMechanism* = enum
    ## The three ways a blob can reach a destination path, in the order
    ## the spec prefers them.
    lmReflink   ## COW clone. Shared extents; a write to either name
                ## copies the touched extents instead of editing the
                ## shared ones. Cheap AND safe.
    lmHardlink  ## One inode, N names. Cheapest, but a write through the
                ## destination edits the CAS blob — the hazard M3 exists
                ## to fence.
    lmCopy      ## Independent bytes. Always available; always correct.

  LinkOutcome* = enum
    ## Why an attempt did or did not work. Derived from the operation's
    ## OWN error (``EXDEV``, ``ERROR_NOT_SAME_DEVICE``,
    ## ``ERROR_INVALID_FUNCTION``, ...), never from a guess about the
    ## filesystem.
    loOk                 ## The link/clone exists and holds the source bytes.
    loCrossDevice        ## EXDEV / ERROR_NOT_SAME_DEVICE. Distinct
                         ## filesystems (or Btrfs subvolumes) — never
                         ## retryable for this pair.
    loUnsupported        ## The filesystem or OS does not implement the
                         ## operation at all (NTFS reflink →
                         ## ERROR_INVALID_FUNCTION; EOPNOTSUPP; ENOSYS).
    loLinkLimitExceeded  ## EMLINK / ERROR_TOO_MANY_LINKS /
                         ## ERROR_BLOCK_TOO_MANY_REFERENCES. A PER-FILE
                         ## limit, not a pair capability.
    loPermissionDenied   ## EPERM / EACCES / ERROR_ACCESS_DENIED.
    loOther              ## Anything else, including a link that was
                         ## created but did not verify.
    loNotAttempted       ## **No syscall was issued.** The declared
                         ## facts already determine that this mechanism
                         ## cannot work on this filesystem, so the
                         ## attempt was skipped (F3). Distinct from
                         ## ``loUnsupported`` on purpose: that one is an
                         ## observation, this one is a deduction, and a
                         ## reader of a log is entitled to know which
                         ## they are looking at. ``message`` names the
                         ## row that ruled it out.

  LinkAttempt* = object
    ## The result of one real attempt, kept as a diagnostic so a caller
    ## can log *why* it fell back rather than only *that* it did.
    outcome*: LinkOutcome
    errorCode*: int    ## ``errno`` / ``GetLastError``; 0 when unused.
    message*: string   ## Human-readable, safe to log. Never parsed.

  FactVerdict* = enum
    ## What the DECLARED facts say about a mechanism for a pair —
    ## Platform-And-Filesystem-Facts F3. Never a capability answer on
    ## its own: only ``fvImpossible`` changes what this module does, and
    ## all it does is remove an attempt.
    fvNoTableEntry
      ## At least one endpoint's filesystem has no row (or could not be
      ## identified at all). Nothing is determined, so nothing is
      ## skipped and nothing is assumed — the F4 degradation rule.
    fvIndefinite
      ## Both endpoints have rows, and at least one declares ``varies``
      ## / ``unknown`` / ``n/a`` for this mechanism. That is a fact, and
      ## the fact is "no single value is correct here" — which is a
      ## statement that policy must probe. NFS, SMB and overlayfs are
      ## the type cases, and their rows say so in as many words.
    fvPossible
      ## Every endpoint declares the mechanism available. This does NOT
      ## make it available for this PAIR — Btrfs refuses ``link()``
      ## across subvolumes on one device — so the attempt is still
      ## issued. What it buys is the right to call a ``loUnsupported``
      ## answer a disagreement rather than an ordinary refusal.
    fvImpossible
      ## Some endpoint declares the mechanism absent, definitely
      ## (``tnNo``). This is the only verdict that removes a syscall.

  FactDisagreementKind* = enum
    ## The table and the probe contradicting each other. Both values are
    ## always named in the message: which of the two is wrong is exactly
    ## what a reader has to decide, and a message that names one has
    ## already decided it for them.
    fdNone
    fdDeclaredPossibleButUnsupported
      ## The table says this filesystem implements the operation; the
      ## operation answered "not implemented". Either the row is wrong
      ## or ``detect.nim`` matched the wrong row.
    fdDeclaredImpossibleButWorked
      ## The table says this filesystem cannot; it did. Only reachable
      ## under ``setFactAudit`` — without it the attempt is skipped, so
      ## there is nothing to disagree with. That asymmetry is why the
      ## audit mode exists.

  FactDisagreement* = object
    ## One surfaced contradiction, in the same "name both values" shape
    ## the F2 conformance suite uses.
    kind*: FactDisagreementKind
    mechanism*: LinkMechanism
    filesystem*: string   ## the OS-reported name of the endpoint.
    declared*: string     ## what the table says.
    observed*: string     ## what the attempt did.
    citation*: string     ## the row's own citation, so a reader can
                          ## check the claim without a machine.
    message*: string      ## the whole thing, safe to log.

  DeclaredEndpoint* = object
    ## What the fact tables say about one end of a pair. A projection,
    ## not the row: this module reads exactly the two facts it acts on,
    ## so a later reader can see the whole of the coupling in one place.
    status*: TableEntryStatus
    reportedName*: string   ## the filesystem name the OS reported.
    volumeKey*: string      ## the filesystem instance, for telling one
                            ## endpoint from another.
    id*: FilesystemId       ## meaningful only when ``status ==
                            ## teKnown``.
    hardlinks*: Ternary
    reflink*: Ternary
    hardlinkCitation*: string
    reflinkCitation*: string
    notice*: string
      ## The F4 notice when this endpoint has no row; ``""`` otherwise.

  DeclaredPair* = object
    source*, dest*: DeclaredEndpoint
    sameFilesystem*: bool
      ## Both endpoints are one filesystem INSTANCE. A pair that spans
      ## two filesystems is not a statement about either, which is why
      ## no disagreement is ever raised for one: a cross-volume reflink
      ## on Windows answers ERROR_INVALID_PARAMETER, which classifies
      ## ``loUnsupported``, and calling that a table defect would make
      ## every cross-volume materialization report a bug in NTFS's row.

  LinkCapability* = object
    ## What a (source directory, destination directory) pair supports.
    probed*: bool
      ## ``true`` when both mechanisms were resolved — attempted, or
      ## skipped because the declared facts already determined them.
      ## ``false`` means nothing could be resolved at all (unwritable
      ## source, missing destination) — such a result is NOT cached, so
      ## a later call with a usable directory re-probes.
    hardlink*: bool
    reflink*: bool
    hardlinkAttempt*: LinkAttempt
    reflinkAttempt*: LinkAttempt
    key*: string
      ## The filesystem-pair cache key this answer is filed under.
    declared*: DeclaredPair
      ## What the fact tables said about the two endpoints (F3).
    hardlinkVerdict*: FactVerdict
    reflinkVerdict*: FactVerdict
    disagreements*: seq[FactDisagreement]
      ## Empty on a healthy host. Non-empty is a BUG in the table or in
      ## the detection, and ``describe`` puts it in the log line rather
      ## than leaving it for a caller to remember to look for.
    notices*: seq[string]
      ## F4 notices for endpoints with no table row.

  LinkCapabilityCache* = object
    ## Per-filesystem-pair memo. Explicitly passed so tests can observe
    ## the probe count; ``linkCapabilities`` wraps a process-wide one.
    entries: Table[string, LinkCapability]
    probes: int
    audit: bool
      ## When set, an attempt the declared facts rule out is issued
      ## ANYWAY, purely to check the table against reality. Off by
      ## default because the whole point of F3 is not to issue it; see
      ## ``setFactAudit``.

# ---------------------------------------------------------------------------
# Platform bindings
# ---------------------------------------------------------------------------

when defined(windows):
  const
    ErrInvalidFunction = 1
    ErrAccessDenied = 5
    ErrNotSameDevice = 17
    ErrNotSupported = 50
    ErrInvalidParameter = 87
    ErrBlockTooManyReferences = 347
    ErrTooManyLinks = 1142

    FsctlDuplicateExtentsToFile = 0x00098344'i32
      ## ReFS block cloning. NTFS answers ERROR_INVALID_FUNCTION.

    FileEndOfFileInfo = 6'i32
      ## ``FILE_INFO_BY_HANDLE_CLASS.FileEndOfFileInfo``.

  type
    DuplicateExtentsData = object
      ## ``DUPLICATE_EXTENTS_DATA`` from ``winioctl.h``.
      fileHandle: Handle
      sourceFileOffset: int64
      targetFileOffset: int64
      byteCount: int64

  proc createHardLinkW(lpFileName, lpExistingFileName: WideCString;
                       lpSecurityAttributes: pointer): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "CreateHardLinkW".}

  proc deviceIoControl(hDevice: Handle; dwIoControlCode: DWORD;
                       lpInBuffer: pointer; nInBufferSize: DWORD;
                       lpOutBuffer: pointer; nOutBufferSize: DWORD;
                       lpBytesReturned: ptr DWORD;
                       lpOverlapped: pointer): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "DeviceIoControl".}

  proc setFileInformationByHandle(hFile: Handle; klass: int32;
                                  lpFileInformation: pointer;
                                  dwBufferSize: DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "SetFileInformationByHandle".}

  proc getVolumePathNameW(lpszFileName: WideCString;
                          lpszVolumePathName: WideCString;
                          cchBufferLength: DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetVolumePathNameW".}

  proc getVolumeInformationW(lpRootPathName: WideCString;
                             lpVolumeNameBuffer: WideCString;
                             nVolumeNameSize: DWORD;
                             lpVolumeSerialNumber: ptr DWORD;
                             lpMaximumComponentLength: ptr DWORD;
                             lpFileSystemFlags: ptr DWORD;
                             lpFileSystemNameBuffer: WideCString;
                             nFileSystemNameSize: DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetVolumeInformationW".}

  proc getDiskFreeSpaceW(lpRootPathName: WideCString;
                         lpSectorsPerCluster: ptr DWORD;
                         lpBytesPerSector: ptr DWORD;
                         lpNumberOfFreeClusters: ptr DWORD;
                         lpTotalNumberOfClusters: ptr DWORD): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "GetDiskFreeSpaceW".}

elif defined(linux):
  const
    Ficlone = 0x40049409'u
      ## ``_IOW(0x94, 9, int)``. Btrfs / XFS-with-reflink / bcachefs.

  proc ioctlClone(f: cint; device: uint): cint
    {.importc: "ioctl", header: "<sys/ioctl.h>", varargs, discardable.}

elif defined(macosx):
  proc clonefile(src, dst: cstring; flags: cint): cint
    {.importc: "clonefile", header: "<sys/clonefile.h>".}

# ---------------------------------------------------------------------------
# Error classification — always from the operation's own error
# ---------------------------------------------------------------------------

when defined(windows):
  proc classifyWinError(code: int; what: string): LinkAttempt =
    let outcome =
      case code
      of ErrNotSameDevice: loCrossDevice
      of ErrInvalidFunction, ErrNotSupported: loUnsupported
      of ErrTooManyLinks, ErrBlockTooManyReferences: loLinkLimitExceeded
      of ErrAccessDenied: loPermissionDenied
      of ErrInvalidParameter: loUnsupported
      else: loOther
    LinkAttempt(outcome: outcome, errorCode: code,
                message: what & " failed with Windows error " & $code)

when defined(posix):
  proc classifyPosixError(code: int; what: string): LinkAttempt =
    let outcome =
      if code == EXDEV: loCrossDevice
      elif code == EMLINK: loLinkLimitExceeded
      elif code == EPERM or code == EACCES: loPermissionDenied
      elif code == EOPNOTSUPP or code == ENOSYS or code == EINVAL:
        loUnsupported
      else: loOther
    LinkAttempt(outcome: outcome, errorCode: code,
                message: what & " failed with errno " & $code)

proc isPerFileFallback*(attempt: LinkAttempt): bool =
  ## ``true`` when the failure is a property of THIS file rather than of
  ## the filesystem pair — NTFS's 1023-link cap and ReFS's per-extent
  ## reference cap being the two that matter. A caller that hits this
  ## MUST fall back to copy for the one file and MUST NOT invalidate the
  ## cached pair capability, and MUST NOT surface it as a build error.
  attempt.outcome == loLinkLimitExceeded

# ---------------------------------------------------------------------------
# Issued-attempt counters
#
# F3's concrete win is FEWER SYSCALLS, and a claim about syscalls needs a
# mechanism behind it or it is the class of claim this campaign removes.
# These counters are that mechanism: every path that actually issues
# ``CreateHardLinkW`` / ``link(2)`` / the clone primitive increments one,
# so a test can assert that a known-failing attempt was never made
# without measuring TIME, which measures the machine rather than the
# code.
#
# Atomics rather than a lock because these sit on the per-file
# materialization path, and because a counter is exactly the shape
# ``fetchAdd`` exists for.
# ---------------------------------------------------------------------------

var
  hardlinkAttemptsIssued: Atomic[int]
  reflinkAttemptsIssued: Atomic[int]

proc linkAttemptsIssued*(mechanism: LinkMechanism): int =
  ## How many real attempts of ``mechanism`` this process has issued.
  ## ``lmCopy`` is always 0: a copy is not an attempt whose availability
  ## is in question.
  case mechanism
  of lmHardlink: hardlinkAttemptsIssued.load()
  of lmReflink: reflinkAttemptsIssued.load()
  of lmCopy: 0

proc resetLinkAttemptCounters*() =
  ## Zero the counters. For tests; production code has no reason to.
  hardlinkAttemptsIssued.store(0)
  reflinkAttemptsIssued.store(0)

# ---------------------------------------------------------------------------
# Mechanism attempts
# ---------------------------------------------------------------------------

proc attemptHardlink*(src, dst: string): LinkAttempt =
  ## Create ``dst`` as a second name for ``src``'s inode. ``dst`` MUST
  ## NOT already exist. Never raises; the outcome carries the reason.
  ##
  ## Reminder from the model above: on success ``src`` and ``dst`` are
  ## the SAME inode, so mode bits, timestamps and in-place writes are
  ## shared between them.
  hardlinkAttemptsIssued.atomicInc()
  when defined(windows):
    let ok = createHardLinkW(newWideCString(extendedPath(dst)),
                             newWideCString(extendedPath(src)), nil)
    if ok == 0:
      return classifyWinError(int(getLastError()), "CreateHardLinkW")
    LinkAttempt(outcome: loOk)
  elif defined(posix):
    if link(cstring(src), cstring(dst)) != 0:
      return classifyPosixError(int(errno), "link()")
    LinkAttempt(outcome: loOk)
  else:
    LinkAttempt(outcome: loUnsupported,
                message: "hardlinks are not available on this platform")

when defined(windows):
  proc volumeRootOf(path: string): string =
    ## The mount point that owns ``path`` (``C:\``, or a directory when a
    ## volume is mounted into a folder). Empty when it cannot be found.
    var buf: array[512, Utf16Char]
    if getVolumePathNameW(newWideCString(path),
                          cast[WideCString](addr buf[0]),
                          DWORD(buf.len)) == 0:
      return ""
    $cast[WideCString](addr buf[0])

  proc clusterSizeOf(path: string): int64 =
    ## Bytes per allocation unit on the volume owning ``path``.
    ## ``FSCTL_DUPLICATE_EXTENTS_TO_FILE`` requires cluster-aligned
    ## offsets and byte counts. Falls back to 4 KiB, the ReFS default.
    let root = volumeRootOf(path)
    if root.len == 0:
      return 4096
    var sectorsPerCluster, bytesPerSector, freeClusters, totalClusters: DWORD
    if getDiskFreeSpaceW(newWideCString(root), addr sectorsPerCluster,
                         addr bytesPerSector, addr freeClusters,
                         addr totalClusters) == 0:
      return 4096
    let size = int64(uint32(sectorsPerCluster)) * int64(uint32(bytesPerSector))
    if size <= 0: 4096 else: size

proc attemptReflink*(src, dst: string): LinkAttempt =
  ## Create ``dst`` as a copy-on-write clone of ``src``: the extents are
  ## shared until either name is written, at which point the written
  ## extents are copied. This is the mechanism the spec prefers, because
  ## it is the only cheap one whose mutation semantics match a copy.
  ##
  ## Any partially created ``dst`` is removed before returning a failure,
  ## so a failed attempt leaves no debris for the caller to clean up.
  reflinkAttemptsIssued.atomicInc()
  when defined(windows):
    let srcW = newWideCString(extendedPath(src))
    let srcH = createFileW(srcW, GENERIC_READ,
                           FILE_SHARE_READ or FILE_SHARE_WRITE or
                             FILE_SHARE_DELETE,
                           nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0)
    if srcH == INVALID_HANDLE_VALUE:
      return classifyWinError(int(getLastError()), "CreateFileW(source)")
    var info: BY_HANDLE_FILE_INFORMATION
    if getFileInformationByHandle(srcH, addr info) == 0:
      let code = int(getLastError())
      discard closeHandle(srcH)
      return classifyWinError(code, "GetFileInformationByHandle")
    let size = (int64(uint32(info.nFileSizeHigh)) shl 32) or
               int64(uint32(info.nFileSizeLow))
    let dstW = newWideCString(extendedPath(dst))
    let dstH = createFileW(dstW, GENERIC_READ or GENERIC_WRITE, 0, nil,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0)
    if dstH == INVALID_HANDLE_VALUE:
      let code = int(getLastError())
      discard closeHandle(srcH)
      return classifyWinError(code, "CreateFileW(destination)")

    template failWin(code: int; what: string): LinkAttempt =
      discard closeHandle(dstH)
      discard closeHandle(srcH)
      try: removeFile(extendedPath(dst)) except CatchableError: discard
      classifyWinError(code, what)

    if size == 0:
      # A zero-length clone shares nothing and needs no FSCTL; the empty
      # destination created above already IS the clone. Issuing the
      # ioctl with a zero byte count would answer ERROR_INVALID_PARAMETER
      # and be misread as "reflink unsupported here".
      discard closeHandle(dstH)
      discard closeHandle(srcH)
      return LinkAttempt(outcome: loOk)

    let cluster = clusterSizeOf(dst)
    let aligned = ((size + cluster - 1) div cluster) * cluster
    # The destination must already be at least as long as the cloned
    # range; the FSCTL does not extend it.
    var eof = aligned
    if setFileInformationByHandle(dstH, FileEndOfFileInfo, addr eof,
                                  DWORD(sizeof(eof))) == 0:
      return failWin(int(getLastError()), "SetEndOfFile(aligned)")
    var request = DuplicateExtentsData(fileHandle: srcH,
                                       sourceFileOffset: 0,
                                       targetFileOffset: 0,
                                       byteCount: aligned)
    var returned: DWORD
    if deviceIoControl(dstH, FsctlDuplicateExtentsToFile, addr request,
                       DWORD(sizeof(request)), nil, 0, addr returned,
                       nil) == 0:
      return failWin(int(getLastError()), "FSCTL_DUPLICATE_EXTENTS_TO_FILE")
    # Trim the cluster-alignment padding back off so the clone is
    # byte-identical to the source.
    var realEof = size
    if setFileInformationByHandle(dstH, FileEndOfFileInfo, addr realEof,
                                  DWORD(sizeof(realEof))) == 0:
      return failWin(int(getLastError()), "SetEndOfFile(exact)")
    discard closeHandle(dstH)
    discard closeHandle(srcH)
    LinkAttempt(outcome: loOk)
  elif defined(linux):
    let srcFd = posix.open(cstring(src), O_RDONLY)
    if srcFd < 0:
      return classifyPosixError(int(errno), "open(source)")
    let dstFd = posix.open(cstring(dst), O_WRONLY or O_CREAT or O_TRUNC,
                           Mode(0o644))
    if dstFd < 0:
      let code = int(errno)
      discard posix.close(srcFd)
      return classifyPosixError(code, "open(destination)")
    let rc = ioctlClone(dstFd, Ficlone, srcFd)
    let code = int(errno)
    discard posix.close(dstFd)
    discard posix.close(srcFd)
    if rc != 0:
      try: removeFile(dst) except CatchableError: discard
      return classifyPosixError(code, "ioctl(FICLONE)")
    LinkAttempt(outcome: loOk)
  elif defined(macosx):
    if clonefile(cstring(src), cstring(dst), 0) != 0:
      return classifyPosixError(int(errno), "clonefile()")
    LinkAttempt(outcome: loOk)
  else:
    LinkAttempt(outcome: loUnsupported,
                message: "no reflink primitive is bound for this platform")

# ---------------------------------------------------------------------------
# Inode-level observations that follow from "one inode"
# ---------------------------------------------------------------------------

proc hardlinkCount*(path: string): int =
  ## Number of directory entries naming ``path``'s inode
  ## (``st_nlink`` / ``nNumberOfLinks``), or ``-1`` when it cannot be
  ## determined.
  ##
  ## This is the free signal in the other direction the model calls for:
  ## a CAS blob whose count exceeds the store's own reference tells the
  ## GC that outstanding materializations exist that it did not record.
  when defined(windows):
    let h = createFileW(newWideCString(extendedPath(path)), 0,
                        FILE_SHARE_READ or FILE_SHARE_WRITE or
                          FILE_SHARE_DELETE,
                        nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0)
    if h == INVALID_HANDLE_VALUE:
      return -1
    var info: BY_HANDLE_FILE_INFORMATION
    let ok = getFileInformationByHandle(h, addr info)
    discard closeHandle(h)
    if ok == 0: -1 else: int(uint32(info.nNumberOfLinks))
  elif defined(posix):
    var st: Stat
    if stat(cstring(path), st) != 0: -1 else: int(st.st_nlink)
  else:
    -1

type
  FileIdentity* = object
    ## A witness that a file is still the same file holding the same
    ## bytes. Local-CAS-Hardlink-Materialization **M2** needs this because
    ## path-based ingest hashes a source and then links it: between those
    ## two steps the source must not have changed, and a blob whose digest
    ## does not match its content is a corrupt store.
    ##
    ## Deliberately more than a size check. The pre-M2 ingest compared
    ## sizes alone, which cannot see an in-place rewrite of the same
    ## length, and cannot see the source being replaced by a different
    ## file at the same path.
    known*: bool
      ## ``false`` when the file could not be stat'd at all. A caller
      ## comparing two identities MUST treat "not known" as "changed" —
      ## see ``sameFileIdentity``.
    sizeBytes*: uint64
    mtimeRaw*: uint64
      ## An OPAQUE last-write stamp: POSIX nanoseconds since the epoch,
      ## Windows ``FILETIME`` 100-ns ticks since 1601. Deliberately not
      ## normalised to one unit — the value is only ever compared with
      ## another value from this same proc, and normalising Windows'
      ## ticks to nanoseconds overflows a 64-bit integer.
    volumeId*: uint64  ## ``st_dev`` / ``dwVolumeSerialNumber``.
    fileId*: uint64    ## ``st_ino`` / ``nFileIndex{High,Low}``.
    linkCount*: int
      ## ``st_nlink`` / ``nNumberOfLinks``. Reported but deliberately NOT
      ## part of ``sameFileIdentity``: another name appearing on the inode
      ## does not change the bytes, and the ingest's own hardlink arm
      ## raises this count itself.

proc fileIdentity*(path: string): FileIdentity =
  ## Stat ``path`` into a comparable witness. Never raises; an
  ## unreachable file yields ``known = false``.
  when defined(windows):
    let h = createFileW(newWideCString(extendedPath(path)), 0,
                        FILE_SHARE_READ or FILE_SHARE_WRITE or
                          FILE_SHARE_DELETE,
                        nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0)
    if h == INVALID_HANDLE_VALUE:
      return
    var info: BY_HANDLE_FILE_INFORMATION
    let ok = getFileInformationByHandle(h, addr info)
    discard closeHandle(h)
    if ok == 0:
      return
    result.sizeBytes = (uint64(uint32(info.nFileSizeHigh)) shl 32) or
                       uint64(uint32(info.nFileSizeLow))
    result.mtimeRaw =
      (uint64(uint32(info.ftLastWriteTime.dwHighDateTime)) shl 32) or
      uint64(uint32(info.ftLastWriteTime.dwLowDateTime))
    result.volumeId = uint64(uint32(info.dwVolumeSerialNumber))
    result.fileId = (uint64(uint32(info.nFileIndexHigh)) shl 32) or
                    uint64(uint32(info.nFileIndexLow))
    result.linkCount = int(uint32(info.nNumberOfLinks))
    result.known = true
  elif defined(posix):
    var st: Stat
    if stat(cstring(path), st) != 0:
      return
    result.sizeBytes = uint64(st.st_size)
    result.mtimeRaw = uint64(st.st_mtim.tv_sec) * 1_000_000_000'u64 +
                      uint64(st.st_mtim.tv_nsec)
    result.volumeId = uint64(st.st_dev)
    result.fileId = uint64(st.st_ino)
    result.linkCount = int(st.st_nlink)
    result.known = true
  else:
    discard

proc sameFileIdentity*(a, b: FileIdentity): bool =
  ## ``true`` only when both witnesses were obtained AND agree on size,
  ## last-write time, and which file on which volume this is.
  ##
  ## Conservative by construction: an unknown identity on either side is
  ## "changed", so a caller that cannot stat the source falls back to the
  ## mechanism that does not depend on the source staying still.
  a.known and b.known and
    a.sizeBytes == b.sizeBytes and
    a.mtimeRaw == b.mtimeRaw and
    a.volumeId == b.volumeId and
    a.fileId == b.fileId

proc describe*(id: FileIdentity): string =
  ## One-line diagnostic. Safe to log; never parsed.
  if not id.known:
    return "identity=unknown"
  "size=" & $id.sizeBytes & " mtimeRaw=" & $id.mtimeRaw &
    " volume=" & $id.volumeId & " fileId=" & $id.fileId &
    " links=" & $id.linkCount

proc filesystemName*(path: string): string =
  ## The filesystem type as the OS reports it (``NTFS``, ``ReFS``, ...),
  ## or ``""`` when unknown.
  ##
  ## DIAGNOSTIC ONLY. Nothing in this module decides a capability from
  ## this string, and callers MUST NOT either — that is the prediction
  ## the probe exists to replace. It is here so a log line can say which
  ## filesystem answered the way it did.
  when defined(windows):
    let root = volumeRootOf(path)
    if root.len == 0:
      return ""
    var fsName: array[64, Utf16Char]
    if getVolumeInformationW(newWideCString(root), nil, 0, nil, nil, nil,
                             cast[WideCString](addr fsName[0]),
                             DWORD(fsName.len)) == 0:
      return ""
    $cast[WideCString](addr fsName[0])
  else:
    ""

# ---------------------------------------------------------------------------
# Filesystem-pair identity (the CACHE KEY — never the answer)
# ---------------------------------------------------------------------------

proc deviceKeyOf(dir: string): string =
  ## A cheap stable identity for the filesystem holding ``dir``, used
  ## ONLY to file the probe result. Returns ``""`` when the identity
  ## cannot be established, which makes the caller fall back to a
  ## path-based key — more probes, never a wrong answer.
  when defined(windows):
    let h = createFileW(newWideCString(extendedPath(dir)), 0,
                        FILE_SHARE_READ or FILE_SHARE_WRITE or
                          FILE_SHARE_DELETE,
                        nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0)
    if h == INVALID_HANDLE_VALUE:
      return ""
    var info: BY_HANDLE_FILE_INFORMATION
    let ok = getFileInformationByHandle(h, addr info)
    discard closeHandle(h)
    if ok == 0:
      return ""
    # Serial alone can collide across cloned disks, so pair it with the
    # mount point that owns the directory.
    volumeRootOf(dir).toLowerAscii & "#" & $uint32(info.dwVolumeSerialNumber)
  elif defined(posix):
    var st: Stat
    if stat(cstring(dir), st) != 0:
      return ""
    # ``st_dev`` is the right key even where it is a poor predictor: a
    # Btrfs subvolume has its own ``st_dev``, so the pair that refuses
    # ``link()`` gets its own cache entry rather than inheriting the
    # parent volume's answer.
    "dev#" & $uint64(st.st_dev)
  else:
    ""

const PathKeysFoldCase =
  hostOsFacts().pathLookupIsCaseSensitive.value == tnNo
  ## Whether two paths differing only in case name the same directory,
  ## read from the OS fact table rather than from ``defined(windows)``.
  ##
  ## Platform-And-Filesystem-Facts F3. This was an unconditional
  ## ``toLowerAscii`` on both paths, and it was WRONG on every
  ## case-sensitive host: ``/srv/A`` and ``/srv/a`` are two directories
  ## on Linux, they can give different answers, and folding them
  ## together filed one answer under both. The Windows arm of
  ## ``deviceKeyOf`` above folds case correctly and always did; this
  ## fallback did not, which is exactly the drift a declared fact
  ## removes.
  ##
  ## ``tnVaries`` — macOS, where case sensitivity is the mounted
  ## volume's property and the OS has no single answer — resolves to
  ## "do not fold", which is the conservative direction here: not
  ## folding can only ever produce a second cache entry and a second
  ## probe, while folding wrongly produces a wrong answer for a
  ## directory that was never measured. Same trade ``deviceKeyOf``
  ## already documents for an unidentifiable device.

func pairKeyPathComponent(dir: string): string =
  if PathKeysFoldCase: dir.toLowerAscii else: dir

proc filesystemPairKey*(srcDir, dstDir: string): string =
  ## Cache key for the (source, destination) filesystem pair. Exposed so
  ## callers can log which pair an answer came from, and so tests can
  ## assert that two genuinely different pairs get different entries.
  let a = deviceKeyOf(srcDir)
  let b = deviceKeyOf(dstDir)
  if a.len == 0 or b.len == 0:
    "path:" & pairKeyPathComponent(srcDir) & "->path:" &
      pairKeyPathComponent(dstDir)
  else:
    a & "->" & b

# ---------------------------------------------------------------------------
# The declared facts — Platform-And-Filesystem-Facts F3
#
# Everything in this section is a READ of ``repro_fs_facts``. Nothing in
# it issues a syscall, and nothing in it can turn a mechanism on: the
# single effect the tables are allowed to have on this module is
# ``fvImpossible`` removing an attempt that would have failed.
# ---------------------------------------------------------------------------

proc `$`*(m: LinkMechanism): string =
  case m
  of lmReflink: "reflink"
  of lmHardlink: "hardlink"
  of lmCopy: "copy"

func `$`*(v: FactVerdict): string =
  case v
  of fvNoTableEntry: "no table entry"
  of fvIndefinite: "indefinite"
  of fvPossible: "possible"
  of fvImpossible: "impossible"

proc declaredEndpoint*(dir: string): DeclaredEndpoint =
  ## What the fact tables say about the filesystem holding ``dir``.
  ##
  ## Reads exactly the two facts this module acts on. When the
  ## filesystem has no row the values stay ``tnUnknown`` and the row is
  ## NOT read — ``factsForPath`` answers the zeroth table row alongside
  ## ``known = false``, and treating that as data is the mistake its own
  ## doc comment warns about.
  let (known, facts, obs) = factsForPath(dir)
  result = DeclaredEndpoint(
    status: obs.status, reportedName: obs.reportedName,
    volumeKey: obs.volumeKey, id: obs.id,
    hardlinks: tnUnknown, reflink: tnUnknown,
    notice: describeTableStatus(obs))
  if known:
    result.hardlinks = facts.hardlinks.value
    result.reflink = facts.reflink.value
    result.hardlinkCitation = facts.hardlinks.citation
    result.reflinkCitation = facts.reflink.citation

proc declaredPairFor*(srcDir, dstDir: string): DeclaredPair =
  ## The declared facts for both ends of a pair.
  result.source = declaredEndpoint(srcDir)
  result.dest = declaredEndpoint(dstDir)
  # One filesystem INSTANCE, not merely one filesystem TYPE: two ReFS
  # volumes are two instances and a link between them is a statement
  # about neither one's row.
  result.sameFilesystem =
    result.source.status != teUnqueried and
    result.dest.status != teUnqueried and
    result.source.volumeKey.len > 0 and
    result.source.volumeKey == result.dest.volumeKey

func declaredValue*(ep: DeclaredEndpoint;
                    mechanism: LinkMechanism): Ternary =
  ## The declared support for ``mechanism`` at one endpoint.
  case mechanism
  of lmHardlink: ep.hardlinks
  of lmReflink: ep.reflink
  of lmCopy: tnYes  ## copy is the arm that cannot be unavailable.

func declaredCitation*(ep: DeclaredEndpoint;
                       mechanism: LinkMechanism): string =
  case mechanism
  of lmHardlink: ep.hardlinkCitation
  of lmReflink: ep.reflinkCitation
  of lmCopy: ""

func verdictFor*(mechanism: LinkMechanism;
                 pair: DeclaredPair): FactVerdict =
  ## What the constants determine about ``mechanism`` for this pair.
  ##
  ## Pure, and deliberately so: the whole of F3's use of the tables is
  ## this function plus ``disagreementKind``, so both can be driven over
  ## their entire input space by a test without a host that has the
  ## filesystem in question.
  ##
  ## The asymmetry is the design. ``tnNo`` at EITHER endpoint makes the
  ## operation impossible — a clone into NTFS cannot work however
  ## capable the source is — while ``tnYes`` at both endpoints is not
  ## enough to make it possible, because pair reachability is the
  ## probe's question. Anything that is not a definite ``tnNo`` or
  ## ``tnYes`` (``varies`` on NFS/SMB/overlayfs, ``unknown``, ``n/a``)
  ## is ``fvIndefinite``, which means probe.
  ##
  ## **An endpoint with no row outranks everything, including a definite
  ## ``tnNo`` at the other end** — the F4 rule, and the precedence is
  ## deliberate rather than incidental. A verdict is a statement about a
  ## PAIR; a table that describes only half of a pair has not described
  ## the pair, and "NTFS cannot clone, so this cannot clone" would skip
  ## an attempt on a pair no observation has ever covered while a notice
  ## saying "assumes nothing" was attached to the answer. It also has to
  ## outrank ``tnNo`` rather than merely appear beside it, or the verdict
  ## would depend on which endpoint the loop reached first — the first
  ## draft of this function did exactly that and its own test caught it.
  ## The cost is one syscall, on precisely the host where the extra
  ## evidence is worth most.
  if mechanism == lmCopy:
    return fvPossible
  var indefinite = false
  var impossible = false
  for ep in [pair.source, pair.dest]:
    if ep.status != teKnown:
      return fvNoTableEntry
    case declaredValue(ep, mechanism)
    of tnNo: impossible = true
    of tnYes: discard
    else: indefinite = true
  if impossible: fvImpossible
  elif indefinite: fvIndefinite
  else: fvPossible

func disagreementKind*(verdict: FactVerdict; issued: bool;
                       outcome: LinkOutcome;
                       sameFilesystem: bool): FactDisagreementKind =
  ## The ONLY place the table and the probe are compared.
  ##
  ## Everything that is not a disagreement has to be excluded here, and
  ## the exclusions carry more weight than the inclusions:
  ##
  ## * **A pair spanning two filesystems is not a statement about
  ##   either.** A cross-volume reflink on Windows answers
  ##   ERROR_INVALID_PARAMETER, which ``classifyWinError`` maps to
  ##   ``loUnsupported``; without this guard every cross-volume
  ##   materialization would report a defect in NTFS's row.
  ## * **Only ``loUnsupported`` contradicts a declared capability.**
  ##   ``loCrossDevice`` is pair reachability, ``loLinkLimitExceeded``
  ##   is a per-file property (``isPerFileFallback``),
  ##   ``loPermissionDenied`` is the caller's, and ``loOther`` is
  ##   undiagnosed. None of them says the filesystem lacks the
  ##   operation.
  ## * **An indefinite or absent declaration cannot be contradicted.**
  ##   ``varies`` is consistent with every observation; that is what
  ##   makes it an honest value rather than an evasion.
  if not issued or not sameFilesystem:
    return fdNone
  case verdict
  of fvPossible:
    if outcome == loUnsupported: fdDeclaredPossibleButUnsupported
    else: fdNone
  of fvImpossible:
    if outcome == loOk: fdDeclaredImpossibleButWorked
    else: fdNone
  of fvIndefinite, fvNoTableEntry:
    fdNone

func describeEndpoint*(ep: DeclaredEndpoint): string =
  ## Short form for a log line. The long form — why a filesystem has no
  ## row, and what adding one takes — is ``ep.notice``.
  case ep.status
  of teKnown: $ep.id
  of teDeferred: "UNROWED-BY-DECISION(" & ep.reportedName & ")"
  of teUnknown: "UNROWED(" & ep.reportedName & ")"
  of teUnqueried: "UNQUERIED"

proc rulingEndpoint(mechanism: LinkMechanism;
                    pair: DeclaredPair): DeclaredEndpoint =
  ## The endpoint whose ``tnNo`` made a mechanism impossible. Source
  ## first, matching ``verdictFor``'s own order, so the message names
  ## the same row the verdict came from.
  if declaredValue(pair.source, mechanism) == tnNo: pair.source
  else: pair.dest

proc skippedAttempt(mechanism: LinkMechanism;
                    pair: DeclaredPair): LinkAttempt =
  ## The record left behind by an attempt that was never issued.
  ##
  ## It names the row rather than only the verdict, because "not
  ## attempted" without a reason is indistinguishable from a broken
  ## probe, and the reader who most needs this line is the one who
  ## suspects the table is wrong.
  let ep = rulingEndpoint(mechanism, pair)
  LinkAttempt(
    outcome: loNotAttempted, errorCode: 0,
    message: $mechanism & " was NOT attempted: the filesystem fact " &
      "table declares " & $ep.id & " " & $mechanism & "=" &
      $declaredValue(ep, mechanism) & ", so the attempt's failure is " &
      "already determined and issuing it would only rediscover it " &
      "(Platform-And-Filesystem-Facts F3)")

proc buildDisagreement*(kind: FactDisagreementKind;
                        mechanism: LinkMechanism; pair: DeclaredPair;
                        attempt: LinkAttempt): FactDisagreement =
  ## Turn a detected disagreement into a message that names BOTH values,
  ## in the same shape the F2 conformance suite uses for a
  ## contradiction. Which of the two is wrong is the reader's call, and
  ## a message that decided it for them would be the paper-over this
  ## milestone forbids.
  let ep =
    if kind == fdDeclaredImpossibleButWorked: rulingEndpoint(mechanism, pair)
    else: pair.source
  result = FactDisagreement(
    kind: kind, mechanism: mechanism, filesystem: ep.reportedName,
    declared: $mechanism & "=" & $declaredValue(ep, mechanism),
    observed: $attempt.outcome, citation: declaredCitation(ep, mechanism))
  result.message =
    case kind
    of fdNone: ""
    of fdDeclaredPossibleButUnsupported:
      "TABLE/PROBE DISAGREEMENT on " & ep.reportedName & " (" & $ep.id &
        "): the fact table declares " & result.declared &
        " but the operation answered " & $attempt.outcome & " on a pair " &
        "within one filesystem (" & attempt.message & "). Either the row " &
        "is wrong or repro_fs_facts/detect.nim matched the wrong row; " &
        "the row's citation is: " & result.citation
    of fdDeclaredImpossibleButWorked:
      "TABLE/PROBE DISAGREEMENT on " & ep.reportedName & " (" & $ep.id &
        "): the fact table declares " & result.declared &
        " but the operation SUCCEEDED. The table is wrong, or this " &
        "filesystem is not the one the table thinks it is; the row's " &
        "citation is: " & result.citation

# ---------------------------------------------------------------------------
# The probe
# ---------------------------------------------------------------------------

var probeSerial: int

proc probeFileName(tag: string): string =
  probeSerial.inc
  ".repro-linkprobe-" & tag & "-" & $getCurrentProcessId() & "-" & $probeSerial

proc quietRemove(path: string) =
  try:
    if fileExists(extendedPath(path)):
      removeFile(extendedPath(path))
  except CatchableError, Defect:
    discard

proc sameBytes(a, b: string): bool =
  try:
    readFile(extendedPath(a)) == readFile(extendedPath(b))
  except CatchableError:
    false

const ProbePayloadSize = 8192
  ## Deliberately larger than one cluster on every filesystem this runs
  ## on, so a reflink attempt exercises a real extent duplication rather
  ## than a degenerate zero/short-file path.

proc noteDeclared(cap: var LinkCapability; pair: DeclaredPair) =
  ## Attach the declared facts and, where an endpoint has no table row,
  ## the F4 notice. Deduped because ``srcDir`` and ``dstDir`` are the
  ## same directory on most pairs and one notice is a report while two
  ## identical ones are noise.
  cap.declared = pair
  cap.hardlinkVerdict = verdictFor(lmHardlink, pair)
  cap.reflinkVerdict = verdictFor(lmReflink, pair)
  for ep in [pair.source, pair.dest]:
    if ep.notice.len > 0 and ep.notice notin cap.notices:
      cap.notices.add(ep.notice)

proc probeUncached(srcDir, dstDir: string;
                   audit: bool): LinkCapability =
  ## One real probe. Each mechanism is either ATTEMPTED and the
  ## resulting link VERIFIED (content, and for hardlinks the shared link
  ## count) before it is called available — an API that returns success
  ## while producing a wrong file must not be recorded as a capability —
  ## or SKIPPED because the declared facts already determine that it
  ## cannot work here.
  ##
  ## ``audit`` issues the skipped attempts anyway, purely to check the
  ## table against reality. Off in production, because not issuing them
  ## is the whole of F3's win; on in the tests, and available to a
  ## caller who has reason to distrust a row on a host the F2
  ## conformance suite has never seen.
  result = LinkCapability(probed: false)
  let declared = declaredPairFor(srcDir, dstDir)
  result.noteDeclared(declared)
  if not dirExists(extendedPath(srcDir)) or not dirExists(extendedPath(dstDir)):
    let why = LinkAttempt(outcome: loOther,
                          message: "probe skipped: source or destination " &
                                   "directory does not exist")
    result.hardlinkAttempt = why
    result.reflinkAttempt = why
    return

  let probeSrc = srcDir / probeFileName("src")
  var payload = newString(ProbePayloadSize)
  for i in 0 ..< ProbePayloadSize:
    payload[i] = char((i * 31 + 7) and 0xFF)
  try:
    writeFile(extendedPath(probeSrc), payload)
  except CatchableError, Defect:
    let why = LinkAttempt(outcome: loPermissionDenied,
                          message: "probe skipped: source directory is not " &
                                   "writable (" & srcDir & ")")
    result.hardlinkAttempt = why
    result.reflinkAttempt = why
    return

  defer: quietRemove(probeSrc)

  # The decision the tables are allowed to make, and the only one:
  # whether the attempt below runs at all.
  let issueHardlink = result.hardlinkVerdict != fvImpossible or audit
  let issueReflink = result.reflinkVerdict != fvImpossible or audit

  block hardlinkArm:
    if not issueHardlink:
      result.hardlinkAttempt = skippedAttempt(lmHardlink, declared)
      result.hardlink = false
      break hardlinkArm
    let dst = dstDir / probeFileName("hl")
    quietRemove(dst)
    var attempt = attemptHardlink(probeSrc, dst)
    if attempt.outcome == loOk:
      if not sameBytes(probeSrc, dst):
        attempt = LinkAttempt(outcome: loOther,
                              message: "hardlink reported success but the " &
                                       "destination bytes differ")
      elif hardlinkCount(probeSrc) < 2:
        attempt = LinkAttempt(outcome: loOther,
                              message: "hardlink reported success but the " &
                                       "inode link count did not rise")
    quietRemove(dst)
    result.hardlinkAttempt = attempt
    # Reality wins over the table for THIS pair, always — including when
    # an audited attempt succeeds against a row that said it could not.
    # The disagreement is recorded rather than resolved in the table's
    # favour, because a capability the machine demonstrated is not
    # something a constant may veto.
    result.hardlink = attempt.outcome == loOk

  block reflinkArm:
    if not issueReflink:
      result.reflinkAttempt = skippedAttempt(lmReflink, declared)
      result.reflink = false
      break reflinkArm
    let dst = dstDir / probeFileName("rl")
    quietRemove(dst)
    var attempt = attemptReflink(probeSrc, dst)
    if attempt.outcome == loOk and not sameBytes(probeSrc, dst):
      attempt = LinkAttempt(outcome: loOther,
                            message: "reflink reported success but the " &
                                     "destination bytes differ")
    quietRemove(dst)
    result.reflinkAttempt = attempt
    result.reflink = attempt.outcome == loOk

  for (mechanism, verdict, issued, attempt) in [
      (lmHardlink, result.hardlinkVerdict, issueHardlink,
       result.hardlinkAttempt),
      (lmReflink, result.reflinkVerdict, issueReflink,
       result.reflinkAttempt)]:
    let kind = disagreementKind(verdict, issued, attempt.outcome,
                                declared.sameFilesystem)
    if kind != fdNone:
      result.disagreements.add(
        buildDisagreement(kind, mechanism, declared, attempt))

  result.probed = true

proc setFactAudit*(cache: var LinkCapabilityCache; enabled: bool) =
  ## Turn the declared-fact audit on or off for this cache, dropping
  ## every cached answer (the answers were derived under the other
  ## setting, so keeping them would mix two policies in one memo).
  ##
  ## The audit exists because F3's skipping makes one direction of
  ## disagreement unobservable in production: an attempt that is never
  ## issued cannot succeed against a row that said it could not. The F2
  ## conformance suite covers that direction for every filesystem the
  ## host offers; this covers it for a host the suite has never run on,
  ## at the cost of the syscalls F3 exists to avoid. That is why it is
  ## off by default rather than merely discouraged.
  if cache.audit != enabled:
    cache.audit = enabled
    cache.entries.clear()
    cache.probes = 0

proc factAudit*(cache: LinkCapabilityCache): bool =
  cache.audit

proc probeLinkCapabilities*(cache: var LinkCapabilityCache;
                            srcDir, dstDir: string): LinkCapability =
  ## Answer which mechanisms work from ``srcDir`` to ``dstDir``, probing
  ## at most once per filesystem pair.
  ##
  ## A result that could not be probed at all (``probed == false``) is
  ## NOT cached: an unwritable source or a missing destination is a
  ## property of those directories, not of the filesystem pair, and
  ## caching it would poison every later caller on the same pair.
  let key = filesystemPairKey(srcDir, dstDir)
  if cache.entries.hasKey(key):
    return cache.entries[key]
  result = probeUncached(srcDir, dstDir, cache.audit)
  result.key = key
  if result.probed:
    cache.probes.inc
    cache.entries[key] = result

proc probeCount*(cache: LinkCapabilityCache): int =
  ## How many real probes this cache has performed. A second call for an
  ## already-known filesystem pair must not move it.
  cache.probes

proc cachedPairCount*(cache: LinkCapabilityCache): int =
  ## How many distinct filesystem pairs have a cached answer.
  cache.entries.len

proc clear*(cache: var LinkCapabilityCache) =
  ## Forget every cached answer and reset the probe counter.
  cache.entries.clear()
  cache.probes = 0

# ---------------------------------------------------------------------------
# Process-wide cache
# ---------------------------------------------------------------------------

var
  globalCacheLock: Lock
  globalCache {.guard: globalCacheLock.}: LinkCapabilityCache

globalCacheLock.initLock()

var globalNotices {.guard: globalCacheLock.}: seq[string]
  ## Every distinct F4 notice and disagreement this process has produced.
  ##
  ## The record in ``LinkCapability`` is the primary channel and
  ## ``describe`` puts it in the caller's own log line, but a caller that
  ## never logs would make the situation silent — which is the one thing
  ## F4 forbids. This is the second channel: a process can ask, once, at
  ## the end, what its filesystem assumptions rested on.

proc linkCapabilities*(srcDir, dstDir: string): LinkCapability =
  ## ``probeLinkCapabilities`` against the process-wide cache. This is
  ## the entry point production callers use; the explicit-cache overload
  ## exists so tests can observe the probe count in isolation.
  withLock globalCacheLock:
    {.gcsafe.}:
      result = probeLinkCapabilities(globalCache, srcDir, dstDir)
      for notice in result.notices:
        if notice notin globalNotices:
          globalNotices.add(notice)
      for d in result.disagreements:
        if d.message notin globalNotices:
          globalNotices.add(d.message)

proc linkFactNotices*(): seq[string] =
  ## Every filesystem the process met that the fact table does not
  ## describe, and every table/probe disagreement it surfaced — in the
  ## order they were first seen. Empty is the healthy answer.
  withLock globalCacheLock:
    {.gcsafe.}:
      result = globalNotices

proc setGlobalFactAudit*(enabled: bool) =
  ## ``setFactAudit`` for the process-wide cache. See its doc for why
  ## this is off by default.
  withLock globalCacheLock:
    {.gcsafe.}:
      globalCache.setFactAudit(enabled)

proc globalProbeCount*(): int =
  withLock globalCacheLock:
    {.gcsafe.}:
      result = globalCache.probeCount()

proc resetGlobalLinkCapabilityCache*() =
  ## Drop the process-wide memo. Intended for tests and for a caller
  ## that knows a mount changed under it.
  withLock globalCacheLock:
    {.gcsafe.}:
      globalCache.clear()
      globalNotices.setLen(0)

# ---------------------------------------------------------------------------
# The decision the model dictates
# ---------------------------------------------------------------------------

proc preferredMechanisms*(cap: LinkCapability;
                          allowSharedInode = true): seq[LinkMechanism] =
  ## The mechanisms to try, best first, per the normative preference
  ## order: reflink, then hardlink, then copy.
  ##
  ## The order is a SAFETY order before it is a performance one. A
  ## reflink breaks sharing on write, so it behaves like a copy for
  ## every observer while costing like a link; a hardlink does not, and
  ## that is why it sorts second even though it is the cheapest.
  ##
  ## ``allowSharedInode = false`` drops the hardlink arm entirely, and it
  ## is expressed here so a caller states its mutation expectation once
  ## rather than re-deriving the policy at each call site.
  ##
  ## Both of the store's own callers pass ``false`` by default and
  ## Local-CAS-Hardlink-Materialization **M3** settled that they keep
  ## doing so: a destination that is written IN PLACE — which is what
  ## ``O_WRONLY|O_CREAT|O_TRUNC`` does, and what every compiler's ``-o``
  ## therefore does — edits the CAS blob through the shared inode, and no
  ## guard rail available to the store removes that. See
  ## ``Local-Content-Addressed-Store.md`` §"The shared-inode arm: a weaker
  ## guarantee, and the conditions for using it".
  ##
  ## ``lmCopy`` is always last and always present: copy is the arm that
  ## cannot be unavailable, which is what lets the spec promise that
  ## correctness never depends on which mechanism was used.
  ##
  ## **Where the two flags come from since F3.** ``cap.reflink`` and
  ## ``cap.hardlink`` are still what an attempt produced, except where
  ## the declared facts made the attempt pointless, in which case they
  ## are ``false`` and the attempt record says ``loNotAttempted`` and
  ## names the row. This function deliberately does NOT consult the fact
  ## tables itself: one seam is easier to reason about than two, and a
  ## second consultation here could only ever disagree with the first.
  result = @[]
  if cap.reflink:
    result.add lmReflink
  if cap.hardlink and allowSharedInode:
    result.add lmHardlink
  result.add lmCopy

proc describe*(cap: LinkCapability): string =
  ## One-line diagnostic suitable for a log or a receipt hint.
  ##
  ## Since F3 it also carries what the fact tables said, because a
  ## mechanism that was never attempted needs to explain itself: a log
  ## reading ``reflink=false(loNotAttempted)`` with no reason attached is
  ## indistinguishable from a broken probe.
  var parts: seq[string] = @[]
  parts.add("pair=" & cap.key)
  parts.add("probed=" & $cap.probed)
  parts.add("fs=" & describeEndpoint(cap.declared.source) & "->" &
            describeEndpoint(cap.declared.dest))
  parts.add("reflink=" & $cap.reflink & "(" & $cap.reflinkAttempt.outcome &
            "; table says " & $cap.reflinkVerdict & ")")
  parts.add("hardlink=" & $cap.hardlink & "(" &
            $cap.hardlinkAttempt.outcome & "; table says " &
            $cap.hardlinkVerdict & ")")
  for notice in cap.notices:
    parts.add("[NO TABLE ENTRY] " & notice)
  for d in cap.disagreements:
    parts.add("[" & d.message & "]")
  parts.join(" ")
