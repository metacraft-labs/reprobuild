import std/[strutils]
when defined(posix):
  import std/[posix, sha1]
type
  NormalizedPathKind* = enum
    npRelative
    npAbsolute

  NormalizedPath* = object
    kind*: NormalizedPathKind
    value*: string

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

proc normalizedPath*(path: string): NormalizedPath =
  let cleaned = collapseSlashes(normalizeSeparators(path).strip())
  if cleaned.len == 0:
    raise newException(ValueError, "normalized path must not be empty")
  if cleaned == ".":
    return NormalizedPath(kind: npRelative, value: ".")
  for part in cleaned.split('/'):
    if part == "..":
      raise newException(ValueError, "normalized path must not contain '..'")
  let kind =
    if cleaned.startsWith("/"): npAbsolute
    else: npRelative
  NormalizedPath(kind: kind, value: cleaned)

proc `$`*(path: NormalizedPath): string =
  path.value

from std/os import absolutePath, normalizedPath, getTempDir, `/`

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
  ## ``name`` must already be unique to the caller — a PID, normally.
  ##
  ## Windows has neither directory nor mode here: named pipes live in the
  ## kernel object namespace and carry their own ACL, so the name is used
  ## as a pipe name directly and nothing above applies.
  when defined(windows):
    "\\\\.\\pipe\\runquotad-" & name.replace('\\', '_').replace('/', '_')
  else:
    result = getTempDir() / name / "runquota.sock"
    when defined(posix):
      # sun_path includes its terminating NUL. Keep the daemon's private
      # parent-directory checks while bounding deep temp roots and names.
      # Hash the full requested path so distinct callers/roots stay distinct.
      if result.len >= sizeof(Sockaddr_un().sun_path):
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
  ## routinely read and write their real inputs and outputs here.
  ##
  ## It is carved out of `isVolatileRuntimeStatePath` below because the
  ## blanket `/run` prefix was silently emptying those actions' evidence.
  if not normalized.startsWith("/run/user/"):
    return false
  let rest = normalized["/run/user/".len .. ^1]
  var uidLen = 0
  while uidLen < rest.len and rest[uidLen] in {'0' .. '9'}:
    inc uidLen
  # `/run/user/<uid>` exactly, or `/run/user/<uid>/...` — never
  # `/run/userland`, and never a non-numeric component.
  uidLen > 0 and (uidLen == rest.len or rest[uidLen] == '/')

func isVolatileRuntimeStatePath*(path: string): bool =
  ## True for paths that describe the running kernel or the host's live
  ## runtime state at one instant. Such a path cannot be reopened and
  ## fingerprinted reliably after the action has finished, so it must
  ## never become a cache input.
  ##
  ## `/dev`, `/proc` and `/sys` are kernel pseudo-filesystems and qualify
  ## outright. `/run` is a tmpfs of ordinary files and qualifies only
  ## because most of it holds host runtime state (pid files, `nscd`,
  ## `systemd`, dbus). Its `/run/user/<uid>` subtree does not — see
  ## `isXdgRuntimeDirPath`.
  ##
  ## THIS IS A SILENT DROP, so it is deliberately narrow. A path that
  ## lands here leaves no diagnostic behind: the monitor records the read
  ## and the fold discards it, and the action is then fingerprinted as
  ## though it had never read anything. That direction is a stale SERVE,
  ## not a spurious miss, which is why the prefix set must cover only
  ## paths that genuinely cannot be re-read — and why the XDG runtime
  ## directory, which can, is excluded.
  let normalized = path.replace('\\', '/')
  if normalized == "/dev" or normalized.startsWith("/dev/") or
     normalized == "/proc" or normalized.startsWith("/proc/") or
     normalized == "/sys" or normalized.startsWith("/sys/"):
    return true
  if normalized == "/run" or normalized.startsWith("/run/"):
    return not normalized.isXdgRuntimeDirPath()
  false
