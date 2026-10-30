## Encrypted secrets for the reprobuild deploy manifest (RDMF v2).
##
## ## Why this exists
##
## An RDMF manifest is SIGNED, not encrypted: every field is plaintext, the
## publish directory is world-readable by design ("the signature, not the ACL,
## is what makes them trustworthy"), and the guest hop is plain HTTP. That is
## the right shape for desired state, which is a public assertion. It is the
## wrong shape for the two things a pull-model box also needs: its binary-cache
## publisher key, and a GitHub registration token that expires hourly.
##
## Before this module those arrived by the controller SCP-ing them into the
## guest on every bootstrap, which is exactly the push dependency the deploy
## agent exists to remove. A dedicated bare-metal box (`win-ci-bare-001`) has
## no such controller leg, so it had no route for either.
##
## This adds a sealed section to the manifest, addressed to ONE recipient.
##
## ## What this does NOT remove
##
## It does not remove the need for a provisioning-time credential; it reduces
## it to exactly one. The box must hold the private half of its recipient
## keypair to open the envelope, and that key has to be installed the same way
## its computer name and SSH key are. What is bought is that everything
## *after* it — publisher key, hourly tokens, anything later — rides the
## manifest and can rotate without touching the box.
##
## ## Construction
##
## Standard ECIES over the curve the codebase already uses, with no new
## dependency: every primitive below is BearSSL, which the guest already links
## for cache signature verification.
##
##   Z        = ECDH(ephemeralPrivate, recipientPublic).X     (32 bytes)
##   K || N   = HKDF-SHA256(ikm = Z,
##                          salt = "RDMF-secrets-v2",
##                          info = target || ephemeralPublic || recipientPublic)
##   sealed   = AES-256-GCM(key = K, nonce = N,
##                          aad = "RDMF-v2:" & target,
##                          plaintext = encoded secret-file list)
##
## `K` is 32 bytes and `N` is 12, taken from one 44-byte HKDF stream.
##
## **On the nonce being derived rather than random.** GCM is catastrophically
## broken by nonce reuse under one key. Here the ephemeral keypair is fresh for
## every seal, so `Z` — and therefore `K` — is fresh for every seal, and a
## derived nonce cannot collide under a repeated key because the key never
## repeats. Deriving it is strictly safer than sampling 12 random bytes, which
## would have a birthday bound if the ephemeral key were ever reused by a
## caller bug.
##
## **On `info` binding.** Binding the target name and both public keys into the
## KDF means an envelope sealed for one target cannot be replayed at another
## even by a producer the box trusts: the derived key would differ and the tag
## check would fail. The AAD repeats the target for defence in depth.
##
## **On placement.** The sealed blob lives INSIDE the manifest's signed prefix,
## so the producer's ECDSA signature already covers it. The GCM tag protects
## the ciphertext against a tamperer who never had the signing key; the
## signature protects it against one who did not have it either but could
## reach the served bytes. Neither is redundant: the tag is what makes
## decryption fail closed, and it is checked BEFORE any plaintext is used.

import std/[os, strutils]
when defined(posix):
  import std/posix
  # std/posix does not export these on every target; take them from libc.
  var oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  var oCloExec {.importc: "O_CLOEXEC", header: "<fcntl.h>".}: cint

from repro_core/codec import elementCountFits

import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

import bearssl/abi/consttypes as bsslConst
import bearssl/abi/bearssl_ec as bsslEc
import bearssl/abi/bearssl_hash as bsslHash
import bearssl/abi/bearssl_kdf as bsslKdf
import bearssl/abi/bearssl_aead as bsslAead
import bearssl/abi/bearssl_block as bsslBlock

const
  GcmNonceLen* = 12
  GcmTagLen* = 16
  AesKeyLen* = 32
  SharedSecretLen* = 32

  HkdfSalt = "RDMF-secrets-v2"
  AadPrefix = "RDMF-v2:"

  P256Curve = cint(bsslEc.EC_secp256r1)

type
  SecretFile* = object
    ## One file to materialise on the target before the apply runs.
    path*: string
      ## Destination, RELATIVE to the agent's secrets directory. Validated:
      ## forward slashes only, no drive letter, no leading separator, no `..`
      ## component. See `validateSecretPath`.
    mode*: uint32
      ## POSIX-style mode. On Windows only the "is this private" bit of it is
      ## meaningful, and the agent tightens the DACL regardless; it is carried
      ## so the same manifest is usable on a POSIX target later.
    content*: seq[byte]

  SealedSecrets* = object
    ## The encrypted section as it appears on the wire.
    ephemeralPubKey*: peerAuth.PublicKeyBytes
    nonce*: array[GcmNonceLen, byte]
    tag*: array[GcmTagLen, byte]
    ciphertext*: seq[byte]

  SecretsError* = object of CatchableError
    ## Malformed secret list, bad key material, or a failed tag check.

# ---------------------------------------------------------------------------
# Path validation.
#
# The agent writes these paths under a directory it owns. A manifest is signed
# by a producer the box trusts, so this is not the primary trust boundary --
# but a path that escapes the secrets directory would let a compromised or
# simply buggy producer drop a file anywhere the agent can write, as SYSTEM.
# Validate structurally and reject, rather than normalise and hope.
# ---------------------------------------------------------------------------

proc validateSecretPath*(path: string) =
  ## Raise `SecretsError` unless `path` is a safe relative destination.
  if path.len == 0:
    raise newException(SecretsError, "secret file path is empty")
  if '\\' in path:
    raise newException(SecretsError,
      "secret file path must use forward slashes, got: " & path)
  if path[0] == '/':
    raise newException(SecretsError,
      "secret file path must be relative, got: " & path)
  if path.len >= 2 and path[1] == ':':
    raise newException(SecretsError,
      "secret file path must not carry a drive letter, got: " & path)
  for part in path.split('/'):
    if part.len == 0:
      raise newException(SecretsError,
        "secret file path has an empty component, got: " & path)
    if part == "..":
      raise newException(SecretsError,
        "secret file path must not contain '..', got: " & path)

# ---------------------------------------------------------------------------
# Plaintext codec for the secret-file list.
#
# Same hand-rolled little-endian shape as the manifest envelope so the whole
# format stays byte-traceable by a reviewer.
# ---------------------------------------------------------------------------

proc writeU32LE(buf: var seq[byte]; v: uint32) =
  for shift in countup(0, 24, 8):
    buf.add(byte((v shr uint32(shift)) and 0xff'u32))

proc readU32LE(buf: openArray[byte]; pos: var int): uint32 =
  if buf.len - pos < 4:
    raise newException(SecretsError, "secret payload truncated reading u32")
  result = 0'u32
  for i in 0 ..< 4:
    result = result or (uint32(buf[pos + i]) shl uint32(i * 8))
  inc pos, 4

proc encodeSecretFiles*(files: seq[SecretFile]): seq[byte] =
  ## Canonical plaintext for the sealed section.
  result = newSeqOfCap[byte](256)
  writeU32LE(result, uint32(files.len))
  for f in files:
    validateSecretPath(f.path)
    writeU32LE(result, uint32(f.path.len))
    for ch in f.path:
      result.add(byte(ch))
    writeU32LE(result, f.mode)
    writeU32LE(result, uint32(f.content.len))
    for b in f.content:
      result.add(b)

proc decodeSecretFiles*(buf: openArray[byte]): seq[SecretFile] =
  ## Inverse of `encodeSecretFiles`. Rejects trailing bytes: a decoder that
  ## silently ignores them would accept a payload the producer did not mean.
  var pos = 0
  let countRaw = readU32LE(buf, pos)
  # Each file carries at least its path length, mode and content length
  # (three u32 fields), so a count the remaining bytes cannot hold is refused
  # before it sizes the result.
  if not elementCountFits(countRaw, buf.len - pos, 12):
    raise newException(SecretsError,
      "secret payload element count exceeds remaining bytes")
  let count = int(countRaw)
  result = newSeqOfCap[SecretFile](count)
  for _ in 0 ..< count:
    var f = SecretFile()
    let pathLen = int(readU32LE(buf, pos))
    if buf.len - pos < pathLen:
      raise newException(SecretsError, "secret payload truncated reading path")
    f.path = newString(pathLen)
    for i in 0 ..< pathLen:
      f.path[i] = char(buf[pos + i])
    inc pos, pathLen
    validateSecretPath(f.path)
    f.mode = readU32LE(buf, pos)
    let contentLen = int(readU32LE(buf, pos))
    if buf.len - pos < contentLen:
      raise newException(SecretsError,
        "secret payload truncated reading content of " & f.path)
    f.content = newSeq[byte](contentLen)
    for i in 0 ..< contentLen:
      f.content[i] = buf[pos + i]
    inc pos, contentLen
    result.add(f)
  if pos != buf.len:
    raise newException(SecretsError,
      "secret payload has trailing bytes: pos=" & $pos & " len=" & $buf.len)

# ---------------------------------------------------------------------------
# ECDH + HKDF.
# ---------------------------------------------------------------------------

proc ecdhSharedX(privateKey: peerAuth.PrivateKeyBytes;
                 peerPublicKey: peerAuth.PublicKeyBytes): array[SharedSecretLen, byte] =
  ## Raw ECDH: multiply the peer's public point by our scalar and return the X
  ## coordinate of the result.
  ##
  ## `mul` works IN PLACE on a mutable copy of the point, and returns 0 for a
  ## point that is not on the curve or a scalar out of range -- which is the
  ## invalid-public-key check, so it is a hard error rather than a value we
  ## proceed with.
  var point: array[peerAuth.P256PubLen, byte]
  for i in 0 ..< peerAuth.P256PubLen:
    point[i] = peerPublicKey[i]
  var scalar: array[peerAuth.P256PrivLen, byte]
  for i in 0 ..< peerAuth.P256PrivLen:
    scalar[i] = privateKey[i]

  let impl = bsslEc.ecGetDefault()
  let ok = impl.mul(addr point[0], csize_t(peerAuth.P256PubLen),
                    cast[bsslConst.ConstPtrByte](addr scalar[0]),
                    csize_t(peerAuth.P256PrivLen), P256Curve)
  if ok != 1'u32:
    raise newException(SecretsError,
      "ECDH failed: recipient public key is not a valid P-256 point")

  var xlen: uint
  let xoff = int(impl.xoff(P256Curve, xlen))
  if int(xlen) != SharedSecretLen:
    raise newException(SecretsError,
      "ECDH produced an X coordinate of " & $xlen & " bytes, expected " &
      $SharedSecretLen)
  for i in 0 ..< SharedSecretLen:
    result[i] = point[xoff + i]

proc deriveKeyAndNonce(shared: array[SharedSecretLen, byte];
                       target: string;
                       ephemeralPub, recipientPub: peerAuth.PublicKeyBytes):
    tuple[key: array[AesKeyLen, byte], nonce: array[GcmNonceLen, byte]] =
  ## HKDF-SHA256 over the shared secret, binding the target name and both
  ## public keys so an envelope cannot be replayed at a different target.
  var info = newSeqOfCap[byte](target.len + 2 * peerAuth.P256PubLen)
  for ch in target:
    info.add(byte(ch))
  for b in ephemeralPub:
    info.add(b)
  for b in recipientPub:
    info.add(b)

  var salt = HkdfSalt
  var ikm = shared
  var hc: bsslKdf.HkdfContext
  bsslKdf.hkdfInit(hc, addr bsslHash.sha256Vtable, addr salt[0],
                   csize_t(salt.len))
  bsslKdf.hkdfInject(hc, addr ikm[0], csize_t(SharedSecretLen))
  bsslKdf.hkdfFlip(hc)

  var stream: array[AesKeyLen + GcmNonceLen, byte]
  let produced = bsslKdf.hkdfProduce(hc, addr info[0], csize_t(info.len),
                                     addr stream[0], csize_t(stream.len))
  if int(produced) != stream.len:
    raise newException(SecretsError,
      "HKDF produced " & $produced & " bytes, expected " & $stream.len)
  for i in 0 ..< AesKeyLen:
    result.key[i] = stream[i]
  for i in 0 ..< GcmNonceLen:
    result.nonce[i] = stream[AesKeyLen + i]

proc gcmTransform(key: array[AesKeyLen, byte];
                  nonce: array[GcmNonceLen, byte];
                  aad: string;
                  data: var seq[byte];
                  encrypt: bool;
                  tag: var array[GcmTagLen, byte]): bool =
  ## Run AES-256-GCM over `data` in place. When `encrypt`, writes the
  ## authentication tag into `tag` and returns true. When decrypting, checks
  ## `tag` and returns whether it matched -- the caller MUST NOT use `data` if
  ## this returns false.
  var keyCopy = key
  var nonceCopy = nonce
  var aadCopy = aad

  var bc: bsslBlock.AesCtCtrKeys
  bsslBlock.aesCtCtrInit(bc, addr keyCopy[0], csize_t(AesKeyLen))

  var gc: bsslAead.GcmContext
  bsslAead.gcmInit(gc, addr bc.vtable, bsslHash.ghashCtmul32)
  bsslAead.gcmReset(gc, addr nonceCopy[0], csize_t(GcmNonceLen))
  if aadCopy.len > 0:
    bsslAead.gcmAadInject(gc, addr aadCopy[0], csize_t(aadCopy.len))
  bsslAead.gcmFlip(gc)
  if data.len > 0:
    bsslAead.gcmRun(gc, (if encrypt: cint(1) else: cint(0)), addr data[0],
                    csize_t(data.len))
  else:
    bsslAead.gcmRun(gc, (if encrypt: cint(1) else: cint(0)), nil, csize_t(0))

  if encrypt:
    bsslAead.gcmGetTag(gc, addr tag[0])
    result = true
  else:
    result = bsslAead.gcmCheckTag(gc, addr tag[0]) == 1'u32

# ---------------------------------------------------------------------------
# Seal / open.
# ---------------------------------------------------------------------------

proc sealSecrets*(recipientPubKey: peerAuth.PublicKeyBytes;
                  target: string;
                  files: seq[SecretFile]): SealedSecrets =
  ## Encrypt `files` to `recipientPubKey`. A fresh ephemeral keypair is
  ## generated per call, so the derived AES key is unique per envelope.
  let ephemeral = peerAuth.generateKeypair()
  let shared = ecdhSharedX(ephemeral.privateKey, recipientPubKey)
  let derived = deriveKeyAndNonce(shared, target, ephemeral.publicKey,
                                  recipientPubKey)
  var payload = encodeSecretFiles(files)
  var tag: array[GcmTagLen, byte]
  discard gcmTransform(derived.key, derived.nonce, AadPrefix & target,
                       payload, encrypt = true, tag = tag)
  result.ephemeralPubKey = ephemeral.publicKey
  result.nonce = derived.nonce
  result.tag = tag
  result.ciphertext = payload

proc openSecrets*(recipientPrivKey: peerAuth.PrivateKeyBytes;
                  target: string;
                  sealed: SealedSecrets): seq[SecretFile] =
  ## Decrypt and parse. Raises `SecretsError` on a failed tag check, on a
  ## malformed payload, or on an unusable ephemeral key.
  ##
  ## Fails CLOSED and loudly: there is no partial-success path, and no
  ## plaintext is parsed before the tag is verified.
  let recipientPub = peerAuth.derivePublicKey(recipientPrivKey)
  let shared = ecdhSharedX(recipientPrivKey, sealed.ephemeralPubKey)
  let derived = deriveKeyAndNonce(shared, target, sealed.ephemeralPubKey,
                                  recipientPub)
  var payload = sealed.ciphertext
  var tag = sealed.tag
  if not gcmTransform(derived.key, derived.nonce, AadPrefix & target,
                      payload, encrypt = false, tag = tag):
    raise newException(SecretsError,
      "sealed secrets failed authentication for target '" & target &
      "': wrong recipient key, wrong target, or tampered ciphertext")
  decodeSecretFiles(payload)

# ---------------------------------------------------------------------------
# Materialisation.
# ---------------------------------------------------------------------------

proc refuseLinkOnPath(root, rel: string) =
  ## Raise unless no existing component of ``root/rel`` (the leaf included)
  ## is a symbolic link. The agent writes secrets as root/SYSTEM; a link
  ## planted on the path would redirect plaintext, or overwrite a file of
  ## the attacker's choosing with it.
  var cur = root
  for part in rel.split('/'):
    cur = cur / part
    if symlinkExists(cur):
      raise newException(SecretsError,
        "refusing to write secret " & rel & " through a symbolic link (" &
        cur & ")")

proc materialiseSecrets*(files: seq[SecretFile]; destDir: string): seq[string] =
  ## Write the opened secrets under `destDir`, returning the absolute paths.
  ##
  ## **Each file is published atomically** — staged alongside, then renamed
  ## into place. A registration token is read by a separate process
  ## (`register-runner.ps1`) that polls for it, so a consumer must never be
  ## able to observe the path existing with partial content. Renaming within
  ## the same directory is atomic on both NTFS and POSIX.
  ##
  ## **Never readable more widely than declared, never through a link.** On
  ## POSIX the staged file is created with `O_CREAT|O_EXCL|O_NOFOLLOW` and
  ## its final mode already applied, so there is no window in which the
  ## process umask leaves plaintext group- or world-readable (writing first
  ## and narrowing the mode afterwards had exactly that window), and a link
  ## planted at the staged name cannot redirect the write. No existing
  ## component of the destination path may be a link either.
  ##
  ## **Securing `destDir` is the PROFILE's job, not this proc's.** The
  ## directory carries the DACL and the files inherit it, exactly as
  ## `C:\actions-runner-tokens` already does (an `fs.systemDirectory` paired
  ## with a `windows.acl`). Setting per-file ACLs here would mean the agent
  ## and the profile both assert who may read these bytes, and the profile
  ## would re-apply forever against whatever the agent last wrote.
  createDir(destDir)
  result = newSeqOfCap[string](files.len)
  for f in files:
    validateSecretPath(f.path)
    refuseLinkOnPath(destDir, f.path)
    let dest = destDir / f.path
    let parent = parentDir(dest)
    if parent.len > 0:
      createDir(parent)
    refuseLinkOnPath(destDir, f.path)
    let staged = dest & ".staged"
    var content = newString(f.content.len)
    for i, b in f.content:
      content[i] = char(b)
    when defined(posix):
      if symlinkExists(staged):
        raise newException(SecretsError,
          "refusing to write secret " & f.path &
          ": its staging name is a symbolic link")
      if fileExists(staged):
        removeFile(staged)      # a leftover from an interrupted earlier tick
      let modeBits = Mode(f.mode and 0o644'u32)
      let fd = posix.open(staged.cstring,
        O_WRONLY or O_CREAT or O_EXCL or oNoFollow or oCloExec, modeBits)
      if fd < 0:
        raise newException(SecretsError,
          "cannot create " & staged & ": " & osErrorMsg(osLastError()))
      try:
        # The process umask may have narrowed the open(2) mode further;
        # fchmod sets exactly the declared bits, on the descriptor.
        if fchmod(fd, modeBits) != 0:
          raise newException(SecretsError,
            "cannot set the mode of " & staged & ": " &
            osErrorMsg(osLastError()))
        var off = 0
        while off < content.len:
          let n = posix.write(fd, addr content[off], content.len - off)
          if n < 0:
            raise newException(SecretsError,
              "cannot write " & staged & ": " & osErrorMsg(osLastError()))
          off += n
      finally:
        discard posix.close(fd)
    else:
      writeFile(staged, content)
    moveFile(staged, dest)
    result.add(dest)

# ---------------------------------------------------------------------------
# The recipient key, generated on the host.
#
# Deploy-Agent.md §Sealed secrets (v2) / §Recipient key generation and
# ReproOS-Add-On-Mode.md §6.2 step 3: the private half is GENERATED ON THE
# TARGET and only its public half is printed, for the producer to seal to. The
# key then never travels, which is why this lives in the agent rather than in
# a producer-side tool.
# ---------------------------------------------------------------------------

type
  RecipientKey* = object
    publicKey*: peerAuth.PublicKeyBytes
    created*: bool
      ## True when this call generated the key; false when an existing key
      ## file was read.

when defined(posix):
  import std/posix

  proc posixFail(what, path: string): ref SecretsError =
    newException(SecretsError, what & " " & path & ": " &
      osErrorMsg(osLastError()))

  proc writeAllFd(fd: cint; text: string; path: string) =
    var off = 0
    while off < text.len:
      let n = posix.write(fd, unsafeAddr text[off], text.len - off)
      if n < 0:
        if errno == EINTR: continue
        raise posixFail("cannot write", path)
      off += n

  const KeygenStagingInfix = ".keygen-"
    ## The staging file beside the key is `<key>.keygen-<pid>`; the pid
    ## says which keygen owns it, so a leftover from a crashed one can be
    ## told from a concurrent one's.

  proc sweepStaleKeygenStaging(path: string) =
    ## Remove `<path>.keygen-<pid>` files whose owning process is gone. A
    ## keygen killed between creating its staging file and linking it leaves
    ## one behind (with the scalar in it, 0400 -- a secret that nothing will
    ## ever use); a LIVE keygen's file is left alone, it is about to be
    ## linked or unlinked by its owner.
    let dir = parentDir(path)
    if dir.len == 0 or not dirExists(dir):
      return
    let prefix = extractFilename(path) & KeygenStagingInfix
    for kind, entry in walkDir(dir):
      if kind notin {pcFile, pcLinkToFile}:
        continue
      let name = extractFilename(entry)
      if not name.startsWith(prefix):
        continue
      var pid: int
      try:
        pid = parseInt(name[prefix.len .. ^1])
      except ValueError:
        continue
      if pid <= 0:
        continue
      # kill(pid, 0) delivers nothing; it answers whether the pid exists.
      # EPERM means it exists under another user: live, leave it. One with
      # THIS pid is stale too: this process has not staged anything yet, so
      # it can only be left over from an earlier holder of the pid.
      if pid != int(getpid()) and
          (posix.kill(Pid(pid), 0) == 0 or errno == EPERM):
        continue
      discard posix.unlink(entry.cstring)

  proc createKeyFileExclusive(path, text: string): bool =
    ## Publish `text` at `path` with mode 0400, never replacing anything.
    ## Returns false, having written nothing at `path`, when another file got
    ## there first -- a concurrent keygen -- so the caller reads that one.
    ##
    ## Written to a sibling staging file created 0400 from the start (so the
    ## scalar is never on disk with a wider mode, whatever the umask), flushed,
    ## and then HARD-LINKED onto `path`: `link(2)` fails with EEXIST rather
    ## than overwrite, so a concurrent or repeated keygen cannot replace a key
    ## a producer may already have sealed to, and a crash leaves either no key
    ## or a complete one -- never a truncated file at the real name.
    let tmp = path & KeygenStagingInfix & $getpid()
    let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC,
                        Mode(0o400))
    if fd < 0:
      raise posixFail("cannot create", tmp)
    try:
      writeAllFd(fd, text, tmp)
      if fsync(fd) != 0:
        raise posixFail("cannot flush", tmp)
    except CatchableError:
      discard posix.close(fd)
      discard posix.unlink(tmp.cstring)
      raise
    if posix.close(fd) != 0:
      discard posix.unlink(tmp.cstring)
      raise posixFail("cannot close", tmp)
    let linked = posix.link(tmp.cstring, path.cstring)
    let linkErr = osLastError()
    discard posix.unlink(tmp.cstring)
    if linked != 0:
      if linkErr == OSErrorCode(EEXIST):
        return false
      raise newException(SecretsError, "cannot publish recipient key at " &
        path & ": " & osErrorMsg(linkErr))
    let dirFd = posix.open(parentDir(path).cstring, O_RDONLY or O_CLOEXEC)
    if dirFd >= 0:
      discard fsync(dirFd)
      discard posix.close(dirFd)
    true

  proc createParents0700(path: string) =
    ## Create every missing ancestor of `path`, each mode 0700 regardless of
    ## the umask. `createDir` would make the intermediate ones 0777 & ~umask,
    ## so a key under `a/b/recipient.key` with `a` absent got a world-
    ## searchable `a`; and the mode is set at `mkdir(2)` time, not narrowed
    ## afterwards, so no component is ever wider than it ends up.
    var missing: seq[string] = @[]
    var dir = parentDir(path)
    while dir.len > 0 and not dirExists(dir):
      missing.add(dir)
      let up = parentDir(dir)
      if up == dir:
        break
      dir = up
    for i in countdown(missing.high, 0):
      if posix.mkdir(missing[i].cstring, Mode(0o700)) != 0 and errno != EEXIST:
        raise posixFail("cannot create directory", missing[i])

  proc refuseNonRegularKeyPath(path: string) =
    ## What `fileExists` cannot tell apart from "absent": a directory, or a
    ## symbolic link (dangling, or to a directory) AT `path`. Creating the key
    ## there would fail with an EEXIST that reads like a concurrent keygen, or
    ## follow the link somewhere nobody chose; name the thing instead.
    var st: Stat
    if lstat(path.cstring, st) != 0:
      return
    if S_ISLNK(st.st_mode):
      var target = newString(4096)
      let n = readlink(path.cstring, cstring(target), 4095)
      target.setLen(max(n, 0))
      raise newException(SecretsError, "recipient key path " & path &
        " is a symbolic link (to " & target & "); the key must be a regular " &
        "file, so remove the link or point --secrets-key at the file itself")
    if S_ISDIR(st.st_mode):
      raise newException(SecretsError, "recipient key path " & path &
        " is a directory; --secrets-key names the key FILE (for example " &
        path / "recipient.key" & ")")
    if not S_ISREG(st.st_mode):
      raise newException(SecretsError, "recipient key path " & path &
        " exists but is not a regular file")

proc readRecipientKeyFile(path: string): RecipientKey =
  ## The existing key at `path`, refused when it does not parse (rather than
  ## regenerated: a producer may already be sealing to it, and a silent new
  ## key would make every later manifest undecryptable with no reason given)
  ## and, on POSIX, when group or others can read it.
  when defined(posix):
    var st: Stat
    if stat(path.cstring, st) != 0:
      raise posixFail("cannot stat", path)
    if (st.st_mode.int and 0o077) != 0:
      raise newException(SecretsError, "recipient key " & path &
        " is accessible to group or others (mode " &
        toOct(st.st_mode.int and 0o777, 3) & "); the private key must " &
        "be readable by its owner only -- chmod 0400 it, or rotate it " &
        "if others may have read it")
  let priv =
    try:
      peerAuth.loadPrivateKeyFile(path)
    except CatchableError as e:
      raise newException(SecretsError, "existing recipient key " & path &
        " is not usable (" & e.msg & "); it is left untouched -- remove " &
        "it explicitly to generate a new one")
  RecipientKey(publicKey: peerAuth.derivePublicKey(priv), created: false)

proc ensureRecipientKeyFile*(path: string;
                             beforePublish: proc() {.gcsafe.} = nil):
    RecipientKey =
  ## The deploy agent's sealed-secrets recipient key at `path`: generated
  ## when the file does not exist, read when it does. Never replaces a key.
  ##
  ## The file is the `ecdsa-p256:<hex>` form `--secrets-key` loads
  ## (`peerAuth.loadPrivateKeyFile`). On POSIX it is created mode 0400, and
  ## every missing ancestor directory is created 0700. Securing an EXISTING
  ## parent is the deployment's job (Add-On bootstrap creates
  ## `/var/lib/repro/agent` 0700 root), exactly as for the secrets directory.
  ##
  ## Two keygens racing for the same path both return the same key: the one
  ## whose `link(2)` finds the name taken reads the winner's file. Staging
  ## files a crashed keygen left behind (`<path>.keygen-<pid>`, dead pid) are
  ## removed first. A directory or a symbolic link at `path` is refused by
  ## name. An existing key is refused when it does not parse or is readable
  ## by group or others (`readRecipientKeyFile`).
  ##
  ## `beforePublish` runs after the new key is staged and before it is
  ## linked into place. It exists for the race test, which has no other way
  ## to put a competitor's key there at exactly that point; production
  ## callers leave it nil.
  if path.len == 0:
    raise newException(SecretsError, "recipient key path is empty")
  when defined(posix):
    refuseNonRegularKeyPath(path)
    sweepStaleKeygenStaging(path)
  if fileExists(path):
    return readRecipientKeyFile(path)
  when defined(posix):
    createParents0700(path)
  else:
    let parent = parentDir(path)
    if parent.len > 0 and not dirExists(parent):
      createDir(parent)
  let kp = peerAuth.generateKeypair()
  let text = peerAuth.privateKeyFileText(kp.privateKey)
  when defined(posix):
    if beforePublish != nil:
      beforePublish()
    if not createKeyFileExclusive(path, text):
      # Another keygen published first; its key is the host's key now.
      return readRecipientKeyFile(path)
  else:
    # Windows: the directory's DACL governs who may read the key (see
    # `materialiseSecrets`); POSIX mode bits have no meaning here.
    if beforePublish != nil:
      beforePublish()
    if fileExists(path):
      return readRecipientKeyFile(path)
    writeFile(path, text)
  RecipientKey(publicKey: kp.publicKey, created: true)
