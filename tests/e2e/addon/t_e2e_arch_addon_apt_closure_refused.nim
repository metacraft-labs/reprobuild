## Gate ``e2e_arch_addon_apt_closure_refused`` (spec ReproOS-Add-On-Mode
## §8.1, §8.3 *Services on Arch*, §8.4, §9.1, §13 decisions 92 and 131).
##
## On each Arch guest a ``.deb`` closure (a unit carrying an
## ``aptClosureLock``) is refused with ``EAddOnOutOfScope`` naming
## "``.deb`` closures are not supported on Arch", and nothing is realised
## or written. Two independent checks refuse it, and the gate has legs for
## each:
##
## *The realisation legs* (the engine, installed in the guest from the Nix
## closure ``REPRO_ADDON_ENGINE_CLOSURE`` built from this tree):
##
## 1. ``reprobuild infra plan`` of a ``.nim`` system profile through a host
##    registry whose entry for the host is ``system: addOn``: on the guest's
##    real ``/etc/os-release`` the registry realises ``add-on-arch``, and
##    the plan is refused. Control: the same unit as a Reprobuild store
##    package plans, ``realised add-on-arch``.
## 2. The deploy agent's own compile, as the fetch unit runs it:
##    ``reprobuild deploy-agent compile-profile --stdio --system-mode addOn
##    --system-base this-host`` exits 1 with the refusal. Control: the store
##    profile compiles.
##
## *The apply-side legs* (the static add-on binary): ``repro infra plan``
## and ``repro infra apply`` of the canonical text carrying the lock are
## refused before anything is observed or written -- the fingerprint, the
## ledger, ``current``, the store's prefix list are unchanged and no
## ``.deb`` cache directory appears. Control: the same unit as a store
## package plans and applies.
##
## The record carries a verdict per group (``realisationLegs``,
## ``applySideLegs``) beside the gate's.
##
## Falsifying mutations (``REPRO_ADDON_MUTATION``):
##
## * ``arch-realisation-accepts-deb-closure``: an engine whose
##   ``add-on-arch`` keeps ``aptClosureLock``. The red run's
##   ``REPRO_ADDON_ENGINE_CLOSURE`` is the engine built with it:
##   ``nix build --no-link --print-out-paths --impure --expr
##   '((builtins.getFlake (toString ./.)).packages.${builtins.currentSystem}
##   .reprobuild).overrideAttrs (_: { REPRO_ADDON_MUTATION =
##   "arch-realisation-accepts-deb-closure"; })'`` (``scripts/build_apps.sh``
##   compiles the variable in). The realisation legs go red; the gate is red.
## * ``arch-apply-skips-deb-closure-check``: a static binary without the
##   apply-side refusal. The realisation legs stay green -- the realisation
##   alone refuses every profile that is compiled -- and the apply-side
##   legs, which hand the binary a canonical text no realisation compiled,
##   go red.
##
## The lock is a real one (the realiser's test fixture: Debian trixie
## armhf, ``prometheus-node-exporter``); its members are never fetched,
## because every refusal comes before realisation.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and ``REPRO_ADDON_ENGINE_CLOSURE``
## (``just e2e_arch_addon_apt_closure_refused``).
## Bases: ``REPRO_ADDON_BASES`` (default ``arch-btrfs-amd64,arch-ext4-amd64``).
##
## *Mocking.* None: real Arch guests, the real engine and static binary.

import std/[base64, json, os, strutils, unittest]

import repro_test_support/reasoned_skip

import ./agent_e2e_support
import ./arch_gate_support

const LockText = staticRead("../../../libs/repro_dsl_stdlib/tests/fixtures/" &
  "apt_closure/debian-trixie-20261001-armhf-node-exporter.lock")

proc closureProfile(): string =
  addOnStanza() &
  "systemd.systemUnit {\n" &
  "  floorExceptions = [\"serviceFloor: a test fixture that is refused before it runs\"]\n" &
  "  name = \"repro-addon-deb-fixture.service\"\n" &
  "  content = \"[Unit]\nDescription=a .deb closure on Arch\n[Service]\n" &
    "ExecStart=/usr/bin/prometheus-node-exporter\n\"\n" &
  "  enabled = false\n" &
  "  aptClosureLock = \"" & LockText & "\"\n}\n"

proc storeProfile(reproExe: string): string =
  addOnStanza() & fixtureUnit(reproExe)

const
  EngineHost = "ar1-arch"
    ## The host the registry declares ``system: addOn``.
  EngineDir = "/root/ar1-engine"
    ## The engine's sandbox in the guest: its home, profile and state
    ## directories, away from the add-on's own state and store.
  RegistryProfile = "import repro_profile\n\nprofile \"ar1Registry\":\n" &
    "  hosts:\n    \"" & EngineHost & "\":\n      system: addOn\n"

proc nimUnit(lockLine, execStart: string): string =
  ## A ``.nim`` system profile with one unit; ``lockLine`` (empty or the
  ## ``aptClosureLock`` argument) decides whether it is a ``.deb`` closure.
  "import repro_profile\n\nconst debLock = staticRead(\"deb.lock\")\n\n" &
  "profile \"ar1Apt\":\n  resources:\n" &
  "    systemdSystemUnit(name = \"repro-addon-deb-fixture.service\",\n" &
  "      content = \"[Service]\\nExecStart=" & execStart & "\\n\",\n" &
  lockLine &
  "      floorExceptions = @[\"serviceFloor: a test fixture that is " &
    "never started\"],\n      address = \"debFixture\")\n" &
  "discard debLock\n"

proc debNim(): string =
  nimUnit("      aptClosureLock = debLock,\n",
          "/usr/bin/prometheus-node-exporter")

proc storeNim(reproExe: string): string = nimUnit("", reproExe & " --version")

proc engineEnv(engine: string): string =
  ## The engine's isolated environment in the guest (as the profile
  ## sandbox of the host-side tests sets it, ``profile_compile_edge_harness``).
  "env HOME=" & EngineDir & "/home XDG_CACHE_HOME=" & EngineDir & "/xdg-cache" &
  " XDG_STATE_HOME=" & EngineDir & "/xdg-state XDG_CONFIG_HOME=" & EngineDir &
  "/xdg-config XDG_DATA_HOME=" & EngineDir & "/xdg-data" &
  " REPRO_HOME_PROFILE_DIR=" & EngineDir & "/profile REPRO_HOME_STATE_DIR=" &
  EngineDir & "/home-state REPRO_STORE_ROOT=" & EngineDir & "/store" &
  " REPROBUILD_ACTION_CACHE_ROOT=" & EngineDir & "/action-cache " &
  engine & "/bin/reprobuild"

proc putGuestFile(g: Guest; name, guestPath, text: string) =
  writeFile(g.runDir / name, text)
  g.copyTo(g.runDir / name, guestPath)

proc stdioRequest(profile: string): string =
  ## The fetch unit's ``compile-profile --stdio`` input
  ## (``repro_addon/verified_compile``): the profile and its files, base64.
  $(%*{"profileText": base64.encode(profile), "profileFiles": [
    {"path": "deb.lock", "content": base64.encode(LockText)}]})

proc state(g: Guest; repro: string): string =
  ## What a refused plan or apply must leave as it is, beyond the
  ## fingerprint: the ledger copy, ``current``, the store's prefixes and
  ## whether a ``.deb`` cache exists.
  g.run("cat /var/lib/repro/system/addon-ledger; echo ---; " &
        "readlink /var/lib/repro/system/current; echo ---; " &
        "ls -1 /repro/store/prefixes/*/ 2>/dev/null; echo ---; " &
        "ls -d /var/cache/repro/apt 2>/dev/null; true")

proc runBase(b: BaseImage; record: JsonNode; engine: string): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  var realisationRed, applySideRed = false
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  proc realisationStep(name: string; ok: bool; detail: string) =
    if not ok: realisationRed = true
    step("[realisation] " & name, ok, detail)
  proc applySideStep(name: string; ok: bool; detail: string) =
    if not ok: applySideRed = true
    step("[apply side] " & name, ok, detail)
  proc refusedForArch(said: string): bool =
    "EAddOnOutOfScope" in said and
      ".deb` closures are not supported on Arch" in said
  try:
    g = newArchGuest(b)
    g.boot()
    g.prepareArchGuest()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    g.installEngineClosure(engine)
    record["engine"] = %engine
    if not g.bootstrapArch(repro, step).ok: return fails
    let exe = g.gen0ReproExe()

    let f0 = g.fingerprintArch(repro)
    let s0 = g.state(repro)
    proc unchanged(what: string; stepFn: StepFn) =
      let same = identityReport(f0, g.fingerprintArch(repro))
      stepFn(what & " wrote nothing (fingerprint)", same.ok, same.text)
      let s1 = g.state(repro)
      stepFn(what & " realised and committed nothing", s0 == s1,
             "before:\n" & s0 & "\nafter:\n" & s1)

    # The realisation legs.
    discard g.run("mkdir -p " & EngineDir & "/profile " & EngineDir & "/home")
    g.putGuestFile("ar1-home.nim", EngineDir & "/profile/home.nim",
                   RegistryProfile)
    g.putGuestFile("ar1-deb.lock", EngineDir & "/profile/deb.lock", LockText)
    g.putGuestFile("ar1-deb.nim", EngineDir & "/profile/deb.nim", debNim())
    g.putGuestFile("ar1-store.nim", EngineDir & "/profile/store.nim",
                   storeNim(exe))
    let eng = engineEnv(engine)
    proc enginePlan(module: string): ExecOut =
      g.exec("cd " & EngineDir & " && " & eng & " infra plan --state-dir " &
        EngineDir & "/infra-state --profile " & EngineDir & "/profile/" &
        module & " --host " & EngineHost, timeoutSec = 1800)
    let ep = enginePlan("deb.nim")
    record["enginePlanDeb"] = %(ep.stdout & ep.stderr)
    realisationStep("infra plan of a .nim profile with an aptClosureLock, " &
      "through a `system: addOn` registry entry, is refused",
      ep.exitCode == 1 and refusedForArch(ep.stderr) and
        "plan-id" notin ep.stdout,
      "exit " & $ep.exitCode & "\n" & ep.stdout & ep.stderr)
    unchanged("the refused engine plan", realisationStep)
    let epc = enginePlan("store.nim")
    realisationStep("control: the same unit as a store package plans, " &
      "realised add-on-arch", epc.exitCode == 0 and
        "realised add-on-arch" in epc.stdout,
      "exit " & $epc.exitCode & "\n" & epc.stdout & epc.stderr)

    proc agentCompile(name, profile: string): ExecOut =
      g.putGuestFile("ar1-" & name & ".json", EngineDir & "/" & name & ".json",
                     stdioRequest(profile))
      g.exec("cd " & EngineDir & " && " & eng & " deploy-agent " &
        "compile-profile --stdio --host " & EngineHost & " --platform " &
        "linux --arch x86_64 --system-mode addOn --system-base this-host < " &
        EngineDir & "/" & name & ".json", timeoutSec = 1800)
    let ac = agentCompile("deb-stdio", debNim())
    record["agentCompileDeb"] = %(ac.stdout & ac.stderr)
    realisationStep("the agent's compile (--system-base this-host) of the " &
      "aptClosureLock profile is refused", ac.exitCode == 1 and
        refusedForArch(ac.stderr) and "REPRO-COMPILED-PROFILE" notin ac.stdout,
      "exit " & $ac.exitCode & "\n" & ac.stdout & ac.stderr)
    unchanged("the refused agent compile", realisationStep)
    let acc = agentCompile("store-stdio", storeNim(exe))
    realisationStep("control: the agent's compile of the store package " &
      "profile succeeds", acc.exitCode == 0 and
        "REPRO-COMPILED-PROFILE" in acc.stdout,
      "exit " & $acc.exitCode & "\n" & acc.stderr)

    # The apply-side legs.
    for verb in ["plan", "apply"]:
      let r =
        if verb == "plan": g.planProfile(repro, "deb-" & verb, closureProfile())
        else: g.applyProfile(repro, "deb-" & verb, closureProfile())
      let said = r.stdout & r.stderr
      applySideStep(verb & " of an aptClosureLock unit is refused with " &
        "EAddOnOutOfScope", r.exitCode != 0 and refusedForArch(said),
        "exit " & $r.exitCode & "\n" & said)
      unchanged("the refused " & verb, applySideStep)

    let p = g.planProfile(repro, "store-plan", storeProfile(exe))
    applySideStep("control: the same unit as a store package plans",
      p.exitCode == 0, p.stdout & p.stderr)
    let a = g.applyProfile(repro, "store-apply", storeProfile(exe))
    applySideStep("control: the same unit as a store package applies",
      a.exitCode == 0, a.stdout & a.stderr)
    let un = g.exec(repro & " system addon uninstall")
    step("uninstall", un.exitCode == 0, un.stdout & un.stderr)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
    realisationRed = true
    applySideRed = true
  finally:
    record["steps"] = steps
    record["realisationLegs"] = %(if realisationRed: "red" else: "green")
    record["applySideLegs"] = %(if applySideRed: "red" else: "green")
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite "e2e_arch_addon_apt_closure_refused":
  test "a .deb closure is refused on Arch before anything is realised":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " &
           "e2e_arch_addon_apt_closure_refused)")
    elif getEnv("REPRO_ADDON_ENGINE_CLOSURE").len == 0:
      echo "FAIL: REPRO_ADDON_ENGINE_CLOSURE is not set (the realisation " &
        "legs need the engine built from this tree)"
      check false
    else:
      let engine = getEnv("REPRO_ADDON_ENGINE_CLOSURE")
      var failures: seq[string]
      for b in selectedArchBases():
        let record = archGateRecord("e2e_arch_addon_apt_closure_refused")
        record["base"] = %b.name
        let f = runBase(b, record, engine)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        echo "record: ", writeRecord("e2e_arch_addon_apt_closure_refused", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
