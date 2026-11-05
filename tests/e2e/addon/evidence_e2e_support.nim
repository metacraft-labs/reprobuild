## What the A11 gates share: an Evidence sink the gate itself creates on the
## build host (spec §12.1) -- reprobuild's own ``repro-evidence-sink``, run
## as its own process with its own store, identity and checkpoint key under
## the guest's run directory -- and a guest bootstrapped to ship to it.
##
## The sink binds the build host's loopback; a QEMU user-network guest
## reaches it at ``HostFromGuest`` (slirp's gateway), so the shipping unit's
## ``IPAddressAllow=`` names that address. The sink binary is compiled by
## the gate from this tree: under ``REPRO_ADDON_MUTATION`` naming a sink
## mutation (``SinkMutations``) it is that falsifying build, so the gate
## runs against exactly the sink the mutation describes.
##
## *Mocking.* None: a real sink process, real TLS, the guest's real units.

import std/[json, os, osproc, strutils, times]

import repro_peer_cache/auth as peerAuth
import repro_peer_cache/evidence
import repro_peer_cache/identity
import repro_peer_cache/pki
import repro_peer_cache/types
import repro_deploy_agent/manifest

import repro_addon/evidence_check

import ./addon_testbed
import ./agent_e2e_support

const
  SinkMutations* = ["sink-credential-has-read-scope"]
    ## Falsifying builds that live in the sink, not in the add-on binary.
  GuestSinkCa* = "/root/addon/evidence-sink.crt"
  GuestCredentialCert* = "/var/lib/repro/evidence/host-ca.crt"
  GateHeartbeatSec* = 30
  GatePollSec* = 30

type
  GateSink* = ref object
    root*: string
    storeDir*: string
    identityDir*: string
    anchorsDir*: string
    keyDir*: string
    port*: int
    hostId*: string
    process: Process
    log*: string
    published*: string     ## every manifest the producer published, by sequence

proc sinkBinary*(): string =
  ## The sink of this tree, built for the gate's mutation if it is a sink
  ## mutation; one compile at a time per output (a lock beside it).
  let m = mutation()
  let isSinkMutation = m in SinkMutations
  result = reproRoot() / "build" / "test-bin" /
           ("repro-evidence-sink" & (if isSinkMutation: "-" & m else: ""))
  let cache = reproRoot() / "build" / "nimcache" /
              ("repro-evidence-sink-gate" & (if isSinkMutation: "-" & m else: ""))
  createDir(parentDir(result))
  let cmd = "cd " & quoteShell(reproRoot()) & " && flock " &
    quoteShell(cache & ".lock") & " nim c --hints:off --warnings:off " &
    (if isSinkMutation: "-d:reproAddonMutation=" & m & " " else: "") &
    "--nimcache:" & quoteShell(cache) & " --out:" & quoteShell(result) &
    " apps/repro-evidence-sink/repro_evidence_sink.nim"
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    raise newException(TestBedError, "cannot build the evidence sink: " & output)

proc startGateSink*(g: Guest): GateSink =
  ## A fresh sink under the guest's run directory.
  result = GateSink(root: g.runDir / "sink")
  result.storeDir = result.root / "store"
  result.identityDir = result.root / "identity"
  result.anchorsDir = result.root / "anchors"
  result.keyDir = result.root / "checkpoint-key"
  result.published = result.root / "published"
  result.log = result.root / "sink.log"
  for d in [result.storeDir, result.anchorsDir, result.published]: createDir(d)
  let identity = loadOrCreateHostIdentity(result.identityDir / "host-ca.crt",
                                          result.identityDir / "host-ca.key")
  result.hostId = $identity.hostId
  let ready = result.root / "sink.ready"
  result.process = startProcess("/bin/sh", args = ["-c", "exec " &
    quoteShell(sinkBinary()) & " serve --dir=" & quoteShell(result.storeDir) &
    " --identity=" & quoteShell(result.identityDir) &
    " --anchors=" & quoteShell(result.anchorsDir) &
    " --checkpoint-key=" & quoteShell(result.keyDir) &
    " --bind=127.0.0.1 --port=0 --ready-file=" & quoteShell(ready) &
    " >> " & quoteShell(result.log) & " 2>&1"])
  while true:
    if fileExists(ready):
      let ep = readFile(ready).splitLines()[0].strip()
      result.port = parseInt(ep[ep.rfind(':') + 1 .. ^1])
      return
    if result.process.peekExitCode() != -1:
      raise newException(TestBedError, "the evidence sink exited: " &
        (if fileExists(result.log): readFile(result.log) else: ""))
    sleep(50)

proc stop*(s: GateSink) =
  if s != nil and s.process != nil:
    try:
      s.process.terminate()
      discard s.process.waitForExit(5000)
      s.process.close()
    except CatchableError: discard

proc caPath*(s: GateSink): string = s.identityDir / "host-ca.crt"

proc evidenceFlags*(s: GateSink): string =
  " --evidence-sink " & HostFromGuest & ":" & $s.port &
  " --evidence-sink-ca " & GuestSinkCa &
  " --heartbeat-interval " & $GateHeartbeatSec &
  " --poll-interval " & $GatePollSec

proc ensureNftables*(g: Guest) =
  ## The egress observer needs the base's ``nft``; Debian's genericcloud
  ## images do not ship it (Ubuntu's do), and bootstrap never installs a
  ## package. As an operator would before bootstrapping an agent host with
  ## a sink, the fixture installs the distribution's ``nftables`` first.
  discard g.exec("command -v nft >/dev/null || DEBIAN_FRONTEND=noninteractive " &
    "apt-get install -y -q nftables >/dev/null", timeoutSec = 1800)

proc provideSinkCa*(g: Guest; s: GateSink) =
  ## Before the preflight: the sink's CA where the flags name it, and the
  ## base's nftables for the egress observer.
  discard g.run("mkdir -p /root/addon")
  g.copyTo(s.caPath, GuestSinkCa)
  g.ensureNftables()

proc enrol*(g: Guest; s: GateSink): string =
  ## The operator's step after bootstrap: the guest's credential certificate
  ## into the sink's anchor directory. Returns the guest's host id as the
  ## sink will stamp it.
  let local = s.root / "guest-credential.crt"
  g.copyFrom(GuestCredentialCert, local)
  result = $derivePeerIdFromPublicKey(certPublicKey(certPemToDer(readFile(local))))
  copyFile(local, s.anchorsDir / (result & ".crt"))

proc entries*(s: GateSink): seq[EvidenceEntry] =
  ## Read locally, as an investigator on the sink host would (EVID-3).
  try: readEvidenceStore(s.storeDir) except CatchableError: @[]

proc waitFor*(s: GateSink; host: string; detector, trigger: string;
              timeoutSec = 300; since = 0'u64): bool =
  ## Until the sink holds a record of ``detector`` / ``trigger`` ("" any)
  ## from ``host`` with a sink sequence above ``since``.
  let deadline = epochTime() + float(timeoutSec)
  while epochTime() < deadline:
    for e in s.entries():
      if e.kind == ekRecord and e.seq > since and $e.senderHostId == host and
          e.record.detector == detector and
          (trigger.len == 0 or e.record.trigger == trigger):
        return true
    sleep(1000)
  false

proc headSeq*(s: GateSink): uint64 =
  for e in s.entries(): result = max(result, e.seq)

proc archive*(s: GateSink; m: seq[byte]; sequence: uint64) =
  ## Keep a copy of what the producer published (the checker compares hosts
  ## with the producer's whole history, not only its latest).
  var bytes = newString(m.len)
  for i, b in m: bytes[i] = char(b)
  # One file per copy: a re-signed copy of a sequence must not replace the
  # first (the lag check counts from the first publication).
  let t = getTime()
  writeFile(s.published / ($sequence & "-" & $t.toUnix() & "-" &
    $t.nanosecond & ".rdm"), bytes)

proc check*(s: GateSink; host: string; signersPath: string;
            nowMs = 0'i64): CheckReport =
  ## The off-host check over the sink's store and the producer's archive.
  runEvidenceCheck(CheckInputs(storeDir: s.storeDir,
    hosts: @[EnrolledHost(hostId: host, target: AgentTarget)],
    manifests: loadPublishedManifests(s.published,
      peerAuth.loadTrustAnchors(signersPath)),
    nowMs: (if nowMs > 0: nowMs else: int64(epochTime() * 1000)),
    silenceFactor: 3))

proc toJson*(r: CheckReport): JsonNode =
  result = %*{"alerts": newJArray(), "statuses": newJArray()}
  for a in r.alerts:
    result["alerts"].add(%*{"detector": a.detector, "trigger": a.trigger,
      "sinkSeq": a.sinkSeq, "detail": a.detail})
  for st in r.statuses:
    result["statuses"].add(%*{"detector": st.detector, "status": st.status,
      "detections": st.detections})

proc bootstrapShipping*(g: Guest; repro: string; step: StepFn;
                        producer: var Producer):
    tuple[ok: bool; sink: GateSink; host: string; anchors: Anchors] =
  ## A sink, then the guest bootstrapped with the deploy agent and that
  ## sink, then its credential enrolled: from here on the guest's records
  ## reach the sink.
  result.sink = startGateSink(g)
  g.provideSinkCa(result.sink)
  let bs = g.bootstrapWithAgent(repro, step, extraFlags = result.sink.evidenceFlags)
  producer = bs.producer
  result.anchors = bs.anchors
  if not bs.ok: return
  result.host = g.enrol(result.sink)
  # The records bootstrap queued go out at the next run of the shipping
  # unit; start one now rather than wait for its timer.
  discard g.exec("systemctl start repro-addon-evidence.service")
  result.ok = result.sink.waitFor(result.host, "addon-bootstrap", "bootstrap",
                                  timeoutSec = 120)
  step("the bootstrap record reached the gate's sink", result.ok,
       g.exec("journalctl -q -o cat -u repro-addon-evidence.service | tail -20").stdout)

type RequestHandler* = proc(name, ext, content: string): tuple[handled: bool;
                                                             output: string]
  ## A bed's own request kinds beside ``.sh`` and ``.copy`` (the audit bed's
  ## ``.publish`` and ``.reboot``): handled when ``handled``.

proc serveRequests*(g: Guest; dir: string; until: string; holdSec: int;
                    extra: RequestHandler = nil) =
  ## The investigator's access to the guest while the drill holds: each
  ## ``requests/<n>.sh`` is run in the guest as root and answered with
  ## ``requests/<n>.out`` (exit code, stdout, stderr); each
  ## ``requests/<n>.copy`` (one guest path) is copied to ``copies/<n>/``.
  ## Ends when ``until`` exists or after ``holdSec``.
  let req = dir / "requests"
  createDir(req)
  createDir(dir / "copies")
  let deadline = epochTime() + float(holdSec)
  while not fileExists(until) and epochTime() < deadline:
    for kind, p in walkDir(req):
      let (_, name, ext) = splitFile(p)
      if kind != pcFile or fileExists(req / (name & ".out")): continue
      if ext == ".sh":
        let r = g.exec(readFile(p), timeoutSec = 1800)
        writeFile(req / (name & ".out"), "exit " & $r.exitCode & "\n--- stdout\n" &
          r.stdout & "\n--- stderr\n" & r.stderr)
      elif not extra.isNil and ext notin [".sh", ".copy", ".out"]:
        let r = try: extra(name, ext, readFile(p))
                except CatchableError as e: (true, "failed: " & e.msg & "\n")
        if r.handled: writeFile(req / (name & ".out"), r.output)
      elif ext == ".copy":
        let dest = dir / "copies" / name
        createDir(dest)
        try:
          g.copyFrom(readFile(p).strip(), dest)
          writeFile(req / (name & ".out"), "copied to " & dest & "\n")
        except CatchableError as e:
          writeFile(req / (name & ".out"), "copy failed: " & e.msg & "\n")
    sleep(1000)


const FetchCgroupProcs* = "/sys/fs/cgroup/system.slice/system-reproagent.slice/" &
  "repro-agent-fetch.service/cgroup.procs"
  ## The fetch unit's cgroup under the egress observer's slice (while the
  ## unit runs).

proc forbiddenConnectFromFetch*(g: Guest; host = "1.1.1.1"; port = 53):
    tuple[paused: bool; connect: int] =
  ## DET-AO-3's positive control: the fetch unit paused after it selected a
  ## manifest (seam build), a shell moved into its cgroup connects to an
  ## address outside its allow-list (refused by the unit's IP filter), and
  ## the unit is let go -- after which the egress check runs (``OnSuccess=``
  ## / ``OnFailure=``). Returns whether it paused and the connect's status.
  g.armFetchSeam("agent-fetch-after-select")
  g.startFetchNoWait()
  result.paused = g.waitSeam(FetchSeamDir, "agent-fetch-after-select")
  if result.paused:
    result.connect = g.exec("echo $$ > " & FetchCgroupProcs & " && timeout 10 " &
      "bash -c 'exec 3<>/dev/tcp/" & host & "/" & $port & "'").exitCode
    g.resumeSeam(FetchSeamDir)
  g.waitApplyIdle()
