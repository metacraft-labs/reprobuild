## Test support (not a test): local git origins served over real HTTPS, for
## the Nimble index generator's tests.
##
## Nothing here contacts the internet. The origins are bare repositories
## under a temporary directory, served by `git http-backend` (git's own
## smart-HTTP server, run as a CGI) behind a TLS listener on 127.0.0.1 with
## a certificate minted for the test's host names. The generator reaches
## them through its production path: the egress policy vets the URL, the
## host and every redirect, and git fetches over https with the vetted
## address pinned. Two things are the test's:
##
## * the RESOLVER answers the test's host names (`forge.test` and friends)
##   with the addresses a test names -- a documentation address
##   (203.0.113.0/24, never routed) for the forge, loopback, private,
##   link-local and metadata addresses for the hosts the policy must refuse;
## * the DIALER connects the forge's vetted documentation address to the
##   local listener. It is the only substitution: the policy checks the
##   address the resolver answered, exactly as in production.
##
## The same listener can also serve, by route: a directory as a static
## HTTPS mirror (`serveDir`, GET and HEAD), and a served repository's commit
## archives the way a forge does (`forgeArchives`: `/<owner>/<repo>/archive/
## <commit>.tar.gz`, made by `git archive` with the forge's single top
## directory `<repo>-<commit>/`).

from repro_core/process_streams import drainStream
import std/[exitprocs, nativesockets, net, options, os, osproc, random, streams, strtabs, strutils, tables, tempfiles, times]

import repro_nimble_generator
import repro_nimble_index
import repro_domain_types/nimble_index

const
  ForgeAddress* = "203.0.113.10"
  ForgeHost* = "forge.test"
  CertHosts = ["forge.test", "mirror.test", "internal.test", "private.test",
               "linklocal.test", "metadata.test"]

type
  Route* = object
    prefix*: string     ## a request path prefix
    redirectTo*: string ## answer 302 to this URL
    stall*: bool        ## answer headers, then nothing
    failFetchWhile*: string
      ## while this file exists, answer a `fetch` request (an upload-pack
      ## POST asking for objects) with 503; refs are still listed
    serveDir*: string
      ## answer GET and HEAD under ``prefix`` from this directory (a static
      ## mirror); a missing file is 404
    forgeArchives*: bool
      ## answer `<prefix><owner>/<repo>/archive/<commit>.tar.gz` with
      ## `git archive` of the served `<owner>/<repo>.git`, as a forge does

  ServerConfig = object
    root, cert, key, gitBin: string
    routes: seq[Route]
    listenFd: int
    logPath: string

  Fixture* = object
    dir*: string        ## everything the fixture writes
    root*: string       ## the served repositories
    cert*, key*: string
    port*: int
    gitBin*: string
    logPath*: string
    thread: Thread[ServerConfig]
    listener: Socket

proc run*(args: openArray[string]; cwd = ""; env: StringTableRef = nil;
          input = ""): string =
  ## Run a fixture command (no shell); raise on failure.
  let p = startProcess(args[0], workingDir = cwd, args = args[1 .. ^1],
    env = env, options = {poUsePath, poStdErrToStdOut})
  if input.len > 0: p.inputStream.write(input)
  p.inputStream.close()
  result = drainStream(p.outputStream)
  let code = p.waitForExit()
  p.close()
  if code != 0:
    raise newException(OSError, args.join(" ") & " failed (" & $code & "): " &
      result)

proc gitEnv*(date = 1_700_000_000'i64): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if not k.startsWith("GIT_"): result[k] = v
  result["GIT_CONFIG_NOSYSTEM"] = "1"
  result["GIT_CONFIG_GLOBAL"] = "/dev/null"
  result["GIT_AUTHOR_NAME"] = "Fixture"
  result["GIT_AUTHOR_EMAIL"] = "fixture@example.invalid"
  result["GIT_COMMITTER_NAME"] = "Fixture"
  result["GIT_COMMITTER_EMAIL"] = "fixture@example.invalid"
  result["GIT_AUTHOR_DATE"] = $date & " +0000"
  result["GIT_COMMITTER_DATE"] = $date & " +0000"

proc gitAt*(date: int64; work: string; args: varargs[string]): string =
  var a = @["git", "-C", work]
  for x in args: a.add x
  run(a, env = gitEnv(date)).strip()

proc git*(work: string; args: varargs[string]): string =
  gitAt(1_700_000_000'i64, work, args)

proc gitIn*(work, input: string; args: varargs[string]): string =
  var a = @["git", "-C", work]
  for x in args: a.add x
  run(a, env = gitEnv(), input = input).strip()

# ---------------------------------------------------------------------------
# The HTTPS smart-HTTP server
# ---------------------------------------------------------------------------

proc logLine(cfg: ServerConfig; line: string) =
  let f = open(cfg.logPath, fmAppend)
  f.writeLine(line)
  f.close()

proc readRequest(s: Socket): tuple[ok: bool; meth, path, query: string;
                                   headers: Table[string, string];
                                   body: string] =
  let first = s.recvLine(timeout = 10_000)
  let parts = first.split(' ')
  if parts.len < 3: return
  result.meth = parts[0]
  let target = parts[1]
  let q = target.find('?')
  result.path = if q < 0: target else: target[0 ..< q]
  result.query = if q < 0: "" else: target[q + 1 .. ^1]
  while true:
    let line = s.recvLine(timeout = 10_000)
    if line.len == 0 or line == "\r\n": break
    let c = line.find(':')
    if c > 0:
      result.headers[line[0 ..< c].strip().toLowerAscii()] =
        line[c + 1 .. ^1].strip()
  if result.headers.getOrDefault("transfer-encoding").toLowerAscii() ==
      "chunked":
    while true:
      let sizeLine = s.recvLine(timeout = 10_000).strip()
      let n = parseHexInt(sizeLine.split(';')[0])
      if n == 0:
        discard s.recvLine(timeout = 10_000)
        break
      result.body.add s.recv(n, timeout = 10_000)
      discard s.recv(2, timeout = 10_000)
  elif result.headers.hasKey("content-length"):
    let n = parseInt(result.headers["content-length"])
    if n > 0: result.body = s.recv(n, timeout = 10_000)
  result.ok = true

proc cgi(cfg: ServerConfig; req: auto): string =
  let env = newStringTable(modeCaseSensitive)
  env["PATH"] = parentDir(cfg.gitBin)
  env["GIT_PROJECT_ROOT"] = cfg.root
  env["GIT_HTTP_EXPORT_ALL"] = "1"
  env["GIT_CONFIG_NOSYSTEM"] = "1"
  env["GIT_CONFIG_GLOBAL"] = "/dev/null"
  env["PATH_INFO"] = req.path
  env["QUERY_STRING"] = req.query
  env["REQUEST_METHOD"] = req.meth
  env["REMOTE_ADDR"] = "127.0.0.1"
  env["CONTENT_TYPE"] = req.headers.getOrDefault("content-type")
  env["CONTENT_LENGTH"] = $req.body.len
  if req.headers.hasKey("content-encoding"):
    env["HTTP_CONTENT_ENCODING"] = req.headers["content-encoding"]
  if req.headers.hasKey("git-protocol"):
    env["GIT_PROTOCOL"] = req.headers["git-protocol"]
  let p = startProcess(cfg.gitBin, args = ["http-backend"], env = env,
    options = {})
  p.inputStream.write(req.body)
  p.inputStream.close()
  let output = drainStream(p.outputStream)
  discard p.waitForExit()
  p.close()
  let sep = output.find("\r\n\r\n")
  let sep2 = output.find("\n\n")
  var headerEnd, bodyStart: int
  if sep >= 0 and (sep2 < 0 or sep < sep2):
    headerEnd = sep
    bodyStart = sep + 4
  elif sep2 >= 0:
    headerEnd = sep2
    bodyStart = sep2 + 2
  else:
    return "HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\n"
  var status = "200 OK"
  var headers = ""
  for line in output[0 ..< headerEnd].splitLines():
    if line.len == 0: continue
    if line.toLowerAscii().startsWith("status:"):
      status = line[7 .. ^1].strip()
    else:
      headers.add line & "\r\n"
  "HTTP/1.1 " & status & "\r\n" & headers & "Connection: close\r\n\r\n" &
    output[bodyStart .. ^1]

proc serve(cfg: ServerConfig) {.thread.} =
  {.cast(gcsafe).}:
    let ctx = newContext(verifyMode = CVerifyNone, certFile = cfg.cert,
      keyFile = cfg.key)
    let listener = newSocket(fd = SocketHandle(cfg.listenFd))
    var stalled: seq[Socket]
    while true:
      var client: Socket
      try:
        listener.accept(client)
      except CatchableError:
        return
      try:
        ctx.wrapConnectedSocket(client, handshakeAsServer)
        let req = readRequest(client)
        if not req.ok:
          client.close()
          continue
        cfg.logLine(req.meth & " " & req.path & "?" & req.query &
          " host=" & req.headers.getOrDefault("host"))
        var handled = false
        for r in cfg.routes:
          if req.path.startsWith(r.prefix) and r.serveDir.len > 0:
            handled = true
            let rel = req.path[r.prefix.len .. ^1]
            let file = r.serveDir / rel
            if ".." in rel.split('/') or not fileExists(file):
              client.send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n" &
                "Connection: close\r\n\r\n")
            else:
              let body = readFile(file)
              client.send("HTTP/1.1 200 OK\r\nContent-Length: " & $body.len &
                "\r\nConnection: close\r\n\r\n" &
                (if req.meth == "HEAD": "" else: body))
            client.close()
            break
          let archiveParts =
            if r.forgeArchives and req.path.startsWith(r.prefix):
              req.path[r.prefix.len .. ^1].split('/')
            else: @[]
          if archiveParts.len == 4 and archiveParts[2] == "archive" and
              archiveParts[3].endsWith(".tar.gz"):
            handled = true
            let parts = archiveParts
            var answer = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n" &
              "Connection: close\r\n\r\n"
            block:
              let commit = parts[3][0 ..< parts[3].len - ".tar.gz".len]
              let repo = cfg.root / parts[0] / parts[1] & ".git"
              if dirExists(repo):
                let p = startProcess(cfg.gitBin, args = ["--git-dir=" & repo,
                  "archive", "--format=tar.gz", "--prefix=" & parts[1] & "-" &
                  commit & "/", commit], options = {})
                let body = drainStream(p.outputStream)
                let code = p.waitForExit()
                p.close()
                if code == 0:
                  answer = "HTTP/1.1 200 OK\r\nContent-Length: " & $body.len &
                    "\r\nConnection: close\r\n\r\n" & body
            client.send(answer)
            client.close()
            break
          if r.forgeArchives or r.serveDir.len > 0:
            continue
          if req.path.startsWith(r.prefix):
            if r.failFetchWhile.len > 0:
              let asksObjects = req.meth == "POST" and
                ("command=fetch" in req.body or
                 ("command=" notin req.body and "want " in req.body))
              if fileExists(r.failFetchWhile) and asksObjects:
                handled = true
                client.send("HTTP/1.1 503 Service Unavailable\r\n" &
                  "Content-Length: 0\r\nConnection: close\r\n\r\n")
                client.close()
              break
            handled = true
            if r.stall:
              client.send("HTTP/1.1 200 OK\r\nContent-Type: " &
                "application/x-git-upload-pack-advertisement\r\n\r\n")
              stalled.add client
            else:
              client.send("HTTP/1.1 302 Found\r\nLocation: " & r.redirectTo &
                "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
              client.close()
            break
        if not handled:
          client.send(cfg.cgi(req))
          client.close()
      except CatchableError as e:
        cfg.logLine("error " & e.msg)
        try: client.close() except CatchableError: discard

proc mintCertificate(dir: string): tuple[cert, key: string] =
  result = (dir / "cert.pem", dir / "key.pem")
  var san: seq[string]
  for h in CertHosts: san.add "DNS:" & h
  discard run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
    "ec_paramgen_curve:prime256v1", "-nodes", "-keyout", result.key, "-out",
    result.cert, "-days", "2", "-subj", "/CN=forge.test", "-addext",
    "subjectAltName=" & san.join(","), "-addext",
    "basicConstraints=critical,CA:TRUE"])

proc newFixture*(prefix: string; routes: seq[Route] = @[]): Fixture =
  ## A fresh fixture with its HTTPS server running.
  result.dir = createTempDir("npc-m4-" & prefix & "-", "")
  result.root = result.dir / "srv"
  createDir(result.root)
  (result.cert, result.key) = mintCertificate(result.dir)
  result.gitBin = findExe("git")
  result.logPath = result.dir / "requests.log"
  writeFile(result.logPath, "")
  result.listener = newSocket()
  result.listener.setSockOpt(OptReuseAddr, true)
  result.listener.bindAddr(Port(0), "127.0.0.1")
  result.listener.listen()
  result.port = int(result.listener.getLocalAddr()[1])
  var rs = routes
  for r in rs.mitems:
    r.redirectTo = r.redirectTo.replace("{port}", $result.port)
  createThread(result.thread, serve, ServerConfig(root: result.root,
    cert: result.cert, key: result.key, gitBin: result.gitBin, routes: rs,
    listenFd: int(result.listener.getFd()), logPath: result.logPath))

proc requests*(f: Fixture): seq[string] =
  for l in readFile(f.logPath).splitLines():
    if l.len > 0: result.add l

proc url*(f: Fixture; path: string; host = ForgeHost): string =
  "https://" & host & ":" & $f.port & "/" & path

proc testResolver*(extra: seq[(string, string)] = @[]): Resolver =
  var table = initTable[string, string]()
  table[ForgeHost] = ForgeAddress
  table["internal.test"] = "127.0.0.1"
  table["private.test"] = "10.20.30.40"
  table["linklocal.test"] = "169.254.10.20"
  table["metadata.test"] = "169.254.169.254"
  for (h, a) in extra: table[h] = a
  result = proc(host: string): seq[IpAddress] {.gcsafe.} =
    {.cast(gcsafe).}:
      if host in table: result = @[parseIpAddress(table[host])]

proc testDialer*(): Dialer =
  result = proc(address: IpAddress): IpAddress {.gcsafe.} =
    if $address == ForgeAddress: parseIpAddress("127.0.0.1") else: address

proc testPolicy*(f: Fixture; limits = DefaultLimits): EgressPolicy =
  EgressPolicy(limits: limits, resolver: testResolver(), dialer: testDialer(),
    caFile: f.cert)

# ---------------------------------------------------------------------------
# Repositories
# ---------------------------------------------------------------------------

type
  FileSpec* = object
    path*, content*: string
    link*: bool        ## a symbolic link whose target is ``content``
    gitlink*: string   ## a gitlink to this commit (``content`` unused)

proc file*(path, content: string): FileSpec = FileSpec(path: path, content: content)
proc symlink*(path, target: string): FileSpec =
  FileSpec(path: path, content: target, link: true)
proc gitlinkTo*(path, commit: string): FileSpec =
  FileSpec(path: path, gitlink: commit)

proc nimbleFile*(name: string; requires: seq[string] = @[];
                 extra = ""): FileSpec =
  var body = "# " & name & "\nversion = \"0.0.0\"\nauthor = \"x\"\n" &
    "description = \"x\"\nlicense = \"MIT\"\nsrcDir = \"src\"\n"
  for r in requires: body.add "requires " & r.escape() & "\n"
  body.add extra
  file(name & ".nimble", body)

proc newRepo*(f: Fixture; path: string): string =
  ## A bare served repository at ``<root>/<path>`` and its work tree; returns
  ## the work tree.
  let bare = f.root / path
  createDir(parentDir(bare))
  discard run(["git", "init", "-q", "--bare", "-b", "main", bare],
    env = gitEnv())
  discard git(bare, "config", "uploadpack.allowFilter", "true")
  discard git(bare, "config", "uploadpack.allowAnySHA1InWant", "true")
  result = f.dir / "work" / path
  createDir(parentDir(result))
  discard run(["git", "init", "-q", "-b", "main", result], env = gitEnv())
  discard git(result, "remote", "add", "origin", bare)

proc commit*(work: string; files: seq[FileSpec]; message = "commit";
             date = 1_700_000_000'i64; replace = true): string =
  ## Replace the work tree's content with ``files`` and commit; returns the
  ## commit id.
  if replace:
    for kind, p in walkDir(work):
      if extractFilename(p) != ".git":
        if kind == pcDir: removeDir(p) else: removeFile(p)
  discard git(work, "rm", "-r", "-q", "--cached", "--ignore-unmatch", ".")
  for s in files:
    if s.gitlink.len > 0:
      discard git(work, "update-index", "--add", "--cacheinfo",
        "160000," & s.gitlink & "," & s.path)
      continue
    let full = work / s.path
    createDir(parentDir(full))
    if s.link:
      createSymlink(s.content, full)
    else:
      writeFile(full, s.content)
    discard git(work, "add", "-f", "--", s.path)
  discard gitAt(date, work, "commit", "-q", "--allow-empty", "-m", message)
  git(work, "rev-parse", "HEAD")

proc tag*(work, name: string; at = "HEAD"; date = 1_700_000_000'i64) =
  discard gitAt(date, work, "tag", "-f", name, at)

proc annotatedTag*(work, name: string; at = "HEAD") =
  discard git(work, "tag", "-f", "-a", "-m", name, name, at)

proc publish*(work: string) =
  ## Push every branch and tag to the served repository, rewriting both.
  discard git(work, "push", "-q", "--force", "--prune", "origin",
    "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*")

proc deleteServed*(f: Fixture; path: string) =
  removeDir(f.root / path)

proc packagesJson*(entries: seq[(string, string)];
                   aliases: seq[(string, string)] = @[]): FileSpec =
  ## A `packages.json` naming ``entries`` (name, url).
  var items: seq[string]
  for (n, u) in entries:
    items.add "  {\"name\": " & n.escape() & ", \"url\": " & u.escape() &
      ", \"method\": \"git\", \"tags\": [], \"description\": \"x\", " &
      "\"license\": \"MIT\"}"
  for (a, t) in aliases:
    items.add "  {\"name\": " & a.escape() & ", \"alias\": " & t.escape() & "}"
  file("packages.json", "[\n" & items.join(",\n") & "\n]\n")

var fixtureMirror = ""

proc defaultFixtureMirror*(): string =
  ## A directory mirror for source sets that name none: publishing needs at
  ## least one required mirror (NPC-AREQ13). One per test process, removed
  ## when it exits.
  if fixtureMirror.len == 0:
    fixtureMirror = createTempDir("npc-fixture-mirror-", "")
    addExitProc(proc () =
      try: removeDir(fixtureMirror) except CatchableError: discard)
  fixtureMirror

proc sourceSetText*(registryUrl, registryCommit: string; extra = "";
                    mirror = ""): string =
  ## A source set over one registry, with ``extra`` appended, publishing to
  ## the directory ``mirror`` (default: `defaultFixtureMirror`).
  let m = if mirror.len > 0: mirror else: defaultFixtureMirror()
  "schema = \"reprobuild.nimble-source-set.v1\"\n\n[[registry]]\nremote = " &
    registryUrl.escape() & "\ncommit = " & registryCommit.escape() & "\n" &
    "\n[[mirror]]\nurl = " & m.escape() & "\n" & extra

proc genConfig*(f: Fixture; ss: SourceSet; generatedAt: uint64;
                stateDir: string; previous = ""; outputDir = "";
                limits = DefaultLimits): GeneratorConfig =
  GeneratorConfig(sourceSet: ss, generatedAt: generatedAt,
    previousIndex: previous, stateDir: stateDir, outputDir: outputDir,
    policy: testPolicy(f, limits), gitBin: f.gitBin, shardBits: -1)

proc randomBytes*(n: int; seed: int): string =
  var r = initRand(seed)
  result = newString(n)
  for i in 0 ..< n: result[i] = char(r.rand(255))

proc envelopeOf*(b: BuiltIndex; name: string): PackageEnvelope =
  var idx = openIndex(memorySource(b.objectTable()), b.rootId)
  let l = idx.lookupPackage(name)
  doAssert l.found, name & " is not in the index"
  l.package

proc hasPackage*(b: BuiltIndex; name: string): bool =
  var idx = openIndex(memorySource(b.objectTable()), b.rootId)
  idx.lookupPackage(name).found

proc observationOf*(b: BuiltIndex; name: string): PackageObservation =
  var idx = openIndex(memorySource(b.objectTable()), b.rootId)
  for r in idx.root.shards:
    let s = idx.loadShard(r.bucket)
    for o in s.get.observations:
      if nameKey(o.name) == nameKey(name): return o
  doAssert false, "no observation of " & name

proc recordBytes*(r: VersionRecord): seq[byte] =
  ## One record encoded alone: what "byte-identical" compares.
  encodeShard(NimbleShard(packages: @[PackageEnvelope(name: "x",
    origins: @[PackageOrigin(url: "https://x.invalid/"),
      PackageOrigin(url: "https://y.invalid/"),
      PackageOrigin(url: "https://z.invalid/")],
    versions: @[r])]))

proc nowSeconds*(): uint64 = uint64(epochTime())
