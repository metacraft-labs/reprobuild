## Fetching a report from a running agent, over plain HTTP.
##
## ## Why this is a separate module
##
## The verifier proper touches no socket: it is a function from documents
## to a verdict, so it can be embedded in a broker that already has its
## own transport, and so the gates that exercise it need no network. This
## module is the thin part the command line adds — ``--report-url`` — and
## nothing in ``verify`` imports it.
##
## ## Why it is hand-written, and why plain HTTP
##
## Hand-written for the same reason the agent's server is: the bounds
## have to be applied while reading, and forty lines of ``GET`` is less
## surface than a client library plus a TLS stack pulled in to talk to a
## loopback port. Plain HTTP because the agent listens on loopback by
## default and the design says deployments front it with their own
## authenticated channel — an ``https://`` URL is therefore refused here
## rather than served by a TLS implementation this build would then be
## claiming things about.
##
## ## What fetching does NOT do
##
## It does not fetch a measurement manifest. The verifier's expected
## measurements never come from the machine being measured; see the CLI
## reference. There is no function here that would retrieve one.
##
## ## Mocking
##
## None. The gate that uses this drives a real socket against the real
## agent.

import std/[net, strutils, times]

type
  FetchError* = object of CatchableError

const
  MaxResponseBytes* = 4 * 1024 * 1024
    ## Four mebibytes. The report envelope bounds itself far below this;
    ## the ceiling is here so a wrong URL cannot be read forever.
  FetchTimeoutMs* = 10_000

proc splitHttpUrl(url: string): tuple[host: string; port: Port; target: string] =
  const scheme = "http://"
  if url.startsWith("https://"):
    raise newException(FetchError,
      "this build fetches over plain HTTP only. The agent listens on " &
      "loopback and a deployment that exposes it fronts it with its own " &
      "authenticated channel, so a TLS client here would be a second " &
      "opinion about a trust decision it does not own. Fetch the report " &
      "with your own tooling and pass it with --report-file.")
  if not url.startsWith(scheme):
    raise newException(FetchError,
      "the URL " & url.escape() & " does not begin " & scheme)
  var rest = url[scheme.len .. ^1]
  var target = "/"
  let slash = rest.find('/')
  if slash >= 0:
    target = rest[slash .. ^1]
    rest = rest[0 ..< slash]
  if rest.len == 0:
    raise newException(FetchError, "the URL " & url.escape() & " has no host")
  var host = rest
  var port = Port(80)
  let colon = rest.rfind(':')
  if colon > 0:
    host = rest[0 ..< colon]
    try:
      port = Port(parseInt(rest[colon + 1 .. ^1]))
    except ValueError:
      raise newException(FetchError,
        "the URL " & url.escape() & " has a port that is not a number")
  (host: host, port: port, target: target)

proc httpGet*(url: string): string =
  ## Fetch one document. Returns the body; raises on any status other
  ## than 200, naming what the server said, because a verifier that
  ## silently verified an error page would produce a verdict about a
  ## sentence.
  let parts = splitHttpUrl(url)
  var s = newSocket(buffered = false)
  defer:
    try: s.close()
    except CatchableError: discard
  try:
    s.connect(parts.host, parts.port)
  except CatchableError as err:
    raise newException(FetchError,
      "could not connect to " & parts.host & ":" & $int(parts.port) & ": " &
      err.msg)
  var request = "GET " & parts.target & " HTTP/1.1\r\n"
  request.add "Host: " & parts.host & ":" & $int(parts.port) & "\r\n"
  request.add "Accept: application/json\r\n"
  request.add "Connection: close\r\n\r\n"
  try:
    s.send(request)
  except CatchableError as err:
    raise newException(FetchError, "could not send the request: " & err.msg)

  var raw = ""
  let deadline = epochTime() + float(FetchTimeoutMs) / 1000.0
  while raw.len < MaxResponseBytes:
    if epochTime() > deadline:
      raise newException(FetchError, "the server did not finish answering " &
        "within " & $FetchTimeoutMs & " ms")
    var chunk = ""
    var got = 0
    try:
      got = s.recv(chunk, 8192, FetchTimeoutMs)
    except TimeoutError:
      break
    except OSError:
      break
    if got <= 0: break
    raw.add chunk[0 ..< got]
  if raw.len == 0:
    raise newException(FetchError, "the server answered nothing")

  let headEnd = raw.find("\r\n\r\n")
  if headEnd < 0:
    raise newException(FetchError, "the server's answer has no header block")
  let head = raw[0 ..< headEnd]
  let body = raw[headEnd + 4 .. ^1]
  let statusLine = head.split("\r\n")[0]
  let fields = statusLine.split(' ')
  if fields.len < 2:
    raise newException(FetchError,
      "the server's status line is " & statusLine.escape())
  var status = 0
  try:
    status = parseInt(fields[1])
  except ValueError:
    raise newException(FetchError,
      "the server's status line is " & statusLine.escape())
  if status != 200:
    raise newException(FetchError,
      "the server answered " & $status & ": " & body.strip().escape())
  body
