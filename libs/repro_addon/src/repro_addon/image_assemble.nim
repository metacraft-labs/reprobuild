## ``repro system addon image-assemble --payload <dir>``: the assembly boot
## of ``repro infra image`` (ReproOS Add-On Mode §6.5.2 step 5).
##
## The build host stages a payload into the image's root filesystem and
## boots the image once, with no network, under a oneshot unit that runs
## this verb as root. It has no preflight, bootstrap or apply code of its
## own: it runs §6.1's preflight, §6.2's bootstrap and the add-on apply
## ``repro infra apply`` runs (``runAddonApply``), in process -- the same
## procs the operator's verbs call -- then plans again and requires no
## ledger change, no transition and no drift. Then it removes everything the assembly added
## that the add-on does not own, puts back the first-boot state the boot
## consumed, writes ``result.json`` and returns; the unit's
## ``SuccessAction=poweroff`` / ``FailureAction=poweroff`` power the machine
## off either way.
##
## The payload directory (``AssemblyPayloadDir``) holds:
##
## - ``repro``: this binary (its digest is ``assembly.json``'s
##   ``binarySha256``, checked before anything else);
## - ``assembly.json``: the bootstrap options, the canonical profile's file
##   name, the upstream image's ``/etc/machine-id`` bytes and the SSH host
##   keys it shipped;
## - ``profile.txt``: the host profile's canonical text;
## - the anchor files the options name.
##
## ``result.json`` is the one file left there; the build host reads it with
## ``debugfs`` after QEMU exits and removes the directory.

import std/[algorithm, base64, json, os, strutils]

import repro_infra/state_dir

import ./addon_apply
import ./bootstrap
import ./fingerprint
import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./preflight
import ./store_root
from repro_deploy_agent/secrets import ensureRecipientKeyFile

const
  AssemblyPayloadDir* = ImageAssemblyDir
    ## Not under ``/var/lib/repro``: the preflight refuses a foreign occupant
    ## there (§6.1), and this directory is gone before the image is written.
  AssemblyUnitName* = "addon-image-assembly.service"
    ## Not ``repro-*``: the preflight refuses any such unit in the load path.
  AssemblyUnitPath* = "/etc/systemd/system/" & AssemblyUnitName
  AssemblyWantsLink* = "/etc/systemd/system/multi-user.target.wants/" &
                       AssemblyUnitName
  AssemblyDebCacheDir* = "/var/cache/repro/apt"
    ## ``apt_closure.AddOnAptDebCacheDir``: the staged ``.deb`` files.
  CloudInitDisabledMarker* = "/etc/cloud/cloud-init.disabled"
  AssemblyResultName* = "result.json"
  AssemblyConsoleTag* = "REPRO-IMAGE-ASSEMBLY:"
    ## Prefix of the lines written to the console, which the build host's
    ## serial log carries.

type
  AssemblySpec* = object
    ## ``assembly.json``.
    binarySha256*: string
    preflightFlags*: seq[string]   ## the bootstrap options as CLI flags
    profileFile*: string           ## "profile.txt"
    machineId*: string             ## the upstream /etc/machine-id bytes
    keepSshHostKeys*: seq[string]  ## /etc/ssh/ssh_host_* the image shipped
    stagedDebs*: seq[string]       ## file names under AssemblyDebCacheDir
    removeDebCacheParents*: seq[string]
      ## The directories the build host created for the cache, deepest
      ## first; removed when empty.

  AssemblyStep* = object
    name*: string
    ok*: bool
    detail*: string

  AssemblyResult* = object
    ok*: bool
    steps*: seq[AssemblyStep]
    planDigest*: string
    generationId*: string
    reproExe*: string
    ledgerSha256*: string
    storePrefixes*: seq[string]
    generation0Id*: string        ## bootstrap's generation
    assemblyMachineId*: string    ## the assembly boot's own machine id
    assemblySshHostKeys*: seq[string]
      ## ``<name> <sha256>`` of the SSH host public keys the assembly boot
      ## had: a device booted from the image must have none of them.

proc renderAssemblySpec*(s: AssemblySpec): string =
  $(%*{"schema": "reprobuild.addon.image-assembly.v1",
       "binarySha256": s.binarySha256, "preflightFlags": s.preflightFlags,
       "profileFile": s.profileFile,
       "machineIdBase64": base64.encode(s.machineId),
       "keepSshHostKeys": s.keepSshHostKeys, "stagedDebs": s.stagedDebs,
       "removeDebCacheParents": s.removeDebCacheParents})

proc parseAssemblySpec*(text: string): AssemblySpec =
  let j = parseJson(text)
  if j{"schema"}.getStr() != "reprobuild.addon.image-assembly.v1":
    raise newException(ValueError, "assembly.json: unknown schema " &
      j{"schema"}.getStr())
  result.binarySha256 = j["binarySha256"].getStr()
  for f in j["preflightFlags"]: result.preflightFlags.add f.getStr()
  result.profileFile = j["profileFile"].getStr()
  if result.profileFile.len == 0 or '/' in result.profileFile:
    raise newException(ValueError, "assembly.json: profileFile must be a " &
      "file name in the payload directory")
  result.machineId = base64.decode(j["machineIdBase64"].getStr())
  for k in j["keepSshHostKeys"]: result.keepSshHostKeys.add k.getStr()
  for d in j["stagedDebs"]: result.stagedDebs.add d.getStr()
  for d in j["removeDebCacheParents"]: result.removeDebCacheParents.add d.getStr()

proc renderAssemblyResult*(r: AssemblyResult): string =
  var steps = newJArray()
  for s in r.steps:
    steps.add %*{"name": s.name, "ok": s.ok, "detail": s.detail}
  $(%*{"schema": "reprobuild.addon.image-assembly-result.v1", "ok": r.ok,
       "steps": steps, "planDigest": r.planDigest,
       "generationId": r.generationId, "reproExe": r.reproExe,
       "ledgerSha256": r.ledgerSha256, "storePrefixes": r.storePrefixes,
       "generation0Id": r.generation0Id,
       "assemblyMachineId": r.assemblyMachineId,
       "assemblySshHostKeys": r.assemblySshHostKeys})

proc parseAssemblyResult*(text: string): AssemblyResult =
  let j = parseJson(text)
  if j{"schema"}.getStr() != "reprobuild.addon.image-assembly-result.v1":
    raise newException(ValueError, "result.json: unknown schema")
  result.ok = j["ok"].getBool()
  for s in j["steps"]:
    result.steps.add AssemblyStep(name: s["name"].getStr(),
      ok: s["ok"].getBool(), detail: s["detail"].getStr())
  result.planDigest = j["planDigest"].getStr()
  result.generationId = j["generationId"].getStr()
  result.reproExe = j["reproExe"].getStr()
  result.ledgerSha256 = j["ledgerSha256"].getStr()
  for p in j["storePrefixes"]: result.storePrefixes.add p.getStr()
  result.generation0Id = j{"generation0Id"}.getStr()
  result.assemblyMachineId = j{"assemblyMachineId"}.getStr()
  for k in j{"assemblySshHostKeys"}.getElems(): result.assemblySshHostKeys.add k.getStr()

proc planIsClean*(r: AddonApplyResult): string =
  ## "" when an add-on plan predicts nothing -- no ledger change, no service
  ## transition, no drift -- otherwise what it predicts.
  if r.ledgerDiff.len > 0:
    return "the plan after the apply still changes the ledger: " &
      r.ledgerDiff.join("; ")
  if r.transitions.len > 0:
    return "the plan after the apply still has " & $r.transitions.len &
      " service transition(s)"
  if r.drift.len > 0:
    return "the plan after the apply reports drift: " & r.drift.join(", ")
  ""

proc console(line: string) =
  ## The unit's standard output is `journal+console`: every line reaches
  ## the serial log the build host keeps.
  stdout.writeLine(AssemblyConsoleTag & " " & line)
  stdout.flushFile()

proc tail(s: string; n = 4000): string =
  if s.len <= n: s else: "..." & s[^n .. ^1]

proc removeIfPresent(path: string) =
  if symlinkExists(path) or fileExists(path):
    removeFile(path)
  elif dirExists(path):
    removeDir(path)

proc storePrefixesNow(): seq[string] =
  let dir = StoreRoot / "prefixes"
  if not dirExists(dir): return
  for kind, p in walkDir(dir):
    if kind in {pcDir, pcLinkToDir}:
      for k2, v in walkDir(p):
        if k2 in {pcDir, pcLinkToDir}: result.add v

proc cleanUp*(spec: AssemblySpec; payload: string; root = "/";
              rotateJournal = true) =
  ## Remove what the assembly added that the add-on does not own and put
  ## back the first-boot state the boot consumed (§6.5.2 step 5). ``root``
  ## is the system's root (``/`` in the assembly boot; a scratch tree in
  ## the unit test); ``payload`` is an absolute path.
  for d in spec.stagedDebs:
    removeIfPresent(root / AssemblyDebCacheDir / d)
  for d in spec.removeDebCacheParents:
    if dirExists(root / d):
      var empty = true
      for _ in walkDir(root / d): empty = false
      if empty: removeDir(root / d)
  removeIfPresent(root / AssemblyWantsLink)
  removeIfPresent(root / AssemblyUnitPath)
  for kind, p in walkDir(payload):
    if p.extractFilename != AssemblyResultName:
      removeIfPresent(p)
  # First-boot state: the machine id the image shipped (empty, or
  # "uninitialized", is what makes systemd treat the next boot as the
  # first), no SSH host key the image did not carry, no random seed and no
  # credential secret of this boot.
  when not mutated("image-keeps-first-boot-state"):
    writeFile(root / "etc/machine-id", spec.machineId)
    if dirExists(root / "etc/ssh"):
      for kind, p in walkDir(root / "etc/ssh"):
        let n = p.extractFilename
        if n.startsWith("ssh_host_") and n notin spec.keepSshHostKeys:
          removeIfPresent(p)
  else:
    # FALSIFYING MUTATION (see mutations.nim): an assembly that leaves the
    # assembly boot's machine id and SSH host keys in the image, so every
    # device boots with the same identity.
    discard
  removeIfPresent(root / "var/lib/systemd/random-seed")
  removeIfPresent(root / "var/lib/systemd/credential.secret")
  if rotateJournal:
    discard runHostTool(["/usr/bin/journalctl", "--rotate"], timeoutSec = 60)
    discard runHostTool(["/usr/bin/journalctl", "--vacuum-time=1s"],
                        timeoutSec = 60)

proc sshHostKeyDigests*(root = "/"): seq[string] =
  ## ``<name> <sha256>`` of every SSH host public key under ``/etc/ssh``,
  ## sorted: the identity a booted host must NOT share with its assembly.
  if dirExists(root / "etc/ssh"):
    for kind, p in walkDir(root / "etc/ssh"):
      let n = p.extractFilename
      if n.startsWith("ssh_host_") and n.endsWith(".pub"):
        result.add(n & " " & sha256OfFile(p))
  result.sort()

proc runImageAssembly*(payload: string; spec: AssemblySpec;
                       preflightInputs: PreflightInputs;
                       bootstrapOpts: BootstrapOptions): AssemblyResult =
  ## Steps 5a-5d of §6.5.2. Never raises: a failure is a red step.
  template step(n: string; body: untyped) =
    if result.steps.len == 0 or result.steps[^1].ok:
      var s = AssemblyStep(name: n)
      try:
        body
        s.ok = true
      except CatchableError as e:
        s.detail = e.msg
      result.steps.add s
      console(n & ": " & (if s.ok: "ok" else: "FAILED " & s.detail))
  var opts = bootstrapOpts
  step("preflight"):
    let r = runPreflight(preflightInputs)
    var failed: seq[string]
    for c in r.checks:
      if c.verdict != vPass: failed.add c.id & " (" & c.detail & ")"
    if not r.compatible:
      raise newException(CatchableError, "the preflight refuses this image: " &
        failed.join("; "))
    result.planDigest = r.digest
    opts.planDigest = r.digest
  step("bootstrap"):
    let b = runAddonBootstrap(opts)
    result.reproExe = b.reproExe
    result.generationId = b.generationId
    result.generation0Id = b.generationId
  when mutated("image-bakes-recipient-key"):
    # FALSIFYING MUTATION (see mutations.nim): an assembly that creates the
    # recipient key in the image, so every device flashed from it shares
    # one private key.
    discard ensureRecipientKeyFile(RecipientKeyPath)
  let profileText = try: readFile(payload / spec.profileFile)
                    except IOError: ""
  step("apply"):
    # What `repro infra apply --profile` runs on an add-on host
    # (`cli.runAddonGeneration`), in process.
    let r = runAddonApply(AddonApplyOptions(stateDir: DefaultStateDir,
      hostIdentity: readHostname(), userProfileText: profileText))
    if r.drift.len > 0:
      raise newException(CatchableError, "the apply left drift: " &
        r.drift.join(", "))
  step("plan"):
    # What `repro infra plan --profile` runs: it must predict nothing.
    let r = runAddonApply(AddonApplyOptions(stateDir: DefaultStateDir,
      hostIdentity: readHostname(), userProfileText: profileText,
      planOnly: true))
    let why = planIsClean(r)
    if why.len > 0: raise newException(CatchableError, why)
  step("record"):
    let stateDir = DefaultStateDir
    result.generationId = readCurrentGenerationId(stateDir)
    result.ledgerSha256 = sha256OfFile(ledgerCopyPath(stateDir))
    result.storePrefixes = storePrefixesNow()
    result.assemblyMachineId = readFile("/etc/machine-id").strip()
    result.assemblySshHostKeys = sshHostKeyDigests()
  when mutated("image-omits-gen0-ledger"):
    # FALSIFYING MUTATION (see mutations.nim): an assembly that leaves the
    # add-on's ledger out of the image.
    removeIfPresent(ledgerCopyPath(DefaultStateDir))
  when mutated("image-omits-store-closure"):
    # FALSIFYING MUTATION (see mutations.nim): an assembly that leaves an apt
    # closure's store prefix out of the image (through the private writable
    # view of the store; the host's own view is read-only).
    enterWritableStoreView()
    for p in storePrefixesNow():
      if "/apt-closure-" in p or "/apt-deb-" in p:
        removeDir(p)
  step("clean up"):
    cleanUp(spec, payload)
  result.ok = result.steps.len > 0 and result.steps[^1].ok and
              result.steps[^1].name == "clean up"
  writeFile(payload / AssemblyResultName, renderAssemblyResult(result) & "\n")
  discard runHostTool(["/usr/bin/sync"], timeoutSec = 120)
  console(if result.ok: "assembled generation " & result.generationId
          else: "assembly FAILED")
