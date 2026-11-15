## Access control for the development-session control API.
##
## The rules are reprobuild-pm
## `spec/Development-Environments-And-Control-API.md`
## §"Control API Access Control". In short: whoever reaches the control API
## can stop the session (and, once restart and run routes land, run commands
## as the session's user), and being "local" is not a boundary -- every
## account on a multi-user host can connect to a loopback port, and any web
## page can send a CORS-simple request to one or reach it through DNS
## rebinding. So:
##
## * the endpoint lives in a per-user directory only its user can enter
##   (``devSessionEndpointDir`` / ``ensurePrivateEndpointDir``);
## * on POSIX the default transport is an AF_UNIX socket in that directory
##   (``controlSocketPath``), so no other account can even connect;
## * every request carries a per-session random token
##   (``mintControlToken`` / ``writeControlToken``), compared without an early
##   exit (``tokensEqual``);
## * a request is refused unless its ``Host`` names a loopback host or the
##   configured ``--http`` host (``hostHeaderAccepted``) and any ``Origin`` is
##   the API's own (``originAccepted``);
## * a non-loopback ``--http`` host needs an explicit opt-in
##   (``refuseNonLoopbackBind``).
##
## This module holds the pure predicates and the filesystem steps, so the
## listener, the supervisor and the clients share ONE statement of each rule.

import std/[net, os, strutils, sysrand]
import blake3
import repro_core

when defined(posix):
  import std/posix
  var O_NOFOLLOW {.importc, header: "<fcntl.h>".}: cint
    ## Not declared by std/posix. Refusing to follow a symlink at the
    ## token's path is belt and braces: the directory is already private.

const
  ControlSocketName* = "control.sock"
    ## The AF_UNIX socket the POSIX default transport listens on, inside
    ## the endpoint directory.
  ControlTokenName* = "http-token"
    ## The file holding the session token, inside the endpoint directory.
  UnixBindPrefix* = "unix:"
    ## A recorded bind of the AF_UNIX transport is ``unix:<absolute path>``.
  ControlTokenBytes = 32
    ## 256 bits from the OS CSPRNG, hex-encoded to 64 characters.
  EndpointKeyChars = 16
    ## 64 bits of blake3 over the session directory; the same width
    ## ``repro_daemon_core/protocol.endpointDigest`` uses for its names.
  AllowRemoteFlag* = "--http-allow-remote"

proc currentUserId(): int =
  when defined(posix): int(geteuid())
  else: 0

proc perUserEndpointRoot(): string =
  ## The per-user directory every session's endpoint directory lives under.
  when defined(windows):
    # The profile ACL already admits only this user.
    let local = getEnv("LOCALAPPDATA")
    let base =
      if local.len > 0: local
      else: getEnv("USERPROFILE") / "AppData" / "Local"
    base / "repro" / "dev-sessions"
  else:
    let xdg = getEnv("XDG_RUNTIME_DIR")
    if xdg.len > 0:
      xdg / "repro" / "dev-sessions"
    else:
      getTempDir() / ("repro-" & $currentUserId()) / "dev-sessions"

proc endpointKey(sessionDir: string): string =
  ## One session directory has one endpoint directory: the key is derived
  ## from its absolute, normalized path.
  let identity = os.normalizedPath(absolutePath(sessionDir))
  blake3.digest(identity).toHex()[0 ..< EndpointKeyChars].toLowerAscii()

proc devSessionEndpointDir*(sessionDir: string): string =
  ## The per-user directory holding ``sessionDir``'s control socket and token.
  ##
  ## Without ``XDG_RUNTIME_DIR`` the root is ``<temp>/repro-<uid>``; when that
  ## would leave a socket path longer than ``std/net`` can bind (a deep
  ## ``$TMPDIR``), it is ``/tmp/repro-<uid>`` instead -- the rule
  ## ``repro_daemon_core/protocol.boundedTempRuntimeDir`` applies to the user
  ## daemon's own endpoint. ``XDG_RUNTIME_DIR`` is used verbatim: an
  ## over-long one is refused by ``controlSocketPath``, naming the limit.
  let key = endpointKey(sessionDir)
  result = perUserEndpointRoot() / key
  when defined(posix):
    if getEnv("XDG_RUNTIME_DIR").len == 0 and
        not unixSocketPathFits(result / ControlSocketName):
      result = "/tmp" / ("repro-" & $currentUserId()) / "dev-sessions" / key

proc controlSocketPath*(endpointDir: string): string =
  ## The AF_UNIX socket path in ``endpointDir``. Refuses, naming the path and
  ## the limit, rather than truncating a path the platform cannot bind.
  result = endpointDir / ControlSocketName
  when defined(posix):
    if not unixSocketPathFits(result):
      raise newException(IOError,
        "the dev-session control socket path " & result & " is " &
        $result.len & " bytes, longer than the " & $unixSocketPathMaxLen() &
        " bytes this platform can bind; set XDG_RUNTIME_DIR (or TMPDIR) to " &
        "a shorter directory")

proc controlTokenPath*(endpointDir: string): string =
  endpointDir / ControlTokenName

when defined(posix):
  proc verifyOwnedDirectory(path: string; privateDir: bool) =
    ## Refuse ``path`` unless it is a real directory (not a symlink) owned
    ## by this user. ``privateDir`` additionally refuses ANY group or other
    ## permission (the endpoint directory itself); otherwise only group or
    ## other WRITE is refused, which is what lets another account replace
    ## an entry below it.
    var st: Stat
    if lstat(path.cstring, st) != 0:
      raiseOSError(osLastError(),
        "cannot inspect the dev-session control directory " & path)
    if not S_ISDIR(st.st_mode):
      raise newException(IOError,
        "refusing the dev-session control directory " & path &
        ": it is not a directory (a symlink or another file is in its place)")
    if int(st.st_uid) != currentUserId():
      raise newException(IOError,
        "refusing the dev-session control directory " & path &
        ": it is owned by uid " & $st.st_uid & ", not by this user (uid " &
        $currentUserId() & "), so another account could read the session " &
        "token or replace the control socket")
    let mode = int(st.st_mode) and 0o777
    let forbidden = if privateDir: 0o077 else: 0o022
    if (mode and forbidden) != 0:
      raise newException(IOError,
        "refusing the dev-session control directory " & path & ": its mode " &
        "is 0" & toOct(mode, 3) & ", and it must grant " &
        (if privateDir: "no group or other permissions (0700)"
         else: "no group or other write permission") &
        "; remove it or fix its mode and start the session again")

  proc ensureOwnedDirectory(path: string; privateDir: bool) =
    ## Create ``path`` as ``0700`` when it is missing; then verify it,
    ## whoever created it.
    if mkdir(path.cstring, Mode(0o700)) == 0:
      # mkdir's mode is narrowed by the umask; set it exactly.
      if chmod(path.cstring, Mode(0o700)) != 0:
        raiseOSError(osLastError(), path)
    elif errno != EEXIST:
      raiseOSError(osLastError(),
        "cannot create the dev-session control directory " & path)
    verifyOwnedDirectory(path, privateDir)

proc ensurePrivateEndpointDir*(endpointDir: string) =
  ## Create (or admit) ``endpointDir`` and every directory between the
  ## per-user root and it.
  ##
  ## On POSIX the endpoint directory must be ``0700`` and owned by this user;
  ## each directory above it that this code may create must be owned by this
  ## user and not group- or other-writable, because whoever can write a
  ## parent can rename the endpoint directory away and put their own in its
  ## place. The roots themselves (``$XDG_RUNTIME_DIR``, the temp directory)
  ## are the system's. On Windows the profile ACL already admits only this
  ## user, so the directories are simply created.
  when defined(posix):
    # The chain below the root, outermost first. Every endpoint directory
    # ``devSessionEndpointDir`` returns is exactly three levels below its
    # root (``<root>/repro/dev-sessions/<key>`` or
    # ``<temp>/repro-<uid>/dev-sessions/<key>``), so the chain is taken by
    # depth rather than by walking up until a path compares equal to the
    # root: an ``XDG_RUNTIME_DIR`` spelled with a trailing slash (or any
    # other non-normalized form) never compares equal, and the walk would
    # then reach the system-owned directories above it and refuse them.
    let sessionsDir = parentDir(endpointDir)
    let chain = @[parentDir(sessionsDir), sessionsDir, endpointDir]
    for i, dir in chain:
      ensureOwnedDirectory(dir, privateDir = i == chain.high)
  else:
    createDir(extendedPath(endpointDir))

proc mintControlToken*(): string =
  ## A fresh session token: ``ControlTokenBytes`` from the OS CSPRNG, hex.
  ## ``urandom`` raises rather than returning weak bytes.
  var bytes: array[ControlTokenBytes, byte]
  if not urandom(bytes):
    raise newException(IOError,
      "the OS random number generator failed while minting the dev-session " &
      "control token")
  result = newStringOfCap(ControlTokenBytes * 2)
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())

proc writeControlToken*(path, token: string) =
  ## Write ``token`` to ``path``, owner read/write only from the moment the
  ## file exists. A leftover file (a listener that was killed) is replaced,
  ## never reused or appended to.
  when defined(posix):
    if unlink(path.cstring) != 0 and errno != ENOENT:
      raiseOSError(osLastError(), "cannot replace " & path)
    let fd = posix.open(path.cstring,
      O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW or O_CLOEXEC, Mode(0o600))
    if fd < 0:
      raiseOSError(osLastError(), "cannot create " & path)
    var ok = false
    try:
      # The open mode is narrowed by the umask only; this makes it exact.
      if fchmod(fd, Mode(0o600)) != 0:
        raiseOSError(osLastError(), path)
      var written = 0
      while written < token.len:
        let n = posix.write(fd, unsafeAddr token[written], token.len - written)
        if n < 0:
          if errno == EINTR: continue
          raiseOSError(osLastError(), "cannot write " & path)
        written += n
      ok = true
    finally:
      discard posix.close(fd)
      if not ok:
        discard unlink(path.cstring)
  else:
    writeFile(extendedPath(path), token)

proc readControlToken*(path: string): string =
  ## The token at ``path``. A client that cannot read it is not the
  ## session's user, and is told which file it could not read.
  if path.len == 0:
    raise newException(IOError,
      "the dev-session record names no control token (httpTokenPath); it " &
      "was written by a reprobuild that did not authenticate its control API")
  try:
    result = readFile(extendedPath(path)).strip()
  except IOError, OSError:
    raise newException(IOError,
      "cannot read the dev-session control token " & path & ": " &
      getCurrentExceptionMsg())
  if result.len == 0:
    raise newException(IOError, "the dev-session control token " & path &
      " is empty")

proc removeControlEndpointFiles*(tokenPath, socketPath: string) =
  ## Best-effort removal of a listener's token and socket, and of their
  ## directory once it is empty. A file that is already gone is not an
  ## error, and a failure leaves at worst a token nobody listens for.
  for path in [tokenPath, socketPath]:
    if path.len == 0: continue
    try: removeFile(extendedPath(path))
    except OSError: discard
  let dir =
    if tokenPath.len > 0: parentDir(tokenPath)
    elif socketPath.len > 0: parentDir(socketPath)
    else: ""
  if dir.len > 0:
    when defined(posix):
      discard rmdir(dir.cstring) # fails, harmlessly, unless empty
    else:
      try:
        var empty = true
        for _ in walkDir(extendedPath(dir)):
          empty = false
          break
        if empty: removeDir(extendedPath(dir))
      except OSError: discard

proc tokensEqual*(presented, expected: string): bool =
  ## Compare a presented token with the session's without stopping at the
  ## first differing byte. The loop runs over the EXPECTED token's length
  ## whatever is presented, so the time taken says nothing about how much of
  ## a guess was right.
  var diff = presented.len xor expected.len
  for i in 0 ..< expected.len:
    let c = if i < presented.len: presented[i] else: '\0'
    diff = diff or (ord(c) xor ord(expected[i]))
  diff == 0 and expected.len > 0

proc stripBrackets(host: string): string =
  if host.len >= 2 and host[0] == '[' and host[^1] == ']': host[1 .. ^2]
  else: host

proc isLoopbackHost*(host: string): bool =
  ## ``localhost``, any ``127.0.0.0/8`` address, or ``::1`` (bracketed or
  ## not). Nothing else -- in particular not ``0.0.0.0`` or ``::``, which
  ## bind every interface.
  let bare = stripBrackets(host)
  if cmpIgnoreCase(bare, "localhost") == 0:
    return true
  try:
    let address = parseIpAddress(bare)
    case address.family
    of IpAddressFamily.IPv4: address.address_v4[0] == 127
    of IpAddressFamily.IPv6: address == parseIpAddress("::1")
  except ValueError:
    false

proc splitHostPort*(value: string): tuple[host, port: string; ok: bool] =
  ## Split an HTTP ``Host`` value (RFC 9110 §7.2: ``uri-host [":" port]``,
  ## an IPv6 literal in brackets) into its host and port text.
  if value.len == 0:
    return ("", "", false)
  if value[0] == '[':
    let close = value.find(']')
    if close < 0: return ("", "", false)
    let rest = value[close + 1 .. ^1]
    if rest.len == 0: return (value[1 ..< close], "", true)
    if rest[0] != ':': return ("", "", false)
    return (value[1 ..< close], rest[1 .. ^1], true)
  case value.count(':')
  of 0: (value, "", true)
  of 1:
    let colon = value.find(':')
    (value[0 ..< colon], value[colon + 1 .. ^1], true)
  else: ("", "", false) # an unbracketed IPv6 literal is not a valid Host

proc hostAccepted(host, configuredHost: string): bool =
  host.len > 0 and (isLoopbackHost(host) or
    (configuredHost.len > 0 and
      cmpIgnoreCase(host, stripBrackets(configuredHost)) == 0))

proc hostHeaderAccepted*(hostHeader, configuredHost: string): bool =
  ## Whether a request's ``Host`` names this API: a loopback name, or the
  ## host ``--http`` configured. The port is not compared. Refusing every
  ## other name is what defeats DNS rebinding, where the browser sends the
  ## attacker's name to 127.0.0.1.
  let parts = splitHostPort(hostHeader.strip())
  parts.ok and hostAccepted(parts.host, configuredHost)

proc originAccepted*(origin, configuredHost: string; port: int): bool =
  ## Whether an ``Origin`` header is the API's own:
  ## ``http://<accepted host>:<port>`` exactly, with ``port`` the listening
  ## port. ``null``, any other scheme, host or port, and any origin at all on
  ## the AF_UNIX transport (``port`` 0, which no browser origin can name) are
  ## refused.
  const scheme = "http://"
  if port <= 0 or not origin.startsWith(scheme):
    return false
  let rest = origin[scheme.len .. ^1]
  if rest.contains('/'):
    return false
  let parts = splitHostPort(rest)
  parts.ok and parts.port == $port and hostAccepted(parts.host, configuredHost)

proc refuseNonLoopbackBind*(bindValue, host: string; allowRemote: bool) =
  ## Raise, before any session state exists, when ``--http`` names a host
  ## other than a loopback one and the caller did not opt in.
  if allowRemote or isLoopbackHost(host):
    return
  raise newException(ValueError,
    "refusing --http " & bindValue & ": " &
    (if host.len > 0: host else: "(empty host)") & " is not a loopback " &
    "address (127.0.0.0/8, ::1 or localhost). A non-loopback bind exposes " &
    "the session control API to the network, where the session token is " &
    "the only thing standing between it and anyone who can reach the port; " &
    "pass " & AllowRemoteFlag & " as well to accept that")
