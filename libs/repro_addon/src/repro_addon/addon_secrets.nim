## Secrets on an add-on host (ReproOS Add-On Mode §10.3, §7.7 step 3).
##
## What is at rest, and where:
##
## - the **recipient key** (``/var/lib/repro/agent/recipient.key``, ``0400``
##   root), generated on the host at bootstrap (``bootstrap.nim``) and the
##   only secret on disk;
## - **sealed** envelopes only: the deploy agent's v2 sealed section
##   (``repro_deploy_agent/secrets``) with the target it was sealed for,
##   which nothing can read without the key. Three kinds of copy exist:
##   - ``/var/lib/repro/agent/sealed-secrets``: the latest one accepted,
##     what an operator's next apply materialises from;
##   - ``/var/lib/repro/agent/sealed-secrets.staged``: a deploy agent's
##     section between the tick that received it and the commit of the
##     apply that uses it; the commit promotes it to the latest, a failed
##     apply discards it, so a section whose apply failed never replaces
##     what the host runs;
##   - ``<state>/generations/<id>/sealed-secrets``: the one each committed
##     generation materialised from, so that the boot, a revert and a
##     rollback re-materialise exactly what that generation had.
##
## Plaintext exists only under ``/run/repro/secrets/<service>/<name>``. That
## directory is a ``ramfs`` mounted in the host's mount namespace: unlike a
## tmpfs, ramfs pages are never written to swap, so no plaintext page can
## reach a disk through the swap device (threat model G18). The directory is
## ``0700`` root, each file ``0400`` root, and systemd hands a file to the
## one unit that names it in its ``credentials`` (``LoadCredential=``).
## Which entries are materialised is decided by a generation's
## ``secrets.secretFile`` declarations (``repro_infra/profile
## .SecretFileDecl``); a sealed entry no declaration names is never
## written, and a file no declaration covers any longer is removed.
##
## The add-on's own processes may run inside a private mount namespace (the
## writable store view, ``repro_elevation/store_view``; a systemd unit's
## own namespace). Every path under the secrets directory is therefore
## opened through ``/proc/1/root`` -- the host's root, resolved in PID 1's
## mount namespace -- and the ramfs is mounted there by a transient unit of
## PID 1 (``host_exec.runInHostNamespaces``).
##
## The properties this module exists for, each with a gate:
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
##   and left as it is; a leaf that is not a regular file (a FIFO) is
##   refused without blocking on it (``O_NONBLOCK``)
##   (``t_addon_secret_files_created_private_and_never_through_symlinks``);
## - **plaintext never reaches a disk**: the directory and every service
##   directory below it must be on the ramfs (``fstatfs`` on the descriptor
##   then written through); the processes that hold plaintext are not
##   dumpable and write no core file (``hardenProcessForSecrets``); the
##   plaintext buffers this module owns are zeroed after use
##   (``e2e_addon_no_plaintext_secret_on_disk``, swap pass included).
##   *Limit:* Nim strings are copied by value in places the module does not
##   control (the codec's decode, the GC moving a seq), so zeroing what this
##   module owns narrows, and does not close, the window in which plaintext
##   sits in the process's heap; the heap itself is never swapped out only
##   because nothing here locks it, and the process is short-lived.
##
## Recipient-key rotation (CRED-2, G36): ``rotateRecipientKey`` generates
## ``recipient.key.next`` beside the current key and returns its public
## half for the producer to seal to. When an apply commits a generation
## whose envelope only the next key opens, the current key is retired
## (``retireCurrentKey``): every envelope the host keeps that the old key
## opens is re-sealed to the new key first (so a revert or rollback to an
## older generation still opens), then the old key's file is overwritten
## and the next key renamed over it. Completion is idempotent:
## ``reconcileRotation`` brings ``recipient.pub`` and the ledger's key
## digests in line with the key on every accept, commit and re-assert, so a
## crash between the rename and those writes cannot leave drift.
##
## Nothing here takes the host's apply lock; the callers (``secrets_ops``,
## the switch) hold it around every call that writes.

import std/[algorithm, os, posix, strutils]

import repro_infra/profile

import repro_elevation/nofollow_write
import repro_deploy_agent/secrets as agentSecrets
import repro_peer_cache/auth as peerAuth

import ./fingerprint
import ./host_exec
import ./ledger
import ./mutations
import ./seams

export agentSecrets.SecretFile, agentSecrets.SealedSecrets

var
  oDirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
  oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  oCloExec {.importc: "O_CLOEXEC", header: "<fcntl.h>".}: cint
  oNonBlock {.importc: "O_NONBLOCK", header: "<fcntl.h>".}: cint
  atSymlinkNoFollow {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint
  atRemoveDir {.importc: "AT_REMOVEDIR", header: "<fcntl.h>".}: cint
  prSetDumpable {.importc: "PR_SET_DUMPABLE", header: "<sys/prctl.h>".}: cint
  rlimitCore {.importc: "RLIMIT_CORE", header: "<sys/resource.h>".}: cint

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
proc c_symlinkat(target: cstring; newdirfd: cint; linkpath: cstring): cint
  {.importc: "symlinkat", header: "<unistd.h>".}
proc c_prctl(option: cint; arg2: culong): cint
  {.importc: "prctl", header: "<sys/prctl.h>", varargs.}

type
  RLimitObj {.importc: "struct rlimit", header: "<sys/resource.h>".} = object
    rlim_cur, rlim_max: culong
proc c_setrlimit(resource: cint; rlim: var RLimitObj): cint
  {.importc: "setrlimit", header: "<sys/resource.h>".}

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

  SecretsFs* = enum
    sfRamfs   ## the directory must be a ramfs (mounted if it is not one)
    sfTmpfs   ## a tmpfs or a ramfs is accepted (``secrets-on-tmpfs``)
    sfAny     ## no filesystem check (unit tests; ``secrets-on-disk``)

  SecretsLayout* = object
    ## Where the secrets live, and what the checks require. Production uses
    ## ``defaultSecretsLayout``; the unit tests point it at a scratch
    ## directory with the test user as the required owner.
    agentDir*: string
      ## The deploy agent's directory: the key, its public half, the next
      ## key during a rotation, the latest and staged envelopes.
    runDir*: string
      ## Where plaintext is materialised (``/run/repro/secrets``).
    owner*: int
      ## The uid that must own the key and every secrets directory (root).
    fs*: SecretsFs
    hostRoot*: string
      ## Prefix under which ``runDir`` is reached: ``/proc/1/root`` on a
      ## host (PID 1's mount namespace), "" in tests.

  RetainedEnvelope* = object
    ## A sealed envelope kept on the host, with the target name it was
    ## sealed for (the KDF binds it).
    target*: string
    sealed*: SealedSecrets

  OpenedEnvelope* = object
    files*: seq[SecretFile]
    byNextKey*: bool
      ## Opened by ``recipient.key.next``: the producer has moved to the
      ## new key, and committing a generation with it retires the old one.

const
  RecipientKeyName* = "recipient.key"
  RecipientPubName* = "recipient.pub"
  NextRecipientKeyName* = "recipient.key.next"
  RetainedEnvelopeName* = "sealed-secrets"
    ## The latest envelope, in the agent directory; also the name of each
    ## generation's own copy in its generation directory.
  StagedEnvelopeName* = "sealed-secrets.staged"
  RetiredKeyName* = "recipient.key.retired"
    ## Used only by the ``rotation-keeps-old-key`` negative control.
  SecretFileMode* = 0o400
  SecretDirMode* = 0o700
  RetainedMagic = "RAOSEAL1\n"
    ## The retained envelope's own framing (it is not an RDMF manifest:
    ## nothing in it is signed, and it never leaves the host).
  TmpfsMagic = 0x01021994
  RamfsMagic = 0x858458f6
  OnDiskSecretsDir* = "/var/lib/repro/secrets"
    ## Where the ``secrets-on-disk`` falsifying build materialises.

proc defaultSecretsLayout*(): SecretsLayout =
  ## The add-on host's layout (spec §5.3, §10.3).
  result = SecretsLayout(agentDir: "/var/lib/repro/agent",
    runDir: SecretsRunRoot, owner: 0, fs: sfRamfs, hostRoot: "/proc/1/root")
  when mutated("secrets-on-disk"):
    # FALSIFYING MUTATION (e2e_addon_no_plaintext_secret_on_disk): the
    # plaintext goes to a directory on the root filesystem, reached by the
    # units through a link at /run/repro/secrets (`prepareRunDir`), and no
    # filesystem check refuses it.
    result.runDir = OnDiskSecretsDir
    result.fs = sfAny
  elif mutated("secrets-on-tmpfs"):
    # FALSIFYING MUTATION (the swap pass of the same gate): a plain
    # directory on /run's tmpfs is accepted, whose pages can be swapped.
    result.fs = sfTmpfs

proc recipientKeyPath*(l: SecretsLayout): string = l.agentDir / RecipientKeyName
proc recipientPubPath*(l: SecretsLayout): string = l.agentDir / RecipientPubName
proc nextRecipientKeyPath*(l: SecretsLayout): string =
  l.agentDir / NextRecipientKeyName
proc latestEnvelopePath*(l: SecretsLayout): string =
  l.agentDir / RetainedEnvelopeName
proc retainedEnvelopePath*(l: SecretsLayout): string = latestEnvelopePath(l)
proc stagedEnvelopePath*(l: SecretsLayout): string =
  l.agentDir / StagedEnvelopeName
proc generationEnvelopePath*(generationDir: string): string =
  generationDir / RetainedEnvelopeName

proc fail(msg: string) {.noreturn.} =
  raise newException(AddonSecretsFailed, "aoSecretsFailed: " & msg)

proc errText(): string = osErrorMsg(osLastError())

proc stagedSecretName*(name: string): string =
  ## The hidden temporary name a secret is created under before it is
  ## renamed into place (the same shape as the no-follow writer's).
  "." & name & ".repro-tmp-" & $getCurrentProcessId()

# ---------------------------------------------------------------------------
# The process and its buffers.
# ---------------------------------------------------------------------------

proc hardenProcessForSecrets*() =
  ## Before a process holds plaintext: no core file (``RLIMIT_CORE`` 0) and
  ## not dumpable (``PR_SET_DUMPABLE`` 0: no core either, and no
  ## ``ptrace`` attach or ``/proc/<pid>/mem`` read by a non-root process),
  ## so a crash cannot write a secret to disk. Idempotent; a failure is
  ## refused, not ignored.
  var rl = RLimitObj(rlim_cur: 0, rlim_max: 0)
  if c_setrlimit(rlimitCore, rl) != 0:
    fail("cannot set RLIMIT_CORE to 0: " & errText())
  if c_prctl(prSetDumpable, culong(0)) != 0:
    fail("cannot clear PR_SET_DUMPABLE: " & errText())

proc wipe*(s: var string) =
  ## Zero a plaintext buffer this module owns before it is freed.
  if s.len > 0: zeroMem(addr s[0], s.len)

proc wipe*(files: var seq[SecretFile]) =
  for f in files.mitems:
    if f.content.len > 0: zeroMem(addr f.content[0], f.content.len)

# ---------------------------------------------------------------------------
# Reading leaves without blocking or following.
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
  zeroMem(addr buf[0], buf.len)

proc openRegularLeaf(dirfd: cint; leaf, what: string): cint =
  ## ``leaf`` under ``dirfd`` opened read-only, ``O_NOFOLLOW`` and
  ## ``O_NONBLOCK`` (a FIFO planted there does not block the open), and
  ## refused unless it is a regular file. -1 with ``ENOENT`` when absent.
  result = c_openat(dirfd, leaf.cstring,
    O_RDONLY or oNoFollow or oCloExec or oNonBlock, Mode(0))
  if result < 0:
    if errno == ENOENT: return -1
    if errno == ELOOP:
      fail(what & " is a symbolic link; refusing it")
    fail("cannot open " & what & ": " & errText())
  var st: Stat
  if fstat(result, st) != 0 or not S_ISREG(st.st_mode):
    discard posix.close(result)
    fail(what & " is not a regular file; refusing it")

# ---------------------------------------------------------------------------
# The recipient key, checked at load.
# ---------------------------------------------------------------------------

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
  ## descriptor is opened with ``O_NOFOLLOW`` and ``O_NONBLOCK`` and the
  ## checks read IT, so a link at the path, a FIFO, or a file swapped in
  ## between a check and the read cannot pass a check meant for another file.
  let fd = posix.open(path.cstring,
                      O_RDONLY or oNoFollow or oCloExec or oNonBlock)
  if fd < 0:
    let e = errno
    if e == ELOOP:
      fail("recipient key " & path & " is a symbolic link; refusing it")
    fail("cannot open recipient key " & path & ": " & errText())
  defer: discard posix.close(fd)
  var st: Stat
  if fstat(fd, st) != 0:
    fail("cannot stat recipient key " & path & ": " & errText())
  if not S_ISREG(st.st_mode):
    fail("recipient key " & path & " is not a regular file; refusing it")
  when not mutated("recipient-key-mode-unchecked"):
    let why = keyModeProblem(st, owner)
    if why.len > 0:
      fail("recipient key " & path & " " & why & "; refusing to open any " &
        "envelope with it (chmod 0400 and chown root it, and rotate it " &
        "with `repro system addon rotate-recipient-key` if anyone else " &
        "may have read it)")
  var text = readAllFd(fd, path)
  try:
    result = peerAuth.parsePrivateKeyText(text, path)
  except CatchableError as e:
    fail("recipient key " & path & " is not usable: " & e.msg)
  finally:
    wipe(text)

# ---------------------------------------------------------------------------
# Envelope files.
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

proc openParentOf(l: SecretsLayout; path: string): cint =
  ## The directory holding ``path``: the agent directory with its checks,
  ## any other (a generation directory) through a no-follow walk.
  if parentDir(path) == l.agentDir:
    return openAgentDir(l)
  try:
    openDirNoFollow(parentDir(path))
  except CatchableError as e:
    fail("cannot open " & parentDir(path) & ": " & e.msg)

proc writeFileAt(dfd: cint; dir, leaf, content: string; mode: int) =
  ## Write ``dir/leaf`` atomically and never through a link: a hidden
  ## temporary created ``O_EXCL|O_NOFOLLOW`` with its final mode, fsynced,
  ## renamed over the leaf, and the directory fsynced.
  var st: Stat
  if c_fstatat(dfd, leaf.cstring, st, atSymlinkNoFollow) == 0 and
      not S_ISREG(st.st_mode):
    fail("refusing to write " & dir / leaf & ": it is not a regular file")
  let tmp = stagedSecretName(leaf)
  discard c_unlinkat(dfd, tmp.cstring, 0)
  let fd = c_openat(dfd, tmp.cstring,
    O_WRONLY or O_CREAT or O_EXCL or oNoFollow or oCloExec, Mode(mode))
  if fd < 0:
    fail("cannot create " & dir / tmp & ": " & errText())
  var ok = false
  try:
    var off = 0
    while off < content.len:
      let n = posix.write(fd, unsafeAddr content[off], content.len - off)
      if n < 0:
        if errno == EINTR: continue
        fail("cannot write " & dir / leaf & ": " & errText())
      off += n
    if fsync(fd) != 0:
      fail("cannot flush " & dir / leaf & ": " & errText())
    ok = true
  finally:
    discard posix.close(fd)
    if not ok: discard c_unlinkat(dfd, tmp.cstring, 0)
  if c_renameat(dfd, tmp.cstring, dfd, leaf.cstring) != 0:
    let msg = errText()
    discard c_unlinkat(dfd, tmp.cstring, 0)
    fail("cannot publish " & dir / leaf & ": " & msg)
  if fsync(dfd) != 0:
    fail("cannot flush the directory " & dir & ": " & errText())

proc writeEnvelopeFile*(l: SecretsLayout; path: string; env: RetainedEnvelope) =
  ## Keep ``env`` at ``path`` (``0600``, root).
  let dfd = openParentOf(l, path)
  defer: discard posix.close(dfd)
  writeFileAt(dfd, parentDir(path), extractFilename(path),
              encodeRetained(env), 0o600)

proc readEnvelopeFile*(l: SecretsLayout; path: string):
    tuple[present: bool; env: RetainedEnvelope] =
  if not dirExists(parentDir(path)): return
  let dfd = openParentOf(l, path)
  defer: discard posix.close(dfd)
  let fd = openRegularLeaf(dfd, extractFilename(path), path)
  if fd < 0: return
  defer: discard posix.close(fd)
  let text = readAllFd(fd, path, limit = 256 * 1024 * 1024)
  try:
    (true, decodeRetained(text))
  except ValueError as e:
    fail("the sealed envelope " & path & " is malformed (" & e.msg & ")")

proc writeRetained*(l: SecretsLayout; env: RetainedEnvelope) =
  ## Keep ``env`` as the host's latest sealed envelope.
  writeEnvelopeFile(l, latestEnvelopePath(l), env)

proc readRetained*(l: SecretsLayout): tuple[present: bool; env: RetainedEnvelope] =
  readEnvelopeFile(l, latestEnvelopePath(l))

proc removeAgentLeaf(l: SecretsLayout; leaf: string) =
  let dfd = openAgentDir(l)
  defer: discard posix.close(dfd)
  if c_unlinkat(dfd, leaf.cstring, 0) != 0 and errno != ENOENT:
    fail("cannot remove " & l.agentDir / leaf & ": " & errText())
  discard fsync(dfd)

# ---------------------------------------------------------------------------
# Opening, staging, rotating.
# ---------------------------------------------------------------------------

proc keyExists(path: string): bool =
  var st: Stat
  lstat(path.cstring, st) == 0

proc openEnvelope*(l: SecretsLayout; env: RetainedEnvelope): OpenedEnvelope =
  ## Open ``env`` with the host's key. During a rotation the next key is
  ## tried first (the producer seals to it once it has it), then the
  ## current one. Either key is checked at load. Raises
  ## ``AddonSecretsFailed`` when neither opens it. The caller owns the
  ## plaintext and ``wipe``s it.
  hardenProcessForSecrets()
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

proc missingEntries(files: openArray[SecretFile];
                    decls: openArray[SecretFileDecl]): seq[string] =
  for d in decls:
    var found = false
    for f in files:
      if f.path == secretEntryPath(d.service, d.name): found = true
    if not found: result.add(secretEntryPath(d.service, d.name))

proc stageEnvelope*(l: SecretsLayout; env: RetainedEnvelope;
                    decls: openArray[SecretFileDecl]) =
  ## A deploy agent's sealed section, before its apply: it must open with
  ## the host's checked key and carry an entry for every declaration of the
  ## generation it comes with; then it is kept as the staged envelope. It
  ## replaces nothing the host runs: the apply's commit promotes it, a
  ## failed apply discards it.
  var opened = openEnvelope(l, env)
  let missing = missingEntries(opened.files, decls)
  wipe(opened.files)
  if missing.len > 0:
    fail("the sealed section carries no entry for " & missing.join(", ") &
      ", which the profile it comes with declares; nothing was accepted")
  when mutated("secrets-single-retained-envelope"):
    # FALSIFYING MUTATION (e2e_addon_secrets_follow_generations): the
    # round-1 design -- the section replaces the one retained envelope
    # before its apply, and every generation materialises from it.
    writeRetained(l, env)
  writeEnvelopeFile(l, stagedEnvelopePath(l), env)

proc discardStaged*(l: SecretsLayout) =
  if keyExists(stagedEnvelopePath(l)):
    removeAgentLeaf(l, StagedEnvelopeName)

proc derivedPubHex(l: SecretsLayout): string =
  peerAuth.publicKeyHex(peerAuth.derivePublicKey(
    loadRecipientKeyChecked(recipientKeyPath(l), l.owner)))

proc reconcileRotation*(l: SecretsLayout; ledgerPath: string): seq[string] =
  ## Bring what follows the key in line with it, idempotently: the public
  ## half (``recipient.pub``) and the ledger copy's digests of the key and
  ## its public half (``lcKey``, pinned since bootstrap). A crash after a
  ## rotation's rename and before these writes is completed here, on the
  ## next accept, commit or re-assert. Returns what was brought up to date.
  when mutated("rotation-not-reconciled"):
    # FALSIFYING MUTATION: a rotation cut short after its rename is never
    # completed (the public half and the ledger keep the old key's).
    return
  if not keyExists(recipientKeyPath(l)): return
  let pubHex = derivedPubHex(l)
  var current = ""
  if keyExists(recipientPubPath(l)):
    let dfd = openAgentDir(l)
    let fd = openRegularLeaf(dfd, RecipientPubName, recipientPubPath(l))
    if fd >= 0:
      current = readAllFd(fd, recipientPubPath(l)).strip()
      discard posix.close(fd)
    discard posix.close(dfd)
  if current != pubHex:
    let dfd = openAgentDir(l)
    defer: discard posix.close(dfd)
    writeFileAt(dfd, l.agentDir, RecipientPubName, pubHex & "\n", 0o444)
    result.add(recipientPubPath(l) & " rewritten for the current key")
  if ledgerPath.len == 0 or not fileExists(ledgerPath): return
  var led = readLedger(ledgerPath)
  var changed = false
  for e in led.entries.mitems:
    if e.class != lcKey or e.path notin [recipientKeyPath(l), recipientPubPath(l)] or
        not fileExists(e.path):
      continue
    let digest = sha256OfFile(e.path)
    let st = statOwner(e.path)
    if digest != e.sha256 or st.mode != e.mode or st.owner != e.owner:
      e.sha256 = digest
      e.mode = st.mode
      e.owner = st.owner
      changed = true
  if changed:
    writeLedger(ledgerPath, led)
    result.add(ledgerPath & ": the recipient key's ledger digests follow it")

proc retireCurrentKey*(l: SecretsLayout; resealPaths: openArray[string];
                       ledgerPath: string; seamStateDir = "") =
  ## Finish a rotation (CRED-2). First every kept envelope that the old key
  ## opens (``resealPaths``: the latest, each generation's copy) is
  ## re-sealed to the next key under the same target, so a revert or a
  ## rollback to an older generation still opens after the old key is
  ## gone; then the old key file is overwritten and the next key renamed
  ## over it; then ``reconcileRotation``. Idempotent once done.
  ##
  ## *What "deleted" means.* The overwrite replaces the old scalar's bytes
  ## in the file's blocks on a filesystem that writes in place (ext4,
  ## xfs). On a copy-on-write filesystem (btrfs, and any snapshot of the
  ## root) the overwrite lands in new blocks and the old ones survive until
  ## reused, and in every snapshot taken while the key existed; there,
  ## only the name is gone. The spec states this residual (§10.3).
  let next = nextRecipientKeyPath(l)
  if not keyExists(next): return
  let oldKey = loadRecipientKeyChecked(recipientKeyPath(l), l.owner)
  let newKey = loadRecipientKeyChecked(next, l.owner)
  let newPub = peerAuth.derivePublicKey(newKey)
  for p in resealPaths:
    let (present, env) = readEnvelopeFile(l, p)
    if not present: continue
    var files: seq[SecretFile]
    try:
      files = openSecrets(oldKey, env.target, env.sealed)
    except SecretsError:
      continue                     # sealed to the next key already
    writeEnvelopeFile(l, p, RetainedEnvelope(target: env.target,
      sealed: sealSecrets(newPub, env.target, files)))
    wipe(files)
  let dfd = openAgentDir(l)
  defer: discard posix.close(dfd)
  when mutated("rotation-keeps-old-key"):
    discard c_renameat(dfd, RecipientKeyName.cstring, dfd,
                       RetiredKeyName.cstring)
  else:
    var ofd = c_openat(dfd, RecipientKeyName.cstring,
                       O_WRONLY or oNoFollow or oCloExec or oNonBlock, Mode(0))
    if ofd < 0 and errno == EACCES:
      # Not root (a test): the 0400 file is made writable for its owner on
      # a descriptor first; root opens it for writing as it is.
      let rfd = c_openat(dfd, RecipientKeyName.cstring,
                         O_RDONLY or oNoFollow or oCloExec or oNonBlock, Mode(0))
      if rfd >= 0:
        discard fchmod(rfd, Mode(0o600))
        discard posix.close(rfd)
      ofd = c_openat(dfd, RecipientKeyName.cstring,
                     O_WRONLY or oNoFollow or oCloExec or oNonBlock, Mode(0))
    if ofd < 0:
      fail("cannot open the old recipient key to overwrite it: " & errText())
    try:
      var st: Stat
      if fstat(ofd, st) != 0 or not S_ISREG(st.st_mode):
        fail("the old recipient key is not a regular file")
      var zeros = newString(int(st.st_size))
      var off = 0
      while off < zeros.len:
        let n = posix.write(ofd, addr zeros[off], zeros.len - off)
        if n < 0:
          if errno == EINTR: continue
          fail("cannot overwrite the old recipient key: " & errText())
        off += n
      if fsync(ofd) != 0:
        fail("cannot flush the overwritten old recipient key: " & errText())
    finally:
      discard posix.close(ofd)
  if c_renameat(dfd, NextRecipientKeyName.cstring, dfd,
                RecipientKeyName.cstring) != 0:
    fail("cannot retire the old recipient key: " & errText())
  if fsync(dfd) != 0:
    fail("cannot flush " & l.agentDir & ": " & errText())
  if seamStateDir.len > 0:
    seamPause(seamStateDir, "rotation-after-rename")
  discard reconcileRotation(l, ledgerPath)

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

proc commitEnvelope*(l: SecretsLayout; source, generationCopy: string;
                     resealPaths: openArray[string]; ledgerPath: string;
                     seamStateDir = "") =
  ## A generation committed having materialised from ``source``: keep a
  ## copy as the generation's own (``generationCopy``); a staged source
  ## becomes the latest envelope; and when only the next key opens it,
  ## the old key is retired (``retireCurrentKey``). Idempotent.
  if source.len > 0:
    let (present, env) = readEnvelopeFile(l, source)
    if present:
      if generationCopy.len > 0 and generationCopy != source:
        writeEnvelopeFile(l, generationCopy, env)
      if source == stagedEnvelopePath(l):
        let dfd = openAgentDir(l)
        defer: discard posix.close(dfd)
        if c_renameat(dfd, StagedEnvelopeName.cstring, dfd,
                      RetainedEnvelopeName.cstring) != 0:
          fail("cannot promote the staged envelope: " & errText())
        if fsync(dfd) != 0:
          fail("cannot flush " & l.agentDir & ": " & errText())
      if keyExists(nextRecipientKeyPath(l)):
        var opened = openEnvelope(l, env)
        let byNext = opened.byNextKey
        wipe(opened.files)
        if byNext:
          var paths = @resealPaths
          if latestEnvelopePath(l) notin paths: paths.add(latestEnvelopePath(l))
          retireCurrentKey(l, paths, ledgerPath, seamStateDir)
  discard reconcileRotation(l, ledgerPath)

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

proc fsMagic(fd: cint; path: string): uint32 =
  var sf: StatFs
  if c_fstatfs(fd, sf) != 0:
    fail("cannot statfs " & path & ": " & errText())
  uint32(cast[culong](sf.f_type) and 0xffffffff'u)

proc checkFs(l: SecretsLayout; fd: cint; path: string) =
  ## The filesystem ``l.fs`` requires, read from the descriptor written
  ## through: a ramfs never swaps; a tmpfs may.
  let t = fsMagic(fd, path)
  case l.fs
  of sfRamfs:
    if t != uint32(RamfsMagic):
      fail(path & " is not on a ramfs (filesystem type 0x" & toHex(int(t), 8) &
        "); plaintext secrets go only where no page is ever written to a " &
        "disk or to swap")
  of sfTmpfs:
    if t != uint32(TmpfsMagic) and t != uint32(RamfsMagic):
      fail(path & " is not on a tmpfs (filesystem type 0x" & toHex(int(t), 8) & ")")
  of sfAny:
    discard

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

proc readSecretLeaf(dfd: cint; leaf, path: string):
    tuple[present: bool; text: string; mode: int] =
  let fd = openRegularLeaf(dfd, leaf, path)
  if fd < 0: return
  defer: discard posix.close(fd)
  var st: Stat
  discard fstat(fd, st)
  (true, readAllFd(fd, path, limit = 256 * 1024 * 1024),
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
  ## it by ``renameat`` (see the module header). ``dirPath`` is the path
  ## the directory is reached by from this process.
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
      O_WRONLY or O_CREAT or O_EXCL or oNoFollow or oCloExec or oNonBlock,
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

proc hostPath(l: SecretsLayout; p: string): string = l.hostRoot & p

proc openHostDir(l: SecretsLayout; path: string; mode: int): cint =
  ## The directory ``path`` of the host, created (``mode``) where missing:
  ## the host's root is opened through ``l.hostRoot`` (``/proc/1/root``, a
  ## link the kernel resolves into PID 1's mount namespace), and every
  ## component below it relative to its parent with ``O_NOFOLLOW``, so a
  ## link on the way is refused.
  let root = if l.hostRoot.len > 0: l.hostRoot else: "/"
  var fd = posix.open(root.cstring, O_RDONLY or oDirectory or oCloExec)
  if fd < 0:
    fail("cannot open the host's root " & root & ": " & errText())
  var cur = ""
  for seg in path.split('/'):
    if seg.len == 0: continue
    cur.add("/" & seg)
    var next = c_openat(fd, seg.cstring,
      O_RDONLY or oDirectory or oNoFollow or oCloExec, Mode(0))
    if next < 0 and errno == ENOENT:
      if c_mkdirat(fd, seg.cstring, Mode(mode)) != 0 and errno != EEXIST:
        let msg = errText()
        discard posix.close(fd)
        fail("cannot create " & cur & ": " & msg)
      next = c_openat(fd, seg.cstring,
        O_RDONLY or oDirectory or oNoFollow or oCloExec, Mode(0))
    if next < 0:
      let e = errno
      discard posix.close(fd)
      if e in [ELOOP, ENOTDIR]:
        fail("refusing " & cur & ": it is a symbolic link or not a directory")
      fail("cannot open " & cur & ": " & osErrorMsg(OSErrorCode(e)))
    discard posix.close(fd)
    fd = next
  fd

proc mountRamfsOnRunDir(l: SecretsLayout) =
  ## Mount the secrets ramfs on ``l.runDir`` in the host's mount namespace
  ## (a transient unit PID 1 spawns, ``runInHostNamespaces``), so systemd -- which reads the files for
  ## ``LoadCredential=`` -- sees it whatever namespace this process is in.
  ## Whatever the plain directory held is removed first: a mount would
  ## only hide it.
  let mountExe = resolveHostTool(["/usr/bin/mount", "/bin/mount"])
  if mountExe.len == 0:
    fail("mount(8) is not installed; cannot mount the secrets ramfs")
  let r = runInHostNamespaces([mountExe, "-t", "ramfs", "-o",
    "mode=0700,uid=0,gid=0,nosuid,nodev,noexec", "repro-secrets", l.runDir])
  if r.exitCode != 0:
    fail("cannot mount the secrets ramfs on " & l.runDir & ": " &
      r.output.strip())

proc prepareRunDir(l: SecretsLayout): cint =
  ## The secrets directory, ready to write through: created, owned, ``0700``
  ## and on the filesystem ``l.fs`` requires (a ramfs is mounted when the
  ## directory is a plain one). Returns its descriptor.
  let parent = parentDir(l.runDir)
  when mutated("secrets-on-disk"):
    # The falsifying build: /run/repro/secrets is a link to the directory
    # on the root filesystem the plaintext goes to, so the units still load
    # their credentials and only the disk scan can tell.
    discard posix.close(openHostDir(l, l.runDir, 0o700))
    let lp = openHostDir(l, parentDir(SecretsRunRoot), 0o755)
    var st: Stat
    let leaf = extractFilename(SecretsRunRoot)
    if c_fstatat(lp, leaf.cstring, st, atSymlinkNoFollow) != 0 or
        not S_ISLNK(st.st_mode):
      discard c_unlinkat(lp, leaf.cstring, atRemoveDir)
      discard c_symlinkat(l.runDir.cstring, lp, leaf.cstring)
    discard posix.close(lp)
  # `/run/repro` (0755 root) is gone after every boot; it is re-created
  # without following a link on the way.
  let pfd = openHostDir(l, parent, 0o755)
  defer: discard posix.close(pfd)
  result = openOrCreateDirAt(pfd, extractFilename(l.runDir), l.runDir, l.owner)
  if l.fs == sfRamfs and fsMagic(result, l.runDir) != uint32(RamfsMagic):
    for leaf in listDirAt(result): removeTreeAt(result, leaf)
    discard posix.close(result)
    mountRamfsOnRunDir(l)
    result = openOrCreateDirAt(pfd, extractFilename(l.runDir), l.runDir, l.owner)
  checkFs(l, result, l.runDir)

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
  let missing = missingEntries(files, decls)
  if missing.len > 0:
    fail("the sealed envelope carries no entry for " & missing.join(", ") &
      "; nothing was materialised")
  hardenProcessForSecrets()
  let rfd = prepareRunDir(l)
  defer: discard posix.close(rfd)
  var services: seq[string]
  for d in decls:
    if d.service notin services: services.add(d.service)
  services.sort()
  var written = 0
  for svc in services:
    let sdir = l.runDir / svc
    let sfd = openOrCreateDirAt(rfd, svc, sdir, l.owner)
    defer: discard posix.close(sfd)
    checkFs(l, sfd, sdir)
    var names: seq[string]
    for d in decls:
      if d.service == svc: names.add(d.name)
    names.sort()
    var changed = false
    for n in names:
      var want = ""
      for f in files:
        if f.path == secretEntryPath(svc, n):
          want = newString(f.content.len)
          for i, b in f.content: want[i] = char(b)
      var have = readSecretLeaf(sfd, n, sdir / n)
      let same = have.present and have.text == want and have.mode == SecretFileMode
      wipe(have.text)
      if not same:
        writeSecretAt(sfd, hostPath(l, sdir), n, want)
        changed = true
        inc written
        if written == 1 and seamStateDir.len > 0:
          seamPause(seamStateDir, "secrets-mid-write")
      wipe(want)
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
  ## Nothing is mounted for it, and no filesystem is required: removing
  ## plaintext is right wherever it is.
  let dir = hostPath(l, l.runDir)
  if not dirExists(dir) or symlinkExists(dir): return
  let fd = posix.open(dir.cstring, O_RDONLY or oDirectory or oNoFollow or oCloExec)
  if fd < 0: return
  defer: discard posix.close(fd)
  for leaf in listDirAt(fd):
    removeTreeAt(fd, leaf)
    result.add(leaf)
  result.sort()

proc openForDecls(l: SecretsLayout; decls: openArray[SecretFileDecl];
                  envelope: string): OpenedEnvelope =
  let (present, env) = readEnvelopeFile(l, envelope)
  if not present:
    fail("the generation declares " & $decls.len & " secret(s), but there " &
      "is no sealed envelope at " & envelope & " (deliver one through the " &
      "deploy agent or `repro system addon secret put`)")
  result = openEnvelope(l, env)
  let missing = missingEntries(result.files, decls)
  if missing.len > 0:
    wipe(result.files)
    fail("the sealed envelope " & envelope & " carries no entry for " &
      missing.join(", "))

proc materialiseFromEnvelope*(l: SecretsLayout;
                              decls: openArray[SecretFileDecl];
                              envelope: string; seamStateDir = ""): seq[string] =
  ## Materialise ``decls`` from the envelope at ``envelope`` (at apply and at
  ## boot). A generation that declares no secret needs no key and no
  ## envelope; one that does refuses (``AddonSecretsFailed``) when either
  ## is missing or unusable.
  if decls.len == 0:
    return clearMaterialised(l)
  var opened = openForDecls(l, decls, envelope)
  try:
    result = materialise(l, decls, opened.files, seamStateDir)
  finally:
    wipe(opened.files)

proc materialiseFromRetained*(l: SecretsLayout;
                              decls: openArray[SecretFileDecl];
                              seamStateDir = ""): seq[string] =
  ## ``materialiseFromEnvelope`` with the latest envelope.
  materialiseFromEnvelope(l, decls, latestEnvelopePath(l), seamStateDir)

proc checkSecretsAvailable*(l: SecretsLayout; decls: openArray[SecretFileDecl];
                            envelope: string) =
  ## Everything ``materialiseFromEnvelope`` needs is there -- a key that
  ## passes its check, an envelope that opens, an entry per declaration --
  ## decided before a switch writes anything. Writes nothing.
  if decls.len == 0: return
  var opened = openForDecls(l, decls, envelope)
  wipe(opened.files)

proc plannedSecretChanges*(l: SecretsLayout; decls: openArray[SecretFileDecl];
                           envelope: string): seq[string] =
  ## The services whose materialised secrets would differ after
  ## materialising ``decls`` from ``envelope``: a file added, changed or
  ## removed. The switch plans their units' restarts from it (§7.3), before
  ## anything is written. Reads only.
  var opened: OpenedEnvelope
  if decls.len > 0:
    opened = openForDecls(l, decls, envelope)
  defer: wipe(opened.files)
  let dir = hostPath(l, l.runDir)
  var rfd: cint = -1
  if dirExists(dir) and not symlinkExists(dir):
    rfd = posix.open(dir.cstring, O_RDONLY or oDirectory or oNoFollow or oCloExec)
  defer:
    if rfd >= 0: discard posix.close(rfd)
  var services: seq[string]
  for d in decls:
    if d.service notin services: services.add(d.service)
  for svc in services:
    var names: seq[string]
    for d in decls:
      if d.service == svc: names.add(d.name)
    var changed = rfd < 0
    var sfd: cint = -1
    if rfd >= 0:
      sfd = c_openat(rfd, svc.cstring,
        O_RDONLY or oDirectory or oNoFollow or oCloExec, Mode(0))
      if sfd < 0: changed = true
    if sfd >= 0:
      for n in names:
        var want = ""
        for f in opened.files:
          if f.path == secretEntryPath(svc, n):
            want = newString(f.content.len)
            for i, b in f.content: want[i] = char(b)
        var have = (present: false, text: "", mode: 0)
        try:
          have = readSecretLeaf(sfd, n, l.runDir / svc / n)
        except AddonSecretsFailed:
          discard
        if not have.present or have.text != want: changed = true
        wipe(have.text)
        wipe(want)
      for leaf in listDirAt(sfd):
        if leaf notin names and not leaf.startsWith("."): changed = true
      discard posix.close(sfd)
    if changed: result.add(svc)
  if rfd >= 0:
    for leaf in listDirAt(rfd):
      if leaf notin services and leaf notin result: result.add(leaf)
  result.sort()

proc runDirMtimes*(l: SecretsLayout; service: string): int64 =
  ## The newest modification time (seconds) of a service's materialised
  ## secrets, 0 when there are none: what a unit that loads them must have
  ## started after to hold the current ones.
  let dir = hostPath(l, l.runDir / service)
  if not dirExists(dir) or symlinkExists(dir): return 0
  let fd = posix.open(dir.cstring, O_RDONLY or oDirectory or oNoFollow or oCloExec)
  if fd < 0: return 0
  defer: discard posix.close(fd)
  for leaf in listDirAt(fd):
    var st: Stat
    if c_fstatat(fd, leaf.cstring, st, atSymlinkNoFollow) == 0:
      result = max(result, int64(st.st_mtim.tv_sec))

proc envelopeCopies*(stateDir: string): seq[string] =
  ## Every generation's own envelope copy under ``stateDir``.
  let gens = stateDir / "generations"
  if not dirExists(gens): return
  for kind, d in walkDir(gens):
    if kind != pcDir: continue
    let p = generationEnvelopePath(d)
    if fileExists(p) and not symlinkExists(p): result.add(p)
  result.sort()

proc releaseRunDir*(l: SecretsLayout) =
  ## Uninstall: every materialised secret removed and the secrets ramfs
  ## unmounted in the host's mount namespace, so ``/run/repro`` can go.
  discard clearMaterialised(l)
  let dir = hostPath(l, l.runDir)
  if not dirExists(dir) or symlinkExists(dir): return
  let fd = posix.open(dir.cstring, O_RDONLY or oDirectory or oNoFollow or oCloExec)
  if fd < 0: return
  let isRamfs = fsMagic(fd, l.runDir) == uint32(RamfsMagic)
  discard posix.close(fd)
  if not isRamfs: return
  let umountExe = resolveHostTool(["/usr/bin/umount", "/bin/umount"])
  if umountExe.len == 0:
    fail("umount(8) is not installed; cannot unmount " & l.runDir)
  let r = runInHostNamespaces([umountExe, l.runDir])
  if r.exitCode != 0:
    fail("cannot unmount " & l.runDir & ": " & r.output.strip())
