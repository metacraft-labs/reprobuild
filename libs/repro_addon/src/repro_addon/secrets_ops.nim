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
##   (the deploy agent's tick, ``agent_split``, uses ``acceptSealedSection``
##   as its secrets sink and ``tickApply`` around its apply)
##
## Every write here holds the host-wide apply lock and the state
## directory's apply lock, the same two the switch takes, so a secret is
## never re-materialised under a running switch.

import std/[os, posix, strutils]

import repro_core/host_apply_lock
import repro_infra
import repro_infra/apply_lock
import repro_infra/state_dir

import repro_deploy_agent/agent
import repro_deploy_agent/manifest
import repro_deploy_agent/secrets as agentSecrets
import repro_deploy_agent/tick_record
import repro_deploy_agent/tick_status
import repro_infra/addon_diagnostics
import repro_peer_cache/auth as peerAuth

import ./addon_apply
import ./addon_secrets
import ./apt_hook
import ./fingerprint
import ./generation0
import ./host_exec
import ./ledger
import ./mutations
import ./preflight
import ./seams
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
      # The declarations the apply will materialise are the stored
      # profile's -- the manifest's plus those of any unit the switch would
      # keep in place as drift -- so the switch's own plan decides whether
      # the staged section serves them (it writes nothing), and a section
      # that does not is refused here, as aoSecretsFailed, and discarded.
      try:
        discard runAddonApply(AddonApplyOptions(stateDir: stateDir,
          hostIdentity: readHostname(), userProfileText: m.profileText,
          planOnly: true, secretsEnvelope: stagedEnvelopePath(l)))
      except AddonSecretsFailed as e:
        discardStaged(l)
        raise e
      except CatchableError:
        discard   # not a secrets refusal: the apply reports it
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

proc addEntry*(l: SecretsLayout; path, entry: string; content: LockedBytes;
              target: string; createIfAbsent: bool): string =
  ## Re-seal the envelope at ``path`` with ``entry`` added or replaced, to
  ## the key that opens it (the current key when there is no envelope and
  ## ``createIfAbsent``). The new payload is built in a locked buffer from
  ## the opened one and ``content`` (itself locked), and sealed in place.
  ## Returns the target it was sealed for, "" when nothing was there.
  let (present, env) = readEnvelopeFile(l, path)
  if not present and not createIfAbsent: return ""
  var opened: OpenedEnvelope
  var tgt = target
  var sealTo: PublicKeyBytes
  if present:
    if target.len > 0 and target != env.target:
      raise newException(AddonSecretsFailed, "secret put: the envelope at " &
        path & " is sealed for target '" & env.target & "', not '" &
        target & "'")
    tgt = env.target
    opened = openEnvelope(l, env)
    let keyPath = if opened.byNextKey: nextRecipientKeyPath(l)
                  else: recipientKeyPath(l)
    sealTo = derivePublicKey(loadRecipientKeyChecked(keyPath, l.owner))
  else:
    if tgt.len == 0: tgt = readHostname()
    sealTo = derivePublicKey(loadRecipientKeyChecked(recipientKeyPath(l),
                                                     l.owner))
  var parts: seq[tuple[path: string; mode: uint32; data: pointer; len: int]]
  var replaced = false
  for e in opened.entries:
    if e.path == entry:
      parts.add((entry, uint32(SecretFileMode), content.toPtr, content.len))
      replaced = true
    else:
      parts.add((e.path, e.mode, opened.buf.toPtr(e.off), e.len))
  if not replaced:
    parts.add((entry, uint32(SecretFileMode), content.toPtr, content.len))
  var payload = encodeLocked(l, parts)
  writeEnvelopeFile(l, path, sealLocked(sealTo, tgt, payload))
  tgt

proc readLockedFd*(l: SecretsLayout; fd: cint; what: string): LockedBytes =
  ## Everything readable from ``fd`` (stdin) into a buffer locked in RAM,
  ## never through a string; at most ``MaxPlaintextBytes`` (exactly that
  ## many is accepted: the buffer grows one byte past the cap, so the read
  ## that finds EOF has room, and only a byte beyond the cap refuses).
  ## The envelope the secret goes into is bounded separately, as a whole
  ## (``encodeLocked``).
  const limit = MaxPlaintextBytes + 1
  result = newLockedBytes(0, requireLock = l.lockPlaintext)
  while true:
    if result.len > MaxPlaintextBytes:
      raise newException(AddonSecretsFailed, what & " is larger than " &
        $MaxPlaintextBytes & " bytes")
    if result.len == result.capacity:
      grow(result, min(limit, 2 * result.capacity), l.lockPlaintext)
    let n = posix.read(fd, addr result.data[result.len],
                       result.capacity - result.len)
    if n < 0:
      if errno == EINTR: continue
      raise newException(AddonSecretsFailed, "cannot read " & what & ": " &
        osErrorMsg(osLastError()))
    if n == 0: break
    result.len += n

proc secretPut*(stateDir: string; l: SecretsLayout; service, name: string;
                content: LockedBytes; target = ""): seq[string] =
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
  guardPlaintext(l)
  withSecretsLocks(stateDir, "repro system addon secret put"):
    # The seam build can hold this process here, with the secret in its
    # heap, while a gate puts the guest under memory pressure.
    seamPause(stateDir, "secrets-holding-plaintext")
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
    var stopped: seq[string]
    try:
      for u in plan.exclusive:
        stopExclusive(u)
        stopped.add(u)
        result.add(u & ": stopped and confirmed exited (exclusive)")
      discard materialiseFromEnvelope(l, decls, source)
    except CatchableError:
      # The exclusive units this put stopped are started again (confirmed
      # exited first, as the switch does) before the failure is reported:
      # a failed put must not leave a service down.
      for u in stopped:
        try:
          confirmExited([u], u)
          startUnit(u)
        except CatchableError as e2:
          stderr.writeLine("repro system addon secret put: restarting " & u &
                           " failed: " & e2.msg)
      raise
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

proc retryPendingSecretsCommit*(stateDir: string; l: SecretsLayout) =
  ## A committed switch whose secrets were not yet kept (its record is still
  ## there and no switch is pending): keep them now. Runs before a tick
  ## stages a new section over the staged path, and in the re-assert.
  if not hasPendingMarker(stateDir) and readSecretsSource(stateDir).len > 0:
    commitSecretsOf(stateDir, l, readCurrentGenerationId(stateDir))

proc tickApply*(stateDir: string; l: SecretsLayout; m: DeployManifest;
                apply: proc(o: AddonApplyOptions): AddonApplyResult):
    tuple[ok: bool; message: string] =
  ## The add-on tick's apply of ``m``: from the section it staged, when it
  ## carries one. When the apply did not commit, the staged section is
  ## discarded (it never changes what the host runs); when it committed,
  ## the commit promoted it -- or, if keeping it failed, it stays staged and
  ## its record stays, for ``retryPendingSecretsCommit``.
  let staged = if m.hasSecrets: stagedEnvelopePath(l) else: ""
  try:
    let r = apply(AddonApplyOptions(stateDir: stateDir,
      hostIdentity: readHostname(), userProfileText: m.profileText,
      secretsEnvelope: staged))
    result = (true, "generation " & r.generationId &
      (if r.drift.len > 0: "; " & $r.drift.len & " object(s) left as " &
         "actionable drift" else: ""))
  except EAddOnUnsupportedBase, EApplyRolledBack:
    # Typed through to the agent: aoUnsupportedBase, exit 2 (spec §7.9);
    # aoRolledBack, the deployment quarantined (spec §9.2, A8).
    try: discardStaged(l)
    except CatchableError: discard
    raise
  except CatchableError as e:
    result = (false, e.msg)
    try: discardStaged(l)
    except CatchableError: discard

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
      # A switch committed and did not keep its secrets (it died, or the
      # copy failed).
      retryPendingSecretsCommit(stateDir, l)
      result.notes.add("secrets: retried keeping the committed " &
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

proc bootSecrets*(stateDir: string; l = defaultSecretsLayout()):
    tuple[ok: bool; line: string] =
  ## ``repro-addon-secrets.service`` (§7.7, §10.3): the current generation's
  ## secrets, re-materialised early in the boot and without waiting for
  ## anything slow -- the units that load them, and multi-user.target with
  ## them, are ordered after this. Both locks are tried once
  ## (``reassertSecrets``): an apply that holds one materialises its own
  ## generation's secrets, and waiting for it here would put that apply
  ## (or a recovery's confirm) on the base's boot path. The one exception
  ## is the state directory's lock left by a switch a crash killed in a
  ## previous boot (its recorded boot id is not this boot's): nothing
  ## holds it, whatever process its PID now names, so it is taken over, as
  ## the recovery would. Never raises.
  var tookStale = false
  try:
    let rec = readApplyLockRecord(stateDir)
    let boot = currentBootId()
    if rec.present and rec.bootId.len > 0 and boot.len > 0 and
        rec.bootId != boot and applyLockOwner(stateDir) != getCurrentProcessId():
      var policy = defaultApplyLockPolicy()
      policy.forceUnlock = true
      tookStale = tryAcquireApplyLock(stateDir, policy).acquired
  except CatchableError:
    discard
  defer:
    if tookStale: releaseApplyLock(stateDir)
  let r = reassertSecrets(stateDir, l)
  (r.status in ["ok", "drift", "deferred"],
   r.status & (if r.notes.len + r.findings.len > 0:
                 ": " & (r.notes & r.findings).join("; ") else: ""))

# ---------------------------------------------------------------------------
# Running where plaintext cannot be swapped.
# ---------------------------------------------------------------------------

proc hostHasSecrets*(l = defaultSecretsLayout()): bool =
  ## Whether this host keeps any sealed envelope (so an apply or a
  ## re-assert may open one).
  fileExists(latestEnvelopePath(l)) or fileExists(stagedEnvelopePath(l)) or
    envelopeCopies(DefaultStateDir).len > 0

proc reexecInNoSwapScope*(): int =
  ## Re-run this very command (same executable, same arguments, same stdin)
  ## in a transient scope of PID 1 with ``MemorySwapMax=0``, unless this
  ## process may already not swap. Returns -1 when the caller should go on
  ## (it is in such a group); otherwise it does not return on success
  ## (``execv``), and returns an exit status after printing why it could
  ## not. A process re-executed this way whose group may still swap is
  ## refused, never re-entered.
  # The plaintext itself is locked in RAM (``locked_buffer``) on every
  # host; the scope is defence in depth, and only where a cgroup v2 memory
  # controller makes ``MemorySwapMax=`` mean something.
  if not memoryControllerActive() or not processMaySwap(): return -1
  if getEnv(NoSwapScopeEnv) == "1":
    stderr.write("repro-addon: note: the scope's MemorySwapMax=0 did not " &
      "take (memory.swap.max is '" & ownCgroupSwapMax() & "'); the " &
      "plaintext is still locked in RAM\n")
    return -1
  var argv: seq[string]
  try:
    argv = noSwapScopeArgv(getAppFilename(), commandLineParams())
  except CatchableError as e:
    stderr.write("repro-addon: " & e.msg & "\n")
    return 1
  putEnv(NoSwapScopeEnv, "1")
  var cargs = allocCStringArray(argv)
  discard posix.execv(argv[0].cstring, cargs)
  deallocCStringArray(cargs)
  stderr.write("repro-addon: cannot run " & argv[0] & ": " &
    osErrorMsg(osLastError()) & "\n")
  1

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
  let layout = defaultSecretsLayout()
  try:
    guardPlaintext(layout)   # before the plaintext is read
    let content = readLockedFd(layout, 0, "the secret on stdin")
    if content.len == 0:
      stderr.write("repro system addon secret put: no secret on stdin\n")
      return 2
    for line in secretPut(DefaultStateDir, layout, service, name, content,
                          target):
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

# ``repro system addon agent-tick`` moved to ``agent_split`` with milestone
# A8, beside the fetch and apply units it shares its apply with.
