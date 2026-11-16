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
