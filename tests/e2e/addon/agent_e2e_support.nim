## What the A8 deploy-agent gates share: a producer on the test host that
## serves signed RDMF v3 manifests over HTTP, a guest bootstrapped with the
## agent's two units pointed at it, and one fetch-then-apply cycle of those
## units observed through the tick status record.
##
## The producer is this test process (``signManifest`` with the deploy
## signer the guest anchors) and a plain ``python3 -m http.server`` bound to
## the host's loopback; a QEMU user-network guest reaches the host's
## loopback at ``HostFromGuest`` (slirp's gateway address), so the origin is
## an address literal and the fetch unit's ``IPAddressAllow=`` names it.
##
## *Mocking.* None: real units under the guest's systemd, a real HTTP
## origin, real signatures.

import std/[algorithm, json, os, osproc, strutils, times]

import repro_deploy_agent/manifest
import repro_deploy_agent/secrets
import repro_peer_cache/auth as peerAuth
import repro_profile

import ./addon_testbed

const
  HostFromGuest* = "10.0.2.2"
    ## The test host's loopback as a QEMU user-network guest sees it.
  AgentTarget* = "addon-tb"
    ## The guest's host name (``newGuest``'s cloud-init ``local-hostname``).
  TickStatus* = "/var/lib/repro/agent/state/deploy-agent/" & AgentTarget &
                ".last-tick.json"
  SeqFloor* = "/var/lib/repro/agent/state/deploy-agent/" & AgentTarget & ".seq"

type
  Producer* = ref object
    dir*: string            ## served root; manifests at <dir>/<target>/latest.rdm
    port*: int
    process: Process
    signer*: PeerKeypair

proc startProducer*(g: Guest; signer: PeerKeypair): Producer =
  ## An HTTP origin on the host's loopback serving ``g.runDir/served``, on a
  ## port the kernel picks: the server binds port 0 and prints the port it
  ## got ("Serving HTTP on 127.0.0.1 port N"), and the wait ends on that
  ## line or on the server's exit, never on a deadline (see
  ## ``cache_e2e_support.startCache`` for why a probed port and a startup
  ## deadline are both races on a busy host).
  result = Producer(dir: g.runDir / "served", signer: signer)
  createDir(result.dir / AgentTarget)
  let log = g.runDir / "producer.log"
  result.process = startProcess("/bin/sh", args = ["-c",
    "exec python3 -u -m http.server --bind 127.0.0.1 0 --directory " &
    quoteShell(result.dir) & " >> " & quoteShell(log) & " 2>&1"])
  const Marker = "Serving HTTP on 127.0.0.1 port "
  while true:
    if fileExists(log):
      for line in readFile(log).splitLines():
        if line.startsWith(Marker):
          result.port = parseInt(line[Marker.len .. ^1].split(' ')[0])
          return
    let code = result.process.peekExitCode()
    if code != -1:
      raise newException(TestBedError, "the producer's HTTP server exited " &
        "(status " & $code & "): " & (if fileExists(log): readFile(log) else: ""))
    sleep(50)

proc stop*(p: Producer) =
  if p != nil and p.process != nil:
    try:
      p.process.terminate()
      discard p.process.waitForExit(5000)
      p.process.close()
    except CatchableError: discard

proc url*(p: Producer): string =
  "http://" & HostFromGuest & ":" & $p.port & "/" & AgentTarget & "/latest.rdm"

proc originUrl*(p: Producer): string =
  "http://" & HostFromGuest & ":" & $p.port

type PublishSpec* = object
  sequence*: uint64
  profileText*: string
  issuedAt*: int64          ## 0: now
  maxAgeSeconds*: uint64    ## 0: one day
  rollbackFloor*: uint64
  closureDigests*: seq[ClosureDigest]
  buildActions*: seq[ProfileBuildAction]
  deploymentId*: string
  plainV2*: bool            ## emit no attestation block (a v1/v2 manifest)
  compiledProfile*: CompiledProfilePin
    ## The producer's compile of a source ``profileText``
    ## (``producerCompile``); empty for canonical text.

proc publish*(p: Producer; s: PublishSpec): seq[byte] =
  ## Sign and serve one manifest at the target's ``latest.rdm``.
  var m = DeployManifest(target: AgentTarget, sequence: s.sequence,
    deploymentId: (if s.deploymentId.len > 0: s.deploymentId
                   else: "a8-" & $s.sequence),
    profileText: s.profileText, buildActions: s.buildActions)
  if not s.plainV2:
    m.issuedAt = uint64(if s.issuedAt > 0: s.issuedAt else: getTime().toUnix())
    m.maxAgeSeconds = if s.maxAgeSeconds > 0: s.maxAgeSeconds else: 86_400'u64
    m.rollbackFloor = s.rollbackFloor
    m.closureDigests = s.closureDigests
    m.compiledProfile = s.compiledProfile
  signManifest(p.signer, m)
  result = encodeManifest(m)
  var bytes = newString(result.len)
  for i, b in result: bytes[i] = char(b)
  let tmp = p.dir / AgentTarget / ".latest.rdm.tmp"
  writeFile(tmp, bytes)
  moveFile(tmp, p.dir / AgentTarget / "latest.rdm")

proc engineClosureTar(engine: string): string =
  ## ``engine``'s closure as one tar of absolute store paths (cached).
  result = reproRoot() / "build" / ("a8-engine-closure-" &
    engine.extractFilename & ".tar")
  if fileExists(result): return
  let (paths, c) = execCmdEx("nix-store -qR " & quoteShell(engine))
  doAssert c == 0, paths
  let lst = result & ".list"
  writeFile(lst, paths)
  let (o, c2) = execCmdEx("tar -cf " & quoteShell(result & ".tmp") &
    " -T " & quoteShell(lst))
  doAssert c2 == 0, o
  moveFile(result & ".tmp", result)

proc installEngineClosure*(g: Guest; engine: string) =
  ## The full engine (a Nix store path holding ``bin/reprobuild``, built
  ## from this tree; ``REPRO_ADDON_ENGINE_CLOSURE``) with its closure, at
  ## the same store paths in the guest.
  let tar = engineClosureTar(engine)
  g.copyTo(tar, "/root/engine.tar")
  discard g.run("tar -xf /root/engine.tar -C / && rm /root/engine.tar",
                timeoutSec = 1800)

const CompileHost* = "a8-testbed"
  ## The host identity a gate's producer compiles source profiles for.

proc producerCompile*(engine, source: string; arch = "x86_64";
                      host = CompileHost;
                      files: seq[ProfileFile] = @[];
                      systemMode = "";
                      systemActivities: seq[string] = @[]): CompiledProfilePin =
  ## The producer's side of the compiled-profile pin: compile ``source``
  ## on THIS machine with ``engine`` (a store path holding
  ## ``bin/reprobuild``), for the facts the target's agent will compile
  ## with, and pin the digest and the engine's revision -- what infra's
  ## renderer does with ``--profile-compiler``.
  let work = getTempDir() / ("a8-producer-compile-" & $getCurrentProcessId() &
    "-" & $epochTime().int64)
  createDir(work / "src")
  defer: removeDir(work)
  writeFile(work / "src" / StagedProfileModule, source)
  for f in files:
    createDir(parentDir(work / "src" / f.path))
    writeFile(work / "src" / f.path, f.content)
  let cmd = quoteShellCommand(@[engine / "bin" / "reprobuild", "deploy-agent",
    "compile-profile", "--staged", work / "src" / StagedProfileModule,
    "--canonical-out", work / "c", "--actions-out", work / "a",
    "--digest-out", work / "d", "--revision-out", work / "r",
    "--state-dir", work / "state", "--host", host, "--platform", "linux",
    "--arch", arch] & (if systemMode.len > 0 or systemActivities.len > 0:
      @["--system-mode", (if systemMode.len > 0: systemMode else: "full"),
        "--system-activities", systemActivities.join(",")]
    else: @[]))
  let (o, c) = execCmdEx("env HOME=" & quoteShell(work / "home") & " " & cmd)
  doAssert c == 0, "the producer's compile failed: " & o
  var selected = systemActivities
  selected.sort()
  result = CompiledProfilePin(digest: readFile(work / "d").strip(),
    compilerRevision: readFile(work / "r").strip(), platform: "linux",
    arch: arch, host: host,
    systemMode: (if systemMode.len > 0 or selected.len > 0:
                   (if systemMode.len > 0: systemMode else: "full") else: ""),
    systemActivities: selected)
  doAssert result.digest == compiledProfileDigest(readFile(work / "c"),
    readFile(work / "a"), systemSelectionText(result))

proc agentFlags*(a: Anchors; p: Producer; cacheUrl = ""): string =
  ## Preflight / bootstrap options: the anchors, the agent's target and
  ## manifest source, and (optionally) a cache at an address literal.
  result = " --deploy-signers /root/addon/deploy-signers.anchors" &
           " --target " & AgentTarget & " --manifest " & p.url
  if cacheUrl.len > 0:
    result.add(" --cache-publishers /root/addon/cache-publishers.anchors" &
               " --cache-url " & cacheUrl)

proc bootstrapWithAgent*(g: Guest; repro: string; step: StepFn;
                         extraFlags = ""; cacheUrl = "";
                         cachePublishers: seq[string] = @[]):
    tuple[ok: bool; anchors: Anchors; producer: Producer] =
  ## Preflight and bootstrap with the deploy agent configured, its producer
  ## started first (the plan pins its address).
  let anchors = g.installAnchors()
  result.anchors = anchors
  if cachePublishers.len > 0:
    writeFile(g.runDir / "cache-publishers.anchors",
              cachePublishers.join("\n") & "\n")
    g.copyTo(g.runDir / "cache-publishers.anchors",
             "/root/addon/cache-publishers.anchors")
  result.producer = g.startProducer(anchors.deploySignerKeys[0])
  let flags = agentFlags(anchors, result.producer, cacheUrl) & extraFlags
  let pre = g.exec(repro & " system addon preflight" & flags)
  step("preflight with the deploy agent is compatible", pre.exitCode == 0,
       pre.stdout & pre.stderr)
  if pre.exitCode != 0: return
  let boot = g.exec(repro & " system addon bootstrap --plan " &
                    planDigestOf(pre.stdout) & flags, timeoutSec = 1800)
  step("bootstrap with the deploy agent", boot.exitCode == 0,
       boot.stdout & boot.stderr)
  if boot.exitCode != 0: return
  # The timer must not race the gate's own ticks.
  discard g.exec("systemctl stop repro-agent-fetch.timer")
  result.ok = true

type TickResult* = object
  outcome*: string
  exitCode*: int
  message*: string
  errorCode*: string
  sequence*: int
  fetchLog*: string
  applyLog*: string

proc tickUnits*(g: Guest; timeoutSec = 1800): TickResult =
  ## One cycle of the real units: start the fetch (a oneshot, so this
  ## waits for it), let ``OnSuccess=`` start the apply, wait for the apply
  ## to finish, and read the tick status record it wrote.
  discard g.exec("rm -f " & TickStatus)
  let since = g.run("date +%s").strip()
  let f = g.exec("systemctl start repro-agent-fetch.service", timeoutSec)
  result.fetchLog = g.exec("journalctl -q -o cat --since @" & since &
    " -u repro-agent-fetch.service").stdout
  if f.exitCode != 0:
    result.outcome = "fetch-failed"
    result.message = f.stdout & f.stderr & result.fetchLog
    return
  # The apply job OnSuccess queued: wait until the unit is inactive again
  # and the record exists.
  discard g.exec("for i in $(seq 1 " & $timeoutSec & "); do " &
    "s=$(systemctl show -p ActiveState --value repro-agent-apply.service); " &
    "[ -e " & TickStatus & " ] && [ \"$s\" != activating ] && " &
    "[ \"$s\" != active ] && break; sleep 1; done", timeoutSec + 30)
  result.applyLog = g.exec("journalctl -q -o cat --since @" & since &
    " -u repro-agent-apply.service").stdout
  let st = g.exec("cat " & TickStatus)
  if st.exitCode != 0:
    result.outcome = "no-record"
    result.message = result.applyLog
    return
  let j = parseJson(st.stdout)
  result.outcome = j["outcome"].getStr
  result.exitCode = j["exitCode"].getInt
  result.message = j["message"].getStr
  result.errorCode = j["errorCode"].getStr
  result.sequence = j["sequence"].getInt

proc `$`*(t: TickResult): string =
  t.outcome & " (exit " & $t.exitCode & ", " & t.errorCode & ") seq " &
    $t.sequence & ": " & t.message

proc unitProfile*(name, execStart: string; health = ""; extra = ""): string =
  ## A ``systemd.systemUnit`` the add-on runs, as canonical text.
  "systemd.systemUnit {\n  name = \"" & name & "\"\n  content = \"[Unit]\n" &
    "Description=A8 fixture " & name & "\n\n[Service]\nExecStart=" &
    execStart & "\n" & extra & "\n[Install]\nWantedBy=multi-user.target\n\"\n" &
    "  enabled = true\n" &
    (if health.len > 0: "  healthCheck = \"" & health & "\"\n" else: "") &
    "}\n"

proc waitSeam*(g: Guest; controlDir, point: string; timeoutSec = 600): bool =
  ## Wait until a seam build paused at ``point`` (``seams.nim``).
  g.exec("for i in $(seq 1 " & $timeoutSec & "); do " &
    "grep -qx " & point & " " & controlDir & "/test-paused-at 2>/dev/null && " &
    "exit 0; sleep 1; done; exit 1", timeoutSec + 30).exitCode == 0

type GateBody* = proc(g: Guest; repro: string; step: StepFn;
                      record: JsonNode; producer: var Producer) {.closure.}

proc runAgentGate*(b: BaseImage; record: JsonNode; body: GateBody;
                   bootstrap = true; extraFlags = ""; diskGiB = 8;
                   beforeBootstrap: proc(g: Guest) = nil): seq[string] =
  ## One base of an A8 gate: a fresh guest with the static add-on, the
  ## deploy agent bootstrapped (unless ``bootstrap`` is false), the gate's
  ## ``body``, and teardown of everything it created.
  var g: Guest
  var producer: Producer
  let steps = newJArray()
  var fails: seq[string]
  let step: StepFn = proc(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b, diskGiB = diskGiB)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if beforeBootstrap != nil: beforeBootstrap(g)
    if bootstrap:
      let bs = g.bootstrapWithAgent(repro, step, extraFlags)
      producer = bs.producer
      if not bs.ok: return fails
    body(g, repro, step, record, producer)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    producer.stop()
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

proc gateMain*(gate: string; body: GateBody; bootstrap = true;
               extraFlags = ""; diskGiB = 8;
               beforeBootstrap: proc(g: Guest) = nil): seq[string] =
  ## Every selected base, one record each; returns the failures.
  for b in selectedBases():
    let record = %*{"gate": gate, "base": b.name, "arch": b.debArch,
      "backend": (if useIncus(): "incus" else: "qemu"),
      "mutation": mutation(), "reprobuild": gitHead(),
      "started": $now().utc}
    let f = runAgentGate(b, record, body, bootstrap, extraFlags, diskGiB,
                         beforeBootstrap)
    record["verdict"] = %(if f.len == 0: "green" else: "red")
    record["finished"] = %($now().utc)
    echo "record: ", writeRecord(gate, record)
    result.add(f)
  for f in result: echo "FAIL ", f

proc canonicalFile*(path, content: string): string =
  "fs.systemFile {\n  path = \"" & path & "\"\n  content = \"" & content &
    "\"\n}\n"

proc fetchPid*(g: Guest): string =
  g.run("systemctl show -p MainPID --value repro-agent-fetch.service").strip()

proc applyPid*(g: Guest): string =
  g.run("systemctl show -p MainPID --value repro-agent-apply.service").strip()

const
  ApplySeamDir* = "/var/lib/repro/system/addon"
  FetchSeamDir* = "/var/lib/private/repro-agent-fetch/addon"

proc armApplySeam*(g: Guest; point: string) =
  discard g.run("mkdir -p " & ApplySeamDir & " && echo " & point & " > " &
                ApplySeamDir & "/test-pause-at")

proc armFetchSeam*(g: Guest; point: string) =
  ## The fetch unit runs as a dynamic user: its control directory must be
  ## writable by it (it removes the control file and writes its marker).
  discard g.run("mkdir -p " & FetchSeamDir & " && chmod 0777 " & FetchSeamDir &
                " && echo " & point & " > " & FetchSeamDir & "/test-pause-at")

proc resumeSeam*(g: Guest; dir: string) =
  ## Release a paused seam. Only ``touch``: the paused process removes the
  ## file as soon as it sees it (the fetch unit's dynamic user may, in its
  ## 0777 control directory), so anything run on it afterwards races.
  discard g.run("touch " & dir & "/test-resume")

proc startFetchNoWait*(g: Guest) =
  discard g.run("systemctl start --no-block repro-agent-fetch.service")

proc waitApplyIdle*(g: Guest; timeoutSec = 1800) =
  discard g.exec("for i in $(seq 1 " & $timeoutSec & "); do " &
    "s=$(systemctl show -p ActiveState --value repro-agent-apply.service); " &
    "f=$(systemctl show -p ActiveState --value repro-agent-fetch.service); " &
    "[ \"$s\" != activating ] && [ \"$s\" != active ] && " &
    "[ \"$f\" != activating ] && [ -e " & TickStatus & " ] && break; " &
    "sleep 1; done", timeoutSec + 30)

proc lastTick*(g: Guest): TickResult =
  let st = g.exec("cat " & TickStatus)
  if st.exitCode != 0:
    result.outcome = "no-record"
    return
  let j = parseJson(st.stdout)
  result.outcome = j["outcome"].getStr
  result.exitCode = j["exitCode"].getInt
  result.message = j["message"].getStr
  result.errorCode = j["errorCode"].getStr
  result.sequence = j["sequence"].getInt
