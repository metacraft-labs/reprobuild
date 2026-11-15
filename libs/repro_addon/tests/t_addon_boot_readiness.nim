## The boot re-assertion's readiness (spec §7.7; §13 decision 155).
##
## Every floored unit is ordered after ``repro-addon-reassert.service``
## (decision 144). A boot replay runs inside that unit and confirms the
## floored units it started, so the unit must let them start before it
## exits: it is ``Type=notify``, and the add-on says ``READY=1`` before a
## boot replay's confirm and on every way out. This checks the two halves
## that can be checked without a booted host:
##
## - ``sd_notify.notifyReady`` sends ``READY=1`` to the socket
##   ``$NOTIFY_SOCKET`` names, a path or an abstract name, and sends
##   nothing without one (an operator's ``recover``, a oneshot unit);
## - the rendered unit is ``Type=notify`` with the main process allowed to
##   notify (no ``NotifyAccess=`` override), bounded before and after
##   readiness, and its store-missing fallback notifies by exec'ing
##   ``systemd-notify``, so the start job never waits for its timeout.
##
## That the readiness comes before the confirm, and lets the confirm see a
## floored unit, is the VM gate ``e2e_addon_boot_replay_confirms_floored_unit``.
##
## *Mocking.* The service manager's notification socket is a real
## ``AF_UNIX`` datagram socket this test binds; nothing else is stubbed.

import std/[os, posix, strutils, times, unittest]

import repro_addon/generation0
import repro_addon/sd_notify

proc bindDatagram(name: string): SocketHandle =
  ## A datagram socket bound to ``name`` (a path, or ``@`` + an abstract
  ## name), as the service manager's ``/run/systemd/notify``.
  result = socket(AF_UNIX, SOCK_DGRAM or SOCK_CLOEXEC, 0)
  doAssert result.cint >= 0
  var sa: Sockaddr_un
  sa.sun_family = TSa_Family(AF_UNIX)
  for i, c in name: sa.sun_path[i] = c
  if name[0] == '@': sa.sun_path[0] = '\0'
  let off = cast[int](addr sa.sun_path) - cast[int](addr sa)
  let len = SockLen(off + name.len + (if name[0] == '@': 0 else: 1))
  doAssert bindSocket(result, cast[ptr SockAddr](addr sa), len) == 0,
    "bind " & name & ": " & $strerror(errno)

proc receive(fd: SocketHandle): string =
  ## One datagram, waiting at most two seconds.
  var tv = Timeval(tv_sec: posix.Time(2), tv_usec: 0)
  discard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, addr tv, SockLen(sizeof(tv)))
  var buf: array[256, char]
  let n = recv(fd, addr buf[0], buf.len, 0)
  if n <= 0: return ""
  result = newString(n)
  copyMem(addr result[0], addr buf[0], n)

suite "sd_notify READY=1 (sd_notify(3))":
  let dir = getTempDir() / ("repro-addon-notify-" & $getCurrentProcessId())
  createDir(dir)

  test "to a path socket":
    let path = dir / "notify"
    let fd = bindDatagram(path)
    defer: discard close(fd)
    putEnv("NOTIFY_SOCKET", path)
    defer: delEnv("NOTIFY_SOCKET")
    check notifyReady()
    check receive(fd) == "READY=1"

  test "to an abstract socket":
    let name = "@repro-addon-notify-" & $getCurrentProcessId() & "-" &
      $epochTime().int
    let fd = bindDatagram(name)
    defer: discard close(fd)
    putEnv("NOTIFY_SOCKET", name)
    defer: delEnv("NOTIFY_SOCKET")
    check notifyReady()
    check receive(fd) == "READY=1"

  test "nothing without a manager that asked for it":
    delEnv("NOTIFY_SOCKET")
    check not notifyReady()
    # Not a socket address: refused, never sent somewhere relative.
    putEnv("NOTIFY_SOCKET", "relative/notify")
    defer: delEnv("NOTIFY_SOCKET")
    check not notifyReady()

  test "a socket nobody listens on is a false, not an exception":
    putEnv("NOTIFY_SOCKET", dir / "absent")
    defer: delEnv("NOTIFY_SOCKET")
    check not notifyReady()

  removeDir(dir)

suite "the re-assert unit is Type=notify (§13 decision 155)":
  let exe = "/repro/store/prefixes/x/1/bin/repro"
  var reassert = ""
  for o in generation0Objects(Gen0Inputs(reproExe: exe)):
    if o.unit == ReassertUnit: reassert = o.content

  test "its start job ends at READY=1, not at exit":
    check reassert.len > 0
    check "Type=notify\n" in reassert
    check "Type=oneshot" notin reassert
    # The add-on binary is the main process (the shell execs it), and the
    # default NotifyAccess=main is what lets it, and only it, notify.
    check "NotifyAccess=" notin reassert
    check ("then exec " & exe & " system addon reassert --boot") in reassert
    check "RemainAfterExit=yes\n" in reassert

  test "bounded before readiness and after it":
    check "TimeoutStartSec=" & $ReassertTimeoutMin & "min\n" in reassert
    check "RuntimeMaxSec=" & $ReassertTimeoutMin & "min\n" in reassert

  test "the store-missing fallback notifies as its main process":
    let parts = reassert.split("; else ")
    check parts.len == 2
    # Last in the fallback, after the report is written, and exec'd: the
    # notifier is then the main process.
    check "; exec systemd-notify --ready; fi'\n" in parts[^1]
    check parts[^1].find(ReassertReportPath) <
      parts[^1].find("exec systemd-notify --ready")
