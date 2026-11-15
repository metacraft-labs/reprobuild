## Readiness notification for the boot re-assertion (spec §7.7, §13
## decision 155).
##
## ``repro-addon-reassert.service`` is ``Type=notify``: its start job, which
## every floored unit is ordered ``After=`` (decision 144), completes when
## this process says ``READY=1``, not when it exits. A boot replay says it
## just before its confirm step, once every write and hold of the
## generation is in place, so the floored units it started can run while
## the confirm waits for them; every run says it again before it exits.
##
## The protocol is sd_notify(3): one datagram to the ``AF_UNIX`` socket
## named by ``$NOTIFY_SOCKET`` (a path, or an abstract name written with a
## leading ``@``). <https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html>
## Implemented here rather than linked from libsystemd: the add-on binary
## is static (musl) and links no systemd library.

import std/[os, posix]

proc sdNotify*(state: string): bool =
  ## Send ``state`` (``"READY=1"``) to the service manager. False, and
  ## nothing sent, when this process was not started by a manager that
  ## asked for notifications (``$NOTIFY_SOCKET`` unset: an operator's
  ## ``recover``, a unit that is still ``Type=oneshot`` on a host
  ## bootstrapped before decision 155), or when the send fails. Never
  ## raises: a missed notification costs the boot order, never the run.
  let name = getEnv("NOTIFY_SOCKET")
  if name.len == 0 or not (name[0] in {'/', '@'}): return false
  var sa: Sockaddr_un
  if name.len > sa.sun_path.len - 1: return false
  sa.sun_family = TSa_Family(AF_UNIX)
  for i, c in name: sa.sun_path[i] = c
  # An abstract socket's name starts with a NUL byte (unix(7)); its address
  # length counts exactly the name's bytes.
  if name[0] == '@': sa.sun_path[0] = '\0'
  let pathOffset = cast[int](addr sa.sun_path) - cast[int](addr sa)
  let len = SockLen(pathOffset + name.len + (if name[0] == '@': 0 else: 1))
  let fd = socket(AF_UNIX, SOCK_DGRAM or SOCK_CLOEXEC, 0)
  if fd.cint < 0: return false
  defer: discard close(fd)
  let sent = sendto(fd, state.cstring, state.len, MSG_NOSIGNAL,
                    cast[ptr SockAddr](addr sa), len)
  sent == state.len

proc notifyReady*(): bool =
  ## ``READY=1``: the start job of the unit running this process is done.
  ## Idempotent for the manager: a second ``READY=1`` changes nothing.
  sdNotify("READY=1")
