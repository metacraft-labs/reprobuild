## Shared fixtures for the Distributed-Execution M7 tests: per-node host CAs
## laid out exactly where `parsePeerCache("lan://…?tls=1")` looks for them,
## trust and grants between nodes, and the evidence sink run as a SEPARATE
## PROCESS (`build/bin/repro-evidence-sink`) — the closest a single-host test
## gets to "off-host": the sink's store is written by another process that
## the workers can only reach through its append-only wire vocabulary.
##
## Not a test file (no `t_` prefix); imported by the M7 tests.
##
## MOCK POLICY — none: real host CAs and leaves (`identity.nim`), real TLS,
## the real sink binary, real on-disk stores.

import std/[os, osproc, strtabs, strutils, times]

import repro_peer_cache

type
  TestNode* = object
    name*: string
    root*: string
    xdgState*: string
      ## `XDG_STATE_HOME` for this node: `parsePeerCache` derives the TLS
      ## directory from it.
    tlsDir*: string
    certPath*: string
    keyPath*: string
    anchorsDir*: string
    identity*: HostIdentity

  SinkProcess* = object
    dir*: string
    identityDir*: string
    anchorsDir*: string
    keyDir*: string
      ## The checkpoint key's directory — separate from the store (G28).
    revokedPath*: string
    endpoint*: string
    hostId*: PeerId
    certPath*: string
    logPath*: string
    port*: int
      ## Fixed after the first start, so a restarted sink keeps its endpoint.
    process*: Process

  SignerProcess* = object
    ## The certificate signer (`repro cert-signer serve`), its own process
    ## — the off-worker holder of the workers' signing CAs (D5).
    stateDir*: string
    identityDir*: string
    anchorsDir*: string
    authorizedPath*: string
    revokedPath*: string
    endpoint*: string
    hostId*: PeerId
    certPath*: string
    process*: Process

proc repoRootDir*(): string =
  ## The reprobuild checkout (the directory holding `repro_tests.nim`).
  var dir = getCurrentDir()
  while dir.len > 1:
    if fileExists(dir / "repro_tests.nim"):
      return dir
    dir = dir.parentDir
  getCurrentDir()

proc m7TestBase*(name: string): string =
  ## A fresh per-test base directory. On Linux it is directly under `/tmp`:
  ## the lease floor runs goals as a subordinate uid that must be able to
  ## search every ancestor of its lease, and the dev shell's `TMPDIR` is
  ## owner-only. Elsewhere the ordinary temp directory.
  when defined(linux):
    result = "/tmp" / (name & "-" & $getCurrentProcessId())
  else:
    result = normalizedPath(absolutePath(getTempDir() / (name & "-" &
      $getCurrentProcessId())))
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc evidenceSinkBin*(): string =
  repoRootDir() / "build" / "bin" / addFileExt("repro-evidence-sink", ExeExt)

proc engineBin*(): string =
  repoRootDir() / "build" / "bin" / addFileExt("reprobuild", ExeExt)

proc newTestNode*(base, name: string): TestNode =
  ## A node with a freshly minted host CA under
  ## `<base>/<name>/xdg/repro-peer-cache/tls/`.
  result.name = name
  result.root = base / name
  result.xdgState = result.root / "xdg"
  result.tlsDir = result.xdgState / "repro-peer-cache" / "tls"
  result.certPath = result.tlsDir / "host-ca.crt"
  result.keyPath = result.tlsDir / "host-ca.key"
  result.anchorsDir = result.tlsDir / "anchors"
  createDir(result.anchorsDir)
  result.identity = loadOrCreateHostIdentity(result.certPath, result.keyPath)

proc trusts*(a: TestNode; b: TestNode) =
  ## `a` pins `b`'s host CA.
  copyFile(b.certPath, a.anchorsDir / (b.name & ".crt"))

proc mutualTrust*(nodes: openArray[TestNode]) =
  for a in nodes:
    for b in nodes:
      if a.name != b.name:
        a.trusts(b)

proc grantRoles*(a: TestNode; b: TestNode; roles: string) =
  ## `a` grants host `b` the boundary roles `roles` (`cache-peer,…`).
  let path = a.tlsDir / "grants"
  var text = if fileExists(path): readFile(path) else: ""
  text.add($b.identity.hostId & " " & roles & "\n")
  writeFile(path, text)

proc tlsConfig*(n: TestNode; seeds: seq[Endpoint] = @[]; evidence = "";
                heartbeatMs = 0; bindSpec = "";
                cidr = "127.0.0.0/8";
                profile = tpHardened): PeerCacheConfig =
  ## What `parsePeerCache("lan://127.0.0.0/8?tls=1&…")` produces for `n`.
  ## `profile`: the M7 tests of hardened-profile controls (one-hour leaves,
  ## the evidence sink, the certificate signer) run hardened, which is this
  ## helper's default; a test of the trusted profile (the product default)
  ## passes `tpTrusted` explicitly.
  PeerCacheConfig(
    discoveryMode: pdmUnicastSeed,
    seedPeers: seeds,
    cidrAllowlistRaw: @[cidr],
    advertiseIntervalMs: 200,
    maxBlobBytes: DefaultMaxBlobBytes,
    listenPort: 0,
    multicastDisabled: true,
    trustMode: tmTls,
    tlsCertPath: n.certPath,
    tlsKeyPath: n.keyPath,
    tlsTrustAnchorsPath: n.anchorsDir,
    bindSpec: bindSpec,
    evidenceSinkSpec: evidence,
    heartbeatIntervalMs: heartbeatMs,
    trustProfile: profile)

proc prepareEvidenceSink*(base: string): SinkProcess =
  ## The sink's directories and host CA (minted now, so workers can pin it
  ## before the sink starts).
  result.dir = base / "sink" / "store"
  result.identityDir = base / "sink" / "identity"
  result.anchorsDir = base / "sink" / "anchors"
  result.keyDir = base / "sink" / "checkpoint-key"
  result.revokedPath = base / "sink" / "revoked"
  result.logPath = base / "sink" / "sink.log"
  createDir(result.dir)
  createDir(result.anchorsDir)
  let identity = loadOrCreateHostIdentity(result.identityDir / "host-ca.crt",
    result.identityDir / "host-ca.key")
  result.hostId = identity.hostId
  result.certPath = result.identityDir / "host-ca.crt"

proc acceptsFrom*(sink: SinkProcess; node: TestNode) =
  ## The sink accepts appends from `node`, and `node`'s appender pins the
  ## sink: its CA goes to `<tls dir>/evidence-sink.crt`, OUTSIDE the peer
  ## anchors (the sink is not a cache peer, and no peer can pose as the
  ## sink — G28).
  copyFile(node.certPath, sink.anchorsDir / (node.name & ".crt"))
  copyFile(sink.certPath, node.tlsDir / "evidence-sink.crt")

proc sinkAnchors*(sink: SinkProcess): TrustAnchorSet =
  ## The sink's CA alone: what an appender pins.
  loadTrustAnchorFile(sink.certPath)

proc sinkCheckpointKey*(sink: SinkProcess): PublicKeyBytes =
  ## The checkpoint key, from the certificate the operator pinned out of
  ## band (here: the key directory's own copy, never the store).
  checkpointPublicKeyFromCert(sinkCheckpointCertPath(sink.keyDir))

proc startEvidenceSink*(sink: var SinkProcess; retentionSeconds = 0;
                        segmentMaxEntries = 0) =
  let bin = evidenceSinkBin()
  if not fileExists(bin):
    raise newException(IOError, "the evidence sink binary is not built: " &
      bin & " (run `just build`)")
  let ready = sink.dir.parentDir / "sink.ready"
  try: removeFile(ready) except OSError: discard
  var args = @["serve", "--dir=" & sink.dir,
    "--identity=" & sink.identityDir, "--anchors=" & sink.anchorsDir,
    "--checkpoint-key=" & sink.keyDir, "--revoked=" & sink.revokedPath,
    "--bind=127.0.0.1", "--port=" & $sink.port, "--ready-file=" & ready]
  if retentionSeconds > 0:
    args.add("--retention-seconds=" & $retentionSeconds)
  if segmentMaxEntries > 0:
    args.add("--segment-max-entries=" & $segmentMaxEntries)
  let logFile = sink.logPath
  sink.process = startProcess(bin, args = args,
    options = {poStdErrToStdOut, poParentStreams})
  let deadline = epochTime() + 30.0
  while epochTime() < deadline:
    if fileExists(ready):
      sink.endpoint = readFile(ready).splitLines()[0].strip()
      sink.port = parseInt(sink.endpoint[sink.endpoint.rfind(':') + 1 .. ^1])
      return
    if not sink.process.running:
      break
    sleep(50)
  raise newException(IOError, "the evidence sink did not start: " &
    (if fileExists(logFile): readFile(logFile) else: "<no log>"))

proc stopEvidenceSink*(sink: var SinkProcess) =
  if sink.process.isNil:
    return
  if sink.process.running:
    sink.process.terminate()
  discard sink.process.waitForExit()
  sink.process.close()
  sink.process = nil

proc sinkEntries*(sink: SinkProcess): seq[EvidenceEntry] =
  ## Reading is LOCAL to the sink's store (EVID-3) — the test reads the
  ## directory the way an investigator on the sink host would.
  try: readEvidenceStore(sink.dir) except CatchableError: @[]

proc detections*(sink: SinkProcess; trigger: string): seq[EvidenceEntry] =
  for e in sink.sinkEntries():
    if e.kind == ekRecord and e.record.category == ecDetection and
        e.record.trigger == trigger:
      result.add(e)

proc waitForDetection*(sink: SinkProcess; trigger: string;
                       timeoutMs = 10_000;
                       pump: proc() {.closure.} = nil): seq[EvidenceEntry] =
  ## Waits until the sink holds at least one `trigger` detection.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    result = sink.detections(trigger)
    if result.len > 0:
      return
    if not pump.isNil: pump()
    else: sleep(50)

# ---------------------------------------------------------------------------
# The certificate signer (Distributed-Execution M7, D5).
# ---------------------------------------------------------------------------

proc prepareSigner*(base: string): SignerProcess =
  result.stateDir = base / "signer" / "state"
  result.identityDir = base / "signer" / "identity"
  result.anchorsDir = base / "signer" / "anchors"
  result.authorizedPath = base / "signer" / "authorized"
  result.revokedPath = base / "signer" / "revoked"
  createDir(result.anchorsDir)
  writeFile(result.authorizedPath, "")
  let identity = loadOrCreateHostIdentity(result.identityDir / "host-ca.crt",
    result.identityDir / "host-ca.key")
  result.hostId = identity.hostId
  result.certPath = result.identityDir / "host-ca.crt"

proc servesWorker*(signer: SignerProcess; node: TestNode) =
  ## The signer knows `node`'s host CA and authorizes it; `node` pins the
  ## signer at `<tls dir>/cert-signer.crt`.
  copyFile(node.certPath, signer.anchorsDir / (node.name & ".crt"))
  copyFile(signer.certPath, node.tlsDir / "cert-signer.crt")
  let text = readFile(signer.authorizedPath)
  writeFile(signer.authorizedPath, text & $node.identity.hostId & "\n")

proc deauthorize*(signer: SignerProcess; node: TestNode) =
  var keep: seq[string] = @[]
  for line in readFile(signer.authorizedPath).splitLines:
    if line.strip().len > 0 and line.strip() != $node.identity.hostId:
      keep.add(line)
  writeFile(signer.authorizedPath, keep.join("\n") & (if keep.len > 0: "\n" else: ""))

proc startSigner*(signer: var SignerProcess) =
  let bin = engineBin()
  if not fileExists(bin):
    raise newException(IOError, "the engine binary is not built: " & bin)
  let ready = signer.stateDir.parentDir / "signer.ready"
  try: removeFile(ready) except OSError: discard
  signer.process = startProcess(bin, args = @["cert-signer", "serve",
    "--state=" & signer.stateDir, "--identity=" & signer.identityDir,
    "--anchors=" & signer.anchorsDir, "--authorized=" & signer.authorizedPath,
    "--revoked=" & signer.revokedPath, "--bind=127.0.0.1", "--port=0",
    "--ready-file=" & ready], options = {poStdErrToStdOut, poParentStreams})
  let deadline = epochTime() + 30.0
  while epochTime() < deadline:
    if fileExists(ready):
      signer.endpoint = readFile(ready).splitLines()[0].strip()
      return
    if not signer.process.running:
      break
    sleep(50)
  raise newException(IOError, "the certificate signer did not start")

proc stopSigner*(signer: var SignerProcess) =
  if signer.process.isNil:
    return
  if signer.process.running:
    signer.process.terminate()
  discard signer.process.waitForExit()
  signer.process.close()
  signer.process = nil

proc registrationOf*(signer: SignerProcess; node: TestNode):
    tuple[keyId, publicKey: string] =
  ## The registered-keys entry a caller adds to accept `node`'s
  ## certificates (`repro cert-signer registration`).
  let res = execCmdEx(quoteShellCommand([engineBin(), "cert-signer",
    "registration", "--state=" & signer.stateDir,
    "--worker=" & $node.identity.hostId]))
  if res.exitCode != 0:
    raise newException(IOError, "cert-signer registration failed: " & res.output)
  for line in res.output.splitLines:
    let l = line.strip()
    if l.startsWith("key_id = "):
      result.keyId = l["key_id = ".len .. ^1].strip(chars = {'"'})
    elif l.startsWith("public_key = "):
      result.publicKey = l["public_key = ".len .. ^1].strip(chars = {'"'})

proc sinkReceipts*(path: string): seq[SinkReceipt] =
  ## The receipts an appender stored (`<state>/evidence-receipt`).
  if fileExists(path):
    for line in readFile(path).splitLines:
      if line.strip().len > 0:
        result.add(decodeReceipt(line))
