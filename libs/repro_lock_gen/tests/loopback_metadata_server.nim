## A REAL loopback HTTP server serving package version-metadata records.
##
## Named-Lock-Files NLF-M5 test support. Not named `t_*` / `test_*` so
## `scripts/generate_test_edges.nim` does not register it as a test binary of
## its own.
##
## ## Test-double policy — read this before reaching for a mock
##
## This is **not** a mock, a stub, or a fake HTTP client. It is a real TCP
## listener on `127.0.0.1`, speaking real HTTP/1.1, served to by the real
## `repro_binary_cache_client/http_pool` client over a real socket. Nothing on
## the fetch path is substituted: `fetchMetadataObject` runs unchanged and
## opens a genuine connection.
##
## The project policy is that every use of a test double be justified in the
## test's header, and the honest statement here is that there is no double to
## justify. What IS synthetic is the *content* — the version lists are written
## into a directory by the test rather than published by a real registry —
## which is fixture data, not a double. The distinction matters for what the
## tests can conclude: they can conclude things about whether the network was
## reached, because the network is real; they cannot conclude anything about a
## particular upstream registry's behaviour, and none of them try to.
##
## A mocked HTTP client would have made corpus case NLF-GEN-7 vacuous. "The
## build attempted no metadata fetch" against a mock proves only that a mock
## was not called; against a listener that has been shut down it proves that
## nothing could have succeeded even if it had been attempted, which is the
## claim the case is actually making.

import std/[atomics, net, os, strutils]

type
  MetadataServerState* = object
    socket: Socket
    root*: string
      ## Directory served. A `GET /metadata/<name>.versions` is answered from
      ## `<root>/<name>.versions`.
    port*: int
    requests*: Atomic[int]
      ## How many requests the server has ANSWERED. An independent witness,
      ## on the far side of a real socket, for the client-side attempt
      ## counter. Two counters that must agree is a stronger statement than
      ## either alone: a client counter that stopped being incremented would
      ## still be caught, and so would a fetch that bypassed
      ## `fetchMetadataObject` entirely.
    stopping: Atomic[bool]

  MetadataServer* = ref object
    state*: ptr MetadataServerState
    thread: Thread[ptr MetadataServerState]

proc respond(client: Socket; status, body: string) =
  client.send("HTTP/1.1 " & status & "\r\nContent-Length: " & $body.len &
    "\r\nConnection: close\r\n\r\n" & body)

proc serveLoop(state: ptr MetadataServerState) {.thread.} =
  while not state.stopping.load():
    var client: Socket
    try:
      state.socket.accept(client)
    except CatchableError:
      break
    try:
      let requestLine = client.recvLine(timeout = 5000)
      # Drain headers so the client's write completes before we answer.
      while true:
        let header = client.recvLine(timeout = 5000)
        if header.len == 0 or header == "\r\n": break
      let parts = requestLine.splitWhitespace()
      if parts.len < 2 or parts[0] != "GET":
        client.respond("400 Bad Request", "")
      else:
        # NLF-M6 serves a real path hierarchy, not just a basename: the
        # `Repository-And-Index-Format.md` object kinds live at
        # `/metadata/index/<shard>.shard`, `/metadata/acquisition/…` and
        # `/metadata/repository.manifest`, so a basename-only server would map
        # a shard and a package with the same name to one file. The prefix
        # before the LAST `/metadata/` is stripped and the remainder is the
        # path under `root`; `..` is refused rather than normalised, because a
        # test server that could be walked out of would make the served bytes
        # something other than what the test published.
        var rel = parts[1]
        const marker = "/metadata/"
        let at = rel.rfind(marker)
        if at >= 0:
          rel = rel[at + marker.len .. ^1]
        rel = rel.strip(chars = {'/'})
        state.requests.atomicInc()
        if rel.len == 0 or rel.contains(".."):
          client.respond("400 Bad Request", "")
        else:
          let path = state.root / rel
          if fileExists(path):
            client.respond("200 OK", readFile(path))
          else:
            client.respond("404 Not Found", "")
    except CatchableError:
      discard
    try: client.close()
    except CatchableError: discard

proc startMetadataServer*(root: string): MetadataServer =
  ## Bind an ephemeral loopback port and start serving `root`.
  createDir(root)
  let state = create(MetadataServerState)
  state.root = root
  state.socket = newSocket()
  state.socket.setSockOpt(OptReuseAddr, true)
  state.socket.bindAddr(Port(0), "127.0.0.1")
  state.port = int(state.socket.getLocalAddr()[1])
  state.socket.listen()
  state.stopping.store(false)
  state.requests.store(0)
  result = MetadataServer(state: state)
  createThread(result.thread, serveLoop, state)

proc endpoint*(server: MetadataServer): string =
  ## The metadata index base URL callers put in `LockGenerationRequest.endpoints`.
  "http://127.0.0.1:" & $server.state.port & "/metadata"

proc requestsServed*(server: MetadataServer): int =
  ## Readable before AND after `stop`; see the note there.
  if server.isNil or server.state.isNil: 0
  else: server.state.requests.load()

proc publish*(server: MetadataServer; packageName: string;
              versions: openArray[string]) =
  var body = ""
  for v in versions: body.add(v & "\n")
  writeFile(server.state.root / (packageName & ".versions"), body)

proc publishAt*(server: MetadataServer; relPath, body: string) =
  ## Publish an arbitrary metadata object at `relPath` under the served root.
  ##
  ## NLF-M6's folded criterion needs one object of each
  ## `Repository-And-Index-Format.md` kind published, and the four
  ## non-version-list kinds live at paths this server had no way to write.
  ## Still fixture DATA over a real socket — nothing about the retrieval path
  ## is substituted; see the header's test-double note.
  let full = server.state.root / relPath
  createDir(parentDir(full))
  writeFile(full, body)

proc withdraw*(server: MetadataServer; packageName: string) =
  ## Unpublish a package's version-metadata record.
  ##
  ## The registry rollback case: an upstream that published a version and then
  ## yanked it. NLF-M6's two-phase lookup is only observable if upstream can be
  ## moved BACK to a state a previously recorded path set was taken over.
  let path = server.state.root / (packageName & ".versions")
  if fileExists(path): removeFile(path)

proc stop*(server: MetadataServer) =
  ## Shut the listener down and JOIN the serving thread, so that after this
  ## returns the port genuinely refuses connections. The join is what makes
  ## "the network is unavailable" a fact rather than a race.
  if server.isNil or server.state.isNil: return
  server.state.stopping.store(true)
  try: server.state.socket.close()
  except CatchableError: discard
  # Nudge the blocking `accept` so the loop observes `stopping`.
  try:
    let poke = newSocket()
    poke.connect("127.0.0.1", Port(server.state.port))
    poke.close()
  except CatchableError:
    discard
  joinThread(server.thread)
  # The state is deliberately NOT freed here. `requestsServed()` is EVIDENCE,
  # and NLF-GEN-7 reads it after the listener is gone — "the far side answered
  # no further request while the build was pinned" is a statement about the
  # period after shutdown. Freeing it would make the counter unreadable at
  # exactly the moment it matters. The allocation is one small object per
  # server per test process; `destroyMetadataServer` releases it for a caller
  # that wants to.

proc destroyMetadataServer*(server: MetadataServer) =
  ## Release the state a stopped server kept alive for its counter. After this
  ## `requestsServed` reports 0, so call it only once the evidence has been
  ## read.
  if server.isNil or server.state.isNil: return
  dealloc(server.state)
  server.state = nil
