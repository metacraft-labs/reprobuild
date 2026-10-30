## Secrets on an add-on host (ReproOS Add-On Mode §10.3, §7.7 step 3).
##
## What is at rest, and where:
##
## - the **recipient key** (``/var/lib/repro/agent/recipient.key``, ``0400``
##   root), generated on the host at bootstrap (``bootstrap.nim``) and the
##   only secret on disk;
## - a copy of the last accepted **sealed** envelope
##   (``/var/lib/repro/agent/sealed-secrets``), so secrets can be
##   re-materialised at every boot without the network. It is the deploy
##   agent's v2 sealed section (``repro_deploy_agent/secrets``) with the
##   target it was sealed for; nothing in it is readable without the key.
##
## Plaintext exists only under ``/run/repro/secrets/<service>/<name>`` (a
## tmpfs, the directory ``0700`` root, each file ``0400`` root), from where
## systemd hands it to the one unit that names it in its ``credentials``
## (``LoadCredential=``). Which entries are materialised is decided by the
## current generation's ``secrets.secretFile`` declarations
## (``repro_infra/profile.SecretFileDecl``); a sealed entry no generation
## declares is never written, and a file no declaration covers any longer
## is removed.
##
## Three properties this module exists for, each with a gate:
##
## - **the key is checked before it is used** (threat model G4, T21): it is
##   opened with ``O_NOFOLLOW`` and its owner and mode are read from that
##   descriptor (``fstat``) before a byte of it is parsed; a key not owned by
##   root, or readable by group or others, refuses with
##   ``AddonSecretsFailed`` (the deploy agent's ``aoSecretsFailed``)
##   (``t_addon_recipient_key_mode_checked_at_load``);
## - **a secret file is born private and never written through a link**
##   (G18, G29, F3, T34): every directory is opened relative to its parent
##   with ``O_NOFOLLOW``, every file is created ``O_CREAT|O_EXCL|O_NOFOLLOW``
##   with mode ``0400`` at ``open(2)`` -- never written first and narrowed
##   after -- under a hidden temporary name, and ``renameat``-ed into place;
##   a symbolic link at the destination or at the temporary name is refused
##   and left as it is (``t_addon_secret_files_created_private_and_never_
##   through_symlinks``);
## - **plaintext never reaches a disk**: the materialisation directory must
##   be on a tmpfs (``statfs``), checked on the directory descriptor that
##   is then written through (``e2e_addon_no_plaintext_secret_on_disk``).
##
## Recipient-key rotation (CRED-2, G36): ``rotateRecipientKey`` generates
## ``recipient.key.next`` beside the current key and returns its public
## half for the producer to seal to. The first envelope that the NEXT key
## opens retires the current one: its bytes are overwritten and the next
## key is renamed over it (``acceptEnvelope``), after which an envelope
## sealed to the old key no longer opens (``e2e_addon_recipient_key_
## rotation``).
##
## Nothing here takes the host's apply lock; the callers (``secrets_ops``,
## the switch) hold it around every call that writes.

import std/[algorithm, os, posix, strutils]

import repro_infra/profile

import repro_elevation/nofollow_write
import repro_deploy_agent/secrets as agentSecrets
import repro_peer_cache/auth as peerAuth

import ./mutations
import ./seams

var
  oDirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
  oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  oCloExec {.importc: "O_CLOEXEC", header: "<fcntl.h>".}: cint
  atSymlinkNoFollow {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint
  atRemoveDir {.importc: "AT_REMOVEDIR", header: "<fcntl.h>".}: cint

proc c_openat(dirfd: cint; path: cstring; flags: cint; mode: Mode): cint
  {.importc: "openat", header: "<fcntl.h>", varargs.}
proc c_renameat(olddirfd: cint; oldpath: cstring; newdirfd: cint;
                newpath: cstring): cint
  {.importc: "renameat", header: "<stdio.h>".}
proc c_fstatat(dirfd: cint; path: cstring; st: var Stat; flags: cint): cint
  {.importc: "fstatat", header: "<sys/stat.h>".}
proc c_unlinkat(dirfd: cint; path: cstring; flags: cint): cint
  {.importc: "unlinkat", header: "<unistd.h>".}
proc c_mkdirat(dirfd: cint; path: cstring; mode: Mode): cint
  {.importc: "mkdirat", header: "<sys/stat.h>".}
proc c_fdopendir(fd: cint): ptr DIR {.importc: "fdopendir", header: "<dirent.h>".}

type
  StatFs {.importc: "struct statfs", header: "<sys/vfs.h>".} = object
    f_type: clong
proc c_fstatfs(fd: cint; buf: var StatFs): cint
  {.importc: "fstatfs", header: "<sys/vfs.h>".}

type
  AddonSecretsFailed* = object of CatchableError
    ## A recipient key that may not be used, an envelope that does not
    ## open, a declared secret the envelope does not carry, or a
    ## materialisation that was refused. The deploy agent reports it as
    ## ``aoSecretsFailed`` (exit 2: an operator must act); an apply refuses
    ## with it before anything is written.

  SecretsLayout* = object
    ## Where the secrets live, and what the checks require. Production uses
    ## ``defaultSecretsLayout``; the unit tests point it at a scratch
    ## directory with the test user as the required owner.
    agentDir*: string
      ## The deploy agent's directory: the key, its public half, the next
      ## key during a rotation, the retained sealed envelope.
    runDir*: string
      ## Where plaintext is materialised (``/run/repro/secrets``).
    owner*: int
      ## The uid that must own the key and every secrets directory (root).
    requireTmpfs*: bool
      ## Refuse a ``runDir`` that is not on a tmpfs (or ramfs).

  RetainedEnvelope* = object
    ## The sealed envelope kept for re-materialisation, with the target
    ## name it was sealed for (the KDF binds it).
    target*: string
    sealed*: SealedSecrets

  OpenedEnvelope* = object
    files*: seq[SecretFile]
    byNextKey*: bool
      ## Opened by ``recipient.key.next``: the producer has moved to the
      ## new key, and accepting the envelope retires the old one.

const
  RecipientKeyName* = "recipient.key"
  RecipientPubName* = "recipient.pub"
  NextRecipientKeyName* = "recipient.key.next"
  RetainedEnvelopeName* = "sealed-secrets"
  RetiredKeyName* = "recipient.key.retired"
    ## Used only by the ``rotation-keeps-old-key`` negative control.
  SecretFileMode* = 0o400
  SecretDirMode* = 0o700
  RetainedMagic = "RAOSEAL1\n"
    ## The retained envelope's own framing (it is not an RDMF manifest:
    ## nothing in it is signed, and it never leaves the host).
  TmpfsMagic = 0x01021994
  RamfsMagic = 0x858458f6

proc defaultSecretsLayout*(): SecretsLayout =
  ## The add-on host's layout (spec §5.3, §10.3).
  when mutated("secrets-on-disk"):
    # FALSIFYING MUTATION (e2e_addon_no_plaintext_secret_on_disk): the
    # plaintext goes to a directory on the root filesystem
    # (``SecretsRunRoot`` is /var/lib/repro/secrets in this build, for the
    # units' LoadCredential= too), and the tmpfs check that would refuse it
    # is off.
    SecretsLayout(agentDir: "/var/lib/repro/agent",
                  runDir: SecretsRunRoot, owner: 0,
                  requireTmpfs: false)
  else:
    SecretsLayout(agentDir: "/var/lib/repro/agent", runDir: SecretsRunRoot,
                  owner: 0, requireTmpfs: true)

proc recipientKeyPath*(l: SecretsLayout): string = l.agentDir / RecipientKeyName
proc recipientPubPath*(l: SecretsLayout): string = l.agentDir / RecipientPubName
proc nextRecipientKeyPath*(l: SecretsLayout): string =
  l.agentDir / NextRecipientKeyName
proc retainedEnvelopePath*(l: SecretsLayout): string =
  l.agentDir / RetainedEnvelopeName

proc fail(msg: string) {.noreturn.} =
  raise newException(AddonSecretsFailed, "aoSecretsFailed: " & msg)

proc errText(): string = osErrorMsg(osLastError())

proc stagedSecretName*(name: string): string =
  ## The hidden temporary name a secret is created under before it is
  ## renamed into place (the same shape as the no-follow writer's).
  "." & name & ".repro-tmp-" & $getCurrentProcessId()

# ---------------------------------------------------------------------------
# The recipient key, checked at load.
# ---------------------------------------------------------------------------

proc readAllFd(fd: cint; what: string; limit = 64 * 1024): string =
  var buf: array[4096, char]
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0:
      if errno == EINTR: continue
      fail("cannot read " & what & ": " & errText())
    if n == 0: break
    for i in 0 ..< n: result.add(buf[i])
    if result.len > limit:
      fail(what & " is larger than " & $limit & " bytes")

proc keyModeProblem*(st: Stat; owner: int): string =
  ## Why a recipient key with this ``stat`` may not be used, or "": it must
  ## be a regular file owned by ``owner`` that neither group nor others may
  ## read or write (threat model G4, T21). A key readable by more than root
  ## may have been copied; using it would keep sealing secrets to a key
  ## that is no longer private.
  if not S_ISREG(st.st_mode):
    return "is not a regular file"
  if int(st.st_uid) != owner:
    return "is owned by uid " & $st.st_uid & ", not " & $owner
  if (int(st.st_mode) and 0o077) != 0:
    return "is accessible to group or others (mode " &
      toOct(int(st.st_mode) and 0o7777, 4) & ")"
  ""

proc loadRecipientKeyChecked*(path: string; owner: int):
    peerAuth.PrivateKeyBytes =
  ## The recipient private key at ``path``, refused with
  ## ``AddonSecretsFailed`` before it is parsed -- before any envelope is
  ## opened -- unless its owner and mode pass ``keyModeProblem``. The
  ## descriptor is opened with ``O_NOFOLLOW`` and the checks read IT, so a
  ## link at the path, or a file swapped in between a check and the read,
  ## cannot pass a check meant for another file.
  let fd = posix.open(path.cstring, O_RDONLY or oNoFollow or oCloExec)
  if fd < 0:
    let e = errno
    if e == ELOOP:
      fail("recipient key " & path & " is a symbolic link; refusing it")
    fail("cannot open recipient key " & path & ": " & errText())
  defer: discard posix.close(fd)
  var st: Stat
  if fstat(fd, st) != 0:
    fail("cannot stat recipient key " & path & ": " & errText())
  when not mutated("recipient-key-mode-unchecked"):
    let why = keyModeProblem(st, owner)
    if why.len > 0:
      fail("recipient key " & path & " " & why & "; refusing to open any " &
        "envelope with it (chmod 0400 and chown root it, and rotate it " &
        "with `repro system addon rotate-recipient-key` if anyone else " &
        "may have read it)")
  try:
    peerAuth.parsePrivateKeyText(readAllFd(fd, path), path)
  except CatchableError as e:
    fail("recipient key " & path & " is not usable: " & e.msg)

# ---------------------------------------------------------------------------
# The retained sealed envelope.
# ---------------------------------------------------------------------------

proc putU32(buf: var string; v: uint32) =
  for shift in countup(0, 24, 8):
    buf.add(char((v shr uint32(shift)) and 0xff'u32))

proc getU32(buf: string; pos: var int): uint32 =
  if buf.len - pos < 4:
    raise newException(ValueError, "truncated")
  for i in 0 ..< 4:
    result = result or (uint32(ord(buf[pos + i])) shl uint32(i * 8))
  inc pos, 4

proc encodeRetained*(env: RetainedEnvelope): string =
  ## ``RAOSEAL1\n``, the target, then the sealed section's four fields.
  result = RetainedMagic
  putU32(result, uint32(env.target.len))
  result.add(env.target)
  for b in env.sealed.ephemeralPubKey: result.add(char(b))
  for b in env.sealed.nonce: result.add(char(b))
  for b in env.sealed.tag: result.add(char(b))
  putU32(result, uint32(env.sealed.ciphertext.len))
  for b in env.sealed.ciphertext: result.add(char(b))

proc decodeRetained*(text: string): RetainedEnvelope =
  ## Inverse of ``encodeRetained``; trailing or missing bytes refuse.
  if not text.startsWith(RetainedMagic):
    raise newException(ValueError, "not a retained sealed envelope")
  var pos = RetainedMagic.len
  let tlen = int(getU32(text, pos))
  if tlen > 4096 or text.len - pos < tlen:
    raise newException(ValueError, "truncated target")
  result.target = text[pos ..< pos + tlen]
  inc pos, tlen
  proc take(n: int): string =
    if text.len - pos < n:
      raise newException(ValueError, "truncated")
    result = text[pos ..< pos + n]
    inc pos, n
  let pub = take(result.sealed.ephemeralPubKey.len)
  for i, c in pub: result.sealed.ephemeralPubKey[i] = byte(c)
  let nonce = take(GcmNonceLen)
  for i, c in nonce: result.sealed.nonce[i] = byte(c)
  let tag = take(GcmTagLen)
  for i, c in tag: result.sealed.tag[i] = byte(c)
  let clen = int(getU32(text, pos))
  let ct = take(clen)
  result.sealed.ciphertext = newSeq[byte](ct.len)
  for i, c in ct: result.sealed.ciphertext[i] = byte(c)
  if pos != text.len:
    raise newException(ValueError, "trailing bytes")

proc openAgentDir(l: SecretsLayout): cint =
  ## The agent directory, opened without following a link, required to be
  ## a directory of ``l.owner`` that nobody else may enter (``0700``).
  result = posix.open(l.agentDir.cstring,
                      O_RDONLY or oDirectory or oNoFollow or oCloExec)
  if result < 0:
    fail("cannot open " & l.agentDir & ": " & errText())
  var st: Stat
  if fstat(result, st) != 0 or int(st.st_uid) != l.owner or
      (int(st.st_mode) and 0o077) != 0:
    discard posix.close(result)
    fail(l.agentDir & " must be a directory owned by uid " & $l.owner &
      " with mode 0700")

proc writeAgentFile(l: SecretsLayout; leaf, content: string; mode: int) =
  ## Write ``agentDir/leaf`` atomically and never through a link: a hidden
  ## temporary created ``O_EXCL|O_NOFOLLOW`` with its final mode, fsynced,
  ## renamed over the leaf, and the directory fsynced.
  let dfd = openAgentDir(l)
  defer: discard posix.close(dfd)
  var st: Stat
  if c_fstatat(dfd, leaf.cstring, st, atSymlinkNoFollow) == 0 and
      S_ISLNK(st.st_mode):
    fail("refusing to write " & l.agentDir / leaf & ": it is a symbolic link")
  let tmp = stagedSecretName(leaf)
  discard c_unlinkat(dfd, tmp.cstring, 0)
  let fd = c_openat(dfd, tmp.cstring,
    O_WRONLY or O_CREAT or O_EXCL or oNoFollow or oCloExec, Mode(mode))
  if fd < 0:
    fail("cannot create " & l.agentDir / tmp & ": " & errText())
  var ok = false
  try:
    var off = 0
    while off < content.len:
      let n = posix.write(fd, unsafeAddr content[off], content.len - off)
      if n < 0:
        if errno == EINTR: continue
        fail("cannot write " & l.agentDir / leaf & ": " & errText())
      off += n
    if fsync(fd) != 0:
      fail("cannot flush " & l.agentDir / leaf & ": " & errText())
    ok = true
  finally:
    discard posix.close(fd)
    if not ok: discard c_unlinkat(dfd, tmp.cstring, 0)
  if c_renameat(dfd, tmp.cstring, dfd, leaf.cstring) != 0:
    let msg = errText()
    discard c_unlinkat(dfd, tmp.cstring, 0)
    fail("cannot publish " & l.agentDir / leaf & ": " & msg)
  discard fsync(dfd)

proc readAgentFile(l: SecretsLayout; leaf: string): tuple[present: bool; text: string] =
  let dfd = openAgentDir(l)
  defer: discard posix.close(dfd)
  let fd = c_openat(dfd, leaf.cstring, O_RDONLY or oNoFollow or oCloExec, Mode(0))
  if fd < 0:
    if errno == ENOENT: return (false, "")
    fail("cannot open " & l.agentDir / leaf & ": " & errText())
  defer: discard posix.close(fd)
  (true, readAllFd(fd, l.agentDir / leaf, limit = 256 * 1024 * 1024))

proc writeRetained*(l: SecretsLayout; env: RetainedEnvelope) =
  ## Keep ``env`` as the host's sealed envelope (``0600``, root).
  writeAgentFile(l, RetainedEnvelopeName, encodeRetained(env), 0o600)

proc readRetained*(l: SecretsLayout): tuple[present: bool; env: RetainedEnvelope] =
  let (present, text) = readAgentFile(l, RetainedEnvelopeName)
  if not present: return
  try:
    (true, decodeRetained(text))
  except ValueError as e:
    fail("the retained sealed envelope " & retainedEnvelopePath(l) &
      " is malformed (" & e.msg & ")")

# ---------------------------------------------------------------------------
# Opening, accepting, rotating.
# ---------------------------------------------------------------------------

proc keyExists(path: string): bool =
  var st: Stat
  lstat(path.cstring, st) == 0

proc openEnvelope*(l: SecretsLayout; env: RetainedEnvelope): OpenedEnvelope =
  ## Open ``env`` with the host's key. During a rotation the next key is
  ## tried first (the producer seals to it once it has it), then the
  ## current one. Either key is checked at load. Raises
  ## ``AddonSecretsFailed`` when neither opens it.
  var tried: seq[string]
  if keyExists(nextRecipientKeyPath(l)):
    let k = loadRecipientKeyChecked(nextRecipientKeyPath(l), l.owner)
    try:
      return OpenedEnvelope(files: openSecrets(k, env.target, env.sealed),
                            byNextKey: true)
    except SecretsError as e:
      tried.add("the next key: " & e.msg)
  let k = loadRecipientKeyChecked(recipientKeyPath(l), l.owner)
  try:
    return OpenedEnvelope(files: openSecrets(k, env.target, env.sealed))
  except SecretsError as e:
    tried.add("the current key: " & e.msg)
  when mutated("rotation-keeps-old-key"):
    # NEGATIVE CONTROL (e2e_addon_recipient_key_rotation): the retired key
    # was kept, and still opens what was sealed to it.
    let retired = l.agentDir / RetiredKeyName
    if keyExists(retired):
      let old = loadRecipientKeyChecked(retired, l.owner)
      try:
        return OpenedEnvelope(files: openSecrets(old, env.target, env.sealed))
      except SecretsError as e:
        tried.add("the retired key: " & e.msg)
  fail("the sealed envelope for target '" & env.target & "' does not open " &
    "with this host's recipient key (" & tried.join("; ") & ")")

proc retireCurrentKey*(l: SecretsLayout) =
  ## Finish a rotation: the next key becomes the recipient key, and the old
  ## key's bytes are overwritten before the rename unlinks it, so its
  ## scalar does not linger in the file's blocks. The public half is
  ## rewritten to match. Idempotent once done.
  let next = nextRecipientKeyPath(l)
  if not keyExists(next): return
  let newKey = loadRecipientKeyChecked(next, l.owner)
  let dfd = openAgentDir(l)
  defer: discard posix.close(dfd)
  when mutated("rotation-keeps-old-key"):
    discard c_renameat(dfd, RecipientKeyName.cstring, dfd,
                       RetiredKeyName.cstring)
  else:
    let ofd = c_openat(dfd, RecipientKeyName.cstring,
                       O_WRONLY or oNoFollow or oCloExec, Mode(0))
    if ofd >= 0:
      var st: Stat
      if fstat(ofd, st) == 0 and S_ISREG(st.st_mode):
        let zeros = newString(int(st.st_size))
        if zeros.len > 0:
          discard posix.write(ofd, unsafeAddr zeros[0], zeros.len)
        discard fsync(ofd)
      discard posix.close(ofd)
  if c_renameat(dfd, NextRecipientKeyName.cstring, dfd,
                RecipientKeyName.cstring) != 0:
    fail("cannot retire the old recipient key: " & errText())
  discard fsync(dfd)
  writeAgentFile(l, RecipientPubName,
    peerAuth.publicKeyHex(peerAuth.derivePublicKey(newKey)) & "\n", 0o444)

proc rotateRecipientKey*(l: SecretsLayout): tuple[publicKeyHex: string; created: bool] =
  ## Generate the next recipient key beside the current one (``0400`` at
  ## creation, never replacing anything: ``ensureRecipientKeyFile``) and
  ## return its public half for the producer to seal to. A rotation already
  ## in progress returns the pending key's public half again.
  discard loadRecipientKeyChecked(recipientKeyPath(l), l.owner)
  let next = nextRecipientKeyPath(l)
  if keyExists(next):
    let k = loadRecipientKeyChecked(next, l.owner)
    return (peerAuth.publicKeyHex(peerAuth.derivePublicKey(k)), false)
  let r = ensureRecipientKeyFile(next)
  discard loadRecipientKeyChecked(next, l.owner)
  (peerAuth.publicKeyHex(r.publicKey), r.created)

proc acceptEnvelope*(l: SecretsLayout; env: RetainedEnvelope): OpenedEnvelope =
  ## A new sealed section (from the deploy agent, or rebuilt by ``secret
  ## put``): it must open, then it becomes the retained envelope, and when
  ## the next key opened it the old key is retired. Retained FIRST, so a
  ## crash between the two leaves an envelope that the next key (still
  ## there) opens, never one that only a deleted key could.
  result = openEnvelope(l, env)
  writeRetained(l, env)
  if result.byNextKey:
    retireCurrentKey(l)

# ---------------------------------------------------------------------------
# Materialisation.
# ---------------------------------------------------------------------------

proc checkOwnedPrivateDir(fd: cint; path: string; owner: int) =
  ## A secrets directory: ours (``owner``) and ``0700``. A wider mode is
  ## narrowed on the descriptor (nothing is created in it before); another
  ## owner is refused.
  var st: Stat
  if fstat(fd, st) != 0:
    fail("cannot stat " & path & ": " & errText())
  if not S_ISDIR(st.st_mode):
    fail(path & " is not a directory")
  if int(st.st_uid) != owner:
    fail(path & " is owned by uid " & $st.st_uid & ", not " & $owner)
  if (int(st.st_mode) and 0o7777) != SecretDirMode:
    if fchmod(fd, Mode(SecretDirMode)) != 0:
      fail("cannot set mode 0700 on " & path & ": " & errText())

proc openOrCreateDirAt(parentFd: cint; leaf, path: string; owner: int): cint =
  ## ``leaf`` under ``parentFd``: created ``0700`` with ``mkdirat`` when
  ## missing, opened ``O_NOFOLLOW`` (a link is refused), checked.
  var fd = c_openat(parentFd, leaf.cstring,
    O_RDONLY or oDirectory or oNoFollow or oCloExec, Mode(0))
  if fd < 0 and errno == ENOENT:
    if c_mkdirat(parentFd, leaf.cstring, Mode(SecretDirMode)) != 0 and
        errno != EEXIST:
      fail("cannot create " & path & ": " & errText())
    fd = c_openat(parentFd, leaf.cstring,
      O_RDONLY or oDirectory or oNoFollow or oCloExec, Mode(0))
  if fd < 0:
    if errno in [ELOOP, ENOTDIR]:
      fail("refusing " & path & ": it is a symbolic link or not a directory")
    fail("cannot open " & path & ": " & errText())
  checkOwnedPrivateDir(fd, path, owner)
  fd

proc readLeafNoFollow(dfd: cint; leaf: string): tuple[present: bool; text: string; mode: int] =
  let fd = c_openat(dfd, leaf.cstring, O_RDONLY or oNoFollow or oCloExec, Mode(0))
  if fd < 0: return
  defer: discard posix.close(fd)
  var st: Stat
  if fstat(fd, st) != 0 or not S_ISREG(st.st_mode): return
  (true, readAllFd(fd, leaf, limit = 256 * 1024 * 1024),
   int(st.st_mode) and 0o7777)

proc removeTreeAt(dfd: cint; leaf: string) =
  ## Remove ``leaf`` under ``dfd`` without following anything: a file or
  ## link is unlinked, a directory emptied the same way and removed.
  var st: Stat
  if c_fstatat(dfd, leaf.cstring, st, atSymlinkNoFollow) != 0: return
  if S_ISDIR(st.st_mode):
    let sub = c_openat(dfd, leaf.cstring,
      O_RDONLY or oDirectory or oNoFollow or oCloExec, Mode(0))
    if sub >= 0:
      let d = c_fdopendir(sub)
      if d != nil:
        var names: seq[string]
        while true:
          let ent = readdir(d)
          if ent == nil: break
          let n = $cast[cstring](addr ent.d_name)
          if n notin [".", ".."]: names.add(n)
        for n in names: removeTreeAt(sub, n)
        discard closedir(d)
      else:
        discard posix.close(sub)
    discard c_unlinkat(dfd, leaf.cstring, atRemoveDir)
  else:
    discard c_unlinkat(dfd, leaf.cstring, 0)

proc listDirAt(dfd: cint): seq[string] =
  let dup = c_openat(dfd, ".".cstring, O_RDONLY or oDirectory or oCloExec, Mode(0))
  if dup < 0: return
  let d = c_fdopendir(dup)
  if d == nil:
    discard posix.close(dup)
    return
  while true:
    let ent = readdir(d)
    if ent == nil: break
    let n = $cast[cstring](addr ent.d_name)
    if n notin [".", ".."]: result.add(n)
  discard closedir(d)

proc writeSecretAt(dfd: cint; dirPath, name, content: string) =
  ## Create ``dirPath/name`` with its final mode at ``open(2)`` and publish
  ## it by ``renameat`` (see the module header).
  let staged = stagedSecretName(name)
  let path = dirPath / name
  when mutated("secrets-write-then-narrow"):
    # FALSIFYING MUTATION (t_addon_secret_files_created_private_and_never_
    # through_symlinks): the reused deploy agent's write before it was
    # fixed -- a path-based write that follows a link at the staged name
    # and creates the file with the process umask's mode, narrowed after.
    writeFile(dirPath / staged, content)
    setFilePermissions(dirPath / staged, {fpUserRead})
    moveFile(dirPath / staged, path)
  else:
    var st: Stat
    if c_fstatat(dfd, staged.cstring, st, atSymlinkNoFollow) == 0:
      if not S_ISREG(st.st_mode):
        fail("refusing to write secret " & path & ": its temporary name " &
          staged & " is a symbolic link or not a regular file")
      # A leftover of a materialisation killed between create and rename.
      if c_unlinkat(dfd, staged.cstring, 0) != 0:
        fail("cannot remove the leftover " & dirPath / staged & ": " & errText())
    if c_fstatat(dfd, name.cstring, st, atSymlinkNoFollow) == 0 and
        not S_ISREG(st.st_mode):
      fail("refusing to write secret " & path & ": a symbolic link or " &
        "non-file is at its path")
    let fd = c_openat(dfd, staged.cstring,
      O_WRONLY or O_CREAT or O_EXCL or oNoFollow or oCloExec,
      Mode(SecretFileMode))
    if fd < 0:
      fail("cannot create " & dirPath / staged & ": " & errText())
    var ok = false
    try:
      # The umask can only take bits away from 0400; a umask that took the
      # owner's read bit leaves 0000, which is restored here -- a widening
      # back to the declared mode, never a narrowing after the write.
      var fst: Stat
      if fstat(fd, fst) == 0 and (int(fst.st_mode) and 0o7777) != SecretFileMode:
        if fchmod(fd, Mode(SecretFileMode)) != 0:
          fail("cannot set mode 0400 on " & path & ": " & errText())
      var off = 0
      while off < content.len:
        let n = posix.write(fd, unsafeAddr content[off], content.len - off)
        if n < 0:
          if errno == EINTR: continue
          fail("cannot write " & path & ": " & errText())
        off += n
      ok = true
    finally:
      discard posix.close(fd)
      if not ok: discard c_unlinkat(dfd, staged.cstring, 0)
    # The destination again, just before the rename: a link planted since
    # the check above is refused, not replaced silently.
    if c_fstatat(dfd, name.cstring, st, atSymlinkNoFollow) == 0 and
        not S_ISREG(st.st_mode):
      discard c_unlinkat(dfd, staged.cstring, 0)
      fail("refusing to write secret " & path & ": a symbolic link or " &
        "non-file is at its path")
    if c_renameat(dfd, staged.cstring, dfd, name.cstring) != 0:
      let msg = errText()
      discard c_unlinkat(dfd, staged.cstring, 0)
      fail("cannot publish " & path & ": " & msg)

proc materialise*(l: SecretsLayout; decls: openArray[SecretFileDecl];
                  files: openArray[SecretFile]; seamStateDir = ""):
    seq[string] =
  ## Make ``l.runDir`` hold exactly the declared secrets: each
  ## ``<service>/<name>`` of ``decls`` with the bytes of the sealed entry of
  ## that path, and nothing else (an undeclared file or service directory
  ## is removed). Returns the services whose secrets changed, sorted. A
  ## declared entry ``files`` does not carry refuses before anything is
  ## written. With ``seamStateDir`` the seam build can stop after the first
  ## secret is written (``secrets-mid-write``).
  var byPath: seq[(string, string)]
  for f in files:
    var c = newString(f.content.len)
    for i, b in f.content: c[i] = char(b)
    byPath.add((f.path, c))
  proc lookup(p: string): tuple[found: bool; content: string] =
    for (k, v) in byPath:
      if k == p: return (true, v)
  var missing: seq[string]
  for d in decls:
    if not lookup(secretEntryPath(d.service, d.name)).found:
      missing.add(secretEntryPath(d.service, d.name))
  if missing.len > 0:
    fail("the sealed envelope carries no entry for " & missing.join(", ") &
      "; nothing was materialised")
  let parent = parentDir(l.runDir)
  # `/run/repro` (0755 root) is gone after every boot; it is re-created
  # without following a link on the way.
  try:
    createDirsNoFollow(parent, 0o755)
  except CatchableError as e:
    fail("cannot create " & parent & ": " & e.msg)
  let pfd = posix.open(parent.cstring,
                       O_RDONLY or oDirectory or oNoFollow or oCloExec)
  if pfd < 0:
    fail("cannot open " & parent & ": " & errText())
  defer: discard posix.close(pfd)
  let rfd = openOrCreateDirAt(pfd, extractFilename(l.runDir), l.runDir, l.owner)
  defer: discard posix.close(rfd)
  if l.requireTmpfs:
    var sf: StatFs
    if c_fstatfs(rfd, sf) != 0:
      fail("cannot statfs " & l.runDir & ": " & errText())
    let t = uint32(cast[culong](sf.f_type) and 0xffffffff'u)
    if t != uint32(TmpfsMagic) and t != uint32(RamfsMagic):
      fail(l.runDir & " is not on a tmpfs (filesystem type 0x" &
        toHex(int(t), 8) & "); plaintext secrets never go to a disk")
  var services: seq[string]
  for d in decls:
    if d.service notin services: services.add(d.service)
  services.sort()
  var written = 0
  for svc in services:
    let sdir = l.runDir / svc
    let sfd = openOrCreateDirAt(rfd, svc, sdir, l.owner)
    defer: discard posix.close(sfd)
    var names: seq[string]
    for d in decls:
      if d.service == svc: names.add(d.name)
    names.sort()
    var changed = false
    for n in names:
      let want = lookup(secretEntryPath(svc, n)).content
      let have = readLeafNoFollow(sfd, n)
      if have.present and have.text == want and have.mode == SecretFileMode:
        continue
      writeSecretAt(sfd, sdir, n, want)
      changed = true
      inc written
      if written == 1 and seamStateDir.len > 0:
        seamPause(seamStateDir, "secrets-mid-write")
    for leaf in listDirAt(sfd):
      if leaf notin names:
        removeTreeAt(sfd, leaf)
        changed = true
    if changed: result.add(svc)
  for leaf in listDirAt(rfd):
    if leaf notin services:
      removeTreeAt(rfd, leaf)
      if leaf notin result: result.add(leaf)
  result.sort()

proc clearMaterialised*(l: SecretsLayout): seq[string] =
  ## Remove every materialised secret (a generation that declares none).
  if not dirExists(l.runDir): return
  # Removing plaintext is right wherever it is: the tmpfs check guards
  # writes, not this.
  var relaxed = l
  relaxed.requireTmpfs = false
  materialise(relaxed, [], [])

proc materialiseFromRetained*(l: SecretsLayout;
                              decls: openArray[SecretFileDecl];
                              seamStateDir = ""): seq[string] =
  ## Re-materialise ``decls`` from the retained envelope (at apply and at
  ## boot). A generation that declares no secret needs no key and no
  ## envelope; one that does refuses (``AddonSecretsFailed``) when either
  ## is missing or unusable.
  if decls.len == 0:
    return clearMaterialised(l)
  let (present, env) = readRetained(l)
  if not present:
    fail("the generation declares " & $decls.len & " secret(s), but no " &
      "sealed envelope is retained at " & retainedEnvelopePath(l) &
      " (deliver one through the deploy agent or `repro system addon " &
      "secret put`)")
  materialise(l, decls, openEnvelope(l, env).files, seamStateDir)

proc checkSecretsAvailable*(l: SecretsLayout; decls: openArray[SecretFileDecl]) =
  ## Everything ``materialiseFromRetained`` needs is there -- a key that
  ## passes its check, an envelope that opens, an entry per declaration --
  ## decided before a switch writes anything. Writes nothing.
  if decls.len == 0: return
  let (present, env) = readRetained(l)
  if not present:
    fail("the generation declares " & $decls.len & " secret(s), but no " &
      "sealed envelope is retained at " & retainedEnvelopePath(l))
  let opened = openEnvelope(l, env)
  var missing: seq[string]
  for d in decls:
    var found = false
    for f in opened.files:
      if f.path == secretEntryPath(d.service, d.name): found = true
    if not found: missing.add(secretEntryPath(d.service, d.name))
  if missing.len > 0:
    fail("the sealed envelope carries no entry for " & missing.join(", "))
