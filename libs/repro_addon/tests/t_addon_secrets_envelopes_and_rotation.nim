## The add-on's envelope bookkeeping and rotation (ReproOS Add-On Mode
## spec §10.3), on real files: staging, committing, re-sealing at
## retirement, idempotent completion after a crash, the planned secret
## changes, the credential-change transition rule, and the refusal of
## hand-written credential directives.
##
## - a staged section that lacks an entry its profile declares is refused
##   and stages nothing; a covering one is staged and replaces nothing;
## - a commit keeps the generation's copy, promotes the staged section, and
##   -- when only the next key opens it -- retires the old key AFTER
##   re-sealing every kept copy, so an older generation's copy still opens;
## - ``reconcileRotation`` completes a rotation a crash cut short after the
##   rename (stale ``recipient.pub`` and ledger digests), idempotently;
## - ``plannedSecretChanges`` names exactly the services whose files would
##   change;
## - the planner turns a credential change into a confirmed stop-start for
##   an exclusive unit, a restart otherwise, and a pending ``leave`` when
##   the unit holds its restarts -- never a reload;
## - ``rawCredentialDirective`` finds ``LoadCredential=`` and its kin;
## - the plaintext bound is one bound: a payload of exactly
##   ``MaxPlaintextBytes`` is built and one byte more is refused before
##   anything is sealed or written (a put cannot leave an envelope that
##   ``openEnvelope`` refuses), and ``readLockedFd`` accepts a secret of
##   exactly ``MaxPlaintextBytes`` and refuses one byte more.
##
## *Mocking.* None: real files, the real codec, keys and planner. The
## layout points at a scratch directory, owned by the test user, with no
## filesystem requirement (the VM gates check the ramfs).

import std/[os, posix, strutils, unittest]

import repro_infra/profile
import repro_deploy_agent/secrets
import repro_peer_cache/auth as peerAuth

import repro_deploy_agent/manifest
import repro_addon/[addon_apply, addon_secrets, fingerprint, ledger, secrets_ops, transitions]

proc bytesOf(s: string): seq[byte] =
  for ch in s: result.add(byte(ch))

type Bed = object
  root: string
  layout: SecretsLayout

proc newBed(name: string): Bed =
  result.root = getTempDir() / ("repro-addon-envelopes-" & name & "-" &
                                $getCurrentProcessId())
  removeDir(result.root)
  createDir(result.root)
  doAssert posix.mkdir(cstring(result.root / "agent"), Mode(0o700)) == 0
  createDir(result.root / "run")
  result.layout = SecretsLayout(agentDir: result.root / "agent",
    runDir: result.root / "run" / "secrets", owner: int(geteuid()), fs: sfAny)
  let k = ensureRecipientKeyFile(recipientKeyPath(result.layout))
  writeFile(recipientPubPath(result.layout), peerAuth.publicKeyHex(k.publicKey) & "\n")

proc pubOf(b: Bed; path: string): PublicKeyBytes =
  derivePublicKey(loadRecipientKeyChecked(path, b.layout.owner))

proc env(pub: PublicKeyBytes; entries: openArray[(string, string)]): RetainedEnvelope =
  var files: seq[SecretFile]
  for (p, c) in entries:
    files.add(SecretFile(path: p, mode: 0o400, content: bytesOf(c)))
  RetainedEnvelope(target: "t", sealed: sealSecrets(pub, "t", files))

const A = [SecretFileDecl(service: "web", name: "a")]

suite "envelopes and rotation":
  test "a staged section must cover its profile; staging replaces nothing":
    let b = newBed("stage")
    defer: removeDir(b.root)
    let pub = b.pubOf(recipientKeyPath(b.layout))
    writeRetained(b.layout, env(pub, [("web/a", "old")]))
    let before = readFile(latestEnvelopePath(b.layout))
    expect AddonSecretsFailed:
      stageEnvelope(b.layout, env(pub, [("web/b", "new")]), A)
    check not fileExists(stagedEnvelopePath(b.layout))
    stageEnvelope(b.layout, env(pub, [("web/a", "new")]), A)
    check fileExists(stagedEnvelopePath(b.layout))
    check readFile(latestEnvelopePath(b.layout)) == before
    discardStaged(b.layout)
    check not fileExists(stagedEnvelopePath(b.layout))

  test "commit keeps the copy, promotes staged, re-seals, then retires":
    let b = newBed("commit")
    defer: removeDir(b.root)
    let oldPub = b.pubOf(recipientKeyPath(b.layout))
    # Generation 1 materialised from an envelope sealed to the old key.
    let gen1 = b.root / "state" / "generations" / "g1"
    createDir(gen1)
    writeEnvelopeFile(b.layout, generationEnvelopePath(gen1),
                      env(oldPub, [("web/a", "v1")]))
    writeRetained(b.layout, env(oldPub, [("web/a", "v1")]))
    let oldScalar = readFile(recipientKeyPath(b.layout))
    let (nextHex, created) = rotateRecipientKey(b.layout)
    check created
    let nextPub = b.pubOf(nextRecipientKeyPath(b.layout))
    stageEnvelope(b.layout, env(nextPub, [("web/a", "v2")]), A)
    let gen2 = b.root / "state" / "generations" / "g2"
    createDir(gen2)
    commitEnvelope(b.layout, stagedEnvelopePath(b.layout),
      generationEnvelopePath(gen2), @[generationEnvelopePath(gen1)], "")
    check not fileExists(stagedEnvelopePath(b.layout))
    check not fileExists(nextRecipientKeyPath(b.layout))
    check readFile(recipientPubPath(b.layout)).strip() == nextHex
    check readFile(recipientKeyPath(b.layout)) != oldScalar
    # The old generation's copy was re-sealed: it opens with the new key.
    let (present, e1) = readEnvelopeFile(b.layout, generationEnvelopePath(gen1))
    check present
    let o1 = openEnvelope(b.layout, e1)
    let v1 = "v1"
    check o1.entries.len == 1 and o1.entries[0].len == 2 and
      equalMem(o1.buf.toPtr(o1.entries[0].off), unsafeAddr v1[0], 2)
    # Generation 2's copy and the latest hold v2.
    discard materialiseFromEnvelope(b.layout, A, generationEnvelopePath(gen2))
    check readFile(b.layout.runDir / "web" / "a") == "v2"
    # An envelope sealed to the old key is refused now.
    expect AddonSecretsFailed:
      discard openEnvelope(b.layout, env(oldPub, [("web/a", "v3")]))

  test "a rotation cut short after the rename is completed, idempotently":
    let b = newBed("reconcile")
    defer: removeDir(b.root)
    discard rotateRecipientKey(b.layout)
    let ledgerPath = b.root / "addon-ledger"
    let stOld = statOwner(recipientKeyPath(b.layout))
    writeLedger(ledgerPath, Ledger(generation: "g", entries: @[
      LedgerEntry(class: lcKey, path: recipientKeyPath(b.layout),
        sha256: "00", mode: stOld.mode, owner: stOld.owner),
      LedgerEntry(class: lcKey, path: recipientPubPath(b.layout),
        sha256: "00", mode: "0444", owner: stOld.owner)]))
    # The crash: the next key renamed over the old one, nothing else.
    moveFile(nextRecipientKeyPath(b.layout), recipientKeyPath(b.layout))
    let fixed = reconcileRotation(b.layout, ledgerPath)
    check fixed.len == 2
    check readFile(recipientPubPath(b.layout)).strip() ==
      peerAuth.publicKeyHex(b.pubOf(recipientKeyPath(b.layout)))
    for e in readLedger(ledgerPath).entries:
      check observeDrift(e) == ""
    check reconcileRotation(b.layout, ledgerPath).len == 0

  test "planned changes name exactly the services whose files change":
    let b = newBed("plan")
    defer: removeDir(b.root)
    let pub = b.pubOf(recipientKeyPath(b.layout))
    let decls = [SecretFileDecl(service: "web", name: "a"),
                 SecretFileDecl(service: "db", name: "p")]
    writeRetained(b.layout, env(pub, [("web/a", "1"), ("db/p", "2")]))
    check plannedSecretChanges(b.layout, decls, latestEnvelopePath(b.layout)) ==
      @["db", "web"]
    discard materialiseFromRetained(b.layout, decls)
    check plannedSecretChanges(b.layout, decls, latestEnvelopePath(b.layout)).len == 0
    writeRetained(b.layout, env(pub, [("web/a", "1"), ("db/p", "3")]))
    check plannedSecretChanges(b.layout, decls, latestEnvelopePath(b.layout)) == @["db"]
    check plannedSecretChanges(b.layout, A, latestEnvelopePath(b.layout)) == @["db"]

  test "a credential change: stop-start if exclusive, restart, pending, never reload":
    proc one(f: UnitFacts): Transition = planTransitions(@[f])[0]
    let base = UnitFacts(unit: "web.service", owned: true, active: true,
                         activeState: "active", enabled: true,
                         credentialsChanged: true)
    check one(base).verb == tvRestart
    var ex = base
    ex.exclusive = true
    ex.alive = uaPopulated
    check one(ex).verb == tvStopStart
    var held = base
    held.restartHeld = true
    check one(held).verb == tvLeave
    var rel = base
    rel.reloadIfChanged = true
    check one(rel).verb == tvRestart
    check "credentials" in one(base).reason

  test "hand-written credential directives are found":
    check rawCredentialDirective("[Service]\nLoadCredential=x:/run/a\n") == "LoadCredential"
    check rawCredentialDirective("[Service]\nSetCredential=x:y\n") == "SetCredential"
    check rawCredentialDirective("[Service]\n# LoadCredential=x\nExecStart=/bin/true\n") == ""

  test "a retirement interrupted between overwrite and rename is finished":
    let b = newBed("overwrite")
    defer: removeDir(b.root)
    let (nextHex, _) = rotateRecipientKey(b.layout)
    # The crash: the old key overwritten with NUL bytes, the next key not
    # yet renamed over it.
    let n = getFileSize(recipientKeyPath(b.layout))
    setFilePermissions(recipientKeyPath(b.layout), {fpUserRead, fpUserWrite})
    writeFile(recipientKeyPath(b.layout), newString(int(n)))
    setFilePermissions(recipientKeyPath(b.layout), {fpUserRead})
    # Every later step finishes it instead of failing on the zero key.
    discard reconcileRotation(b.layout, "")
    check not fileExists(nextRecipientKeyPath(b.layout))
    check readFile(recipientPubPath(b.layout)).strip() == nextHex
    check peerAuth.publicKeyHex(b.pubOf(recipientKeyPath(b.layout))) == nextHex
    # A zero key with no next key left: a diagnostic that says so.
    writeFile(b.root / "agent" / "zero.key", newString(48))
    setFilePermissions(b.root / "agent" / "zero.key", {fpUserRead})
    var msg = ""
    try:
      discard loadRecipientKeyChecked(b.root / "agent" / "zero.key", b.layout.owner)
    except AddonSecretsFailed as e:
      msg = e.msg
    check "all NUL bytes" in msg and "legacy" notin msg

  test "a commit whose copy failed keeps its record and staged section; the retry keeps them":
    let b = newBed("retry")
    defer: removeDir(b.root)
    let stateDir = b.root / "state"
    let gen = stateDir / "generations" / "g1"
    createDir(gen)
    createDir(stateDir / "addon")
    let pub = b.pubOf(recipientKeyPath(b.layout))
    stageEnvelope(b.layout, env(pub, [("web/a", "v1")]), A)
    writeFile(secretsSourcePath(stateDir), stagedEnvelopePath(b.layout) & "\n" &
      sha256OfFile(stagedEnvelopePath(b.layout)) & "\n")
    # The generation directory cannot be written: the copy fails.
    setFilePermissions(gen, {fpUserRead, fpUserExec})
    commitSecretsOf(stateDir, b.layout, "g1")
    check fileExists(secretsSourcePath(stateDir))
    check not fileExists(generationEnvelopeOf(stateDir, "g1"))
    setFilePermissions(gen, {fpUserRead, fpUserWrite, fpUserExec})
    commitSecretsOf(stateDir, b.layout, "g1")
    check not fileExists(secretsSourcePath(stateDir))
    check fileExists(generationEnvelopeOf(stateDir, "g1"))
    check fileExists(latestEnvelopePath(b.layout))

  test "a recorded source that changed since is not kept as the generation's":
    let b = newBed("changed")
    defer: removeDir(b.root)
    let stateDir = b.root / "state"
    createDir(stateDir / "generations" / "g1")
    createDir(stateDir / "addon")
    let pub = b.pubOf(recipientKeyPath(b.layout))
    stageEnvelope(b.layout, env(pub, [("web/a", "v1")]), A)
    writeFile(secretsSourcePath(stateDir), stagedEnvelopePath(b.layout) & "\n" &
      sha256OfFile(stagedEnvelopePath(b.layout)) & "\n")
    stageEnvelope(b.layout, env(pub, [("web/a", "v2")]), A)   # a later tick
    commitSecretsOf(stateDir, b.layout, "g1")
    check not fileExists(generationEnvelopeOf(stateDir, "g1"))

  test "the tick discards its staged section only when the apply did not commit":
    let b = newBed("tick")
    defer: removeDir(b.root)
    let pub = b.pubOf(recipientKeyPath(b.layout))
    var m = DeployManifest(target: "t", sequence: 1, hasSecrets: true)
    stageEnvelope(b.layout, env(pub, [("web/a", "v1")]), A)
    let failed = tickApply(b.root / "state", b.layout, m,
      proc(o: AddonApplyOptions): AddonApplyResult =
        check o.secretsEnvelope == stagedEnvelopePath(b.layout)
        raise newException(AddonApplyError, "rolled back"))
    check not failed.ok
    check not fileExists(stagedEnvelopePath(b.layout))
    stageEnvelope(b.layout, env(pub, [("web/a", "v1")]), A)
    let committed = tickApply(b.root / "state", b.layout, m,
      proc(o: AddonApplyOptions): AddonApplyResult =
        AddonApplyResult(generationId: "g1"))
    check committed.ok
    # The commit itself would have promoted it; when its copy failed it
    # stays for the retry -- the tick does not delete it.
    check fileExists(stagedEnvelopePath(b.layout))

  test "opened plaintext lives in a buffer locked in RAM, wiped when it goes":
    let b = newBed("locked")
    defer: removeDir(b.root)
    let pub = b.pubOf(recipientKeyPath(b.layout))
    var l = b.layout
    l.lockPlaintext = true      # a small buffer locks within the default limit
    let o = openEnvelope(l, env(pub, [("web/a", "plain")]))
    check o.buf.locked
    check o.entries[0].path == "web/a" and o.entries[0].len == 5
    # The sealed payload limit.
    var big = newSeq[byte](MaxPlaintextBytes + 1)
    expect AddonSecretsFailed:
      discard openEnvelope(l, RetainedEnvelope(target: "t",
        sealed: SealedSecrets(ciphertext: big)))

  test "a put that would outgrow the plaintext bound writes nothing":
    let b = newBed("bound")
    defer: removeDir(b.root)
    let pub = b.pubOf(recipientKeyPath(b.layout))
    # The payload framing: 4 bytes of count, 12 per entry plus its path;
    # room is left for one byte of "web/b".
    let firstLen = MaxPlaintextBytes - 4 - 12 - "web/a".len - 12 - "web/b".len - 1
    var first = newSeq[byte](firstLen)
    for i in 0 ..< first.len: first[i] = byte(i and 0xff)
    let path = latestEnvelopePath(b.layout)
    writeEnvelopeFile(b.layout, path, RetainedEnvelope(target: "t",
      sealed: sealSecrets(pub, "t",
        @[SecretFile(path: "web/a", mode: 0o400, content: first)])))
    let before = readFile(path)
    # One byte that brings the payload to exactly the bound is accepted ...
    var one = newLockedBytes(1, requireLock = false)
    one.len = 1
    one.data[0] = 7
    var exact = encodeLocked(b.layout, [("web/a", 0o400'u32,
      pointer(addr first[0]), first.len), ("web/b", 0o400'u32, one.toPtr, 1)])
    check exact.len == MaxPlaintextBytes
    # ... and the put of two bytes is refused, the envelope untouched.
    var two = newLockedBytes(2, requireLock = false)
    two.len = 2
    expect AddonSecretsFailed:
      discard addEntry(b.layout, path, "web/b", two, "t", createIfAbsent = false)
    check readFile(path) == before
    check openEnvelope(b.layout, readEnvelopeFile(b.layout, path)[1]).entries.len == 1

  test "a secret of exactly the bound is read; one byte more is refused":
    let b = newBed("stdin")
    defer: removeDir(b.root)
    proc readN(n: int): bool =
      let f = b.root / "in"
      var s = newString(n)
      writeFile(f, s)
      let fd = posix.open(cstring(f), O_RDONLY)
      doAssert fd >= 0
      defer: discard posix.close(fd)
      try:
        let got = readLockedFd(b.layout, fd, "the secret")
        doAssert got.len == n
        true
      except AddonSecretsFailed:
        false
    check readN(MaxPlaintextBytes)
    check not readN(MaxPlaintextBytes + 1)
    check readN(0)
