## The environment variables that configure a Nix command, and how a request
## to the shared Nix helper (``reprobuild-nix-daemon``) carries them.
##
## WHY A REQUEST CARRIES THEM. The helper is shared by every reprobuild process
## of the user and outlives the process that started it, so its own
## environment belongs to no particular client. Nix reads its settings --
## among them ``access-tokens``, the credential it presents to GitHub and other
## forges -- from these variables
## (https://nix.dev/manual/nix/latest/command-ref/conf-file.html, section
## "Configuration file"): ``NIX_CONFIG`` holds settings inline (and may
## ``!include`` a file), ``NIX_USER_CONF_FILES`` replaces the per-user file
## list, ``NIX_CONF_DIR`` locates the system file, and ``XDG_CONFIG_HOME`` /
## ``XDG_CONFIG_DIRS`` locate the per-user files when
## ``NIX_USER_CONF_FILES`` is unset. A helper that used its own values ran
## every client's ``nix`` with the configuration of whichever client started
## it, or with none: a CI job whose credential lives in a file its
## ``NIX_CONFIG`` includes got HTTP 401 from GitHub once that credential was
## re-minted or the job that started the helper was gone.
##
## So each request names the client's value of every one of these variables,
## or ``null`` for one the client does not set, and the helper runs that
## request's Nix commands with exactly those values. The request is
## authoritative over the whole set: a variable the client does not set is
## unset for its commands, never inherited from the helper.
##
## The values are credentials, or name the files that hold them. They travel
## only in the request, over the helper's socket, and are not logged or
## written anywhere. ``nixHelperPeerIsThisUser`` lets a client refuse to send
## them to a socket another user holds.

import std/[json, os, strtabs]

when defined(posix):
  import std/[nativesockets, posix]

const NixConfigurationEnvNames* = [
  "NIX_CONFIG",
  "NIX_USER_CONF_FILES",
  "NIX_CONF_DIR",
  "XDG_CONFIG_HOME",
  "XDG_CONFIG_DIRS",
]
  ## The variables Nix reads to find its configuration. Keep in step with
  ## ``NIX_CONFIGURATION_ENV`` in ``tools/reprobuild-nix-daemon``, which
  ## refuses a request naming any other variable.

const NixHelperRequestEnvironmentKey* = "nixEnvironment"
  ## The request member that carries them: an object with one member per
  ## name in ``NixConfigurationEnvNames``, a string or ``null``.

proc nixHelperRequestEnvironment*(): JsonNode =
  ## This process's Nix configuration, in the form a helper request carries
  ## it: every name in ``NixConfigurationEnvNames``, its value when set (an
  ## empty value is a value) and ``null`` when unset.
  result = newJObject()
  for name in NixConfigurationEnvNames:
    result[name] =
      if existsEnv(name): newJString(getEnv(name))
      else: newJNull()

proc withNixHelperRequestEnvironment*(request: string;
    environment = nixHelperRequestEnvironment()): string =
  ## ``request`` (one JSON object) with its ``nixEnvironment`` member set to
  ## ``environment``, replacing any it had. Every other member is kept.
  ##
  ## Raises ``ValueError`` when ``request`` is not a JSON object: the helper
  ## protocol has no other kind of request.
  let parsed =
    try: parseJson(request)
    except JsonParsingError as err:
      raise newException(ValueError,
        "a Nix helper request is not valid JSON: " & err.msg)
  if parsed.kind != JObject:
    raise newException(ValueError,
      "a Nix helper request is not a JSON object")
  parsed[NixHelperRequestEnvironmentKey] = environment
  $parsed

proc environmentWithoutNixConfiguration*(): StringTableRef =
  ## This process's environment without the variables in
  ## ``NixConfigurationEnvNames``: what the shared helper is started with, so
  ## that the configuration of the process that happens to start it is not
  ## left in the helper's own environment for its lifetime.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key notin NixConfigurationEnvNames:
      result[key] = value

when defined(posix):
  when defined(linux):
    type Ucred {.importc: "struct ucred", header: "<sys/socket.h>".} = object
      pid: Pid
      uid: Uid
      gid: Gid
    var SO_PEERCRED {.importc, header: "<sys/socket.h>".}: cint

    proc peerUid(fd: SocketHandle; uid: var Uid): bool =
      ## socket(7) SO_PEERCRED:
      ## https://man7.org/linux/man-pages/man7/unix.7.html
      var cred: Ucred
      var len = SockLen(sizeof(cred))
      if getsockopt(fd, SOL_SOCKET, SO_PEERCRED, addr cred, addr len) != 0:
        return false
      uid = cred.uid
      true
  else:
    proc getpeereid(s: SocketHandle; uid: var Uid; gid: var Gid): cint {.
      importc, header: "<unistd.h>".}

    proc peerUid(fd: SocketHandle; uid: var Uid): bool =
      ## getpeereid(3), macOS and the BSDs.
      var gid: Gid
      getpeereid(fd, uid, gid) == 0

  proc nixHelperPeerIsThisUser*(fd: SocketHandle): bool =
    ## Whether the process at the other end of the connected Unix socket
    ## ``fd`` runs as this process's user, as the kernel reports it. False
    ## when the kernel cannot say.
    ##
    ## The helper's socket lives at a predictable path in a shared directory
    ## (``/tmp`` by default). A request carries the client's Nix
    ## credentials, so a client checks this before it sends one: a socket
    ## another user bound first must not receive them.
    var uid: Uid
    peerUid(fd, uid) and uid == getuid()
