## The registry's Edge HTTP parts (`Remix-Registry.md` §"Zones",
## §"Read API").
##
## `IntakeServer` accepts `POST /v1/submit/<type>` and delivers a framed
## Boundary message to the spool. It holds nothing, reads nothing back, and
## forwards no request header: there is nothing in a header the Interior
## would act on, so the strip is unconditional by construction (FLOW-4).
##
## `ReadFrontServer` serves files the registrar pushed into the publish
## directory. It computes nothing and never fetches anything. Paths are
## validated against the closed route table before any file is touched, so
## a request can only ever name a file the registrar could have written.
##
## Both are plain `std/asynchttpserver` servers on loopback in the double.

import std/[asyncdispatch, asynchttpserver, os, strutils, times]

import repro_remix

import ./boundary

type
  IntakeServer* = ref object
    server: AsyncHttpServer
    spool: Spool
    name*: string
    port*: Port
    serveFut: Future[void]

  ReadFrontServer* = ref object
    server: AsyncHttpServer
    root: string
    port*: Port
    serveFut: Future[void]

proc isHex64(s: string): bool =
  if s.len != 64: return false
  for c in s:
    if c notin {'0'..'9', 'a'..'f'}: return false
  true

proc isDecimal(s: string): bool =
  if s.len == 0 or s.len > 19: return false
  for c in s:
    if c notin {'0'..'9'}: return false
  true

proc isNamePart(s: string): bool =
  if s.len == 0 or s.len > 128 or s[0] notin {'a'..'z', '0'..'9'}: return false
  for c in s:
    if c notin {'a'..'z', '0'..'9', '.', '_', '-'}: return false
  true

proc routeToFile*(path: string): (bool, string) =
  ## Map a read-API path to a file under the publish root, or refuse.
  ## The closed table of `Remix-Registry.md` §"Read API".
  let parts = path.strip(leading = true, trailing = false, chars = {'/'}).split('/')
  if parts.len < 2 or parts[0] != "v1": return (false, "")
  case parts[1]
  of "checkpoint":
    if parts.len == 2: return (true, "v1/checkpoint/latest")
    if parts.len == 3 and parts[2].isDecimal: return (true, "v1/checkpoint/" & parts[2])
  of "consistency":
    if parts.len == 4 and parts[2].isDecimal and parts[3].isDecimal:
      return (true, "v1/consistency/" & parts[2] & "-" & parts[3])
  of "release":
    if parts.len == 3 and parts[2].isHex64: return (true, "v1/release/" & parts[2])
    if parts.len == 4 and parts[2].isHex64 and parts[3] in ["proof", "statements"]:
      return (true, "v1/release/" & parts[2] & "." & parts[3])
  of "blob", "key-log", "bundle":
    if parts.len == 3 and parts[2].isHex64: return (true, "v1/" & parts[1] & "/" & parts[2])
  of "name":
    if parts.len == 4 and parts[2].isNamePart and parts[3].isNamePart:
      return (true, "v1/name/" & parts[2] & "/" & parts[3])
  of "index":
    if parts.len == 3 and (parts[2] == "latest" or parts[2].isDecimal):
      return (true, "v1/index/" & parts[2])
  else: discard
  (false, "")

proc newReadFront*(publishRoot: string): ReadFrontServer =
  ReadFrontServer(server: newAsyncHttpServer(), root: publishRoot)

proc start*(rf: ReadFrontServer; port = Port(0)) =
  proc cb(req: Request) {.async, gcsafe.} =
    if req.reqMethod != HttpGet:
      await req.respond(Http405, "")
      return
    let (ok, rel) = routeToFile(req.url.path)
    if not ok:
      await req.respond(Http404, "")
      return
    # Resolve through `current`, the generation the registrar last swung to.
    let path = rf.root / "current" / rel
    if not fileExists(path):
      await req.respond(Http404, "")
      return
    await req.respond(Http200, readFile(path),
      newHttpHeaders({"Content-Type": "application/octet-stream"}))
  rf.server.listen(port, "127.0.0.1")
  rf.port = rf.server.getPort
  proc loop() {.async.} =
    while true:
      if rf.server.shouldAcceptRequest():
        await rf.server.acceptRequest(cb)
      else:
        await sleepAsync(5)
  rf.serveFut = loop()

proc close*(rf: ReadFrontServer) =
  if not rf.serveFut.isNil and not rf.serveFut.finished:
    rf.serveFut.callback = proc () = discard
  try: rf.server.close() except CatchableError: discard

proc newIntake*(spool: Spool; name: string): IntakeServer =
  IntakeServer(server: newAsyncHttpServer(maxBody = MaxMessageBytes),
               spool: spool, name: name)

proc start*(s: IntakeServer; port = Port(0)) =
  proc cb(req: Request) {.async, gcsafe.} =
    if req.reqMethod != HttpPost or not req.url.path.startsWith("/v1/submit/"):
      await req.respond(Http404, "")
      return
    let (known, t) = parseMessageType(req.url.path["/v1/submit/".len .. ^1])
    if not known:
      await req.respond(Http404, "")
      return
    if req.body.len > maxPayload(t):
      await req.respond(Http413, "")
      return
    var payload = newSeq[byte](req.body.len)
    for i, c in req.body: payload[i] = byte(ord(c))
    try:
      let msg = encodeMessage(BoundaryMessage(msgType: t,
        receivedAt: getTime().toUnix, intake: s.name,
        rateKey: req.hostname, payload: payload))
      let name = s.spool.deliver(s.name, msg)
      await req.respond(Http202, name)
    except RemixError:
      await req.respond(Http400, "")
  s.server.listen(port, "127.0.0.1")
  s.port = s.server.getPort
  proc loop() {.async.} =
    while true:
      if s.server.shouldAcceptRequest():
        await s.server.acceptRequest(cb)
      else:
        await sleepAsync(5)
  s.serveFut = loop()

proc close*(s: IntakeServer) =
  if not s.serveFut.isNil and not s.serveFut.finished:
    s.serveFut.callback = proc () = discard
  try: s.server.close() except CatchableError: discard
