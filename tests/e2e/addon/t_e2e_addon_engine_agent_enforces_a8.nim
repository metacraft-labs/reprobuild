## Gate ``e2e_addon_engine_agent_enforces_a8`` (milestone A8, owner decision
## B3 of the A8 review; spec §9.1, §9.2, §7.5; Deploy-Agent §"The
## compiled-profile pin"; threat model G25, G27, G32).
##
## The full engine's ``repro deploy-agent`` (the agent rpi2 runs) on an
## add-on host is held to every rule the add-on agent's two units are. On a
## bootstrapped host with the engine installed (a Nix closure built from
## this tree), each manifest is one tick of ``<engine>/bin/repro
## deploy-agent``:
##
## 1. a v1 manifest (no attestation block) is rejected
##    (``attestations_required``), and so is a v3 manifest carrying only the
##    profile bundle;
## 2. a manifest past its maximum age is ``aoStale``, and one issued beyond
##    the allowed clock skew in the future is ``aoStale`` (``issued_in_future``);
## 3. a profile writing an sshd drop-in is refused (``EAddOnManagementPath``);
## 4. a source profile without a compiled-profile pin is refused, and one
##    whose pin is for other output is refused (a digest mismatch);
## 5. a closure digest pinned for an action the apply does not realise is
##    refused;
## 6. a source profile with the producer's pin (compiled on the test host by
##    the same engine; it ``staticRead``s a file of the manifest's bundle, as
##    rpi2's reads its apt locks) is compiled on the guest by a transient unit under a
##    dynamic user -- a watcher sees compiler processes (vacuity guard), none
##    as UID 0 -- and applied;
## 7. a later sequence signed before the one applied (an older ``issuedAt``)
##    is ``aoStale`` (``issued_at_regressed``);
## 8. with the add-on's state-directory pointer made group-writable, a
##    pinned source profile the plain apply could apply is refused (exit 2,
##    "pointer is not trusted") and ``/etc/repro/a8-pointer`` is not written.
##
## Nothing of 1-5, 7 or 8 is written (the marker files are absent).
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=engine-agent-skips-a8``): the
## engine's agent requires no attestation block and skips the profile
## checks, so step 1 applies and the gate is red. The mutation lives in the
## engine, so the red run needs an engine built with it:
## ``REPRO_ADDON_ENGINE_CLOSURE=$(nix build --no-link --print-out-paths
## --impure --expr '((builtins.getFlake (toString ./.)).packages.${builtins
## .currentSystem}.reprobuild).overrideAttrs (_: { REPRO_ADDON_MUTATION =
## "engine-agent-skips-a8"; })')`` (``scripts/build_apps.sh`` compiles the
## variable in).
## ``engine-agent-pointer-refusal-unwired`` is step 8's falsifier, built the
## same way: its CLI does not act on the untrusted-pointer route, the tick
## takes the plain apply, and ``/etc/repro/a8-pointer`` is written.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and ``REPRO_ADDON_ENGINE_CLOSURE``.
##
## *Mocking.* None: the real engine in the guest, manifests signed with the
## agent's own code, the producer's compile by the same engine.

import std/[json, os, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_deploy_agent/manifest
import repro_peer_cache/auth as peerAuth

import ./addon_testbed
import ./agent_e2e_support
from repro_addon/addon_apply import DefaultStateDir

const
  Gate = "e2e_addon_engine_agent_enforces_a8"
  Target = "a8-engine"
  StateDir = "/var/lib/repro/agent/state"
  Status = StateDir & "/deploy-agent/" & Target & ".last-tick.json"
  Source = "import repro_profile\n\nconst Body = staticRead(\"locks/a8.lock\")\n\n" &
    "profile \"a8Engine\":\n  resources:\n" &
    "    fsSystemFile(path = \"/etc/repro/a8-engine\", content = Body,\n" &
    "      address = \"a8Engine\")\n"
  Bundle = @[ProfileFile(path: "locks/a8.lock", content: "engine\n")]
    ## Read at compile time (``staticRead``): the unprivileged compile must
    ## see the manifest's bundle, as rpi2's profile reads its apt locks.
  OtherSource = "import repro_profile\n\nprofile \"a8Other\":\n  resources:\n" &
    "    fsSystemFile(path = \"/etc/repro/a8-other\", content = \"other\\n\",\n" &
    "      address = \"a8Other\")\n"
  PointerSource = "import repro_profile\n\nprofile \"a8Pointer\":\n  resources:\n" &
    "    fsSystemFile(path = \"/etc/repro/a8-pointer\", content = \"pointer\\n\",\n" &
    "      address = \"a8Pointer\")\n"
    ## Step 8's profile: a source profile with the producer's pin, which the
    ## plain apply compiles and applies, so a build that does not act on
    ## the untrusted-pointer route writes ``/etc/repro/a8-pointer``.

let engine = getEnv("REPRO_ADDON_ENGINE_CLOSURE")

const Watcher = """
while true; do
  for p in $(pgrep -x 'nim|gcc|cc1|cc' 2>/dev/null) $(pgrep -f 'bin/nim ' 2>/dev/null); do
    u=$(awk '/^Uid:/ {print $2}' /proc/$p/status 2>/dev/null)
    n=$(cat /proc/$p/comm 2>/dev/null)
    [ -n "$u" ] && echo "$p $u $n" >> /root/compilers.log
  done
  sleep 0.2
done
"""

type Tick = object
  exitCode: int
  outcome, errorCode, message, output: string

proc tick(g: Guest; signer: PeerKeypair; m: var DeployManifest): Tick =
  ## Sign ``m``, put it in the guest and run one engine tick over it.
  signManifest(signer, m)
  let wire = encodeManifest(m)
  var bytes = newString(wire.len)
  for i, b in wire: bytes[i] = char(b)
  let name = "m" & $m.sequence & "-" & $epochTime().int64 & ".rdm"
  writeFile(g.runDir / name, bytes)
  g.copyTo(g.runDir / name, "/root/" & name)
  let r = g.exec(engine & "/bin/repro deploy-agent --target " & Target &
    " --manifest /root/" & name & " --allowed-signers " &
    "/etc/repro/anchors/deploy-signers.anchors --state-dir " & StateDir &
    " --host " & CompileHost, timeoutSec = 3600)
  result.exitCode = r.exitCode
  result.output = r.stdout & r.stderr
  let st = g.exec("cat " & Status)
  if st.exitCode == 0:
    try:
      let j = parseJson(st.stdout)
      result.outcome = j{"outcome"}.getStr()
      result.errorCode = j{"errorCode"}.getStr()
      result.message = j{"message"}.getStr()
    except CatchableError:
      discard

proc manifestOf(sequence: uint64; text: string; withBlock = true): DeployManifest =
  result = DeployManifest(target: Target, sequence: sequence,
    deploymentId: "a8-engine-" & $sequence, profileText: text)
  if withBlock:
    result.issuedAt = uint64(getTime().toUnix())
    result.maxAgeSeconds = 86_400

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  # Which engine this verdict is about: the store path of the closure the
  # guest ran (REPRO_ADDON_ENGINE_CLOSURE), so a red run under a mutated
  # engine and a green run under the tree's own are told apart by their
  # records alone.
  record["engineClosure"] = %engine
  g.installEngineClosure(engine)
  let (ok, anchors) = g.bootstrapAddonWithAnchors(repro, step)
  if not ok: return
  let signer = anchors.deploySignerKeys[0]
  let marker = canonicalFile("/etc/repro/a8-engine-marker", "x")
  let notWritten = proc(): bool =
    g.exec("test -e /etc/repro/a8-engine-marker").exitCode != 0

  # 1. No attestation block; the bundle alone.
  var v1 = manifestOf(1, marker, withBlock = false)
  let t1 = g.tick(signer, v1)
  step("a v1 manifest is rejected", t1.errorCode == "attestations_required" and
       notWritten(), $t1)
  var bundle = manifestOf(2, marker, withBlock = false)
  bundle.profileFiles = @[ProfileFile(path: "locks/x.lock", content: "x\n")]
  let t2 = g.tick(signer, bundle)
  step("a bundle-only v3 manifest is rejected",
       t2.errorCode == "attestations_required" and notWritten(), $t2)

  # 2. Freshness.
  var stale = manifestOf(3, marker)
  stale.issuedAt = uint64(getTime().toUnix() - 7200)
  stale.maxAgeSeconds = 600
  let t3 = g.tick(signer, stale)
  step("a stale manifest is aoStale", t3.outcome == "aoStale" and notWritten(),
       $t3)
  var future = manifestOf(4, marker)
  future.issuedAt = uint64(getTime().toUnix() + 7200)
  let t4 = g.tick(signer, future)
  step("a manifest issued in the future is aoStale (issued_in_future)",
       t4.errorCode == "issued_in_future" and notWritten(), $t4)

  # 3. The management path.
  var sshd = manifestOf(5, canonicalFile("/etc/ssh/sshd_config.d/a8.conf",
                                         "PermitRootLogin yes"))
  let t5 = g.tick(signer, sshd)
  step("an sshd drop-in is refused", "EAddOnManagementPath" in t5.message and
       g.exec("test -e /etc/ssh/sshd_config.d/a8.conf").exitCode != 0, $t5)

  # 4. The compiled-profile pin.
  let pin = producerCompile(engine, Source, files = Bundle)
  record["compiledProfilePin"] = %pin.digest
  var unpinned = manifestOf(6, Source)
  unpinned.profileFiles = Bundle
  let t6 = g.tick(signer, unpinned)
  step("a source profile without a pin is refused",
       "pins no digest" in t6.message and
       g.exec("test -e /etc/repro/a8-engine").exitCode != 0, $t6)
  var wrong = manifestOf(7, Source)
  wrong.profileFiles = Bundle
  wrong.compiledProfile = producerCompile(engine, OtherSource)
  let t7 = g.tick(signer, wrong)
  step("a pin for other output is a digest mismatch",
       "digest mismatch" in t7.message and
       g.exec("test -e /etc/repro/a8-engine").exitCode != 0, $t7)

  # 5. A closure digest for an action nothing realises.
  var extra = manifestOf(8, marker)
  extra.closureDigests = @[ClosureDigest(actionId: "a8-not-realised",
    digest: "blake3:" & repeat('0', 64))]
  let t8 = g.tick(signer, extra)
  step("a closure digest for an unrealised action is refused",
       "closure digest" in t8.message and notWritten(), $t8)

  # 6. The pinned source profile, compiled unprivileged.
  discard g.run("cat > /root/watch.sh <<'EOS'\n" & Watcher & "EOS\n")
  discard g.run("rm -f /root/compilers.log")
  g.startGuestSession("sh /root/watch.sh", "/root/watch.group")
  var good = manifestOf(9, Source)
  good.profileFiles = Bundle
  good.compiledProfile = pin
  let t9 = g.tick(signer, good)
  g.stopGuestSession("/root/watch.group")
  let seen = g.exec("sort -u -k1,1 /root/compilers.log 2>/dev/null").stdout
  record["compilerProcesses"] = %seen
  var lines, root: seq[string]
  for l in seen.splitLines():
    let f = l.splitWhitespace()
    if f.len < 3: continue
    lines.add(l)
    if f[1] == "0": root.add(l)
  step("vacuity guard: compiler processes were observed", lines.len > 0, seen)
  step("no compiler ran as UID 0", root.len == 0, root.join("\n"))
  step("the pinned source profile is applied", t9.outcome == "aoApplied" and
       g.exec("cat /etc/repro/a8-engine").stdout == "engine\n",
       $t9 & "\n" & t9.output)

  # 7. A later sequence signed earlier than the one applied.
  var replay = manifestOf(10, marker)
  replay.issuedAt = good.issuedAt - 60
  let t10 = g.tick(signer, replay)
  step("an older issuedAt than the last accepted is aoStale " &
       "(issued_at_regressed)", t10.errorCode == "issued_at_regressed" and
       notWritten(), $t10)

  # 8. An untrusted add-on state-directory pointer (spec §9, decision 29).
  # Made writable by its group, as root, the pointer can no longer be
  # trusted to say where the add-on's state is; the engine's agent must
  # refuse the tick (exit 2, nothing applied) rather than read it as "no
  # add-on here" and take the plain apply. The profile is a pinned source
  # profile the plain apply can compile and apply, so the refusal is the
  # only thing between it and /etc/repro/a8-pointer. The pointer is put
  # back exactly as it was afterwards. Falsifier: an engine built with
  # engine-agent-pointer-refusal-unwired, whose CLI does not act on the
  # route: the tick takes the plain apply, which writes
  # /etc/repro/a8-pointer (the step's "nothing was applied" fails, and the
  # record's pointerTick shows the apply).
  const Pointer = "/var/lib/repro/addon-state-dir"
  let had = g.exec("test -f " & Pointer).exitCode == 0
  if not had:
    discard g.run("printf '%s\n' " & DefaultStateDir & " > " & Pointer &
                  " && chmod 0644 " & Pointer)
  discard g.run("chmod g+w " & Pointer)
  var untrusted = manifestOf(11, PointerSource)
  untrusted.compiledProfile = producerCompile(engine, PointerSource)
  let t11 = g.tick(signer, untrusted)
  discard g.run(if had: "chmod g-w " & Pointer else: "rm -f " & Pointer)
  let pointerWritten = g.exec("test -e /etc/repro/a8-pointer").exitCode == 0
  record["pointerTick"] = %($t11.exitCode & " " & $t11 & "\n" & t11.output &
    "\n/etc/repro/a8-pointer written: " & $pointerWritten)
  step("an untrusted state-directory pointer refuses the engine's tick",
       t11.exitCode == 2 and "pointer is not trusted" in t11.output, $t11.exitCode &
       "\n" & t11.output)
  step("an untrusted state-directory pointer: nothing was applied",
       not pointerWritten, $t11)

suite Gate:
  test "the engine's deploy-agent on an add-on host enforces every A8 rule":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    elif engine.len == 0:
      echo "FAIL: REPRO_ADDON_ENGINE_CLOSURE is not set"
      check false
    else:
      check gateMain(Gate, body, bootstrap = false, diskGiB = 20).len == 0
