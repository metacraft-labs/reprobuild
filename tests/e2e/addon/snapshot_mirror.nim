## A time-shifted distribution mirror for the add-on's upgrade gates.
##
## The upgrade gates (point upgrades, the apt hook, a week of
## ``unattended-upgrades``, the Debian 12 -> 13 and Ubuntu 24.04 -> 26.04
## release upgrades) must be reproducible, so they cannot run against the
## live archives, which change every day. This is an HTTP forward proxy the
## guest's apt is pointed at (``Acquire::http::Proxy``; ``http_proxy`` for
## ``do-release-upgrade``'s own downloads). It answers for the archives the
## stock images name -- ``deb.debian.org``, ``security.debian.org``,
## ``archive.ubuntu.com``, ``security.ubuntu.com`` -- with the archive **as
## it was at the mirror's timestamp**, from the distributions' snapshot
## services:
##
## - ``http://deb.debian.org/debian/<p>`` ->
##   ``https://snapshot.debian.org/archive/debian/<T>/<p>``
##   (https://snapshot.debian.org/, "Usage");
## - ``.../debian-security/<p>`` ->
##   ``https://snapshot.debian.org/archive/debian-security/<T>/<p>``;
## - ``http://{archive,security}.ubuntu.com/ubuntu/<p>`` ->
##   ``https://snapshot.ubuntu.com/ubuntu/<T>/<p>``
##   (https://snapshot.ubuntu.com/, "Using the snapshot service");
## - Ubuntu's release upgrader (``dists/<suite>/main/dist-upgrader-all/``),
##   which ``snapshot.ubuntu.com`` does not carry, from the live archive --
##   but only the files ``fixtures/live-pins.sha256`` pins by SHA-256 (a
##   changed file is refused, never taken), cached like the rest;
## - ``http://changelogs.ubuntu.com/meta-release-lts`` (what
##   ``do-release-upgrade`` reads to find the next LTS) from a committed,
##   dated copy (``fixtures/meta-release-lts``), since that file has no
##   snapshot.
##
## Everything else -- any other host, ``CONNECT`` -- is refused, so a gate
## cannot silently depend on a live service. The gate moves ``T`` (and the
## guest's clock with it) to simulate time passing: a week of daily
## unattended upgrades is seven timestamps.
##
## *Caching, and being a considerate client.* The snapshot services are
## volunteer-run. Every answer is cached under the test bed's cache
## directory (``<cache>/snapshot-mirror``) and never fetched again: index
## files are keyed by their timestamp (a snapshot never changes), and pool
## files and ``by-hash`` objects by their path alone (an archive never
## reuses a pool file name or a hash for other bytes). At most
## ``UpstreamConcurrency`` upstream fetches run at once, each with a
## bounded number of retries. A cached run of a gate makes no upstream
## request at all.
##
## *Mocking.* None: the guest's apt talks HTTP to this proxy as it would to
## any configured proxy, and every byte it is given comes from the real
## archive snapshot (apt verifies the archive signatures as usual).

import std/[locks, nativesockets, net, os, osproc, strutils, times]

type
  SnapshotMirror* = ref object
    port*: int
    root*: string                 ## cache root
    fixtures*: string             ## committed fixture directory
    socket: Socket
    acceptThread: Thread[ptr MirrorShared]
    workers: seq[ref Thread[ptr MirrorShared]]
    shared: ptr MirrorShared

  MirrorShared = object
    lock: Lock
    timestamp: string             ## yyyymmddThhmmssZ
    root: string
    fixtures: string
    upstream: int                 ## upstream fetches in flight
    stopping: bool
    requests: int
    upstreamFetches: int
    refused: seq[string]

const
  UpstreamConcurrency = 3
  Workers = 8
  GuestHostAddress* = "10.0.2.2"
    ## QEMU user-mode networking's alias for the host's loopback.

var gConns: Channel[int]

proc fixturesDir*(): string =
  currentSourcePath().parentDir() / "fixtures"

proc snapshotStamp*(t: DateTime): string =
  t.utc.format("yyyyMMdd'T'HHmmss'Z'")

proc parseStamp*(s: string): DateTime =
  parse(s, "yyyyMMdd'T'HHmmss'Z'", utc())

proc setTimestamp*(m: SnapshotMirror; stamp: string) =
  ## Move the mirror to the archive as it was at ``stamp``.
  discard parseStamp(stamp)
  withLock m.shared.lock:
    m.shared.timestamp = stamp

proc timestamp*(m: SnapshotMirror): string =
  withLock m.shared.lock:
    result = m.shared.timestamp

proc stats*(m: SnapshotMirror): tuple[requests, upstream: int; refused: seq[string]] =
  withLock m.shared.lock:
    result = (m.shared.requests, m.shared.upstreamFetches, m.shared.refused)

proc proxyUrl*(m: SnapshotMirror): string =
  "http://" & GuestHostAddress & ":" & $m.port

type Route = object
  ok: bool
  upstream: string     ## https URL, "" for a fixture
  fixture: string      ## file under fixtures, for unsnapshotted files
  cacheKey: string     ## relative path under the cache root
  pinned: string       ## required SHA-256 of a live (unsnapshotted) file

proc livePin(hostPath: string): string =
  ## The pinned SHA-256 of a live archive file, or "".
  let f = currentSourcePath().parentDir() / "fixtures" / "live-pins.sha256"
  for l in readFile(f).splitLines():
    let t = l.strip()
    if t.len == 0 or t[0] == '#': continue
    let parts = t.splitWhitespace()
    if parts.len == 2 and parts[1] == hostPath: return parts[0]
  ""

proc immutableByName(rest: string): bool =
  "/pool/" in "/" & rest or "/by-hash/" in "/" & rest

proc route*(url, stamp: string): Route =
  ## Map an absolute request URL to its snapshot. Pure.
  if not url.startsWith("http://"): return
  let noScheme = url["http://".len .. ^1]
  let slash = noScheme.find('/')
  if slash < 0: return
  let host = noScheme[0 ..< slash].split(':')[0].toLowerAscii()
  var path = noScheme[slash + 1 .. ^1]
  let q = path.find('?')
  if q >= 0: path = path[0 ..< q]
  if ".." in path.split('/'): return
  proc snap(archive, base, rest: string): Route =
    let key = if immutableByName(rest): archive & "/" & rest
              else: archive & "/" & stamp & "/" & rest
    Route(ok: true, upstream: base & stamp & "/" & rest, cacheKey: key)
  case host
  of "deb.debian.org", "ftp.debian.org", "cdn-fastly.deb.debian.org":
    if path.startsWith("debian/"):
      return snap("debian", "https://snapshot.debian.org/archive/debian/",
                  path["debian/".len .. ^1])
    if path.startsWith("debian-security/"):
      return snap("debian-security",
                  "https://snapshot.debian.org/archive/debian-security/",
                  path["debian-security/".len .. ^1])
  of "security.debian.org":
    let rest = if path.startsWith("debian-security/"):
                 path["debian-security/".len .. ^1] else: path
    return snap("debian-security",
                "https://snapshot.debian.org/archive/debian-security/", rest)
  of "archive.ubuntu.com", "security.ubuntu.com":
    if "/dist-upgrader-all/" in path:
      let pin = livePin(host & "/" & path)
      if pin.len == 0: return
      return Route(ok: true, upstream: "http://archive.ubuntu.com/" & path,
                   cacheKey: "ubuntu-live/" & path, pinned: pin)
    if path.startsWith("ubuntu/"):
      return snap("ubuntu", "https://snapshot.ubuntu.com/ubuntu/",
                  path["ubuntu/".len .. ^1])
  of "changelogs.ubuntu.com":
    if path in ["meta-release-lts", "meta-release"]:
      return Route(ok: true, fixture: path)
  else: discard

# ---------------------------------------------------------------------------
# Upstream fetch, through the cache.
# ---------------------------------------------------------------------------

proc fetchCached(sh: ptr MirrorShared; r: Route): tuple[path: string; code: int] =
  ## The cached file for ``r`` (fetching it first if needed) and an HTTP
  ## status: 200, or the upstream's 404.
  if r.fixture.len > 0:
    let f = sh.fixtures / r.fixture
    return (if fileExists(f): (f, 200) else: ("", 404))
  let path = sh.root / r.cacheKey
  if fileExists(path): return (path, 200)
  if fileExists(path & ".404"): return ("", 404)
  # Bounded upstream concurrency.
  while true:
    var go = false
    withLock sh.lock:
      if sh.upstream < UpstreamConcurrency:
        inc sh.upstream
        inc sh.upstreamFetches
        go = true
    if go: break
    sleep(100)
  defer:
    withLock sh.lock: dec sh.upstream
  if fileExists(path): return (path, 200)
  createDir(parentDir(path))
  let part = path & ".part-" & $getThreadId()
  var code = 0
  for attempt in 1 .. 3:
    let (o, rc) = execCmdEx("curl -sS -L --max-time 1800 -o " &
      quoteShell(part) & " -w '%{http_code}' " & quoteShell(r.upstream))
    code = (try: parseInt(o.strip()[^3 .. ^1]) except CatchableError: 0)
    if rc == 0 and code in [200, 404]: break
    sleep(2000 * attempt)
  if code == 200:
    if r.pinned.len > 0:
      let (d, _) = execCmdEx("sha256sum " & quoteShell(part))
      if d.splitWhitespace()[0] != r.pinned:
        removeFile(part)
        return ("", 502)
    moveFile(part, path)
    return (path, 200)
  removeFile(part)
  if code == 404:
    # Only a timestamped answer is immutable; a missing pool file may be a
    # transient upstream fault, and is not remembered.
    if not immutableByName(r.cacheKey): writeFile(path & ".404", "")
    return ("", 404)
  ("", 502)

proc fetchThrough*(m: SnapshotMirror; url: string): string =
  ## Host-side: the cached local file for ``url`` as the guest would get it
  ## (for the closure lock and seeding a guest's ``.deb`` cache).
  let r = route(url, m.timestamp)
  if not r.ok:
    raise newException(IOError, "the snapshot mirror does not serve " & url)
  let (p, code) = fetchCached(m.shared, r)
  if code != 200:
    raise newException(IOError, url & ": HTTP " & $code)
  p

# ---------------------------------------------------------------------------
# The proxy.
# ---------------------------------------------------------------------------

proc respond(s: Socket; code: int; reason: string; body = "") =
  s.send("HTTP/1.1 " & $code & " " & reason & "\r\nContent-Length: " &
         $body.len & "\r\nConnection: close\r\n\r\n" & body)

proc serve(sh: ptr MirrorShared; s: Socket) =
  var reqLine = ""
  s.readLine(reqLine, timeout = 30_000)
  while true:
    var h = ""
    s.readLine(h, timeout = 30_000)
    if h.len == 0 or h == "\r\n" or h == "\c\L": break
  let parts = reqLine.splitWhitespace()
  if parts.len < 2: return
  withLock sh.lock: inc sh.requests
  let meth = parts[0]
  var stamp = ""
  withLock sh.lock: stamp = sh.timestamp
  let r = route(parts[1], stamp)
  if meth notin ["GET", "HEAD"] or not r.ok:
    withLock sh.lock:
      if sh.refused.len < 200: sh.refused.add(meth & " " & parts[1])
    respond(s, 403, "Forbidden", "not served by the test bed's snapshot mirror\n")
    return
  let (path, code) = fetchCached(sh, r)
  if code == 404:
    respond(s, 404, "Not Found")
    return
  if code != 200:
    respond(s, 502, "Bad Gateway")
    return
  let size = getFileSize(path)
  s.send("HTTP/1.1 200 OK\r\nContent-Length: " & $size &
         "\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n")
  if meth == "HEAD": return
  var f = open(path, fmRead)
  defer: f.close()
  var buf = newString(65536)
  while true:
    let n = f.readBuffer(addr buf[0], buf.len)
    if n <= 0: break
    s.send(buf[0 ..< n])

proc workerLoop(sh: ptr MirrorShared) {.thread.} =
  {.cast(gcsafe).}:
    while true:
      let fd = gConns.recv()
      if fd < 0: break
      let s = newSocket(SocketHandle(fd), AF_INET, SOCK_STREAM, IPPROTO_TCP)
      try:
        serve(sh, s)
      except CatchableError:
        discard
      finally:
        s.close()

var gListen: Socket

proc acceptMain(sh: ptr MirrorShared) {.thread.} =
  {.cast(gcsafe).}:
    while true:
      var client: Socket
      try:
        gListen.accept(client)
      except CatchableError:
        break
      var stop = false
      withLock sh.lock: stop = sh.stopping
      if stop:
        client.close()
        break
      let fd = int(client.getFd())
      # Hand the descriptor over; the worker owns it from here.
      gConns.send(fd)

proc startSnapshotMirror*(stamp: string; root = ""): SnapshotMirror =
  ## Start the mirror on a loopback port at ``stamp``. One per process.
  result = SnapshotMirror(root: root, fixtures: fixturesDir())
  if result.root.len == 0:
    let env = getEnv("REPRO_ADDON_TESTBED_CACHE")
    let base = if env.len > 0: env
               else: (let x = getEnv("XDG_CACHE_HOME");
                      (if x.len > 0: x else: getHomeDir() / ".cache") /
                      "reprobuild" / "addon-testbed")
    result.root = base / "snapshot-mirror"
  createDir(result.root)
  result.shared = createShared(MirrorShared)
  initLock(result.shared.lock)
  result.shared.timestamp = stamp
  result.shared.root = result.root
  result.shared.fixtures = result.fixtures
  discard parseStamp(stamp)
  gConns.open()
  gListen = newSocket()
  gListen.setSockOpt(OptReuseAddr, true)
  gListen.bindAddr(Port(0), "127.0.0.1")
  gListen.listen()
  result.port = int(gListen.getLocalAddr()[1])
  for i in 0 ..< Workers:
    let t = new(Thread[ptr MirrorShared])
    createThread(t[], workerLoop, result.shared)
    result.workers.add(t)
  createThread(result.acceptThread, acceptMain, result.shared)

proc stop*(m: SnapshotMirror) =
  if m == nil or m.shared == nil: return
  withLock m.shared.lock: m.shared.stopping = true
  # Wake the accept loop with one last connection.
  try:
    let s = newSocket()
    s.connect("127.0.0.1", Port(m.port))
    s.close()
  except CatchableError: discard
  joinThread(m.acceptThread)
  gListen.close()
  for _ in m.workers: gConns.send(-1)
  for t in m.workers: joinThread(t[])
  gConns.close()
