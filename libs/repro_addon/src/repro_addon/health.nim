## Health checks and the confirm step of the add-on switch (ReproOS
## Add-On Mode §7.5, §7.2 step 8).
##
## A unit may declare one ``healthCheck`` (``repro_infra/profile``
## ``parseHealthCheck``): the unit reaching ``active``, a TCP connect or an
## HTTP GET on loopback, or a command in the store exiting 0. After step 7
## the switch waits up to the profile's ``confirmTimeout`` -- counted from
## the end of step 7, not from the start of the apply -- for every check to
## have passed once. A check that has not passed by then fails the
## confirmation, and the switch reverts to the generation ``current``
## still names.
##
## **Where a probe runs.** The apply and the re-assert unit run with
## ``PrivateNetwork=yes`` (§9.1), where loopback is a private, empty
## interface: a probe from there would find nothing listening and revert
## every healthy generation. So the TCP, HTTP and command checks run as a
## transient unit of the host's systemd (``host_exec.runInHostNamespaces``),
## in the host's namespaces, the way step 6 reads sysctl values. The TCP
## and HTTP probes are this binary's own ``repro system addon probe``.

import std/[net, os, strutils, times]

import repro_infra/profile

import ./host_exec

type
  UnitHealthCheck* = object
    unit*: string
    address*: string
    raw*: string                 ## the declared text
    spec*: HealthCheckSpec

  ConfirmOutcome* = object
    passed*: bool
    failures*: seq[string]       ## "<unit> <check>: <last reason>"
    waitedSec*: float

  ProbeRunner* = proc(c: UnitHealthCheck): string {.closure.}
    ## "" when the check passes now, otherwise why not.

const
  ProbeConnectTimeoutMs* = 2000
  ConfirmPollIntervalMs* = 1000

proc unitActiveState(unit: string): string =
  let r = runSystemctl(["show", "-p", "ActiveState", "--value", "--", unit])
  if r.exitCode != 0: "unknown (" & r.output.strip() & ")" else: r.output.strip()

proc probeTcp*(host: string; port: int): string =
  ## "" when a TCP connection to ``host:port`` is accepted.
  let domain = if host == "::1": Domain.AF_INET6 else: Domain.AF_INET
  let addr0 = if host == "localhost": "127.0.0.1" else: host
  var s: Socket
  try:
    s = newSocket(domain, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
  except CatchableError as e:
    return "cannot create a socket: " & e.msg
  defer: s.close()
  try:
    s.connect(addr0, Port(port), timeout = ProbeConnectTimeoutMs)
    ""
  except CatchableError as e:
    "connect " & host & ":" & $port & ": " & e.msg

proc probeHttp*(host: string; port: int; path: string): string =
  ## "" when ``GET <path>`` on ``host:port`` answers with a 2xx status.
  let domain = if host == "::1": Domain.AF_INET6 else: Domain.AF_INET
  let addr0 = if host == "localhost": "127.0.0.1" else: host
  var s: Socket
  try:
    s = newSocket(domain, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
  except CatchableError as e:
    return "cannot create a socket: " & e.msg
  defer: s.close()
  try:
    s.connect(addr0, Port(port), timeout = ProbeConnectTimeoutMs)
    let hostHeader = if host == "::1": "[::1]" else: host
    s.send("GET " & path & " HTTP/1.0\r\nHost: " & hostHeader & ":" & $port &
           "\r\nConnection: close\r\nUser-Agent: repro-addon-health\r\n\r\n")
    var line = ""
    s.readLine(line, timeout = ProbeConnectTimeoutMs)
    # "HTTP/1.x NNN reason"
    let parts = line.splitWhitespace()
    if parts.len < 2 or not parts[0].startsWith("HTTP/"):
      return "not an HTTP status line: " & line.strip()
    let code = try: parseInt(parts[1]) except ValueError: 0
    if code in 200 .. 299: "" else: "HTTP status " & parts[1]
  except CatchableError as e:
    "GET http://" & host & ":" & $port & path & ": " & e.msg

proc runProbe*(spec: HealthCheckSpec): string =
  ## The in-namespace half of a TCP or HTTP check (``repro system addon
  ## probe``): run where it is invoked, which is the host's namespaces.
  case spec.kind
  of hcTcp: probeTcp(spec.host, spec.port)
  of hcHttp: probeHttp(spec.host, spec.port, spec.path)
  else: "not a network probe"

proc hostNamespaceProbe*(reproExe: string): ProbeRunner =
  ## The production runner: ``active`` asks systemd; the rest run as a
  ## transient unit in the host's namespaces.
  result = proc(c: UnitHealthCheck): string =
    case c.spec.kind
    of hcActive:
      let st = unitActiveState(c.unit)
      if st == "active": "" else: "ActiveState=" & st
    of hcTcp, hcHttp:
      try:
        let r = runInHostNamespaces([reproExe, "system", "addon", "probe",
                                     c.raw])
        if r.exitCode == 0: "" else: r.output.strip()
      except CatchableError as e:
        "probe could not run: " & e.msg
    of hcExec:
      try:
        let r = runInHostNamespaces(c.spec.argv)
        if r.exitCode == 0: ""
        else: "exited " & $r.exitCode & ": " & r.output.strip()
      except CatchableError as e:
        "command could not run: " & e.msg

proc confirm*(checks: seq[UnitHealthCheck]; timeoutSec: int;
              probe: ProbeRunner;
              pollMs = ConfirmPollIntervalMs): ConfirmOutcome =
  ## Wait up to ``timeoutSec`` for every check to pass once. The clock
  ## starts when this proc is called (the end of step 7).
  let start = epochTime()
  let deadline = start + timeoutSec.float
  var pending = checks
  var lastWhy = newSeq[string](checks.len)
  while true:
    var still: seq[UnitHealthCheck]
    for c in pending:
      let why = probe(c)
      if why.len > 0:
        still.add(c)
        for i, x in checks:
          if x.unit == c.unit and x.raw == c.raw: lastWhy[i] = why
    pending = still
    if pending.len == 0:
      result.passed = true
      break
    if epochTime() >= deadline:
      break
    sleep(pollMs)
  result.waitedSec = epochTime() - start
  for c in pending:
    for i, x in checks:
      if x.unit == c.unit and x.raw == c.raw:
        result.failures.add(c.unit & " " & c.raw & ": " & lastWhy[i])
