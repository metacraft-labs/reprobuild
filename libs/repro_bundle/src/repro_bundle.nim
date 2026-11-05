## Workspace bundles (reprobuild-pm Workspace-Bundles.md): create, publish
## and restore a bundle of a workspace selection's Nix dev-shell closure, its
## source checkouts and its native store, so a fresh machine can work on it
## with no evaluation, build or clone.
##
## Layout under `<out>/<bundle>/` (§5):
##   <system>/latest.json            every half's manifest
##   <system>/restore.sh             the bootstrap for a machine without repro
##   <system>/nix/<id>/              part-NNNN, registration, nix.json
##   <system>/native-store/<id>/     part-NNNN, native-store.json
##   sources/<id>/                   part-NNNN, sources.json

import std/[json, os, posix, strutils, tempfiles, times]
import repro_core/ambient_execution
import repro_local_store/store_bundle
import repro_bundle/[exec, select, nix_half, sources_half, bootstrap]

export exec.BundleError, select.BundleMember, select.resolveMembers,
  nix_half.NixHalf, nix_half.NixHalfOptions,
  sources_half.SourcesHalf

type
  CreateOptions* = object
    workspaceRoot*: string
    selector*: string
    outDir*: string
    name*: string
    nix*: bool
    sources*: bool
    native*: bool
    nixOptions*: NixHalfOptions
    nativeRoots*: BundleRoots
      ## Store and action-cache roots plus any extra workspace roots; the
      ## workspace root itself is always added.
    devEnvs*: seq[FrozenDevEnv]
    level*: int
    partSize*: int64

  HalfReport* = object
    kind*: string
    id*: string
    dir*: string          ## relative to the bundle directory
    reused*: bool
    compressedBytes*: int64
    unpackedBytes*: int64

  CreateReport* = object
    bundleDir*: string
    system*: string
    latestPath*: string
    restoreScript*: string
    halves*: seq[HalfReport]
    members*: seq[BundleMember]
    unpackedBytes*: int64

  RestoreOptions* = object
    source*: string        ## bundle directory or URL, or a latest.json
    workspaceDir*: string  ## default: the workspace path recorded at create
    nixRoot*: string       ## "/" in production; another root in tests
    staging*: string       ## default: /dev/shm when it fits, else /var/tmp
    parallel*: int
    activate*: bool
    activationFile*: string
    afterBootstrap*: bool
    storeRoot*: string
    actionCacheRoot*: string
    importNative*: proc (partsDir: string): ImportReport
      ## Supplied by the CLI so the native half is imported with the roots
      ## and allow-file handling of `repro store import`.

  RestoreReport* = object
    restored*: seq[string]
    alreadyPresent*: seq[string]
    workspaceDir*: string
    primaryEnv*: string
    frozenDevEnv*: string
    activationFile*: string
    native*: ImportReport
    phaseSeconds*: seq[tuple[phase: string, seconds: float]]

const
  LatestName* = "latest.json"
  RestoreScriptName* = "restore.sh"
  NativeHalfDir* = "native-store"
  NativeManifestName* = "native-store.json"
  BundleSchema* = "reprobuild.workspace-bundle.v1"
  SpaceMarginBytes = 1'i64 shl 30

proc hostSystem*(): string =
  ## The Nix system string, from uname: no evaluation on the restoring side.
  var u: Utsname
  discard uname(u)
  let machine = $cast[cstring](addr u.machine[0])
  let sys = ($cast[cstring](addr u.sysname[0])).toLowerAscii()
  let arch = (if machine == "arm64": "aarch64" else: machine)
  arch & "-" & (if sys == "darwin": "darwin" else: sys)

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

proc createBundle*(opts: CreateOptions): CreateReport =
  let ws = normalizedPath(absolutePath(opts.workspaceRoot))
  let members = resolveMembers(ws, opts.selector)
  result.members = members
  let name = (if opts.name.len > 0: opts.name else: opts.selector)
  let bundleDir = normalizedPath(absolutePath(opts.outDir)) / name
  result.bundleDir = bundleDir
  result.system = hostSystem()
  let systemDir = bundleDir / result.system
  createDir(systemDir)
  var memberPaths = newJArray()
  for m in members:
    if m.checkedOut: memberPaths.add(%m.relPath)
  var latest = newJObject()
  latest["schema"] = %BundleSchema
  latest["name"] = %name
  latest["selector"] = %opts.selector
  latest["system"] = %result.system
  latest["workspace_dir"] = %ws
  latest["members"] = memberPaths
  latest["created"] = %now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
  var halves = newJObject()
  var nixHalf: NixHalf
  var hasNix = false
  if opts.nix:
    var no = opts.nixOptions
    if no.level == 0: no.level = opts.level
    if no.partSize == 0: no.partSize = opts.partSize
    let (h, reused) = createNixHalf(members, systemDir, no)
    nixHalf = h
    hasNix = true
    result.halves.add(HalfReport(kind: "nix", id: h.id,
      dir: result.system / NixHalfDir / h.id, reused: reused,
      compressedBytes: h.compressedBytes, unpackedBytes: h.unpackedBytes))
    var node = h.toJson
    node["dir"] = %(result.system / NixHalfDir / h.id)
    halves["nix"] = node
  if opts.sources:
    let (h, reused) = createSourcesHalf(ws, members, bundleDir, opts.level,
      opts.partSize)
    result.halves.add(HalfReport(kind: "sources", id: h.id,
      dir: SourcesHalfDir / h.id, reused: reused,
      compressedBytes: h.compressedBytes, unpackedBytes: h.unpackedBytes))
    var node = h.toJson
    node["dir"] = %(SourcesHalfDir / h.id)
    halves["sources"] = node
  if opts.native:
    var roots = opts.nativeRoots
    if ws notin roots.workspaceRoots:
      roots.workspaceRoots.insert(ws, 0)
    let closure = computeClosure(roots, opts.devEnvs)
    let id = bundleIdOf(closure)
    let rel = result.system / NativeHalfDir / id
    let dir = bundleDir / rel
    var reused = fileExists(dir / NativeManifestName)
    if not reused:
      let partial = dir & ".partial"
      removeDir(partial)
      var eo = defaultExportOptions(partial)
      if opts.level > 0: eo.zstdLevel = opts.level
      if opts.partSize > 0: eo.partSize = opts.partSize
      discard exportBundle(closure, eo)
      removeDir(dir)
      moveDir(partial, dir)
    var node = parseJson(readFile(dir / NativeManifestName))
    result.halves.add(HalfReport(kind: "native-store", id: id, dir: rel,
      reused: reused, compressedBytes: node{"compressedBytes"}.getBiggestInt(),
      unpackedBytes: node{"unpackedBytes"}.getBiggestInt()))
    node["dir"] = %rel
    halves["native_store"] = node
  if halves.len == 0:
    bundleFail("nothing to bundle: every half was turned off")
  latest["halves"] = halves
  for h in result.halves: result.unpackedBytes += h.unpackedBytes
  latest["unpacked_bytes"] = %result.unpackedBytes
  # The bootstrap is written last: it is what a session fetches first, and
  # it names only halves that are complete.
  result.latestPath = systemDir / LatestName
  writeFile(result.latestPath & ".partial", pretty(latest) & "\n")
  moveFile(result.latestPath & ".partial", result.latestPath)
  result.restoreScript = systemDir / RestoreScriptName
  writeFile(result.restoreScript & ".partial",
    renderRestoreScript(latest, hasNix, nixHalf))
  setFilePermissions(result.restoreScript & ".partial",
    {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
     fpOthersRead, fpOthersExec})
  moveFile(result.restoreScript & ".partial", result.restoreScript)

# ---------------------------------------------------------------------------
# restore
# ---------------------------------------------------------------------------

proc isUrl(s: string): bool =
  s.startsWith("https://") or s.startsWith("http://") or s.startsWith("file://")

proc freeBytes*(path: string): int64 =
  ## Free space on the filesystem holding `path` (or its nearest existing
  ## ancestor).
  var p = normalizedPath(absolutePath(path))
  while p.len > 1 and not dirExists(p): p = p.parentDir
  var st: Statvfs
  if statvfs(p.cstring, st) != 0:
    return high(int64)
  int64(st.f_bavail) * int64(st.f_frsize)

proc download(urls: seq[tuple[url, dest: string]]; parallel: int) =
  ## Parallel `curl` transfers. curl honours HTTPS_PROXY and the system CA
  ## bundle (SSL_CERT_FILE), which the session needs.
  if urls.len == 0: return
  var cfg = ""
  for (url, dest) in urls:
    cfg.add("url = \"" & url & "\"\noutput = \"" & dest & "\"\n")
  discard mustRun(requireExe("curl"), ["-fsS", "--retry", "3", "--parallel",
    "--parallel-max", $max(1, parallel), "-K", "-"], stdinData = cfg)

proc fetchHalf(base, staging: string; node: JsonNode; parts: seq[BundlePart];
               extra: seq[string]; parallel: int): string =
  ## A directory holding the half's parts: the half itself for a local
  ## bundle, otherwise a staging directory the parts were downloaded into.
  let rel = node["dir"].getStr()
  if not isUrl(base):
    return base / rel
  result = staging / extractFilename(rel)
  createDir(result)
  var urls: seq[tuple[url, dest: string]]
  for p in parts:
    urls.add((base & "/" & rel & "/" & p.file, result / p.file))
  for f in extra:
    urls.add((base & "/" & rel & "/" & f, result / f))
  download(urls, parallel)

proc readLatest(source, system: string; staging: string):
    tuple[base: string; latest: JsonNode] =
  var base = source.strip(chars = {'/'}, leading = false)
  var latestRef = base / system / LatestName
  if base.endsWith(".json"):
    latestRef = base
    base = base.parentDir.parentDir
  if base.startsWith("file://"):
    base = base["file://".len .. ^1]
    latestRef = latestRef["file://".len .. ^1]
  var text = ""
  if isUrl(base):
    let dest = staging / LatestName
    download(@[(base & "/" & system & "/" & LatestName, dest)], 1)
    text = readFile(dest)
  else:
    if not fileExists(latestRef):
      bundleFail("no bundle at " & latestRef)
    text = readFile(latestRef)
  let node = parseJson(text)
  if node{"schema"}.getStr() != BundleSchema:
    bundleFail("unsupported bundle schema " & node{"schema"}.getStr())
  (base, node)

proc chooseStaging(explicit: string; compressed: int64): string =
  if explicit.len > 0:
    createDir(explicit)
    return explicit
  if dirExists("/dev/shm") and compressed * 2 < freeBytes("/dev/shm"):
    return createTempDir("repro-bundle-", "", "/dev/shm")
  createTempDir("repro-bundle-", "", (if dirExists("/var/tmp"): "/var/tmp"
                                      else: getTempDir()))

proc ensureZstdOnPath(h: NixHalf) =
  ## The base image has no zstd; the Nix half carries one.
  if uncontrolledFindExe("zstd").len == 0 and
      fileExists(h.zstd / "bin" / "zstd"):
    putEnv("PATH", h.zstd / "bin" & ":" & getEnv("PATH"))

proc restoreBundle*(opts: RestoreOptions): RestoreReport =
  var phaseStart = epochTime()
  template phase(name: string) =
    let now = epochTime()
    result.phaseSeconds.add((name, now - phaseStart))
    phaseStart = now
  let system = hostSystem()
  let probeDir = createTempDir("repro-bundle-latest-", "")
  defer: removeDir(probeDir)
  let (base, latest) = readLatest(opts.source, system, probeDir)
  let halves = latest["halves"]
  let ws = (if opts.workspaceDir.len > 0:
              normalizedPath(absolutePath(opts.workspaceDir))
            else: latest["workspace_dir"].getStr())
  result.workspaceDir = ws
  if halves.hasKey("native_store") and ws != latest["workspace_dir"].getStr():
    bundleFail("this bundle has a native-store half, which only restores at " &
      "the workspace path it was made at (" & latest["workspace_dir"].getStr() &
      "), not " & ws)
  let nixRoot = (if opts.nixRoot.len > 0: opts.nixRoot else: "/")
  # What is still to do, and its size.
  var nixHalf: NixHalf
  var needNix, needSources = false
  var sourcesHalf: SourcesHalf
  if halves.hasKey("nix"):
    nixHalf = parseNixHalf(halves["nix"])
    needNix = not opts.afterBootstrap and not nixHalf.nixHalfPresent(nixRoot)
    if not needNix: result.alreadyPresent.add("nix")
  if halves.hasKey("sources"):
    sourcesHalf = parseSourcesHalf(halves["sources"])
    needSources = not sourcesHalf.sourcesPresent(ws)
    if not needSources: result.alreadyPresent.add("sources")
  let needNative = halves.hasKey("native_store")
  var nixBytes, wsBytes, compressed = 0'i64
  if needNix:
    nixBytes += nixHalf.unpackedBytes
    compressed += nixHalf.compressedBytes
  if needSources:
    wsBytes += sourcesHalf.unpackedBytes
    compressed += sourcesHalf.compressedBytes
  if needNative:
    wsBytes += halves["native_store"]{"unpackedBytes"}.getBiggestInt()
    compressed += halves["native_store"]{"compressedBytes"}.getBiggestInt()
  # §7 step 1, before anything is written.
  let nixTarget = (if nixRoot == "/": "/nix" else: nixRoot)
  if needNix and freeBytes(nixTarget) < nixBytes + SpaceMarginBytes:
    bundleFail("not enough disk for the Nix half: it unpacks to " &
      $(nixBytes shr 20) & " MiB and " & nixTarget & " has " &
      $(freeBytes(nixTarget) shr 20) & " MiB free (1 GiB margin required)")
  if wsBytes > 0 and freeBytes(ws.parentDir) < wsBytes + SpaceMarginBytes:
    bundleFail("not enough disk for the workspace halves: they unpack to " &
      $(wsBytes shr 20) & " MiB and " & ws.parentDir & " has " &
      $(freeBytes(ws.parentDir) shr 20) & " MiB free (1 GiB margin required)")
  phase("plan")
  let staging = (if isUrl(base): chooseStaging(opts.staging, compressed)
                 else: "")
  defer:
    if staging.len > 0 and opts.staging.len == 0: removeDir(staging)
  let parallel = (if opts.parallel > 0: opts.parallel else: 16)
  if halves.hasKey("nix"):
    ensureZstdOnPath(nixHalf)
  if needNix:
    let dir = fetchHalf(base, staging, halves["nix"], nixHalf.parts,
      @[nixHalf.registration.file], parallel)
    phase("download nix")
    restoreNixHalf(nixHalf, dir, nixRoot)
    if isUrl(base): removeDir(dir)
    result.restored.add("nix")
    phase("restore nix")
  if needSources:
    let dir = fetchHalf(base, staging, halves["sources"], sourcesHalf.parts,
      @[], parallel)
    phase("download sources")
    restoreSourcesHalf(sourcesHalf, dir, ws)
    if isUrl(base): removeDir(dir)
    result.restored.add("sources")
    phase("restore sources")
  if needNative:
    if opts.importNative == nil:
      bundleFail("this bundle has a native-store half and no importer")
    let node = halves["native_store"]
    let dir = fetchHalf(base, staging, node, parsePartsJson(node["parts"]),
      @[NativeManifestName], parallel)
    phase("download native-store")
    result.native = opts.importNative(dir)
    if isUrl(base): removeDir(dir)
    if result.native.skippedExtraction: result.alreadyPresent.add("native-store")
    else: result.restored.add("native-store")
    phase("restore native-store")
  # §7 step 6.
  if halves.hasKey("nix"):
    for s in nixHalf.shells:
      if s.name == nixHalf.primary: result.primaryEnv = s.env
  for env in result.native.devEnvs:
    if result.frozenDevEnv.len == 0: result.frozenDevEnv = env.scriptPath
  if opts.activate:
    let file = (if opts.activationFile.len > 0: opts.activationFile
                else: "/etc/profile.d/zz-repro-bundle.sh")
    var text = "# Written by `repro bundle restore --activate`.\n"
    if result.primaryEnv.len > 0:
      text.add(". " & quoteShell(result.primaryEnv) & "\n")
    if result.frozenDevEnv.len > 0:
      text.add("[ -f " & quoteShell(result.frozenDevEnv) & " ] && . " &
        quoteShell(result.frozenDevEnv) & "\n")
    createDir(file.parentDir)
    writeFile(file, text)
    result.activationFile = file

# ---------------------------------------------------------------------------
# publish (§6)
# ---------------------------------------------------------------------------

type PublishOptions* = object
  bundleDir*: string     ## `<out>/<bundle>`
  target*: string        ## `s3://bucket/prefix`
  endpoint*: string      ## e.g. https://<account>.r2.cloudflarestorage.com
  region*: string
  parallel*: int

type PublishReport* = object
  uploaded*: seq[string]
  skipped*: seq[string]
  baseUrl*: string

proc s3Base(opts: PublishOptions): tuple[url, bucket, prefix: string] =
  if not opts.target.startsWith("s3://"):
    bundleFail("--to must be s3://BUCKET[/PREFIX], got " & opts.target)
  let rest = opts.target["s3://".len .. ^1].strip(chars = {'/'})
  let slash = rest.find('/')
  let bucket = (if slash < 0: rest else: rest[0 ..< slash])
  let prefix = (if slash < 0: "" else: rest[slash + 1 .. ^1])
  let region = (if opts.region.len > 0: opts.region else: "us-east-1")
  let endpoint = (if opts.endpoint.len > 0: opts.endpoint.strip(chars = {'/'})
                  else: "https://s3." & region & ".amazonaws.com")
  (endpoint & "/" & bucket & (if prefix.len > 0: "/" & prefix else: ""),
   bucket, prefix)

proc authConfig(opts: PublishOptions): string =
  ## curl's per-transfer signing options. `next` in a curl config resets
  ## them, so every transfer block carries its own copy. The credentials go
  ## into curl's config on stdin: never on a command line, never on disk.
  let ak = getEnv("AWS_ACCESS_KEY_ID")
  let sk = getEnv("AWS_SECRET_ACCESS_KEY")
  if ak.len == 0 or sk.len == 0:
    bundleFail("publishing needs AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY " &
      "in the environment")
  let region = (if opts.region.len > 0: opts.region else: "us-east-1")
  result = "user = \"" & ak & ":" & sk & "\"\n" &
    "aws-sigv4 = \"aws:amz:" & region & ":s3\"\n"
  let token = getEnv("AWS_SESSION_TOKEN")
  if token.len > 0:
    result.add("header = \"x-amz-security-token: " & token & "\"\n")

proc curlS3(opts: PublishOptions; blocks: seq[string];
            extraArgs: seq[string] = @[]): seq[tuple[code: int, url: string]] =
  ## Run one transfer per block (in parallel when there are several) and
  ## return each transfer's HTTP status, so a failed transfer cannot hide
  ## behind another's success.
  let auth = authConfig(opts)
  var cfg = ""
  for i, b in blocks:
    if i > 0: cfg.add("next\n")
    cfg.add(auth & b & "write-out = \"%{http_code} %{url}\\n\"\n")
  let r = runTool(requireExe("curl"), @["-sS", "--retry", "3"] & extraArgs &
    @["-K", "-"], stdinData = cfg)
  for line in r.output.splitLines():
    let sp = line.find(' ')
    if sp > 0:
      try: result.add((parseInt(line[0 ..< sp]), line[sp + 1 .. ^1]))
      except ValueError: discard
  if result.len != blocks.len:
    bundleFail("curl reported " & $result.len & " of " & $blocks.len &
      " transfers (exit " & $r.code & "): " & r.errors.strip())

proc remoteExists(opts: PublishOptions; url: string): bool =
  let r = curlS3(opts, @["url = \"" & url & "\"\nhead\noutput = \"/dev/null\"\n"])
  r[0].code in 200 .. 299

proc uploadFiles(opts: PublishOptions; files: seq[tuple[path, url: string]];
                 cacheControl, contentType: string) =
  if files.len == 0: return
  var blocks: seq[string]
  for (path, url) in files:
    blocks.add("upload-file = \"" & path & "\"\nurl = \"" & url & "\"\n" &
      "header = \"Cache-Control: " & cacheControl & "\"\n" &
      "header = \"Content-Type: " & contentType & "\"\n" &
      "output = \"/dev/null\"\n")
  let results = curlS3(opts, blocks, @["--parallel", "--parallel-max",
    $(if opts.parallel > 0: opts.parallel else: 16)])
  for (code, url) in results:
    if code notin 200 .. 299:
      bundleFail("upload of " & url & " failed: HTTP " & $code)

proc publishBundle*(opts: PublishOptions): PublishReport =
  ## Halves first, each manifest last within its half and skipped when the
  ## remote already has it; then each system's latest.json, then its
  ## restore.sh. A reader never sees a manifest naming missing parts.
  let dir = normalizedPath(absolutePath(opts.bundleDir))
  let (base, _, _) = s3Base(opts)
  let bundleUrl = base & "/" & extractFilename(dir)
  result.baseUrl = bundleUrl
  var halfDirs: seq[tuple[rel, manifest: string]]
  for kind, sysDir in walkDir(dir):
    if kind != pcDir: continue
    let sysName = extractFilename(sysDir)
    if sysName == SourcesHalfDir:
      for k, d in walkDir(sysDir):
        if k == pcDir and fileExists(d / SourcesManifestName):
          halfDirs.add((sysName / extractFilename(d), SourcesManifestName))
      continue
    for (sub, manifest) in [(NixHalfDir, NixManifestName),
                            (NativeHalfDir, NativeManifestName)]:
      if dirExists(sysDir / sub):
        for k, d in walkDir(sysDir / sub):
          if k == pcDir and fileExists(d / manifest):
            halfDirs.add((sysName / sub / extractFilename(d), manifest))
  for (rel, manifest) in halfDirs:
    let remote = bundleUrl & "/" & rel
    if remoteExists(opts, remote & "/" & manifest):
      result.skipped.add(rel)
      continue
    var files: seq[tuple[path, url: string]]
    for k, f in walkDir(dir / rel):
      let n = extractFilename(f)
      if k == pcFile and n != manifest and not n.startsWith("."):
        files.add((f, remote & "/" & n))
    let immutable = "public, max-age=31536000, immutable"
    uploadFiles(opts, files, immutable, "application/octet-stream")
    uploadFiles(opts, @[(dir / rel / manifest, remote & "/" & manifest)],
      immutable, "application/json")
    result.uploaded.add(rel)
  for kind, sysDir in walkDir(dir):
    if kind != pcDir or not fileExists(sysDir / LatestName): continue
    let sysRel = extractFilename(sysDir)
    uploadFiles(opts, @[(sysDir / LatestName,
      bundleUrl & "/" & sysRel & "/" & LatestName)], "no-cache",
      "application/json")
    if fileExists(sysDir / RestoreScriptName):
      uploadFiles(opts, @[(sysDir / RestoreScriptName,
        bundleUrl & "/" & sysRel & "/" & RestoreScriptName)], "no-cache",
        "text/x-shellscript")
