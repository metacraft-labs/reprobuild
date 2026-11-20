## Test support (not a test): the Nimble source fetch's tests, on top of the
## generator's HTTPS fixture (`generator_fixtures`).
##
## Nothing here contacts the internet. Origins are bare repositories served
## by `git http-backend` behind a TLS listener on 127.0.0.1; the same
## listener serves directories as HTTPS mirrors (`/mirror/...`) and the
## origins' commit archives as a forge does (`/<owner>/<repo>/archive/
## <commit>.tar.gz`). The origin fallback reaches them through the
## production egress policy: the test's resolver answers the documentation
## address 203.0.113.10 for `forge.test`, and the dialer maps that address
## alone to the listener (see `generator_fixtures`). A mirror is a location
## the configuration names, so `mirror.test` resolves to 127.0.0.1 directly.
##
## Expected digests are computed by the generator's own `source` code
## (`readTree` + `sourceFacts`) over the served repository, which is what an
## index record carries.

import std/[locks, nativesockets, net, os, strutils, tables, tempfiles, times]

import repro_nimble_fetch
import repro_nimble_generator

import ../../repro_nimble_generator/tests/generator_fixtures

export generator_fixtures, repro_nimble_generator, repro_nimble_fetch

const MirrorHost* = "mirror.test"

type
  PublishedSource* = object
    path*: string    ## the served repository, `<owner>/<repo>.git`
    commit*: string
    tree*: string
    archive*: string ## the canonical archive
    archiveSha256*: string

proc mirrorPolicy*(f: Fixture): EgressPolicy =
  ## How a client reaches the fixture's mirrors: `mirror.test` is the local
  ## listener, trusted through the fixture's certificate.
  let resolver = proc(host: string): seq[IpAddress] {.gcsafe.} =
    if host == MirrorHost: @[parseIpAddress("127.0.0.1")] else: @[]
  EgressPolicy(limits: DefaultLimits, resolver: resolver, caFile: f.cert)

proc httpsMirror*(f: Fixture; prefix: string; required = true): Mirror =
  parseMirror("https://" & MirrorHost & ":" & $f.port & prefix, required)

proc forgeRules*(): seq[ForgeRule] =
  ## The test forges: every test host's archive endpoint has the GitHub shape.
  for h in [ForgeHost, "internal.test", "private.test", "linklocal.test",
            "metadata.test"]:
    result.add ForgeRule(host: h,
      archive: "https://" & h & "/{path}/archive/{commit}.tar.gz")

proc fetchConfig*(f: Fixture; work: string; mirrors: seq[Mirror];
                  store = ""): FetchConfig =
  FetchConfig(stateDir: work / "state",
    storeRoot: (if store.len > 0: store else: work / "store"),
    mirrors: mirrors, mirrorAccess: f.mirrorPolicy(),
    originPolicy: f.testPolicy(), forges: forgeRules(), gitBin: f.gitBin,
    useClosureIndex: true, limits: DefaultExtractLimits)

proc sourceOf*(f: Fixture; path, commit: string; subdir = ""): PublishedSource =
  ## What the generator's `source` edge computes for ``commit`` of the served
  ## repository ``path``: the tree digest and the canonical archive.
  let g = OriginGit(gitBin: f.gitBin)
  let tree = readTree(g, f.root / path, commit, subdir, DefaultLimits)
  let (facts, archive, _) = sourceFacts(tree)
  PublishedSource(path: path, commit: commit, tree: facts.treeDigest,
    archive: archive, archiveSha256: facts.archiveSha256)

proc rowOf*(f: Fixture; name: string; s: PublishedSource; withArchive = true):
    NimbleLockRow =
  NimbleLockRow(name: name, origin: f.url(s.path), commit: s.commit,
    tree: s.tree,
    archiveSha256: (if withArchive: s.archiveSha256 else: ""),
    size: (if withArchive: int64(s.archive.len) else: -1'i64))

proc package*(f: Fixture; path: string; files: seq[FileSpec];
              tagName = "v1.0.0"): PublishedSource =
  ## A served repository with one tagged commit of ``files``.
  let work = f.newRepo(path)
  let c = commit(work, files)
  tag(work, tagName)
  publish(work)
  f.sourceOf(path, c)

proc putSource*(m: Mirror; s: PublishedSource) =
  m.putObject(sourceObjectPath(s.tree), s.archive)

proc stagingLeft*(store: string): seq[string] =
  ## Staging directories left beside the store's entries.
  if not dirExists(store): return
  for kind, p in walkDir(store):
    if extractFilename(p).startsWith(".stage-"): result.add p

proc hasGitDir*(dir: string): bool =
  if not dirExists(dir): return false
  for p in walkDirRec(dir, yieldFilter = {pcDir, pcFile, pcLinkToDir,
                                          pcLinkToFile},
                      followFilter = {pcDir}):
    if extractFilename(p) == ".git": return true

proc requestsMatching*(f: Fixture; needle: string): int =
  for l in f.requests():
    if needle in l: inc result

# ---------------------------------------------------------------------------
# A concurrent HTTPS mirror, for what the serial fixture cannot show
# ---------------------------------------------------------------------------
#
# The shared fixture answers one connection at a time, so it cannot show
# that a client overlaps its requests. This server answers each connection
# on a thread of its own and counts the requests it holds at once. It
# serves a directory under `/mirror/` and, to make overlap observable, can
# HOLD every source-object answer until `holdFor` object requests are in
# flight together (or `holdMs` passed): a client that sends one request at
# a time then shows `maxInFlight == 1` and waits `holdMs` per object.
# Under `/drip/` it answers with a declared length of 2 MiB and then sends
# 8 KiB every `dripMs`, never stalling, for the wall-time limit.

type
  ServerStats = object
    lock: Lock
    inFlight, maxInFlight: int
    holdFor, holdMs, dripMs: int

  ConcurrentServerArg = object
    listenFd: int
    cert, key, dir, logPath: string
    stats: ptr ServerStats

  ConnectionArg = object
    fd: int
    cert, key, dir, logPath: string
    stats: ptr ServerStats

  ConcurrentMirror* = object
    port*: int
    logPath*: string
    stats: ptr ServerStats
    listener: Socket
    acceptor: ptr Thread[ConcurrentServerArg] ## never moved, never joined

proc logRequest(a: ConnectionArg; line: string) =
  withLock a.stats.lock:
    let f = open(a.logPath, fmAppend)
    f.writeLine(line)
    f.close()

proc holdObject(st: ptr ServerStats) =
  ## Count this request in flight, then wait until `holdFor` are (once that
  ## many were in flight together every answer flows) or `holdMs` passed.
  withLock st.lock:
    inc st.inFlight
    st.maxInFlight = max(st.maxInFlight, st.inFlight)
  let deadline = epochTime() + float(st.holdMs) / 1000
  while true:
    var enough = false
    withLock st.lock:
      enough = st.holdFor <= 0 or st.maxInFlight >= st.holdFor
    if enough or epochTime() > deadline: break
    sleep(5)

proc answerConnection(a: ConnectionArg) {.thread.} =
  {.cast(gcsafe).}:
    let ctx = newContext(verifyMode = CVerifyNone, certFile = a.cert,
      keyFile = a.key)
    let client = newSocket(SocketHandle(a.fd))
    var held = false
    try:
      ctx.wrapConnectedSocket(client, handshakeAsServer)
      let first = client.recvLine(timeout = 10_000)
      while true:
        let h = client.recvLine(timeout = 10_000)
        if h.len == 0 or h == "\r\n": break
      let parts = first.split(' ')
      if parts.len >= 2:
        let meth = parts[0]
        let target = parts[1]
        let q = target.find('?')
        let path = if q < 0: target else: target[0 ..< q]
        a.logRequest(meth & " " & path)
        if path.startsWith("/drip/"):
          # 2 MiB in 8 KiB pieces, one every `dripMs`: steady progress (a
          # 64 KiB read completes well inside any stall limit), slow total.
          let piece = repeat('x', 8192)
          client.send("HTTP/1.1 200 OK\r\nContent-Length: " &
            $(256 * piece.len) & "\r\nConnection: close\r\n\r\n")
          for _ in 0 ..< 256:
            sleep(a.stats.dripMs)
            client.send(piece)
        elif path.startsWith("/mirror/"):
          let rel = path["/mirror/".len .. ^1]
          let file = a.dir / rel
          if ".." in rel.split('/') or not fileExists(file):
            client.send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n" &
              "Connection: close\r\n\r\n")
          else:
            if "/nimble/sources/" in path:
              held = true
              holdObject(a.stats)
            let body = readFile(file)
            client.send("HTTP/1.1 200 OK\r\nContent-Length: " & $body.len &
              "\r\nConnection: close\r\n\r\n" &
              (if meth == "HEAD": "" else: body))
        else:
          client.send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n" &
            "Connection: close\r\n\r\n")
    except CatchableError:
      discard
    if held:
      withLock a.stats.lock:
        dec a.stats.inFlight
    try: client.close() except CatchableError: discard
    ctx.destroyContext()

proc acceptConnections(a: ConcurrentServerArg) {.thread.} =
  {.cast(gcsafe).}:
    let listener = newSocket(fd = SocketHandle(a.listenFd))
    while true:
      var client: Socket
      try:
        listener.accept(client)
      except CatchableError:
        return
      # One thread per connection, never joined: the test process ends
      # with them. The Thread object lives in shared memory so it is not
      # moved while the thread runs.
      let t = cast[ptr Thread[ConnectionArg]](
        allocShared0(sizeof(Thread[ConnectionArg])))
      createThread(t[], answerConnection, ConnectionArg(
        fd: int(client.getFd()), cert: a.cert, key: a.key, dir: a.dir,
        logPath: a.logPath, stats: a.stats))

proc newConcurrentMirror*(f: Fixture; dir: string; holdFor = 0;
                          holdMs = 5000; dripMs = 100): ConcurrentMirror =
  ## A concurrent HTTPS server on 127.0.0.1 with the fixture's certificate,
  ## serving ``dir`` under `/mirror/` (see above).
  result.logPath = f.dir / "concurrent-" & $epochTime() & ".log"
  writeFile(result.logPath, "")
  result.stats = cast[ptr ServerStats](allocShared0(sizeof(ServerStats)))
  initLock(result.stats.lock)
  result.stats.holdFor = holdFor
  result.stats.holdMs = holdMs
  result.stats.dripMs = dripMs
  result.listener = newSocket()
  result.listener.setSockOpt(OptReuseAddr, true)
  result.listener.bindAddr(Port(0), "127.0.0.1")
  result.listener.listen()
  result.port = int(result.listener.getLocalAddr()[1])
  result.acceptor = cast[ptr Thread[ConcurrentServerArg]](
    allocShared0(sizeof(Thread[ConcurrentServerArg])))
  createThread(result.acceptor[], acceptConnections, ConcurrentServerArg(
    listenFd: int(result.listener.getFd()), cert: f.cert, key: f.key,
    dir: dir, logPath: result.logPath, stats: result.stats))

proc requests*(m: ConcurrentMirror): seq[string] =
  withLock m.stats.lock:
    for l in readFile(m.logPath).splitLines():
      if l.len > 0: result.add l

proc maxInFlight*(m: ConcurrentMirror): int =
  withLock m.stats.lock:
    result = m.stats.maxInFlight

proc mirrorOn*(m: ConcurrentMirror): Mirror =
  ## The server's `/mirror/` as a client configures it (`mirror.test`).
  parseMirror("https://" & MirrorHost & ":" & $m.port & "/mirror/")

# ---------------------------------------------------------------------------
# Hand-made tar archives, for the extractor's refusals
# ---------------------------------------------------------------------------

type TarMember* = object
  name*: string
  typeflag*: char
  content*: string
  link*: string
  mode*: int

proc put(dst: var string; at: int; s: string) =
  for i, c in s: dst[at + i] = c

proc oct(v: int64; width: int): string = toOct(v, width - 1) & "\0"

proc tarHeader(m: TarMember): string =
  result = newString(512)
  for i in 0 ..< 512: result[i] = '\0'
  result.put(0, m.name[0 ..< min(m.name.len, 100)])
  result.put(100, oct(if m.mode == 0: 0o644 else: m.mode, 8))
  result.put(108, oct(0, 8))
  result.put(116, oct(0, 8))
  result.put(124, oct(m.content.len, 12))
  result.put(136, oct(0, 12))
  result.put(148, "        ")
  result[156] = m.typeflag
  result.put(157, m.link)
  result.put(257, "ustar\0")
  result.put(263, "00")
  var sum = 0
  for c in result: sum += ord(c)
  result.put(148, toOct(sum, 6) & "\0 ")

proc tarOf*(members: seq[TarMember]): string =
  ## A plain ustar archive of ``members``, in order.
  for m in members:
    result.add tarHeader(m)
    result.add m.content
    let r = m.content.len mod 512
    if r != 0: result.add repeat('\0', 512 - r)
  result.add repeat('\0', 1024)

proc regular*(name, content: string; mode = 0o644): TarMember =
  TarMember(name: name, typeflag: '0', content: content, mode: mode)
proc dirMember*(name: string): TarMember =
  TarMember(name: name, typeflag: '5', mode: 0o755)
proc linkMember*(name, target: string): TarMember =
  TarMember(name: name, typeflag: '2', link: target, mode: 0o777)
proc hardLinkMember*(name, target: string): TarMember =
  TarMember(name: name, typeflag: '1', link: target)

proc paxMember*(records: seq[(string, string)]): TarMember =
  ## A pax extended header ('x') for the next member.
  var body = ""
  for (k, v) in records:
    let rest = " " & k & "=" & v & "\n"
    var n = rest.len + 1
    while ($n).len + rest.len != n: n = ($n).len + rest.len
    body.add $n & rest
  TarMember(name: "PaxHeader", typeflag: 'x', content: body, mode: 0o644)

proc gzipOf*(work, data: string): string =
  ## ``data`` gzip-compressed by the host's gzip (a fixture tool).
  let input = work / "gz-input"
  writeFile(input, data)
  discard run(["gzip", "-n", "-f", input])
  result = readFile(input & ".gz")
  removeFile(input & ".gz")

proc withNoOrigin*(c: FetchConfig): FetchConfig =
  ## The same configuration with every origin unreachable: no forge archive
  ## endpoint, and no name resolves for the origin fallback.
  result = c
  result.forges = @[]
  result.originPolicy.resolver = proc(host: string): seq[IpAddress] {.gcsafe.} =
    @[]
