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
  ##
  ## A matrix runs one gate on several bases at once, and every cell may
  ## find the cache empty. The build runs under an exclusive ``flock`` on a
  ## sibling lock file and re-checks the cache once it holds the lock, so
  ## exactly one cell writes the (multi-GB) tar and the others reuse it:
  ## sharing one temporary let a cell rename a file another cell had
  ## already moved away (ENOENT), and a temporary per cell would multiply
  ## the disk the cache needs by the number of concurrent cells.
  result = reproRoot() / "build" / ("a8-engine-closure-" &
    engine.extractFilename & ".tar")
  if fileExists(result): return
  let (paths, c) = execCmdEx("nix-store -qR " & quoteShell(engine))
  doAssert c == 0, paths
  let lst = result & ".list." & $getCurrentProcessId()
  writeFile(lst, paths)
  defer: removeFile(lst)
  let tmp = quoteShell(result & ".tmp")
  let build = "[ -f " & quoteShell(result) & " ] || { tar -cf " & tmp &
    " -T " & quoteShell(lst) & " && mv " & tmp & " " & quoteShell(result) &
    "; } || { rc=$?; rm -f " & tmp & "; exit $rc; }"
  let (o, c2) = execCmdEx("flock " & quoteShell(result & ".lock") &
    " sh -c " & quoteShell(build))
  doAssert c2 == 0, o

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
                      systemMode = "addOn";
                      systemActivities: seq[string] = @[]): CompiledProfilePin =
  ## The producer's side of the compiled-profile pin: compile ``source``
  ## on THIS machine with ``engine`` (a store path holding
  ## ``bin/reprobuild``), for the facts the target's agent will compile
  ## with, and pin the digest and the engine's revision -- what infra's
  ## renderer does with ``--profile-compiler``. The selection defaults to
  ## the add-on mode's ``default`` (``addOn`` with no activity), what a
  ## producer pins for an add-on host whose entry is ``system: addOn``
  ## alone; an add-on agent refuses a pin with no selection or ``full``.
  ## It is canonicalised as the producers do (``canonicalSystemSelection``).
  let (systemMode, systemActivities) =
    canonicalSystemSelection(systemMode, systemActivities)
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
    "--arch", arch] & (if systemMode.len > 0:
      @["--system-mode", systemMode,
        "--system-activities", systemActivities.join(",")]
    else: @[]))
  let (o, c) = execCmdEx("env HOME=" & quoteShell(work / "home") & " " & cmd)
  doAssert c == 0, "the producer's compile failed: " & o
  result = CompiledProfilePin(digest: readFile(work / "d").strip(),
    compilerRevision: readFile(work / "r").strip(), platform: "linux",
    arch: arch, host: host, systemMode: systemMode,
    systemActivities: systemActivities)
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

const TimerBaseline* = "/root/addon/tick-timer-trigger"
  ## The fetch timer's last trigger when the gate last stopped it and every
  ## cycle had settled: what the next tick compares with.

proc timerTrigger(g: Guest): string =
  g.run("systemctl show -p LastTriggerUSecMonotonic --value " &
        "repro-agent-fetch.timer 2>/dev/null; true").strip()

proc waitAgentIdle(g: Guest; timeoutSec: int) =
  ## Until neither agent unit is running or queued.
  discard g.exec("for i in $(seq 1 " & $timeoutSec & "); do " &
    "busy=0; for u in repro-agent-fetch.service repro-agent-apply.service; do " &
    "case \"$(systemctl show -p ActiveState --value $u)\" in " &
    "activating|active|deactivating|reloading) busy=1;; esac; done; " &
    # A job OnSuccess= queued is not active yet, but it is in flight.
    "systemctl list-jobs --no-legend 2>/dev/null | grep -q 'repro-agent-' " &
    "&& busy=1; " &
    "[ $busy = 0 ] && break; sleep 1; done", timeoutSec + 30)

proc recordTimerBaseline*(g: Guest; timeoutSec = 1800) =
  ## Stop the fetch timer, let any cycle it started finish, and record its
  ## last trigger: a trigger just before the stop starts a cycle that runs
  ## on after it, and recording before that cycle settles would let the
  ## next tick take it for the gate's own (round 7, finding 7).
  discard g.exec("systemctl stop repro-agent-fetch.timer 2>/dev/null; true")
  g.waitAgentIdle(timeoutSec)
  # With the boot it was taken in: the trigger is on CLOCK_MONOTONIC,
  # which restarts at every boot.
  discard g.exec("printf '%s %s\\n' \"$(cat /proc/sys/kernel/random/boot_id)\" " &
    "\"$(systemctl show -p LastTriggerUSecMonotonic --value " &
    "repro-agent-fetch.timer)\" > " & TimerBaseline & " 2>/dev/null; true")

proc timerBaseline(g: Guest): tuple[sameBoot: bool; trigger: string] =
  ## The recorded baseline, and whether it was taken in this boot. A
  ## baseline from before a reboot says nothing about the clock now: then
  ## only "no trigger since the boot" ("0") is the baseline.
  let f = g.exec("cat " & TimerBaseline & " 2>/dev/null").stdout.strip()
  if f.len == 0: return (true, "")
  let boot = g.run("cat /proc/sys/kernel/random/boot_id").strip()
  let parts = f.split(' ', maxsplit = 1)
  if parts.len < 2: return (true, f)       # round 5's file: the trigger only
  if parts[0] != boot: return (false, "0")
  (true, parts[1].strip())

proc bootstrapWithAgent*(g: Guest; repro: string; step: StepFn;
                         extraFlags = ""; cacheUrl = "";
                         cachePublishers: seq[string] = @[]):
    tuple[ok: bool; anchors: Anchors; producer: Producer;
          attestationKey: string] =
  ## Preflight and bootstrap with the deploy agent configured, its producer
  ## started first (the plan pins its address). ``attestationKey`` is the
  ## public key bootstrap printed (when a sink was configured): what the
  ## operator enrols.
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
  for l in boot.stdout.splitLines():
    if l.startsWith("attestation key:"):
      result.attestationKey = l["attestation key:".len .. ^1].strip()
  if boot.exitCode != 0: return
  # The timer must not race the gate's own ticks. Stopping it once was not
  # enough: a later switch re-arms it (the apply's step 7), and its own
  # cycle then applied the gate's newest sequence before the gate's tick
  # ran ("tick 11 ... already converged", A9 review round 5, finding 6).
  # `tickUnits` stops it again at each tick's end, and refuses a cycle the
  # timer ran since. (Not a mask: the add-on observes its own unit files
  # and refuses to write over a mask.)
  discard g.exec("systemctl stop repro-agent-fetch.timer")
  # The baseline the first tick compares with (A9 review round 7, finding
  # 7): without it a cycle between here and the first tick went unseen.
  # (Variant ``tick-compares-previous-end`` restores round 5's helper.)
  if getEnv("REPRO_A13_MUTATION") != "tick-compares-previous-end":
    g.recordTimerBaseline()
  result.ok = true

type TickResult* = object
  outcome*: string
  exitCode*: int
  message*: string
  errorCode*: string
  sequence*: int
  fetchLog*: string
  applyLog*: string

proc fetchStartMonotonic(g: Guest): string =
  ## When the fetch unit's main process last started, in the guest's
  ## CLOCK_MONOTONIC microseconds (systemd's ``ExecMainStartTimestampMonotonic``;
  ## it outlives the oneshot's exit). "0" before its first start.
  g.run("systemctl show -p ExecMainStartTimestampMonotonic --value " &
        "repro-agent-fetch.service").strip()

proc guestMonotonic(g: Guest): string =
  ## The guest's CLOCK_MONOTONIC now, in microseconds, on the same clock as
  ## systemd's ``*TimestampMonotonic`` properties: the kernel's own
  ## ``now at <ns> nsecs`` line of ``/proc/timer_list`` (read as root; no
  ## interpreter in the guest is needed). "" when it cannot be read.
  let r = g.exec("awk '/^now at [0-9]+ nsecs/ {print int($3 / 1000); exit}' " &
                 "/proc/timer_list")
  if r.exitCode == 0: r.stdout.strip() else: ""

proc tickUnits*(g: Guest; timeoutSec = 1800): TickResult =
  ## One cycle of the real units: start the fetch (a oneshot, so this
  ## waits for it), let ``OnSuccess=`` start the apply, wait for the apply
  ## to finish, and read the tick status record it wrote.
  ##
  ## The cycle it observes is proven to be a new one, started by this call
  ## after everything the caller published. A cycle the agent's own timer
  ## started (``OnBootSec=``, so soon after a reboot) may be running or
  ## queued: `systemctl start` would join that job instead of starting a
  ## fresh fetch, and the cycle observed would be one that fetched before
  ## the caller's latest publish. So the helper first waits for both units
  ## to settle (neither running nor queued), then checks after the start
  ## that the fetch's main process started after the moment it took just
  ## before the start. A cycle that did not (a timer firing in the window
  ## between the two) is reported as ``stale-cycle``, never passed on.
  ## The positive control, ``e2e_addon_tick_observes_a_fresh_cycle``, has
  ## two gate-level variants: ``REPRO_A13_MUTATION=tick-joins-in-flight``
  ## restores the old helper (no wait, no proof), and
  ## ``tick-skips-idle-wait`` keeps the proof but not the wait, so the proof
  ## alone must catch the joined cycle.
  let variant = getEnv("REPRO_A13_MUTATION")
  let oldHelper = variant == "tick-joins-in-flight"
  if not oldHelper and variant != "tick-skips-idle-wait":
    g.waitAgentIdle(timeoutSec)
  # A cycle the fetch timer ran since the previous tick would have applied
  # what the caller published, and this tick would observe "already
  # converged": the gate's own cycle must be the only one (A9 review round
  # 5, finding 6). The timer's last trigger is
  # compared with the one recorded at the previous tick's end, when this
  # helper stopped it again.
  #
  # Complete since round 7 (finding 7): the baseline is recorded at the
  # agent's bootstrap too, so the first tick compares with something; it is
  # recorded only after the timer is stopped and every cycle has settled;
  # the trigger is read again at this tick's end, so a cycle the timer ran
  # during the tick is seen; and any such cycle names the tick, whatever its
  # outcome -- not only a converged one.
  var timerFired = ""
  let trigStart = g.timerTrigger()
  if variant != "tick-trusts-the-timer":
    let (sameBoot, prev) = g.timerBaseline()
    if prev.len == 0:
      if trigStart notin ["", "0"] and variant != "tick-compares-previous-end":
        timerFired = "repro-agent-fetch.timer has triggered (last trigger " &
          trigStart & " us monotonic) and no baseline was recorded when " &
          "the gate stopped it"
    elif trigStart != prev and not (prev == "0" and trigStart.len == 0):
      timerFired = "repro-agent-fetch.timer triggered (last trigger " &
        trigStart & " us monotonic, " & prev &
        (if sameBoot: " when the gate last stopped it)"
         else: ": none since this boot, the gate's last stop being before it)")
  discard g.exec("rm -f " & TickStatus)
  let since = g.run("date +%s").strip()
  # The apply unit's invocation before this tick, so a failure left over
  # from the previous tick is not taken for this tick's.
  let before = g.run("systemctl show -p InvocationID --value " &
                     "repro-agent-apply.service").strip()
  let fetchBefore = g.fetchStartMonotonic()
  let startedAfter = g.guestMonotonic()
  if not oldHelper and startedAfter.len == 0:
    # Without the guest's monotonic clock the proof cannot be made; that is
    # a named failure, not a pass and not a stale cycle.
    result.outcome = "tick-clock-unavailable"
    result.message = "cannot read the guest's CLOCK_MONOTONIC from " &
      "/proc/timer_list, so this tick cannot prove its cycle is new"
    g.recordTimerBaseline(timeoutSec)
    return
  let f = g.exec("systemctl start repro-agent-fetch.service", timeoutSec)
  result.fetchLog = g.exec("journalctl -q -o cat --since @" & since &
    " -u repro-agent-fetch.service").stdout
  if f.exitCode != 0:
    result.outcome = "fetch-failed"
    result.message = f.stdout & f.stderr & result.fetchLog
    g.recordTimerBaseline(timeoutSec)
    return
  if not oldHelper:
    let fetchAfter = g.fetchStartMonotonic()
    var fresh = false
    try:
      fresh = fetchAfter != fetchBefore and
        parseBiggestInt(fetchAfter) >= parseBiggestInt(startedAfter)
    except ValueError:
      fresh = false
    if not fresh:
      result.outcome = "stale-cycle"
      result.message = "the fetch this tick observed did not start after " &
        "the tick began (main process started at " & fetchAfter &
        " us monotonic, before the start it was " & fetchBefore &
        ", the tick began at " & startedAfter & "): it joined a cycle " &
        "already in flight\n" & result.fetchLog
      g.recordTimerBaseline(timeoutSec)
      return
  # The apply job OnSuccess queued: wait until the unit is inactive again
  # and the record exists -- or until this tick's apply has ended failed
  # without one (killed by its syscall filter, say), which no amount of
  # waiting turns into a record; the caller then sees "no-record".
  discard g.exec("for i in $(seq 1 " & $timeoutSec & "); do " &
    "s=$(systemctl show -p ActiveState --value repro-agent-apply.service); " &
    "[ -e " & TickStatus & " ] && [ \"$s\" != activating ] && " &
    "[ \"$s\" != active ] && break; " &
    "[ \"$s\" = failed ] && [ \"$(systemctl show -p InvocationID --value " &
    "repro-agent-apply.service)\" != " & quoteShell(before) & " ] && break; " &
    "sleep 1; done", timeoutSec + 30)
  result.applyLog = g.exec("journalctl -q -o cat --since @" & since &
    " -u repro-agent-apply.service").stdout
  # The apply may have re-armed the timer: stop it again, let what it
  # started settle, and record its last trigger for the next tick.
  g.recordTimerBaseline(timeoutSec)
  if variant notin ["tick-trusts-the-timer", "tick-compares-previous-end"]:
    let trigEnd = g.timerBaseline().trigger
    if trigEnd != trigStart and timerFired.len == 0:
      timerFired = "repro-agent-fetch.timer triggered during this tick " &
        "(last trigger " & trigEnd & " us monotonic, " & trigStart &
        " when the tick began)"
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
  if timerFired.len > 0 and (result.outcome == "aoConverged" or
      variant != "tick-compares-previous-end"):
    # A cycle the gate did not start ran since it last stopped the timer:
    # whatever this tick reports may be that cycle's doing, not its own
    # (rounds 5 and 7, findings 6 and 7). A named failure, never a pass.
    let was = result.outcome
    result.outcome = "timer-cycle-intervened"
    result.message = timerFired & ": a cycle the gate did not start ran, " &
      "and this tick's outcome (" & was & ") may be its doing\n" & result.message

proc `$`*(t: TickResult): string =
  t.outcome & " (exit " & $t.exitCode & ", " & t.errorCode & ") seq " &
    $t.sequence & ": " & t.message

proc unitProfile*(name, execStart: string; health = ""; extra = "";
                  floorWaiver = true): string =
  ## A ``systemd.systemUnit`` the add-on runs, as canonical text; with
  ## ``floorWaiver`` the hardening floor is waived (``FixtureFloorWaiver``).
  "systemd.systemUnit {\n" & (if floorWaiver: FixtureFloorWaiver else: "") &
    "  name = \"" & name & "\"\n  content = \"[Unit]\n" &
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
      "mutation": mutation(),
      # tickUnits reads it (the tick gate also records it as ``variant``);
      # the A13 record classifier requires it.
      "gateMutation": getEnv("REPRO_A13_MUTATION"), "reprobuild": gitHead(),
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
