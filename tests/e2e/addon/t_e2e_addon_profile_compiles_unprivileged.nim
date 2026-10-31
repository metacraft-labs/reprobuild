## Gate ``e2e_addon_profile_compiles_unprivileged`` (milestone A8; spec
## §9.1; threat model G25, F2).
##
## A manifest ships its profile as Nim source. The host's profile compiler
## is the full reprobuild engine (a Nix closure of it, copied into the
## guest, named by ``REPRO_ADDON_ENGINE_CLOSURE``); the fetch unit runs it
## (``repro deploy-agent compile-profile``) and stages the canonical text
## it produces, and the apply unit applies that text -- only because it
## hashes to the digest the producer signed for its own compile of the same
## source with the same engine on the test host (``producerCompile``; the
## compile is deterministic across the two machines). A watcher started
## before the tick samples every compiler process (``nim``, ``gcc``,
## ``cc1``) with its UID (``/proc/<pid>/status``) and its control group
## (the ``systemd-cgls`` view, read from ``/proc/<pid>/cgroup``): at least
## one is seen (vacuity guard), every one runs in
## ``repro-agent-fetch.service`` under its dynamic user, and none runs in
## the apply unit or as UID 0. The compiled file is applied.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=agent-compiles-in-apply``):
## the apply unit compiles the source itself (the reused single-process
## hook's resolver) and a compiler shows up as UID 0 in the apply unit: red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and ``REPRO_ADDON_ENGINE_CLOSURE``
## (a store path holding ``bin/reprobuild`` built from this tree).
##
## *Mocking.* None: the real engine compiles the real profile.

import std/[json, os, osproc, strutils, unittest]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./agent_e2e_support

const
  Gate = "e2e_addon_profile_compiles_unprivileged"
  Source = "import repro_profile\n\nprofile \"a8Compiled\":\n  resources:\n" &
    "    fsSystemFile(path = \"/etc/repro/a8-compiled\", content = \"compiled\\n\",\n" &
    "      address = \"a8File\")\n"

let engine = getEnv("REPRO_ADDON_ENGINE_CLOSURE")

proc installEngine(g: Guest) = g.installEngineClosure(engine)

const Watcher = """
while true; do
  for p in $(pgrep -x 'nim|gcc|cc1|cc|nim_dbg' 2>/dev/null) $(pgrep -f 'bin/nim ' 2>/dev/null); do
    u=$(awk '/^Uid:/ {print $2}' /proc/$p/status 2>/dev/null)
    c=$(cat /proc/$p/cgroup 2>/dev/null | tr '\n' ' ')
    n=$(cat /proc/$p/comm 2>/dev/null)
    [ -n "$u" ] && echo "$p $u $n $c" >> /root/compilers.log
  done
  sleep 0.2
done
"""

proc body(g: Guest; repro: string; step: StepFn; record: JsonNode;
          producer: var Producer) =
  discard g.run("cat > /root/watch.sh <<'EOS'\n" & Watcher & "EOS\n")
  discard g.run("rm -f /root/compilers.log; setsid nohup sh /root/watch.sh " &
                ">/dev/null 2>&1 & echo started")
  # The producer compiles the same source with the same engine on this
  # machine and pins the digest (B1): the guest's compile reproducing it is
  # the cross-host determinism check (x86_64 producer, Debian/Ubuntu guest).
  let pin = producerCompile(engine, Source)
  record["compiledProfilePin"] = %pin.digest
  record["compilerRevision"] = %pin.compilerRevision
  discard producer.publish(PublishSpec(sequence: 1, profileText: Source,
    compiledProfile: pin))
  let t = g.tickUnits(timeoutSec = 2400)
  discard g.exec("pkill -f /root/watch.sh")
  record["tick"] = %($t)
  let seen = g.exec("sort -u -k1,1 /root/compilers.log 2>/dev/null").stdout
  record["compilerProcesses"] = %seen
  var lines: seq[string]
  for l in seen.splitLines():
    if l.strip().len > 0: lines.add(l)
  step("vacuity guard: compiler processes were observed", lines.len > 0, seen)
  var bad: seq[string]
  for l in lines:
    let f = l.splitWhitespace()
    if f.len < 4: continue
    let uid = f[1]
    let cg = f[3 .. ^1].join(" ")
    if uid == "0" or "repro-agent-apply" in cg or
        "repro-agent-fetch.service" notin cg:
      bad.add(l)
  step("every compiler ran in the fetch unit under its dynamic user, none " &
       "as UID 0 or in the apply unit", bad.len == 0, bad.join("\n"))
  # Compiled under the unit's state directory, which systemd mounts noexec
  # for a dynamic user and the unit's ExecPaths= makes exec-capable: the
  # compiled profile binary is there, kept for the next tick.
  step("the compile ran under the fetch unit's state directory", g.exec(
       "ls /var/lib/private/repro-agent-fetch/compile/state/profile-cache/bin/*/profile-build").exitCode == 0,
       g.exec("find /var/lib/private/repro-agent-fetch -maxdepth 3").stdout)
  step("the compiled profile was applied", t.outcome == "aoApplied" and
       g.exec("cat /etc/repro/a8-compiled").stdout == "compiled\n",
       $t & "\n" & t.fetchLog & t.applyLog)

suite Gate:
  test "a source profile is compiled only by the unprivileged fetch unit":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    elif engine.len == 0:
      echo "FAIL: REPRO_ADDON_ENGINE_CLOSURE is not set"
      check false
    else:
      check gateMain(Gate, body, diskGiB = 20,
        extraFlags = " --profile-compiler " & engine & "/bin/reprobuild",
        beforeBootstrap = installEngine).len == 0
