## The add-on's secrets operations (ReproOS Add-On Mode §10.3, §7.7 step 3):
## what the operator runs, what the deploy agent's tick calls, and what the
## re-assert unit does at boot. The mechanics -- the key check, the retained
## envelope, the private no-follow materialisation, the rotation -- are
## ``addon_secrets``; this module adds the host's locks, the ledger and the
## current generation around them.
##
##   repro system addon secret put --service S --name N [--target T] < bytes
##       Seal one secret on the host to the host's own recipient key (the
##       operator path of §10.3: the plaintext arrives on stdin, never in an
##       argument or a file), merge it into the retained envelope and
##       re-materialise the current generation's secrets.
##   repro system addon rotate-recipient-key
##       Generate the next recipient key and print its public half (CRED-2).
##   repro system addon agent-tick --source <manifest>... [--target T]
##       One deploy-agent tick on the add-on host, in one process: the
##       sealed section goes through ``acceptSealedSection`` and the profile
##       through the add-on switch. Milestone A8 splits this into the fetch
##       and apply units (§9.1); the secrets half is this one.
##
## Every write here holds the host-wide apply lock and the state
## directory's apply lock, the same two the switch takes, so a secret is
## never re-materialised under a running switch.

import std/[os, strutils]

import repro_core/host_apply_lock
import repro_infra
import repro_infra/apply_lock

import repro_deploy_agent/agent
import repro_deploy_agent/manifest
import repro_deploy_agent/secrets as agentSecrets
import repro_deploy_agent/tick_status
import repro_peer_cache/auth as peerAuth

import ./addon_apply
import ./addon_secrets
import ./fingerprint
import ./generation0
import ./ledger
import ./preflight
import ./switch

template withSecretsLocks(stateDir, what: string; body: untyped) =
  ## The switch's two locks, in the switch's order (host first).
  var hostLock = acquireHostApplyLock(what)
  try:
    var ownLock = false
    if applyLockOwner(stateDir) != getCurrentProcessId():
      let acq = tryAcquireApplyLock(stateDir)
      if not acq.acquired:
        raise newException(AddonSecretsFailed, what & ": another apply " &
          "holds the lock: " & describeApplyLockHolder(stateDir, acq))
      ownLock = true
    try:
      body
    finally:
      if ownLock: releaseApplyLock(stateDir)
  finally:
    hostLock.release()

proc currentSecretDecls*(stateDir: string): seq[SecretFileDecl] =
  ## The current generation's ``secrets.secretFile`` declarations, from the
  ## operator profile it applied (none on a host with no generation yet).
  let current = readCurrentGenerationId(stateDir)
  var text = ""
  if current.len > 0:
    let g = generationProfiles(stateDir, current)
    if g.found: text = g.user
  if text.len == 0 and fileExists(userProfilePath(stateDir)):
    text = readFile(userProfilePath(stateDir))
  if text.len == 0: return
  parseSystemProfile(text).secretFiles

proc currentCredentialUnits(stateDir: string): seq[SystemResource] =
  let current = readCurrentGenerationId(stateDir)
  if current.len == 0: return
  let g = generationProfiles(stateDir, current)
  if not g.found: return
  for r in parseSystemProfile(g.user).resources:
    if r.kind == srkSystemdSystemUnit and r.suCredentials.len > 0:
      result.add(r)

proc recordKeyRotation*(stateDir: string; l: SecretsLayout) =
  ## The recipient key and its public half are ledger objects (``lcKey``,
  ## pinned by digest; bootstrap recorded them). A completed rotation
  ## replaced both on purpose, so the ledger copy -- the record every later
  ## apply carries them forward from, and what ``verify`` and the re-assert
  ## unit compare against -- is brought up to date, never reported as
  ## drift.
  let lp = ledgerCopyPath(stateDir)
  if not fileExists(lp): return
  var led = readLedger(lp)
  var changed = false
  for e in led.entries.mitems:
    if e.class == lcKey and e.path in [recipientKeyPath(l), recipientPubPath(l)] and
        fileExists(e.path):
      let st = statOwner(e.path)
      e.sha256 = sha256OfFile(e.path)
      e.mode = st.mode
      e.owner = st.owner
      changed = true
  if changed:
    writeLedger(lp, led)

proc acceptSealedSection*(stateDir: string; l: SecretsLayout; target: string;
                          sealed: SealedSecrets): string =
  ## The deploy agent's ``secretsSink`` on an add-on host: the section must
  ## open with the host's checked key, becomes the retained envelope, and
  ## retires the old key when the next one opened it. "" when accepted,
  ## else why not (the tick reports ``aoSecretsFailed``). Nothing is
  ## materialised here: the apply that follows does that for exactly what
  ## its generation declares.
  try:
    withSecretsLocks(stateDir, "accepting a sealed secrets section"):
      let opened = acceptEnvelope(l, RetainedEnvelope(target: target,
                                                      sealed: sealed))
      if opened.byNextKey:
        recordKeyRotation(stateDir, l)
    ""
  except CatchableError as e:
    e.msg

proc restartConsumers(stateDir: string; services: seq[string]): seq[string] =
  ## Restart the running units of the current generation that load a
  ## credential of ``services`` (they read credentials at start).
  for r in currentCredentialUnits(stateDir):
    if credentialServiceOf(r.suName) notin services: continue
    if not unitIsActive(r.suName): continue
    if r.suExclusive or r.suRestartHeld:
      result.add(r.suName & ": restart pending (exclusive or restart held)")
      continue
    restartUnit(r.suName)
    result.add(r.suName & ": restarted")

proc secretPut*(stateDir: string; l: SecretsLayout; service, name: string;
                content: string; target = ""): seq[string] =
  ## ``repro system addon secret put``: seal ``content`` as the entry
  ## ``<service>/<name>`` to the host's own recipient key, merged into the
  ## retained envelope (the other entries are kept), then re-materialise
  ## the current generation's secrets. Returns what was done, line by line.
  if not isSafeSecretComponent(service) or not isSafeSecretComponent(name):
    raise newException(AddonSecretsFailed, "secret put: --service and " &
      "--name must each be one path segment of letters, digits, '.', '-' " &
      "or '_', at most 64 bytes, not starting with '.'")
  withSecretsLocks(stateDir, "repro system addon secret put"):
    let (present, env) = readRetained(l)
    var files: seq[SecretFile]
    var tgt = target
    var sealTo: PublicKeyBytes
    if present:
      if target.len > 0 and target != env.target:
        raise newException(AddonSecretsFailed, "secret put: the retained " &
          "envelope is sealed for target '" & env.target & "', not '" &
          target & "'")
      tgt = env.target
      let opened = openEnvelope(l, env)
      files = opened.files
      let keyPath = if opened.byNextKey: nextRecipientKeyPath(l)
                    else: recipientKeyPath(l)
      sealTo = derivePublicKey(loadRecipientKeyChecked(keyPath, l.owner))
    else:
      if tgt.len == 0: tgt = readHostname()
      sealTo = derivePublicKey(loadRecipientKeyChecked(recipientKeyPath(l),
                                                       l.owner))
    let entry = secretEntryPath(service, name)
    var bytes = newSeq[byte](content.len)
    for i, c in content: bytes[i] = byte(c)
    var replaced = false
    for f in files.mitems:
      if f.path == entry:
        f.content = bytes
        f.mode = uint32(SecretFileMode)
        replaced = true
    if not replaced:
      files.add(SecretFile(path: entry, mode: uint32(SecretFileMode),
                           content: bytes))
    let opened = acceptEnvelope(l, RetainedEnvelope(target: tgt,
      sealed: sealSecrets(sealTo, tgt, files)))
    if opened.byNextKey:
      recordKeyRotation(stateDir, l)
    result.add((if replaced: "replaced " else: "added ") & entry &
      " in the retained envelope (target " & tgt & ")")
    let decls = currentSecretDecls(stateDir)
    var declared = false
    for d in decls:
      if secretEntryPath(d.service, d.name) == entry: declared = true
    if not declared:
      result.add("note: the current generation declares no " &
        "secrets.secretFile for " & entry & "; it is not materialised")
    let changed = materialiseFromRetained(l, decls)
    if changed.len > 0:
      result.add("materialised: " & changed.join(", "))
      result.add(restartConsumers(stateDir, changed))

proc rotateKey*(stateDir: string; l: SecretsLayout):
    tuple[publicKeyHex: string; created: bool] =
  ## ``repro system addon rotate-recipient-key``.
  withSecretsLocks(stateDir, "repro system addon rotate-recipient-key"):
    result = rotateRecipientKey(l)

proc reassertSecrets*(stateDir: string; l: SecretsLayout):
    tuple[ok: bool; line: string] =
  ## Step 3 of the re-assert unit (§7.7): re-materialise the current
  ## generation's secrets from the retained envelope. Never raises.
  try:
    let decls = currentSecretDecls(stateDir)
    let changed = materialiseFromRetained(l, decls, seamStateDir = stateDir)
    (true, "secrets: " & $decls.len & " declared" &
      (if changed.len > 0: ", materialised for " & changed.join(", ") else: ""))
  except CatchableError as e:
    (false, "degraded: secrets: " & e.msg)

# ---------------------------------------------------------------------------
# The CLI.
# ---------------------------------------------------------------------------

proc takeArg(args: seq[string]; i: var int; flag: string): string =
  let a = args[i]
  if a.startsWith(flag & "="):
    return a[flag.len + 1 .. ^1]
  if i + 1 >= args.len:
    raise newException(ValueError, flag & " needs a value")
  inc i
  args[i]

proc runSecretPutCli*(args: seq[string]): int =
  ## ``repro system addon secret put --service S --name N [--target T]``;
  ## the secret is read from stdin, byte for byte.
  if args.len == 0 or args[0] != "put":
    stderr.write("usage: repro system addon secret put --service S " &
      "--name N [--target T] < secret\n")
    return 2
  var service, name, target = ""
  var i = 1
  try:
    while i < args.len:
      let a = args[i]
      if a == "--service" or a.startsWith("--service="):
        service = takeArg(args, i, "--service")
      elif a == "--name" or a.startsWith("--name="):
        name = takeArg(args, i, "--name")
      elif a == "--target" or a.startsWith("--target="):
        target = takeArg(args, i, "--target")
      else:
        raise newException(ValueError, "unknown option " & a)
      inc i
    if service.len == 0 or name.len == 0:
      raise newException(ValueError, "--service and --name are required")
  except ValueError as e:
    stderr.write("repro system addon secret put: " & e.msg & "\n")
    return 2
  let content = stdin.readAll()
  if content.len == 0:
    stderr.write("repro system addon secret put: no secret on stdin\n")
    return 2
  try:
    for line in secretPut(DefaultStateDir, defaultSecretsLayout(), service,
                          name, content, target):
      stdout.write(line & "\n")
    0
  except CatchableError as e:
    stderr.write("repro system addon secret put: " & e.msg & "\n")
    1

proc runRotateRecipientKeyCli*(args: seq[string]): int =
  if args.len != 0:
    stderr.write("usage: repro system addon rotate-recipient-key\n")
    return 2
  try:
    let r = rotateKey(DefaultStateDir, defaultSecretsLayout())
    stdout.write("next recipient public key: " & r.publicKeyHex & "\n")
    if not r.created:
      stdout.write("(a rotation was already pending; this is its key)\n")
    stdout.write("seal the next envelope to it; the current key is deleted " &
      "when the first envelope sealed to the new one opens\n")
    0
  except CatchableError as e:
    stderr.write("repro system addon rotate-recipient-key: " & e.msg & "\n")
    1

proc runAgentTickCli*(args: seq[string]): int =
  ## ``repro system addon agent-tick --source S... [--target T]
  ## [--allowed-signers F]``: one tick (see the module header). Exits with
  ## the deploy agent's outcome code (0 applied/converged, 1 retryable, 2
  ## an operator must act: ``aoSecretsFailed`` among them).
  var sources: seq[string]
  var target = ""
  var signers = DeploySignersPath
  var i = 0
  try:
    while i < args.len:
      let a = args[i]
      if a == "--source" or a.startsWith("--source="):
        sources.add(takeArg(args, i, "--source"))
      elif a == "--target" or a.startsWith("--target="):
        target = takeArg(args, i, "--target")
      elif a == "--allowed-signers" or a.startsWith("--allowed-signers="):
        signers = takeArg(args, i, "--allowed-signers")
      else:
        raise newException(ValueError, "unknown option " & a)
      inc i
    if sources.len == 0:
      raise newException(ValueError, "at least one --source is required")
  except ValueError as e:
    stderr.write("repro system addon agent-tick: " & e.msg & "\n")
    return 2
  if target.len == 0: target = readHostname()
  let layout = defaultSecretsLayout()
  var cfg = AgentConfig(target: target, sources: sources,
    anchors: peerAuth.loadTrustAnchors(signers), stateDir: AgentStateDir,
    fetchTimeoutMs: 30_000)
  cfg.secretsSink = proc(t: string; sealed: SealedSecrets): string {.gcsafe.} =
    {.cast(gcsafe).}:
      acceptSealedSection(DefaultStateDir, layout, t, sealed)
  var deps: AgentDeps
  deps.apply = proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
    {.cast(gcsafe).}:
      try:
        let r = runAddonApply(AddonApplyOptions(stateDir: DefaultStateDir,
          hostIdentity: readHostname(), userProfileText: m.profileText))
        (true, "generation " & r.generationId)
      except CatchableError as e:
        (false, e.msg)
  var hostLock = acquireHostApplyLock("repro system addon agent-tick")
  defer: hostLock.release()
  let outcome = runAgentTick(cfg, deps)
  stdout.write("outcome: " & $outcome.kind & "\n" &
               "sequence: " & $outcome.sequence & "\n" &
               "message: " & outcome.message & "\n")
  deployAgentExitCode(outcome.kind)
