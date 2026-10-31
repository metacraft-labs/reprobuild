## Gate ``e2e_addon_reproos_service_parity`` (milestone A12; ReproOS Add-On
## Mode §8.3, §13 decision 31).
##
## The reference activities (``fixtures/reference_services/system.nim``:
## ``vaultwarden`` and ``ethereum_validator``) are realised twice from the
## same profile source, the same pins, the same packages and the same
## secrets, on two guests of the same base booted for this run:
##
## - **add-on**: the stock image bootstrapped in add-on mode with the deploy
##   agent, the profile compiled by the producer (``compile-profile
##   --system-mode addOn``) and applied by the agent's units;
## - **full**: the same stock image, *re-identified as ReproOS for this
##   test only*, with the full engine applying the profile itself
##   (``repro infra apply --profile system.nim``, the host registry beside it
##   selecting ``system: {mode: full, activities: [...]}``). That is the
##   full realisation the engine has (decision 31): every resource written
##   in place, the secrets materialised from the host's own envelope. It is
##   not a ReproOS image and not the per-generation ``/etc`` farm, which
##   this gate does not claim to cover.
##
## *Re-identification is test-bed only.* The guest's ``/etc/os-release``
## is left as the distribution wrote it. The full engine is told the base
## is ReproOS only through ``REPRO_OS_RELEASE_PATH`` pointing at a file the
## test bed writes (``/etc/repro-testbed/os-release-reproos``), on the
## command lines of this gate. The gate checks both halves: the real
## ``os-release`` still names the distribution, and the same apply
## WITHOUT the override is refused with ``EAddOnModeMismatch`` before
## anything is written (negative control).
##
## *What is compared.* For every resource both realisations applied, the
## file it renders, read as a service reads it: units under
## ``/etc/systemd/system``, tmpfiles and sysusers fragments, ``/etc``
## configuration files, and the materialised secrets -- the bytes (SHA-256,
## following a link), the mode and the owner of what the path resolves to,
## and the kind of the path itself (a file or a link). Plus systemd's view
## of each unit (``FragmentPath``, ``DropInPaths``, ``LoadState``,
## ``UnitFileState``, ``ActiveState``) and the health of each unit through
## the same probe code on both guests (``repro system addon probe``), and
## for the chain the beacon node's head moving past genesis. A difference
## fails the gate unless the ``add-on-debian`` realisation profile lists it
## as ignored with a reason (``addOnDebianProfile().realisationDifferences``);
## the record lists each difference with the entry that excused it.
## Vacuity guards: at least one file of every compared kind, every
## compared file non-empty on both sides, and every unit active on both.
##
## Falsifying mutation (``REPRO_ADDON_MUTATION=addon-unit-renders-differently``,
## a build of the add-on artefact whose switch appends one comment line to
## every unit it writes): the unit bytes differ on the add-on guest, no
## realisation difference excuses them, and the gate is red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``, ``REPRO_ADDON_ENGINE_CLOSURE`` (the
## full engine, built from this tree) and ``REPRO_A12_PACKAGES`` (see
## ``reference_services``). Bases: ``REPRO_ADDON_BASES``.
##
## *Mocking.* None: real images, real packages, a real chain, the real
## agent, engine and cache.

import std/[json, os, sets, strutils, tables, times, unittest]

import repro_test_support/reasoned_skip
import repro_infra
import repro_profile
import repro_profile_compile/addon_realisation
import repro_addon/generation0
from repro_addon/addon_apply import targetPathOf
import repro_peer_cache/auth as peerAuth

import ./addon_testbed
import ./agent_e2e_support
import ./cache_e2e_support
import ./reference_services

const
  Gate = "e2e_addon_reproos_service_parity"
  ReidentifiedOsRelease = "/etc/repro-testbed/os-release-reproos"
  OsReleaseOverride = "REPRO_OS_RELEASE_PATH"
  RefDir = "/root/reference-services"

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc enginePath(engine: string): string = engine / "bin" / "reprobuild"

type Observed = object
  path, pathKind, sha256, mode, owner: string

proc observe(g: Guest; paths: seq[string]): Table[string, Observed] =
  ## Each path as a reader sees it: the path's own kind (`stat` without
  ## following), then what it resolves to: bytes, mode and owner.
  var script = ""
  for p in paths:
    script.add("p=" & quoteShell(p) & "; if [ -L \"$p\" ]; then k=link; " &
      "elif [ -f \"$p\" ]; then k=file; else k=missing; fi; " &
      "if [ -e \"$p\" ]; then s=$(sha256sum < \"$p\" | cut -c1-64); " &
      "m=$(stat -L -c %a \"$p\"); o=$(stat -L -c %U:%G \"$p\"); " &
      "else s=-; m=-; o=-; fi; echo \"$p|$k|$s|$m|$o\"\n")
  for line in g.run(script).splitLines():
    let f = line.split('|')
    if f.len == 5:
      result[f[0]] = Observed(path: f[0], pathKind: f[1], sha256: f[2],
                              mode: f[3], owner: f[4])

proc renderedPaths(sp: SystemProfile): seq[(string, string)] =
  ## (kind, path) for every file the profile's resources render, at the
  ## path both realisations derive it from (`targetPathOf`), and every
  ## materialised secret.
  for r in sp.resources:
    let p = targetPathOf(r)
    if p.len > 0: result.add(($r.kind, p))
  for d in sp.secretFiles:
    result.add(("secrets.secretFile", SecretsRunRoot & "/" & d.service & "/" &
                d.name))

proc unitView(g: Guest; unit: string): string =
  g.run("systemctl show -p FragmentPath -p DropInPaths -p LoadState " &
        "-p UnitFileState -p ActiveState " & quoteShell(unit)).strip()

proc excusedBy(rp: RealisationProfile; kind, aspect: string): string =
  ## The realisation difference that excuses ``aspect`` of ``kind``, or "".
  for d in rp.realisationDifferences:
    if d.field == kind & "." & aspect: return d.field & " -- " & d.reason
  ""

proc body(add, full: Guest; addRepro, engine: string; step: StepFn;
          record: JsonNode) =
  let work = add.runDir / "a12"
  createDir(work)
  let pk = refPackages(work)
  record["packages"] = packageSha256s(pk)
  let cache = add.startCache()
  defer: cache.stop()
  let kp = peerAuth.generateKeypair()
  # --- the add-on guest: bootstrapped with the agent and the cache.
  let bs = add.bootstrapWithAgent(addRepro, step, cacheUrl = cache.guestUrl,
    cachePublishers = @[hexKey(kp.publicKey)])
  if not bs.ok: return
  defer: bs.producer.stop()
  # --- the full guest: the engine, the cache it trusts, re-identified.
  full.installEngineClosure(engine)
  discard full.run("mkdir -p /etc/repro /etc/repro-testbed && " &
    "printf 'ID=reproos\\nNAME=\"ReproOS (re-identified by the test bed)\"\\n" &
    "VERSION_ID=test\\nREPRO_TESTBED_REIDENTIFIED=1\\n' > " &
    ReidentifiedOsRelease)
  writeFile(work / "caches.conf", renderCachesConf(cache.guestUrl,
                                                   @[hexKey(kp.publicKey)]))
  full.copyTo(work / "caches.conf", "/etc/repro/caches.conf")
  let realOsRelease = full.run(". /etc/os-release; echo $ID").strip()
  step("the full guest's own os-release still names the distribution",
       realOsRelease in ["debian", "ubuntu"], realOsRelease)
  let env = OsReleaseOverride & "=" & ReidentifiedOsRelease & " "
  let eng = enginePath(engine)
  # --- the shared inputs: one network, one set of pins, one compile.
  let net = makeTestnet(pk, work)
  record["genesisTime"] = %net.genesisTime
  var pins = basePins(pk, net)
  let addC = compileReference(engine, pins, "addOn", ReferenceActivities)
  let fullC = compileReference(engine, pins, "full", ReferenceActivities)
  step("the two realisations compile to the same canonical text and edges",
       addC.canonical == fullC.canonical and addC.actionsJson == fullC.actionsJson,
       "")
  let digests = publishAll(cache, kp, pk, net, pins, addC.actions)
  # --- the same secrets on both.
  let jwt = jwtHex()
  for (g, verb) in [(add, addRepro & " system addon secret put"),
                    (full, env & eng & " system secret put")]:
    putReferenceSecrets(g, verb, jwt, [DefaultValidatorUnit], step)
    provisionWallet(g, net)
  # --- realise on the add-on guest.
  discard bs.producer.publish(PublishSpec(sequence: 1,
    profileText: addC.canonical, buildActions: addC.actions,
    closureDigests: digests))
  let t1 = add.tickUnits()
  let allUnits = ["vaultwarden.service", "eth-execution.service",
                  "eth-beacon.service", DefaultValidatorUnit]
  step("the add-on guest applies the reference activities",
       t1.outcome == "aoApplied", $t1 & "\n" & t1.fetchLog & t1.applyLog &
       "\n" & add.serviceJournal(allUnits))
  # --- realise on the full guest: negative control first.
  writeFile(work / "system.nim", readFile(ProfileSource))
  writeFile(work / PinsModule, pinsSource(pins))
  writeFile(work / "home.nim", readFile(FixtureDir / "home.nim"))
  discard full.run("mkdir -p " & RefDir)
  for f in ["system.nim", PinsModule, "home.nim"]:
    full.copyTo(work / f, RefDir / f)
  let applyCmd = eng & " infra apply --profile " & RefDir & "/system.nim " &
    "--host " & AgentTarget & " --no-preview"
  let refused = full.exec(applyCmd, timeoutSec = 1800)
  step("without the test bed's re-identification the full apply is refused",
       refused.exitCode != 0 and "EAddOnModeMismatch" in
         refused.stdout & refused.stderr, refused.stdout & refused.stderr)
  step("... and wrote nothing", full.exec("test -e /etc/systemd/system/" &
       "vaultwarden.service").exitCode != 0, "")
  let applied = full.exec(env & applyCmd, timeoutSec = 3600)
  step("the full guest applies the reference activities",
       applied.exitCode == 0, applied.stdout & applied.stderr & "\n" &
       full.serviceJournal(allUnits))
  # --- compare.
  let sp = parseSystemProfile(fullC.canonical)
  let rendered = renderedPaths(sp)
  var paths: seq[string]
  for (_, p) in rendered: paths.add(p)
  let a = add.observe(paths)
  let f = full.observe(paths)
  let rp = addOnDebianProfile()
  var diffs = newJArray()
  var kinds: HashSet[string]
  var unexcused = 0
  for (kind, p) in rendered:
    kinds.incl kind
    let x = a.getOrDefault(p)
    let y = f.getOrDefault(p)
    step("present and non-empty on both: " & p,
         x.pathKind != "missing" and y.pathKind != "missing" and
         x.sha256 != "-" and y.sha256 != "-", $x & " / " & $y)
    for (aspect, av, fv) in [("bytes", x.sha256, y.sha256),
                             ("mode", x.mode, y.mode),
                             ("owner", x.owner, y.owner),
                             ("representation", x.pathKind, y.pathKind)]:
      if av != fv:
        let why = excusedBy(rp, kind, aspect)
        diffs.add(%*{"path": p, "kind": kind, "aspect": aspect,
                     "addOn": av, "full": fv, "excusedBy": why})
        if why.len == 0: inc unexcused
  record["differences"] = diffs
  step("every difference is a listed realisation difference",
       unexcused == 0, $diffs)
  step("every compared kind has at least one file",
       kinds.len == 5, $kinds)
  # --- systemd's view and health.
  var health = newJObject()
  for r in sp.resources:
    if r.kind != srkSystemdSystemUnit: continue
    let va = add.unitView(r.suName)
    let vf = full.unitView(r.suName)
    step("systemd sees " & r.suName & " the same way", va == vf,
         va & "\n---\n" & vf)
    step(r.suName & " is active on both", "ActiveState=active" in va and
         "ActiveState=active" in vf, va & "\n---\n" & vf)
    if r.suHealthCheck.len > 0 and r.suHealthCheck != "active":
      var ok: array[2, bool]
      for i, (g, probe) in [(add, addRepro & " system addon probe "),
                            (full, eng & " system addon probe ")]:
        let deadline = epochTime() + 300
        while epochTime() < deadline:
          if g.exec(probe & quoteShell(r.suHealthCheck)).exitCode == 0:
            ok[i] = true
            break
          sleep(3000)
      health[r.suName] = %*{"check": r.suHealthCheck, "addOn": ok[0],
                            "full": ok[1]}
      step(r.suName & " passes " & r.suHealthCheck & " on both",
           ok[0] and ok[1], $health[r.suName])
  record["health"] = health
  let slotA = add.waitHeadSlot(6, 600)
  let slotF = full.waitHeadSlot(6, 600)
  step("both chains produce blocks past genesis", slotA and slotF,
       $add.headSlot() & " / " & $full.headSlot())

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var add, full: Guest
  let steps = newJArray()
  var fails: seq[string]
  let step: StepFn = proc(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    let engine = engineFromEnv()
    record["engine"] = %engine
    add = newGuest(b, diskGiB = 16, cpus = 4, memoryMB = 6144)
    full = newGuest(b, diskGiB = 16, cpus = 4, memoryMB = 6144)
    add.boot()
    full.boot()
    add.prepareBase()
    full.prepareBase()
    let (repro, sha) = add.installArtefact()
    record["artefactSha256"] = %sha
    body(add, full, repro, engine, step, record)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    for g in [add, full]:
      if g != nil:
        record["log-" & g.name] = %g.log
        g.destroy()
  fails

suite Gate:
  test "the reference activities realise byte-identically on add-on and full":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      var fails: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        fails.add(f)
      for f in fails: echo "FAIL ", f
      check fails.len == 0
