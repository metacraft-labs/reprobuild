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
import repro_infra/state_dir

import repro_deploy_agent/agent
import repro_deploy_agent/manifest
import repro_deploy_agent/secrets as agentSecrets
import repro_deploy_agent/tick_status
import repro_peer_cache/auth as peerAuth

import ./addon_apply
import ./addon_secrets
import ./fingerprint
import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./preflight
import ./pending_plan
import ./static_tree
import ./switch
import ./transitions

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

proc currentGenerationProfile(stateDir: string): SystemProfile =
  ## The operator profile the current generation applied (empty on a host
  ## with no generation yet).
  let current = readCurrentGenerationId(stateDir)
  var text = ""
  if current.len > 0:
    let g = generationProfiles(stateDir, current)
    if g.found: text = g.user
  if text.len == 0 and fileExists(userProfilePath(stateDir)):
    text = readFile(userProfilePath(stateDir))
  if text.len > 0: parseSystemProfile(text) else: SystemProfile()

proc currentSecretDecls*(stateDir: string): seq[SecretFileDecl] =
  ## The current generation's ``secrets.secretFile`` declarations.
  currentGenerationProfile(stateDir).secretFiles

proc currentEnvelope*(stateDir: string; l: SecretsLayout): string =
  ## The envelope the current generation materialises from: its own copy,
  ## or -- for a generation committed before copies were kept -- the latest.
  let current = readCurrentGenerationId(stateDir)
  when mutated("secrets-single-retained-envelope"):
    return latestEnvelopePath(l)
  if current.len > 0 and fileExists(generationEnvelopeOf(stateDir, current)):
    generationEnvelopeOf(stateDir, current)
  else:
    latestEnvelopePath(l)

proc acceptSealedSection*(stateDir: string; l: SecretsLayout;
                          m: DeployManifest): string =
  ## The deploy agent's ``secretsSink`` on an add-on host: the section must
  ## open with the host's checked key and carry every entry the manifest's
  ## profile declares; then it is staged for the apply that follows
  ## (``stageEnvelope``). Nothing the host runs changes here: the apply's
  ## commit promotes it, a failed apply discards it. "" when staged, else
  ## why not (the tick reports ``aoSecretsFailed`` and applies nothing).
  try:
    var decls: seq[SecretFileDecl]
    try:
      decls = parseSystemProfile(m.profileText).secretFiles
    except CatchableError:
      discard        # the apply refuses an unreadable profile itself
    withSecretsLocks(stateDir, "staging a sealed secrets section"):
      stageEnvelope(l, RetainedEnvelope(target: m.target, sealed: m.secrets),
                    decls)
    ""
  except CatchableError as e:
    e.msg

type ConsumerPlan = object
  exclusive, restart, pending: seq[string]

proc planConsumers(stateDir: string; services: seq[string]): ConsumerPlan =
  ## How the running units of the current generation that load a credential
  ## of ``services`` take the change (they read credentials at start), by
  ## the switch's own rule (§7.3): an exclusive unit -- the field or its
  ## content's ``X-Repro-Exclusive=true`` -- is stopped and confirmed
  ## exited before the secret changes and started after; another is
  ## restarted after; one with ``restartIfChanged = false`` is left, and the
  ## re-assert unit reports it until it restarts.
  for r in currentGenerationProfile(stateDir).resources:
    if r.kind != srkSystemdSystemUnit or r.suCredentials.len == 0 or
        credentialServiceOf(r.suName) notin services:
      continue
    let exclusive = isExclusiveUnit(r)
    if not (unitIsActive(r.suName) or
            (exclusive and unitAliveness(r.suName) != uaEmpty)):
      continue
    if r.suRestartHeld: result.pending.add(r.suName)
    elif exclusive: result.exclusive.add(r.suName)
    else: result.restart.add(r.suName)

proc addEntry(l: SecretsLayout; path, entry, content, target: string;
              createIfAbsent: bool): string =
  ## Re-seal the envelope at ``path`` with ``entry`` added or replaced, to
  ## the key that opens it (the current key when there is no envelope and
  ## ``createIfAbsent``). Returns the target it was sealed for, "" when
  ## nothing was there to change.
  let (present, env) = readEnvelopeFile(l, path)
  if not present and not createIfAbsent: return ""
  var files: seq[SecretFile]
  var tgt = target
  var sealTo: PublicKeyBytes
  if present:
    if target.len > 0 and target != env.target:
      raise newException(AddonSecretsFailed, "secret put: the envelope at " &
        path & " is sealed for target '" & env.target & "', not '" &
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
  writeEnvelopeFile(l, path, RetainedEnvelope(target: tgt,
    sealed: sealSecrets(sealTo, tgt, files)))
  wipe(files)
  if bytes.len > 0: zeroMem(addr bytes[0], bytes.len)
  tgt

proc secretPut*(stateDir: string; l: SecretsLayout; service, name: string;
                content: string; target = ""): seq[string] =
  ## ``repro system addon secret put``: seal ``content`` as the entry
  ## ``<service>/<name>`` to the host's own recipient key, merged into the
  ## latest envelope and into the current generation's own copy (the other
  ## entries are kept), then re-materialise the current generation's
  ## secrets and take the change into its running consumers. On a host the
  ## deploy agent drives, the producer's next section replaces the latest
  ## envelope whole, so a put entry lasts there only until the producer's
  ## next generation, unless the producer seals it too (spec §10.3).
  if not isSafeSecretComponent(service) or not isSafeSecretComponent(name):
    raise newException(AddonSecretsFailed, "secret put: --service and " &
      "--name must each be one path segment of letters, digits, '.', '-' " &
      "or '_', at most 64 bytes, not starting with '.'")
  hardenProcessForSecrets()
  withSecretsLocks(stateDir, "repro system addon secret put"):
    discard reconcileRotation(l, ledgerCopyPath(stateDir))
    let entry = secretEntryPath(service, name)
    let tgt = addEntry(l, latestEnvelopePath(l), entry, content, target,
                       createIfAbsent = true)
    result.add("sealed " & entry & " into " & latestEnvelopePath(l) &
               " (target " & tgt & ")")
    let current = readCurrentGenerationId(stateDir)
    if current.len > 0:
      let copy = generationEnvelopeOf(stateDir, current)
      if addEntry(l, copy, entry, content, tgt, createIfAbsent = false).len > 0:
        result.add("sealed " & entry & " into " & copy)
    let decls = currentSecretDecls(stateDir)
    var declared = false
    for d in decls:
      if secretEntryPath(d.service, d.name) == entry: declared = true
    if not declared:
      result.add("note: the current generation declares no " &
        "secrets.secretFile for " & entry & "; it is not materialised")
    let source = currentEnvelope(stateDir, l)
    let changes = plannedSecretChanges(l, decls, source)
    let plan = planConsumers(stateDir, changes)
    for u in plan.exclusive:
      stopExclusive(u)
      result.add(u & ": stopped and confirmed exited (exclusive)")
    discard materialiseFromEnvelope(l, decls, source)
    if changes.len > 0:
      result.add("materialised: " & changes.join(", "))
    for u in plan.exclusive:
      confirmExited([u], u)
      startUnit(u)
      result.add(u & ": started")
    for u in plan.restart:
      restartUnit(u)
      result.add(u & ": restarted")
    for u in plan.pending:
      result.add(u & ": restart pending (restartIfChanged = false); the " &
        "re-assert unit reports it until the unit restarts")

proc rotateKey*(stateDir: string; l: SecretsLayout):
    tuple[publicKeyHex: string; created: bool] =
  ## ``repro system addon rotate-recipient-key``.
  withSecretsLocks(stateDir, "repro system addon rotate-recipient-key"):
    discard reconcileRotation(l, ledgerCopyPath(stateDir))
    result = rotateRecipientKey(l)

proc unitStartedAt(unit: string): int64 =
  ## When the unit last became active (seconds since the epoch), 0 unknown.
  try:
    let r = runSystemctl(["show", "--timestamp=unix", "-p",
                          "ActiveEnterTimestamp", "--value", "--", unit])
    let v = r.output.strip()
    if r.exitCode == 0 and v.startsWith("@"):
      return parseBiggestInt(v[1 .. ^1])
  except CatchableError:
    discard
  0

type SecretsCheck* = object
  status*: string            ## ok | deferred | degraded | drift
  notes*: seq[string]
  findings*: seq[string]

proc reassertSecrets*(stateDir: string; l: SecretsLayout): SecretsCheck =
  ## Step 3 of the re-assert unit (§7.7): under the switch's two locks,
  ## taken without waiting -- a switch or a ``secret put`` that holds one
  ## materialises the secrets itself, so this run defers to it -- finish
  ## what a crash may have cut short (the commit's envelope copy and key
  ## retirement, a rotation's public half and ledger digests), then
  ## re-materialise the current generation's secrets from its own
  ## envelope, and report every running unit that loads credentials older
  ## than its secrets (a pending restart). Never raises.
  result.status = "ok"
  var (hostLock, holder, _) = tryAcquireHostApplyLock(
    "re-materialising secrets")
  if holder.len > 0:
    result.status = "deferred"
    result.notes.add("secrets: deferred, an apply holds the host apply " &
                     "lock (" & holder & ")")
    return
  defer: hostLock.release()
  var ownLock = false
  if applyLockOwner(stateDir) != getCurrentProcessId():
    let acq = tryAcquireApplyLock(stateDir)
    if not acq.acquired:
      result.status = "deferred"
      result.notes.add("secrets: deferred, an apply holds " & stateDir &
                       "'s lock")
      return
    ownLock = true
  defer:
    if ownLock: releaseApplyLock(stateDir)
  try:
    if not hasPendingMarker(stateDir) and
        readSecretsSource(stateDir).len > 0:
      # A switch committed and died before it kept its secrets.
      commitSecretsOf(stateDir, l, readCurrentGenerationId(stateDir))
      result.notes.add("secrets: finished keeping the committed " &
                       "generation's envelope")
    for line in reconcileRotation(l, ledgerCopyPath(stateDir)):
      result.notes.add("secrets: " & line)
    let profile = currentGenerationProfile(stateDir)
    let changed = materialiseFromEnvelope(l, profile.secretFiles,
      currentEnvelope(stateDir, l), seamStateDir = stateDir)
    result.notes.add("secrets: " & $profile.secretFiles.len & " declared" &
      (if changed.len > 0: ", materialised for " & changed.join(", ") else: ""))
    for r in profile.resources:
      if r.kind != srkSystemdSystemUnit or r.suCredentials.len == 0: continue
      if not unitIsActive(r.suName): continue
      let svc = credentialServiceOf(r.suName)
      let since = unitStartedAt(r.suName)
      let newest = runDirMtimes(l, svc)
      if since > 0 and newest > since:
        result.findings.add("drift: " & r.suName & " runs with credentials " &
          "older than its secrets (they changed after it started); restart " &
          "it to load them")
        if result.status == "ok": result.status = "drift"
  except CatchableError as e:
    result.findings.add("degraded: secrets: " & e.msg)
    result.status = "degraded"

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
  try:
    hardenProcessForSecrets()   # before the plaintext is read
  except CatchableError as e:
    stderr.write("repro system addon secret put: " & e.msg & "\n")
    return 1
  var content = stdin.readAll()
  defer: wipe(content)
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
  cfg.secretsSink = proc(m: DeployManifest): string {.gcsafe.} =
    {.cast(gcsafe).}:
      acceptSealedSection(DefaultStateDir, layout, m)
  var deps: AgentDeps
  deps.apply = proc(m: DeployManifest): tuple[ok: bool; message: string] {.gcsafe.} =
    {.cast(gcsafe).}:
      # A manifest with a sealed section applies from the section it
      # staged; the commit promotes it, and whatever happens the staged
      # copy does not outlive this tick.
      let staged = if m.hasSecrets: stagedEnvelopePath(layout) else: ""
      try:
        let r = runAddonApply(AddonApplyOptions(stateDir: DefaultStateDir,
          hostIdentity: readHostname(), userProfileText: m.profileText,
          secretsEnvelope: staged))
        (true, "generation " & r.generationId)
      except CatchableError as e:
        (false, e.msg)
      finally:
        try: discardStaged(layout)
        except CatchableError: discard
  hardenProcessForSecrets()
  var hostLock = acquireHostApplyLock("repro system addon agent-tick")
  defer: hostLock.release()
  let outcome = runAgentTick(cfg, deps)
  stdout.write("outcome: " & $outcome.kind & "\n" &
               "sequence: " & $outcome.sequence & "\n" &
               "message: " & outcome.message & "\n")
  deployAgentExitCode(outcome.kind)
