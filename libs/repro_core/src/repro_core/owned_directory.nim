## Admission of a per-user directory that holds a rendezvous point: a
## Unix-domain socket another process connects to, or a token it reads.
##
## Such a directory is what makes a path in a shared temporary directory safe
## to use. Whoever owns it, or can write it, can replace what is inside it, so
## it is admitted only when ``lstat`` says it is a real directory (never a
## symbolic link, which could point anywhere), owned by the effective uid,
## and -- for the directory that holds the rendezvous point itself -- granting
## no group or other permission at all. A directory that fails is REFUSED and
## left exactly as it is: whoever created it may still be using it, and a
## repair would hand them whatever is put in it next.
##
## The rules each caller applies are in its governing spec:
##
## * the development-session control API, reprobuild-pm
##   ``spec/Development-Environments-And-Control-API.md``
##   §"Control API Access Control" (``repro_cli_support/dev_session_access``);
## * the development store daemon's endpoint directory, reprobuild-pm
##   ``spec/Store-Daemon-And-Multi-User-Coordination.md`` §"The per-user
##   endpoint directory is private" (``repro_store_daemon/protocol``).
##
## The check is POSIX-only. On Windows the callers place these files under
## the user profile, whose ACL already admits only that user.

import std/[os, strutils]

when defined(posix):
  import std/posix

type
  OwnedDirectoryError* = object of IOError
    ## The directory exists but may not be used: it is not a real directory,
    ## it is another account's, or its mode grants more than it may. An
    ## ``IOError`` so that callers which caught the earlier ``IOError`` from
    ## ``dev_session_access`` keep catching it.

  OwnedDirectoryRole* = object
    ## What the directory is for, so a refusal can say what is at stake.
    noun*: string
      ## Names the directory in a message: ``"dev-session control
      ## directory"``.
    exposure*: string
      ## What another account could do with it: ``"another account could
      ## read the session token or replace the control socket"``.
    remedy*: string
      ## What the user can do about it: ``"remove it or fix its mode and
      ## start the session again"``.

when defined(posix):
  const
    OverflowUidFile* = "/proc/sys/kernel/overflowuid"
      ## The uid the kernel shows for an owner the reader's user namespace
      ## cannot map (``overflowuid`` in proc(5)); 65534 unless reconfigured.
    UidMapFile* = "/proc/self/uid_map"
    DefaultOverflowUid* = 65534

  proc namespaceMapsOwnerAway*(uid: int; uidMapText: string;
                               overflowUid: int): bool =
    ## True when ``uid`` is what the kernel shows for an owner that this
    ## process's user namespace has no account for: the kernel's overflow uid,
    ## seen from a namespace other than the initial one, and not itself mapped
    ## by ``uidMapText`` (the contents of ``/proc/self/uid_map``: lines of
    ## ``inside outside count``).
    ##
    ## Outside a user namespace the overflow uid is an ordinary account
    ## (``nobody``, or whoever a site gave it to), so it is NOT unmapped there
    ## -- the initial namespace maps every uid to itself, one line
    ## ``0 0 4294967295``. Inside a sandbox, such as a Nix build, the
    ## directories the sandbox was made from belong to accounts of the host
    ## that the sandbox's mapped uid is not, and they show as the overflow uid.
    ##
    ## NOTE what this does not say: the owner may be host root, but it may also
    ## be ANY other host account, an attacker's included -- every account the
    ## namespace cannot name shows as the same uid. So ``namespaceMapsOwnerAway``
    ## alone is no reason to trust a directory; ``ancestorOwnerIsTrusted``
    ## adds the condition that makes it one.
    if overflowUid < 0 or uid != overflowUid:
      return false
    var lines = 0
    for raw in uidMapText.splitLines():
      let line = raw.strip()
      if line.len == 0:
        continue
      inc lines
      let parts = line.splitWhitespace()
      if parts.len != 3:
        return false  # not understood: do not widen the trust
      try:
        let inside = parseBiggestInt(parts[0])
        let outside = parseBiggestInt(parts[1])
        let count = parseBiggestInt(parts[2])
        if inside < 0 or outside < 0 or count <= 0:
          return false
        if inside == 0 and outside == 0 and count >= 4294967295'i64:
          return false  # the initial namespace maps every uid to itself
        if int64(uid) >= inside and int64(uid) < inside + count:
          return false  # mapped: a real account of this namespace
      except ValueError:
        return false
    lines > 0

  proc ownerIsUnmappedHere*(uid: int): bool =
    ## ``namespaceMapsOwnerAway`` for this process, read from /proc. False
    ## when either file cannot be read (no /proc, or ``/proc/sys`` masked):
    ## the stricter rule then applies.
    try:
      let overflow = parseInt(readFile(OverflowUidFile).strip())
      namespaceMapsOwnerAway(uid, readFile(UidMapFile), overflow)
    except CatchableError:
      false

  proc ancestorOwnerIsTrustedFor*(owner, me, parentMode: int;
                                  unmapped: bool): bool =
    ## The owner rule of a walk down the ancestors of a trusted store, given
    ## the mode of the directory that CONTAINS the entry being judged
    ## (``-1`` for ``/``, which has none) and whether ``owner`` is an unmapped
    ## owner (``namespaceMapsOwnerAway``).
    ##
    ## The entry belongs to this user or to root: trusted. It belongs to an
    ## unmapped owner: that is host root, or any other account of the host, and
    ## the namespace cannot tell which. Such an entry is trusted only when no
    ## unprivileged account could have created it, i.e. its container is not
    ## writable by group or others (the sandbox's own root and the host
    ## directories above the work area), and never when the container is a
    ## shared directory, sticky or not -- an attacker's ``/tmp/x`` and the
    ## symlink they left in ``/tmp`` are refused as before. ``/`` has no
    ## container and is the sandbox's own root.
    if owner == me or owner == 0:
      return true
    if not unmapped:
      return false
    parentMode == -1 or (parentMode and 0o022) == 0

  proc ancestorOwnerIsTrusted*(owner, me, parentMode: int): bool =
    ## ``ancestorOwnerIsTrustedFor`` for this process's namespace.
    ancestorOwnerIsTrustedFor(owner, me, parentMode,
      owner != me and owner != 0 and ownerIsUnmappedHere(owner))

when defined(posix):
  proc effectiveUid(): int = int(geteuid())

  proc modeText(mode: int): string = "0" & toOct(mode, 3)

  proc verifyOwnedDirectory*(path: string; privateDir: bool;
                             role: OwnedDirectoryRole) =
    ## Refuse ``path`` unless it is a real directory (not a symlink) owned by
    ## the effective uid. ``privateDir`` additionally refuses ANY group or
    ## other permission (the directory that holds the rendezvous point);
    ## otherwise only group or other WRITE is refused, which is what lets
    ## another account replace an entry below it.
    ##
    ## Every refusal names the directory, its owner and its mode. Raises
    ## ``OwnedDirectoryError`` for a refusal and ``OSError`` when ``path``
    ## cannot be inspected at all.
    var st: Stat
    if lstat(path.cstring, st) != 0:
      raiseOSError(osLastError(), "cannot inspect the " & role.noun & " " &
        path)
    let mode = int(st.st_mode) and 0o777
    let owner = int(st.st_uid)
    let me = effectiveUid()
    if not S_ISDIR(st.st_mode):
      raise newException(OwnedDirectoryError,
        "refusing the " & role.noun & " " & path & ": it is not a directory " &
        "(a symlink or another file is in its place; owned by uid " & $owner &
        ", mode " & modeText(mode) & "); " & role.remedy)
    if owner != me:
      raise newException(OwnedDirectoryError,
        "refusing the " & role.noun & " " & path & ": it is owned by uid " &
        $owner & " (mode " & modeText(mode) & "), not by this user (uid " &
        $me & "), so " & role.exposure & "; " & role.remedy)
    let forbidden = if privateDir: 0o077 else: 0o022
    if (mode and forbidden) != 0:
      raise newException(OwnedDirectoryError,
        "refusing the " & role.noun & " " & path & ": its mode is " &
        modeText(mode) & " (owned by uid " & $owner & ", this user), and it " &
        "must grant " &
        (if privateDir: "no group or other permissions (0700)"
          else: "no group or other write permission") &
        "; " & role.remedy)

  proc ensureOwnedDirectory*(path: string; privateDir: bool;
                             role: OwnedDirectoryRole) =
    ## Create ``path`` as ``0700`` when it is missing; then verify it
    ## (``verifyOwnedDirectory``), whoever created it. An existing directory
    ## is never chmod-ed, chown-ed, renamed or removed.
    if mkdir(path.cstring, Mode(0o700)) == 0:
      # mkdir's mode is narrowed by the umask; set it exactly.
      if chmod(path.cstring, Mode(0o700)) != 0:
        raiseOSError(osLastError(), path)
    elif errno != EEXIST:
      raiseOSError(osLastError(),
        "cannot create the " & role.noun & " " & path)
    verifyOwnedDirectory(path, privateDir, role)
