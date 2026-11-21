import std/[os, strutils]
from ./relocation import isRealDirectory
when defined(posix):
  import std/[posix, sha1]
type
  NormalizedPathKind* = enum
    npRelative
    npAbsolute

  NormalizedPath* = object
    kind*: NormalizedPathKind
    value*: string

proc joinUnderCwd*(root, path: string): string =
  ## Join a relative `path` onto an action's `root` (its cwd). Nim's `/`
  ## cancels a `<x>/..` inside `root` lexically, but the kernel starts the
  ## action in the directory the spelling reaches through the filesystem:
  ## with `detour -> far/deep` and cwd `<T>/detour/../work`, the action runs
  ## in `<T>/far/work` while `<T>/detour/../work / "stage"` folds to
  ## `<T>/work/stage`. A root carrying a parent walk is therefore kept
  ## verbatim, so whoever opens the result resolves it as the action does.
  var hasWalk = false
  for part in root.replace('\\', '/').split('/'):
    if part == "..":
      hasWalk = true
      break
  if hasWalk: root & "/" & path
  else: root / path

proc normalizeSeparators(path: string): string =
  path.replace('\\', '/')

proc collapseSlashes(path: string): string =
  result = newStringOfCap(path.len)
  var priorSlash = false
  for ch in path:
    if ch == '/':
      if not priorSlash:
        result.add(ch)
      priorSlash = true
    else:
      result.add(ch)
      priorSlash = false

proc absoluteRootLen(cleaned: string): int =
  ## The length of the root of `cleaned` (separators already `/`, runs of
  ## them collapsed) when it is an absolute path whose dot segments can be
  ## folded, or 0 when it is not: `/` (POSIX, or the current drive's root on
  ## Windows) is 1, a drive root such as `D:/` is 3.
  ##
  ## A drive-relative spelling (`D:foo`) is relative to a per-drive current
  ## directory this process cannot see, so it answers 0 and keeps the
  ## relative-path rules.
  if cleaned.startsWith("/"):
    1
  elif cleaned.len >= 3 and cleaned[0].isAlphaAscii and cleaned[1] == ':' and
      cleaned[2] == '/':
    3
  else:
    0

proc hasDotSegment(cleaned: string): bool =
  for part in cleaned.split('/'):
    if part == "." or part == "..":
      return true
  false

proc foldAbsoluteDotSegments(cleaned: string; rootLen: int;
                             physicalParents: bool): string =
  ## `cleaned`, absolute with a root of `rootLen` characters, with every `.`
  ## segment dropped and every `..` popping the segment before it.
  ##
  ## Lexical folding is exact only where the operating system folds the same
  ## way. Win32 normalizes a drive-rooted or `/`-rooted path lexically before
  ## any reparse point is consulted
  ## (https://learn.microsoft.com/en-us/dotnet/standard/io/file-path-formats#path-normalization),
  ## so a Windows path folds purely. A POSIX kernel resolves `..` against the
  ## directory it actually reached, so `/a/link/../b` is `<link target's
  ## parent>/b`, not `/a/b` -- "Never pop a symlink component lexically"
  ## (Monitor-Hook-Shim.md, §"Metadata, Probe, And Symlink APIs"; the same
  ## rule `relocation.foldedPath` follows). With `physicalParents` a `..` pops
  ## only a segment `lstat` shows to be an existing directory that is not a
  ## symlink; anything else is refused rather than given a spelling that
  ## names a different file from the one the process would reach.
  ##
  ## A `..` with nothing left to pop climbs above the root. The kernel would
  ## clamp it to the root, but a path composed that way is a mistake in
  ## whatever built it, so it is refused too.
  ##
  ## A trailing separator is kept, as the unfolded spelling keeps it.
  let root = cleaned[0 ..< rootLen]
  var parts: seq[string] = @[]
  for part in cleaned[rootLen .. ^1].split('/'):
    case part
    of "", ".":
      discard
    of "..":
      if parts.len == 0:
        raise newException(ValueError,
          "normalized path must not climb above its root with '..': " &
          cleaned)
      if physicalParents and not isRealDirectory(root & parts.join("/")):
        raise newException(ValueError,
          "normalized path has a '..' after '" & root & parts.join("/") &
          "', which is not an existing directory that is not a symlink, " &
          "so it cannot be folded to the directory the kernel reaches: " &
          cleaned)
      parts.setLen(parts.len - 1)
    else:
      parts.add(part)
  result = root & parts.join("/")
  if parts.len > 0 and cleaned.endsWith("/"):
    result.add('/')

proc normalizedPath*(path: string): NormalizedPath =
  ## `path` in the one spelling a `ProcessSpec` carries (and an action's
  ## identity is computed from): `/` separators, no empty segments, and no
  ## `..`.
  ##
  ## A RELATIVE path is kept as written apart from that, and a `..` in it is
  ## refused: it is resolved later against some base, which a `..` could
  ## escape, and a spelling that still holds one is not the single spelling
  ## of anything.
  ##
  ## An ABSOLUTE path (`/...`, or a drive-rooted `D:/...` in either separator
  ## spelling) has its `.` and `..` segments folded instead, so `/a/b/../c`
  ## is `/a/c` and `D:\a\b/../c` is `D:/a/c`. Callers hand this operator- and
  ## environment-supplied roots such as `$REPROBUILD_REPO_ROOT`, and
  ## `<checkout>/../<sibling>` is an ordinary way to name one. See
  ## `foldAbsoluteDotSegments` for when folding is refused (a `..` above the
  ## root, or after a POSIX symlink).
  ##
  ## A path spelled with two leading separators (a UNC share `\\server\share`
  ## or a `\\?\` / `\\.\` device path, where Windows does not fold `..` at
  ## all) still refuses `..`, as before.
  let separated = normalizeSeparators(path).strip()
  var cleaned = collapseSlashes(separated)
  if cleaned.len == 0:
    raise newException(ValueError, "normalized path must not be empty")
  if cleaned == ".":
    return NormalizedPath(kind: npRelative, value: ".")
  let rootLen =
    if separated.startsWith("//"): 0
    else: absoluteRootLen(cleaned)
  if rootLen > 0:
    if hasDotSegment(cleaned):
      # `/` on a POSIX host is resolved physically by the kernel; a drive
      # root, or any root on a Windows host, follows Win32's lexical rules.
      let physicalParents =
        when defined(windows): false
        else: rootLen == 1
      cleaned = foldAbsoluteDotSegments(cleaned, rootLen, physicalParents)
  else:
    for part in cleaned.split('/'):
      if part == "..":
        raise newException(ValueError,
          "normalized path must not contain '..'")
  let kind =
    if cleaned.startsWith("/"): npAbsolute
    else: npRelative
  NormalizedPath(kind: kind, value: cleaned)

proc `$`*(path: NormalizedPath): string =
  path.value

from std/os import absolutePath, normalizedPath, getTempDir, `/`

when defined(posix):
  proc unixSocketPathMaxLen*(): int =
    ## The longest Unix-domain socket path, in BYTES, that this binary can
    ## bind or dial — the ONE statement of that limit in the tree.
    ##
    ## It is not the kernel's ``sun_path`` size. Every socket here goes
    ## through Nim's ``std/net`` (``bindUnix`` / ``connectUnix``), whose
    ## ``nativesockets.makeUnixAddr`` refuses ``path.len >=
    ## Sockaddr_un_path_length`` with a bare ``socket path too long`` and
    ## then copies ``path.len + 1`` bytes (the terminating NUL) into
    ## ``sun_path``. ``std/posix`` declares ``Sockaddr_un_path_length`` as
    ## 108 on Linux but **92 on macOS**, below the kernel's 104, so the
    ## binding limit is the smaller of the two arrays, minus the NUL: 107 on
    ## Linux, 91 on macOS. Taking the ``min`` keeps this right on a platform
    ## where the two declarations disagree in the other direction.
    ##
    ## Bytes, not characters: a UTF-8 path counts every byte of every code
    ## point, which is what ``string.len`` measures.
    min(Sockaddr_un_path_length, sizeof(Sockaddr_un().sun_path)) - 1

  proc unixSocketPathFits*(path: string): bool =
    ## Whether ``path`` can be bound or dialled as a Unix-domain socket on
    ## this platform; see ``unixSocketPathMaxLen``.
    path.len <= unixSocketPathMaxLen()

proc runquotaEndpointPath*(name: string): string =
  ## Where a locally spawned ``runquotad`` listens — and the ONE place
  ## that derivation lives, because it used to live in twenty-three.
  ##
  ## THE SOCKET GETS A DIRECTORY OF ITS OWN. It is never a bare path
  ## dropped into the shared temp directory, and that is not tidiness.
  ## The socket's PARENT DIRECTORY is the rendezvous point: `runquotad`
  ## verifies it before it will bind, and every client verifies it again
  ## before it will connect — owned by this user, correct mode, and never
  ## group- or world-writable. A shared ``/tmp`` is root-owned ``1777``
  ## and fails both halves, so a socket placed straight into it is
  ## refused with `refusing a path owned by uid 0 with mode 1777` and the
  ## daemon exits before it ever prints its listening line.
  ##
  ## THE REFUSAL IS RIGHT, and is why this is a path change rather than a
  ## flag that turns the check off: a rendezvous point any local user can
  ## write is a rendezvous point any local user can REPLACE, and what
  ## this daemon hands out is the machine's whole build budget. A caller
  ## that binds in a world-writable directory is offering every local
  ## account the chance to answer for it.
  ##
  ## A directory that is not there yet, `runquotad` CREATES, with exactly
  ## the mode it requires; it only refuses one it found already made. So
  ## the per-caller directory below needs no privileged provisioning step
  ## — and it also keeps the daemon's published stats table, which lands
  ## BESIDE the socket, out of a shared directory where concurrent builds
  ## would collide on one file.
  ##
  ## ``name`` must already be unique to the caller, and it is used verbatim,
  ## so the same name always yields the same path. That suits a caller that
  ## owns its name for its whole life, such as a test fixture. It does NOT
  ## suit one that derives the name from its pid: a pid is reused, and a
  ## socket left behind by an earlier holder of it makes the private bind
  ## refuse. The daemon ``repro`` itself starts uses neither: it serves the
  ## shared per-user endpoint, ``runquota_ipc.userEndpoint``.
  ##
  ## Windows has neither directory nor mode here: named pipes live in the
  ## kernel object namespace and carry their own ACL, so the name is used
  ## as a pipe name directly and nothing above applies.
  when defined(windows):
    "\\\\.\\pipe\\runquotad-" & name.replace('\\', '_').replace('/', '_')
  else:
    result = getTempDir() / name / "runquota.sock"
    when defined(posix):
      # Bounded by the limit ``std/net`` actually enforces (which counts the
      # terminating NUL and, on macOS, is 92 rather than the kernel's 104).
      # Keep the daemon's private parent-directory checks while bounding
      # deep temp roots and names. Hash the full requested path so distinct
      # callers/roots stay distinct.
      if not unixSocketPathFits(result):
        let identity = $secureHash(os.normalizedPath(absolutePath(result)))
        result = "/tmp" / ("repro-rq-" & $getuid() & "-" & identity) /
          "runquota.sock"

proc extendedPath*(path: string): string =
  ## On Windows, rewrites a path into the `\\?\` extended-length form so
  ## file-system calls bypass the 260-character `MAX_PATH` limit. Returns
  ## `path` unchanged on non-Windows platforms, for the empty string, and
  ## for paths already in `\\?\` / `\\.\` / UNC (`\\`) form.
  ##
  ## Apply this only where a path is handed to a file-system call; never
  ## store, compare, log, or pass it to a child process, because `\\?\`
  ## paths do not compare equal to (and are not understood the same way
  ## as) the ordinary form.
  ##
  ## The body collapses any internal `\\` that results from joining a
  ## directory ending in `\\` with a path component beginning with `/`
  ## (a common quirk on Windows when `~` resolves to `C:\Users\X\` and
  ## the relative path uses forward slashes). The `\\?\` namespace is
  ## strict-canonical — Windows rejects paths with `\\` mid-segment —
  ## so this collapse is mandatory, not cosmetic.
  when defined(windows):
    if path.len == 0 or path.startsWith("\\\\"):
      path
    else:
      var canonical = os.normalizedPath(absolutePath(path)).replace('/', '\\')
      while "\\\\" in canonical:
        canonical = canonical.replace("\\\\", "\\")
      "\\\\?\\" & canonical
  else:
    path

func isXdgRuntimeDirPath*(normalized: string): bool =
  ## True for the per-user XDG runtime directory `/run/user/<uid>` and
  ## anything beneath it. `normalized` must already use forward slashes.
  ##
  ## This subtree is NOT host runtime state. It is an ordinary per-user
  ## tmpfs mount whose entire purpose is user-owned scratch: it holds
  ## regular files with stable inodes and mtimes that reopen and
  ## fingerprint exactly like files under `/tmp`. It is also the default
  ## `TMPDIR` on a systemd host and the `TMPDIR` this repository's own
  ## agent instructions hand out (short socket paths), so build actions
  ## routinely read and write their real inputs and outputs here, inside a
  ## project or not. That is why it is classified here, by what the subtree
  ## IS, and not left to `VolatileScope`, which only knows where the
  ## invocation's own trees are.
  if not normalized.startsWith("/run/user/"):
    return false
  let rest = normalized["/run/user/".len .. ^1]
  var uidLen = 0
  while uidLen < rest.len and rest[uidLen] in {'0' .. '9'}:
    inc uidLen
  # `/run/user/<uid>` exactly, or `/run/user/<uid>/...` — never
  # `/run/userland`, and never a non-numeric component.
  uidLen > 0 and (uidLen == rest.len or rest[uidLen] == '/')

func trimmedRuntimePath(path: string): string =
  result = path.replace('\\', '/')
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

func isAtOrUnder(path, root: string): bool =
  path == root or path.startsWith(if root == "/": root else: root & "/")

func isOrdinaryFileUnderRuntimeMount*(normalized: string): bool =
  ## True for the two places under a volatile prefix that hold ordinary files
  ## whoever's they are. `normalized` must already use forward slashes.
  ##
  ## * A path in a DIRECTORY under `/dev/shm`. POSIX shared-memory objects and
  ##   named semaphores are flat entries of `/dev/shm`, because a shm_open(3)
  ##   name may not contain a further slash
  ##   (https://man7.org/linux/man-pages/man3/shm_open.3.html). Anything in a
  ##   subdirectory was put there as a file: a build tree moved to `/dev/shm`
  ##   for speed, a workspace with its sibling repositories, a dependency
  ##   checkout.
  ## * `/run/media/<user>/<volume>`, where desktop hosts automount removable
  ##   and secondary disks, projects and their dependencies included.
  ##
  ## Kept whether or not the path is inside the invocation's own trees
  ## (`dropsAsVolatileRuntimeState`). Those trees are the build's roots and
  ## its source trees (its workspace, the checkouts its lock pins), and a
  ## build also reads files no tree of it contains: an input named by
  ## absolute path, a tool installed there. The path alone says these places
  ## hold ordinary files, the way `isXdgRuntimeDirPath` says it of
  ## `/run/user/<uid>`, so dropping a read there could only serve a stale
  ## result.
  const shmRoot = "/dev/shm/"
  if normalized.startsWith(shmRoot):
    let slash = normalized.find('/', shmRoot.len)
    return slash > shmRoot.len and slash < normalized.high
  normalized.startsWith("/run/media/")

func isVolatileRuntimeStatePath*(path: string): bool =
  ## True for a path under a prefix that holds the running kernel's or the
  ## host's live runtime state: `/dev`, `/proc`, `/sys` and `/run`, less the
  ## per-user `/run/user/<uid>` (`isXdgRuntimeDirPath`). Such state cannot be
  ## reopened and fingerprinted reliably after the action has finished.
  ##
  ## THIS IS A CLASSIFICATION BY PREFIX, NOT THE DECISION. The same prefixes
  ## also hold ordinary files: a build tree on `/dev/shm/<dir>`, a disk an
  ## administrator mounted under `/run/<dir>`, NixOS's system profile under
  ## `/run/current-system`. The path alone cannot tell those apart, so
  ## nothing drops a read on this answer alone: `dropsAsVolatileRuntimeState`
  ## asks it together with the invocation's `VolatileScope` (a read inside
  ## the invocation's own trees is never dropped), and `volatileInputVerdict`
  ## then asks the disk what a path under `/run` is (only a socket, a FIFO or
  ## a device node is dropped there).
  let normalized = path.replace('\\', '/')
  if normalized == "/dev" or normalized.startsWith("/dev/") or
     normalized == "/proc" or normalized.startsWith("/proc/") or
     normalized == "/sys" or normalized.startsWith("/sys/"):
    return true
  if normalized == "/run" or normalized.startsWith("/run/"):
    return not normalized.isXdgRuntimeDirPath()
  false

func volatileRootRefusal*(root: string): string =
  ## Why `root`, a directory whose files an invocation reads as its own (its
  ## project, repository, work, store or output root, or an action's working
  ## directory when none is declared), cannot be told apart from the runtime
  ## state the fold drops; "" when it can.
  ##
  ## A root strictly inside a volatile prefix is fine: everything at or under
  ## it is the invocation's, so `VolatileScope` keeps it, and everything
  ## outside it is still dropped. What is left are the roots where keeping
  ## and dropping are both wrong. Keeping every flat entry of `/dev/shm`
  ## makes every action that touches a POSIX semaphore miss on every run;
  ## dropping them drops the project's own files with them, which serves a
  ## stale result and certifies content nobody tested. Such a root is
  ## REFUSED, loudly, rather than resolved either way in silence.
  let r = trimmedRuntimePath(root)
  if r == "/":
    return "it contains /dev, /proc, /sys and /run, whose reads are " &
      "runtime state and never a cache input, so the project's own files " &
      "there could not be fingerprinted"
  if r in ["/dev", "/dev/shm", "/run"]:
    return "it is a flat namespace of runtime objects (device nodes, POSIX " &
      "shared-memory objects, pid files, sockets) whose reads are never a " &
      "cache input, and a project file there cannot be told apart from one " &
      "of them by its path; move the project into a directory of its own, " &
      "such as " & r & "/<name>"
  if r.isAtOrUnder("/proc") or r.isAtOrUnder("/sys"):
    return "it is on a kernel pseudo-filesystem, whose reads describe the " &
      "running kernel and are never a cache input"
  ""

type
  VolatileScope* = object
    ## The trees an invocation reads as its OWN, for the one purpose of
    ## deciding which reads under a volatile prefix are dropped. Only roots
    ## that lie under such a prefix and pass `volatileRootRefusal` are held,
    ## so the default value exempts nothing, and a root elsewhere, which
    ## needs no exemption, is not carried around.
    exempt: seq[string]

func volatileScope*(roots: openArray[string]): VolatileScope =
  ## The scope of an invocation whose own trees are `roots` (absolute). A
  ## root that `volatileRootRefusal` refuses is LEFT OUT here, which drops
  ## its files: refusing such a root is the caller's job, before anything
  ## runs (the build engine's `volatileRootRefusals`).
  for root in roots:
    let r = trimmedRuntimePath(root)
    if r.len == 0 or not r.startsWith("/"):
      continue
    if not r.isVolatileRuntimeStatePath() or r.volatileRootRefusal().len > 0:
      continue
    if r notin result.exempt:
      result.exempt.add(r)

func exemptRoots*(scope: VolatileScope): seq[string] =
  scope.exempt

func dropsAsVolatileRuntimeState*(path: string; scope: VolatileScope): bool =
  ## THE PREFIX HALF of the decision: whether `path` is in a place the fold
  ## cannot keep on its location alone. True exactly when the path is under a
  ## volatile prefix (`isVolatileRuntimeStatePath`), is not in a place that
  ## holds only ordinary files (`isOrdinaryFileUnderRuntimeMount`), and is at
  ## or under none of the invocation's own trees (`scope`: its roots and the
  ## trees it reads as source).
  ##
  ## PURE, and not the whole decision for a recorded INPUT. Under `/dev`,
  ## `/proc` and `/sys` its answer is final. Under `/run` it only says that
  ## the path has to be looked at: `volatileInputVerdict` keeps it unless it
  ## is a socket, a FIFO or a device node. A caller deciding whether an input
  ## enters an action's evidence or cache record must use that, never this
  ## alone; the build engine still uses this for the observations that are
  ## not inputs (an action's writes and removals), where what a path is after
  ## the action says nothing about what it read.
  ##
  ## THE HISTORY, because each step was a silent stale serve. The decision
  ## used to be the prefix less `/run/user/<uid>` and `/run/media`. That lost
  ## the listing of a project at `/dev/shm/<name>` and a project on a mount at
  ## `/run/<dir>`; the invocation's own roots close those, and a root that
  ## cannot be told apart from the runtime state around it is refused
  ## (`volatileRootRefusal`). The scope also holds the trees the build reads
  ## as source outside its roots (the build engine's
  ## `BuildEngineConfig.sourceTrees`), so a sibling repository on a mount at
  ## `/run/<dir>` is kept as the project is. It still lost NixOS's system
  ## profile: `/run/current-system/sw/bin` (the system `PATH`),
  ## `/run/wrappers/bin` and `/run/opengl-driver/lib` are symbolic links into
  ## the store, so after a `nixos-rebuild switch` an edge that ran one of
  ## those tools or loaded one of those drivers kept hitting with the old
  ## outputs. That is what `volatileInputVerdict` closes.
  let normalized = path.replace('\\', '/')
  if not normalized.isVolatileRuntimeStatePath():
    return false
  if normalized.isOrdinaryFileUnderRuntimeMount():
    return false
  for root in scope.exempt:
    if normalized.isAtOrUnder(root):
      return false
  true

type
  RuntimeEntryKind* = enum
    ## What a path under `/run` IS on disk, as far as deciding whether a
    ## recorded input of it can be re-checked later (`runtimeEntryKind`).
    rekAbsent
      ## Nothing there (`ENOENT`, `ENOTDIR`): the record was an absence
      ## probe, such as a `PATH` walk missing in `/run/wrappers/bin`.
    rekRegular
      ## A regular file, directly or through a symbolic link.
    rekDirectory
      ## A directory, directly or through a symbolic link.
    rekSymlink
      ## A DANGLING symbolic link. The link itself is an entry whose target
      ## `readlink` can re-check.
    rekSocket
      ## A unix-domain socket: a daemon's endpoint.
    rekFifo
      ## A named pipe.
    rekDevice
      ## A character or block device node.
    rekUnknown
      ## The type could not be read (`EACCES`, `ELOOP`, a non-POSIX host).

  VolatileVerdict* = enum
    ## The volatile-runtime fold's answer for one recorded INPUT: a read, an
    ## executed image, a loaded library, a probe or an enumeration
    ## (`volatileInputVerdict`).
    vvKeep
      ## An ordinary input, fingerprinted like any other.
    vvDropKernelState
      ## Under `/dev`, `/proc` or `/sys`, outside the places and trees the
      ## prefix rule keeps: the running kernel's or a device's state, dropped
      ## by prefix as before. Never makes a record host-bound: nearly every
      ## action reads `/dev/null`.
    vvDropRuntimeObject
      ## A socket, a FIFO or a device node under `/run`: a runtime object of
      ## THIS host, with no content to fingerprint. Dropped, and the record
      ## that read it read host state no other host has, so the build engine
      ## keeps it off every other host (not portable).

func isDrop*(verdict: VolatileVerdict): bool =
  verdict != vvKeep

func isRuntimeObjectKind*(kind: RuntimeEntryKind): bool =
  ## The kinds a recorded input under `/run` is dropped for.
  kind in {rekSocket, rekFifo, rekDevice}

proc runtimeEntryKind*(path: string): RuntimeEntryKind =
  ## What `path` is on disk NOW. `lstat` first; a symbolic link is followed
  ## with `stat`, so a link into the store (`/run/current-system`,
  ## `/run/opengl-driver`) answers with what it points at, and a link to a
  ## socket answers `rekSocket` (opening it opens the socket). A link whose
  ## target is gone answers `rekSymlink`, not `rekAbsent`.
  ##
  ## Intermediate components are resolved by the kernel either way, so
  ## `/run/current-system/sw/bin/sh` answers for the store file it reaches.
  ##
  ## `rekUnknown` on any error other than "not there", and on a non-POSIX
  ## host (where no path is under `/run` anyway). `volatileVerdictFor` keeps
  ## such a path: the wrong answer then costs a spurious re-run, never a
  ## stale result.
  ##
  ## https://man7.org/linux/man-pages/man2/lstat.2.html and
  ## https://man7.org/linux/man-pages/man7/inode.7.html (the `S_IS*` tests).
  when defined(posix):
    var st: Stat
    if lstat(cstring(path), st) != 0:
      let err = errno
      return
        if err == ENOENT or err == ENOTDIR: rekAbsent
        else: rekUnknown
    if S_ISLNK(st.st_mode):
      var target: Stat
      if stat(cstring(path), target) != 0:
        let err = errno
        return
          if err == ENOENT or err == ENOTDIR: rekSymlink
          else: rekUnknown
      st = target
    if S_ISREG(st.st_mode): rekRegular
    elif S_ISDIR(st.st_mode): rekDirectory
    elif S_ISSOCK(st.st_mode): rekSocket
    elif S_ISFIFO(st.st_mode): rekFifo
    elif S_ISCHR(st.st_mode) or S_ISBLK(st.st_mode): rekDevice
    else: rekUnknown
  else:
    rekUnknown

func isUnderRunPrefix(normalized: string): bool =
  normalized == "/run" or normalized.startsWith("/run/")

func volatileVerdictFor*(path: string; scope: VolatileScope;
                         kind: RuntimeEntryKind): VolatileVerdict =
  ## The decision for a recorded input of `path`, given what it is on disk
  ## (`kind`, from `runtimeEntryKind`). PURE, so it can be tested for every
  ## kind under `/run`, where a test cannot create entries.
  ##
  ## * The prefix rule keeps it (`dropsAsVolatileRuntimeState` false):
  ##   outside every volatile prefix, `/run/user/<uid>`, `/run/media`, a
  ##   directory under `/dev/shm`, the invocation's own trees. Kept, whatever
  ##   `kind` says.
  ## * Under `/dev`, `/proc` or `/sys`: dropped by prefix, as before
  ##   (`vvDropKernelState`). Their entries describe the running kernel and
  ##   devices; what a file there "contains" is not a fact a later lookup can
  ##   re-check.
  ## * Under `/run`, BY FILE TYPE. A regular file, a directory, a symbolic
  ##   link or an absent path is KEPT: on NixOS `/run/current-system`,
  ##   `/run/wrappers` and `/run/opengl-driver` are links into the store, and
  ##   an absence (a `PATH` walk miss there) is as re-checkable as a file and
  ##   dropping it would hide a tool that later shadows the one that ran. A
  ##   file a daemon rewrites (a pid file) is kept too; the cost is a re-run
  ##   when it changes, which is the honest answer for an action that read it.
  ##   A socket, a FIFO or a device node is DROPPED (`vvDropRuntimeObject`):
  ##   there is nothing to fingerprint, and keeping it would make the action
  ##   miss on every run.
  let normalized = path.replace('\\', '/')
  if not normalized.dropsAsVolatileRuntimeState(scope):
    return vvKeep
  if not normalized.isUnderRunPrefix():
    return vvDropKernelState
  if kind.isRuntimeObjectKind(): vvDropRuntimeObject
  else: vvKeep

proc volatileInputVerdict*(path: string; scope: VolatileScope):
    VolatileVerdict =
  ## THE decision for a recorded INPUT of `path` (a read, an executed image,
  ## a loaded library, a probe, an enumeration, a declared or tool-reported
  ## input): whether it is left out of an action's evidence and cache record
  ## as runtime state, and why. `volatileVerdictFor` with the kind read from
  ## disk, and the disk is read only for a path the prefix rule would drop
  ## under `/run`, so every other path costs no system call.
  ##
  ## A WRONG DROP IS A STALE SERVE: the action is fingerprinted as though it
  ## had never read the file. Every caller that decides what enters an
  ## action's evidence, cache record or portable record goes through this
  ## one proc, so they cannot disagree.
  ##
  ## The kind is read when the action has FINISHED (the fold) or later (the
  ## cache record), not when the action read the path. A socket the action
  ## saw and that is gone by then reads as absent and is kept as an absence,
  ## which costs at most a re-run when it reappears.
  let normalized = path.replace('\\', '/')
  if not normalized.dropsAsVolatileRuntimeState(scope):
    return vvKeep
  if not normalized.isUnderRunPrefix():
    return vvDropKernelState
  volatileVerdictFor(normalized, scope, runtimeEntryKind(path))

proc linkHopsUnderRun*(path: string): seq[string] =
  ## The proper prefixes of `path` under `/run` that are symbolic links
  ## (`lstat`), shortest first: `/run/current-system` and
  ## `/run/current-system/sw` for `/run/current-system/sw/bin/gcc` on NixOS.
  ## Empty for a path outside `/run` and on a non-POSIX host.
  ##
  ## WHY THE BUILD ENGINE RECORDS THEM. A tool, library or data file reached
  ## through a link under `/run` is kept as an input (`volatileInputVerdict`)
  ## and recorded at the path as spelled, but a metadata comparison of that
  ## path (`ffpHybrid`, `ffpTimestamp`) sees only the file the link reaches
  ## NOW: after `nixos-rebuild switch` retargets `/run/current-system`, the
  ## new generation's file of the same size has the same mtime, because every
  ## file in the Nix store has mtime 1, and the edge is served stale. The
  ## monitor records the components of a resolution only for `realpath` and
  ## the `readlink` family, not for an `open` or an `execve` through the
  ## link. The links themselves can be re-checked: a link to a directory is
  ## fingerprinted by its `readlink` text (`linkedDirectoryIdentity` in
  ## `repro_local_store`), so a retarget moves a recorded input whatever the
  ## two targets hold.
  ##
  ## The final component is not included: it is the input itself, already
  ## recorded. A component that cannot be read is skipped: the input it
  ## leads to is still recorded, and its own fingerprint decides.
  ##
  ## https://man7.org/linux/man-pages/man7/path_resolution.7.html
  let normalized = path.replace('\\', '/')
  if not normalized.isUnderRunPrefix():
    return
  when defined(posix):
    var prefix = ""
    let parts = normalized.split('/')
    for i in 0 ..< parts.high:
      if parts[i].len == 0:
        continue
      prefix.add('/')
      prefix.add(parts[i])
      if prefix == "/run":
        continue
      var st: Stat
      if lstat(cstring(prefix), st) == 0 and S_ISLNK(st.st_mode):
        result.add(prefix)

proc dropsAsVolatileInput*(path: string; scope: VolatileScope): bool =
  ## Whether a recorded input of `path` is dropped (`volatileInputVerdict`).
  volatileInputVerdict(path, scope).isDrop

func tarOperand*(path: string): string =
  ## W16/N48: a path about to be handed to ``tar`` as a COMMAND-LINE OPERAND.
  ##
  ## GNU tar unquotes names given on the command line — ``--unquote`` is the
  ## DEFAULT — so on Windows every backslash that precedes an escape letter is
  ## consumed before tar ever uses the path. (WHICH names is measured below,
  ## not assumed: the archive operand turned out NOT to be one of them.)
  ## A destination whose leaf begins ``a b f n r t v`` makes tar raise
  ## (exit 2, zero files), and one beginning ``\0`` makes it SILENTLY
  ## EXTRACT INTO THE PARENT and exit 0 — no error at all. Any path
  ## COMPONENT can trigger it, not just the leaf. Replacing every backslash
  ## with a forward slash removes the TRIGGER rather than asking tar to
  ## behave, so it is correct on GNU tar, on bsdtar, and on anything else.
  ##
  ## WHICH OPERAND, measured on GNU tar 1.35 rather than assumed, because the
  ## two defects do NOT reach the same ones:
  ##
  ##   * ``-C`` IS unquoted. Four leaves behind a single backslash, extracting
  ##     a good archive: ``tango`` exit 2 / 0 files, ``rvw`` exit 2 / 0 files,
  ##     ``0zero`` EXIT 0 with the payload in the PARENT and the destination
  ##     empty, ``sierra`` exit 0 / correct. Any COMPONENT can trigger it, not
  ##     just the leaf.
  ##   * ``-f`` is NOT unquoted. The same four leaves in the ARCHIVE operand,
  ##     with and without ``--force-local``, relative so no drive letter can
  ##     confound: 8 of 8 exit 0 and list the archive correctly. So on this
  ##     tar the rewrite is LOAD-BEARING for ``-C`` and DEFENCE IN DEPTH for
  ##     ``-f`` — applied to both anyway, because one rule for every operand
  ##     is one rule to keep true, the rewrite costs nothing on a path that
  ##     did not need it, and "which operands does this tar unquote" is a
  ##     property of the tar, not of us.
  ##
  ## It does NOT address the second Windows defect, which is the ``-f``
  ## operand's own: GNU tar reads one whose first ``:`` precedes any ``/`` as
  ## a remote ``host:path``, so ``C:/…`` fails exactly as ``C:\…`` does
  ## (measured: exit 128, "Cannot connect to M: resolve failed"). That one
  ## needs ``--force-local``, a GNU extension, offered in an attempt that is
  ## ALLOWED TO FAIL so a bsdtar host still reaches its own shape.
  ##
  ## WINDOWS ONLY, and that asymmetry is deliberate. On POSIX a backslash is
  ## a legal FILENAME character, so rewriting one here would corrupt a path
  ## that means exactly what it says. The POSIX half is therefore a stated
  ## RESIDUAL, not a solved case: a POSIX destination whose name literally
  ## contains ``\t`` is still mis-read by GNU tar, and the only remedy is
  ## the GNU-only ``--no-unquote`` — ruled out because bsdtar rejects it AND
  ## then exits without reading its stdin, HANGING a piped copy.
  ##
  ## The full measured table lives in the W16 block comment above
  ## ``extractTarZst`` in
  ## ``libs/repro_home_apply/src/repro_home_apply/builtin_adapter.nim``.
  ## This proc is the single implementation every ``tar`` call site shares;
  ## a second one would be a second thing to keep true.
  when defined(windows):
    path.replace('\\', '/')
  else:
    path
