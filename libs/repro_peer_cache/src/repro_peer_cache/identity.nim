## Per-host identity and short-lived leaf credentials — Distributed-Execution
## M7 (deployment-security-architecture.md CRED-1, CRED-3, CRED-4, FLOW-4).
##
## THE MODEL. Every host that runs a peer-cache node or a worker holds ONE
## long-lived credential, its *host CA*: a self-signed ECDSA-P256 certificate
## with `cA: TRUE` whose subject CN is the host id
## (`derivePeerIdFromPublicKey(caPublicKey)`). Peers pin each other's host CA
## certificates in their trust-anchor directory. The host CA never appears on
## the wire and never signs anything but leaves.
##
## Everything that talks to a peer presents a *leaf*: a CA-signed certificate
## for a fresh keypair, valid for at most `MaxLeafTtlSeconds` (one hour, the
## CRED-1 target for an Edge identity), whose CN names the host and the ROLE
## the holder plays:
##
##   repro-leaf/<role>/<hostIdHex>
##
## `daemon`       the long-lived node itself (re-minted before expiry);
## `build-worker` a daemon-forked build worker (its own keypair, so the
##                worker never presents — or holds — the daemon's key);
## `lease`        an execution lease (never granted anything but reads).
##
## Why this shape:
##
## * CRED-4 (no shared fleet secret): each host mints its own CA on first
##   start; nothing is copied between hosts, so a stolen leaf or CA key is
##   usable as THAT host only, and peers can revoke that host alone.
## * CRED-1 (short-lived): a stolen leaf expires within the hour on its own.
##   The long-lived CA stays inside the daemon's state directory, which
##   execution leases cannot read (see `repro_distributed_worker/lease.nim`).
## * FLOW-4 (authorize on identity, not on assertion): the receiver derives
##   the caller's host id from the anchor that SIGNED the leaf, never from a
##   field the caller wrote. A leaf whose CN names host X but which was
##   signed by host Y's CA is refused — otherwise any trusted host could mint
##   a leaf impersonating any other.
##
## TLS (BearSSL `X509Minimal`, `tls.nim`) already proves possession of the
## leaf's private key and validates the leaf against the CA anchors. What the
## TLS layer cannot tell us is WHICH anchor signed it, so after the handshake
## each side sends its leaf DER in an `mkIdentityProof` frame and the receiver
## runs `verifyLeaf` against the key the handshake authenticated.
##
## Legacy identities (a self-signed leaf pinned directly as an anchor, or a
## leaf from a shared tenant CA with a free-form CN — the Peer-Cache-BearSSL
## M3/M4 shapes) still verify, with the host id derived from the leaf's own
## key and role `lrLegacy`. A node configured with
## `requireShortLivedLeaves = true` (every node the CLI and the daemon start)
## refuses them: they are long-lived credentials and CRED-1 forbids exactly
## that.

import std/[options, os, strutils, tables, times]
when defined(posix):
  import std/posix

import ./auth
import ./pki
import ./secret_key
import ./types

export secret_key

const
  MaxLeafTtlSeconds* = 3_600
    ## CRED-1: "Target TTL for Edge identities: <= 1 hour".
  LeafClockSkewSeconds* = 300
    ## Tolerance for clock skew between hosts when checking a validity
    ## window. Also the margin `notBefore` is back-dated by at minting.
  LeafRenewMarginSeconds* = 900
    ## A holder re-mints its leaf once less than this remains.
  LeafCnPrefix* = "repro-leaf/"
  HostCaValidityDays* = 3_650
    ## The host CA is the long-lived anchor peers pin. Its lifetime is not
    ## what bounds a compromise — leaves are — and rotating it is a
    ## re-pinning event (`Distributed-Execution-Threat-Model.md` §CRED).

type
  LeafRole* = enum
    lrLegacy = "legacy"
      ## A pre-M7 identity (direct-trust leaf or tenant-CA leaf). Accepted
      ## only by nodes that do not require short-lived leaves.
    lrDaemon = "daemon"
    lrBuildWorker = "build-worker"
    lrLease = "lease"

  HostIdentity* = object
    ## The per-host CA. Held only by the daemon process. `ca` carries the
    ## certificate and the PUBLIC key only (its private scalar is zero);
    ## the private scalar lives in `caKey`, a protected page that a forked
    ## child does not inherit (`secret_key.nim`, threat model G16).
    ca*: CertAndKey
    caKey*: SecretKey
    hostId*: PeerId

  LeafCredential* = object
    ## A short-lived leaf: what a process presents on the wire and signs
    ## memo attestations with. As for the host CA, `cert.keypair` holds the
    ## public key only; the private scalar is `key`.
    cert*: CertAndKey
    key*: SecretKey
    hostId*: PeerId
    role*: LeafRole

  VerifiedLeaf* = object
    ## The outcome of `verifyLeaf`: who the caller IS, derived from the
    ## anchor that signed the presented leaf.
    ok*: bool
    reason*: string
      ## Why verification failed; empty on success.
    hostId*: PeerId
    role*: LeafRole
    leafPublicKey*: PublicKeyBytes
    notBefore*: int64
    notAfter*: int64

  IdentityError* = object of CatchableError

  LeafProvider* = proc(): LeafCredential {.gcsafe, closure.}
    ## The holder's CURRENT leaf (re-minted before expiry by its owner).

proc nowUnix(): int64 =
  getTime().toUnix

proc hexOf(id: PeerId): string =
  $id

proc leafSubjectCn*(hostId: PeerId; role: LeafRole): string =
  LeafCnPrefix & $role & "/" & hexOf(hostId)

proc parseLeafCn*(cn: string): tuple[ok: bool; role: LeafRole; hostHex: string] =
  ## Splits `repro-leaf/<role>/<hostHex>`; `ok = false` for any other shape
  ## (including the legacy role, which is never minted into a CN).
  if not cn.startsWith(LeafCnPrefix):
    return (false, lrLegacy, "")
  let rest = cn[LeafCnPrefix.len .. ^1]
  let slash = rest.find('/')
  if slash <= 0 or slash == rest.high:
    return (false, lrLegacy, "")
  let roleText = rest[0 ..< slash]
  let hostHex = rest[slash + 1 .. ^1]
  if hostHex.len != 64:
    return (false, lrLegacy, "")
  for ch in hostHex:
    if ch notin HexDigits:
      return (false, lrLegacy, "")
  for role in [lrDaemon, lrBuildWorker, lrLease]:
    if roleText == $role:
      return (true, role, hostHex.toLowerAscii)
  (false, lrLegacy, "")

# ---------------------------------------------------------------------------
# Host CA.
# ---------------------------------------------------------------------------

proc hostIdOf*(ca: CertAndKey): PeerId =
  derivePeerIdFromPublicKey(ca.keypair.publicKey)

const KeyFilePrefix = "ecdsa-p256:"

proc readKeyFileSecure(keyPath: string): PrivateKeyBytes =
  ## Reads the `ecdsa-p256:<hex>` key file into a fixed buffer on this
  ## stack frame (never a heap string), parses it, and zeroes the buffer.
  when defined(posix):
    var buf: array[256, char]
    defer: secureZeroVar(buf)
    let fd = posix.open(keyPath.cstring, O_RDONLY or O_CLOEXEC)
    if fd < 0:
      raise newException(IdentityError, "cannot open " & keyPath)
    var n = 0
    try:
      while n < buf.len:
        let r = posix.read(fd, addr buf[n], buf.len - n)
        if r < 0:
          if errno == EINTR: continue
          raise newException(IdentityError, "cannot read " & keyPath)
        if r == 0: break
        n += r
    finally:
      discard posix.close(fd)
    var pos = 0
    while pos < n and buf[pos] in {' ', '\t', '\n', '\r'}: inc pos
    if pos + KeyFilePrefix.len + 2 * P256PrivLen > n:
      raise newException(IdentityError, keyPath & " is not an ecdsa-p256 key file")
    for i, ch in KeyFilePrefix:
      if buf[pos + i] != ch:
        raise newException(IdentityError, keyPath & " lacks the ecdsa-p256: marker")
    pos += KeyFilePrefix.len
    proc nibble(c: char): int =
      case c
      of '0' .. '9': ord(c) - ord('0')
      of 'a' .. 'f': ord(c) - ord('a') + 10
      of 'A' .. 'F': ord(c) - ord('A') + 10
      else: -1
    for i in 0 ..< P256PrivLen:
      let hi = nibble(buf[pos + 2 * i])
      let lo = nibble(buf[pos + 2 * i + 1])
      if hi < 0 or lo < 0:
        secureZeroVar(result)
        raise newException(IdentityError, keyPath & " has invalid hex")
      result[i] = byte(hi * 16 + lo)
  else:
    let ck = loadCertAndKey("", keyPath)
    result = ck.keypair.privateKey

proc writeKeyFileSecure(keyPath: string; priv: PrivateKeyBytes) =
  ## Writes the `ecdsa-p256:<hex>` key file from a buffer on this stack
  ## frame, created owner-only (`O_CREAT|O_EXCL`, mode 0600), and zeroes the
  ## buffer.
  when defined(posix):
    const HexChars = "0123456789abcdef"
    var buf: array[KeyFilePrefix.len + 2 * P256PrivLen + 1, char]
    defer: secureZeroVar(buf)
    for i, ch in KeyFilePrefix: buf[i] = ch
    for i in 0 ..< P256PrivLen:
      buf[KeyFilePrefix.len + 2 * i] = HexChars[(int(priv[i]) shr 4) and 0xf]
      buf[KeyFilePrefix.len + 2 * i + 1] = HexChars[int(priv[i]) and 0xf]
    buf[^1] = '\n'
    if fileExists(keyPath) or symlinkExists(keyPath):
      removeFile(keyPath)
    let fd = posix.open(keyPath.cstring, O_WRONLY or O_CREAT or O_EXCL or
      O_CLOEXEC, Mode(0o600))
    if fd < 0:
      raise newException(IdentityError, "cannot create " & keyPath)
    try:
      var off = 0
      while off < buf.len:
        let r = posix.write(fd, addr buf[off], buf.len - off)
        if r < 0:
          if errno == EINTR: continue
          raise newException(IdentityError, "cannot write " & keyPath)
        off += r
    finally:
      discard posix.close(fd)
  else:
    var kp = PeerKeypair(privateKey: priv)
    writeCertAndKey(CertAndKey(keypair: kp), "", keyPath)

proc loadOrCreateHostIdentity*(certPath, keyPath: string): HostIdentity =
  ## The host CA at `certPath` / `keyPath`, minted on first use. A half-
  ## present pair is refused rather than overwritten (a lost key must be a
  ## deliberate re-pinning, not a silent identity change). A certificate
  ## that exists but is not a CA — the M0 self-signed leaf a node minted
  ## before M7 — is refused with the remedy named, for the same reason.
  ## The private scalar goes straight into a protected page (`caKey`); the
  ## returned `ca` carries the public half only.
  if certPath.len == 0 or keyPath.len == 0:
    raise newException(IdentityError,
      "the host identity needs a certificate path and a key path")
  let haveCert = fileExists(certPath)
  let haveKey = fileExists(keyPath)
  if haveCert and haveKey:
    let pem = readFile(certPath)
    let der = certPemToDer(pem)
    if not findIsCa(der):
      raise newException(IdentityError,
        "the host identity at " & certPath & " is not a CA certificate " &
        "(a pre-M7 long-lived peer certificate); move it and its key aside " &
        "so a host CA is minted, then re-pin the new " & certPath &
        " in every peer's trust-anchor directory")
    var priv = readKeyFileSecure(keyPath)
    let pub = certPublicKey(der)
    if derivePublicKey(priv) != pub:
      secureZeroVar(priv)
      raise newException(IdentityError,
        "key file " & keyPath & " does not match the certificate " & certPath)
    let window = certValidityWindow(der)
    let ca = CertAndKey(keypair: PeerKeypair(publicKey: pub), certPem: pem,
      certDer: der, subjectCn: certSubjectCn(der),
      notBefore: window.notBefore, notAfter: window.notAfter)
    return HostIdentity(ca: ca, caKey: newSecretKey(priv, pub),
      hostId: derivePeerIdFromPublicKey(pub))
  if haveCert != haveKey:
    raise newException(IdentityError,
      "found only one of " & certPath & " and " & keyPath &
      "; refusing to replace the host identity")
  var keypair = generateKeypair()
  let hostId = derivePeerIdFromPublicKey(keypair.publicKey)
  let now = nowUnix()
  var ca = generateCaCertWithWindow(keypair, subjectCn = $hostId,
    notBefore = now - LeafClockSkewSeconds,
    notAfter = now + int64(HostCaValidityDays) * 86_400)
  createDir(certPath.parentDir)
  createDir(keyPath.parentDir)
  writeFile(certPath, ca.certPem)
  writeKeyFileSecure(keyPath, keypair.privateKey)
  secureZeroVar(ca.keypair.privateKey)
  HostIdentity(ca: ca, caKey: newSecretKey(keypair), hostId: hostId)

proc wipePrivateKey*(identity: var HostIdentity) =
  ## Zeroes the CA private scalar in THIS process. A forked child never
  ## had it to begin with (its page is not inherited); this is for an
  ## owner that wants to give the key up early.
  secureZeroVar(identity.ca.keypair.privateKey)
  identity.caKey.wipe()

proc canMint*(identity: HostIdentity): bool =
  identity.caKey.available

proc mintLeaf*(identity: HostIdentity; role: LeafRole;
               ttlSeconds = MaxLeafTtlSeconds; now = 0'i64;
               inheritable = false): LeafCredential =
  ## A fresh keypair and a CA-signed leaf for it, valid from
  ## `now - LeafClockSkewSeconds` for `ttlSeconds` (clamped to
  ## `MaxLeafTtlSeconds`). The leaf's private key is a protected page that
  ## a forked child does not inherit — unless `inheritable`, which is only
  ## for the `build-worker` leaf a daemon pre-mints for its build workers.
  if role == lrLegacy:
    raise newException(IdentityError, "the legacy role is never minted")
  if not identity.canMint:
    raise newException(IdentityError,
      "this process no longer holds the host CA key")
  let at = if now == 0: nowUnix() else: now
  let ttl = max(60, min(ttlSeconds, MaxLeafTtlSeconds))
  var keypair = generateKeypair()
  var cert: CertAndKey
  withKeypair(identity.caKey, caKeypair):
    cert = generateCaSignedCertWithWindow(keypair,
      subjectCn = leafSubjectCn(identity.hostId, role),
      caCertDer = identity.ca.certDer,
      caKeypair = caKeypair,
      notBefore = at - LeafClockSkewSeconds,
      notAfter = at + int64(ttl))
  secureZeroVar(cert.keypair.privateKey)
  LeafCredential(cert: cert, key: newSecretKey(keypair, inheritable),
    hostId: identity.hostId, role: role)

proc mintHostCertificate*(identity: HostIdentity; role: LeafRole;
                          inheritable = false): LeafCredential =
  ## TRUSTED profile (Distributed-Execution M7, trust profiles): a
  ## certificate for the host's OWN long-lived key — no fresh keypair, no
  ## one-hour lifetime. It is signed by that same key with the host
  ## certificate's subject as issuer, so a peer that pinned the host
  ## certificate validates it in the TLS handshake, and `verifyLeaf` under
  ## `ipPinnedHostKey` accepts it only because its key IS the pinned key.
  ## Valid for the host certificate's own window; revoked by removing the
  ## pin. The CN still names the role, which caps what the holder may do.
  if role == lrLegacy:
    raise newException(IdentityError, "the legacy role is never minted")
  if not identity.canMint:
    raise newException(IdentityError,
      "this process no longer holds the host key")
  withKeypair(identity.caKey, hostKp):
    let cert = generateCaSignedCertWithWindow(hostKp,
      subjectCn = leafSubjectCn(identity.hostId, role),
      caCertDer = identity.ca.certDer,
      caKeypair = hostKp,
      notBefore = identity.ca.notBefore,
      notAfter = identity.ca.notAfter)
    var publicOnly = cert
    secureZeroVar(publicOnly.keypair.privateKey)
    var copy = hostKp
    result = LeafCredential(cert: publicOnly,
      key: newSecretKey(copy, inheritable), hostId: identity.hostId,
      role: role)

proc identityPolicyOf*(profile: TrustProfile): IdentityPolicy =
  ## Trusted: pinned long-lived host keys. Hardened: one-hour host-CA
  ## leaves. Neither accepts an unpinned peer.
  case profile
  of tpTrusted: ipPinnedHostKey
  of tpHardened: ipShortLivedLeaves

proc mintNodeCredential*(identity: HostIdentity; role: LeafRole;
                         policy: IdentityPolicy;
                         inheritable = false): LeafCredential =
  ## What a node presents under `policy`: the pinned long-lived host key
  ## (trusted profile) or a one-hour host-CA leaf (hardened profile).
  if policy == ipPinnedHostKey:
    mintHostCertificate(identity, role, inheritable)
  else:
    mintLeaf(identity, role, inheritable = inheritable)

proc needsRenewal*(leaf: LeafCredential; now = 0'i64): bool =
  let at = if now == 0: nowUnix() else: now
  leaf.cert.certDer.len == 0 or
    leaf.cert.notAfter - at < LeafRenewMarginSeconds

# ---------------------------------------------------------------------------
# Verification.
# ---------------------------------------------------------------------------

proc fail(reason: string): VerifiedLeaf =
  VerifiedLeaf(ok: false, reason: reason)

proc verifyLeaf*(leafDer: openArray[byte]; anchors: TrustAnchorSet;
                 at: int64; expectedPublicKey = none(PublicKeyBytes);
                 requireShortLived = true): VerifiedLeaf =
  ## Who presented `leafDer`, checked against `anchors` at time `at`.
  ##
  ## * `expectedPublicKey` — the key the TLS handshake authenticated. When
  ##   given, the leaf must carry exactly that key: a peer cannot present a
  ##   proof for a certificate it does not hold the key of.
  ## * A `repro-leaf/<role>/<host>` leaf must be signed by the CA anchor
  ##   whose host id the CN names, valid at `at` (within the skew), and no
  ##   longer-lived than `MaxLeafTtlSeconds` (+ skew) — a CA that mints a
  ##   week-long leaf has produced something CRED-1 forbids, and the
  ##   receiver, not the minter, is where that is enforced.
  ## * Any other leaf is legacy: accepted (host id = its own key) only when
  ##   `requireShortLived` is false and it is directly pinned or signed by a
  ##   CA anchor.
  var leafKey: PublicKeyBytes
  var window: tuple[notBefore, notAfter: int64]
  var cn = ""
  try:
    leafKey = certPublicKey(leafDer)
    window = certValidityWindow(leafDer)
    cn = certSubjectCn(leafDer)
  except CatchableError as err:
    return fail("unparseable leaf certificate: " & err.msg)
  if expectedPublicKey.isSome and expectedPublicKey.get() != leafKey:
    return fail("the presented leaf is not the certificate the TLS " &
      "handshake authenticated")
  if at + LeafClockSkewSeconds < window.notBefore or
      at - LeafClockSkewSeconds >= window.notAfter:
    return fail("the leaf is not valid at this time (window " &
      $window.notBefore & ".." & $window.notAfter & ", now " & $at & ")")
  let issuerDn = findIssuerDn(leafDer)
  let parsed = parseLeafCn(cn)
  if anchors.identityPolicy == ipPinnedHostKey:
    # TRUSTED profile: the presented key must BE the pinned key of the host
    # the CN names. A key that is merely signed by a pinned key — a CA-style
    # leaf — is not pinned and is refused (no "accept any client
    # certificate" path, in either direction).
    if not parsed.ok:
      return fail("this node accepts only pinned host keys; certificate " &
        "CN '" & cn & "' names no host")
    for peerId, anchor in anchors.byPeerId.pairs:
      if $peerId != parsed.hostHex:
        continue
      if anchor.publicKey != leafKey:
        return fail("the presented key is not the pinned host key of " &
          parsed.hostHex & " (an unpinned key is refused)")
      if anchor.subjectDn != issuerDn or
          not verifyCertSignatureWith(leafDer, anchor.publicKey):
        return fail("the certificate for host " & parsed.hostHex &
          " is not signed by its pinned host key")
      if not validateCertNotExpired(anchor, at):
        return fail("the pinned host certificate is outside its validity window")
      return VerifiedLeaf(ok: true, hostId: peerId, role: parsed.role,
        leafPublicKey: leafKey, notBefore: window.notBefore,
        notAfter: window.notAfter)
    return fail("host " & parsed.hostHex & " is not pinned on this node")
  let shortLivedOnly = requireShortLived or
    anchors.identityPolicy == ipShortLivedLeaves
  if parsed.ok:
    if window.notAfter - window.notBefore >
        int64(MaxLeafTtlSeconds + 2 * LeafClockSkewSeconds):
      return fail("the leaf is valid for " &
        $(window.notAfter - window.notBefore) & " s, longer than the " &
        $MaxLeafTtlSeconds & " s a leaf may live (CRED-1)")
    for peerId, anchor in anchors.byPeerId.pairs:
      if not anchor.isCa or $peerId != parsed.hostHex:
        continue
      if anchor.subjectDn != issuerDn:
        return fail("the leaf names host " & parsed.hostHex &
          " but was not issued by that host's CA")
      if not verifyCertSignatureWith(leafDer, anchor.publicKey):
        return fail("the leaf's signature does not verify under the CA " &
          "of the host it names")
      if not validateCertNotExpired(anchor, at):
        return fail("the issuing host CA is outside its validity window")
      return VerifiedLeaf(ok: true, hostId: peerId, role: parsed.role,
        leafPublicKey: leafKey, notBefore: window.notBefore,
        notAfter: window.notAfter)
    return fail("the leaf names host " & parsed.hostHex &
      ", which is not among the trusted host CAs")
  if shortLivedOnly:
    return fail("a legacy long-lived identity (CN '" & cn &
      "') is refused: this node requires short-lived host-CA leaves (CRED-1)")
  let legacyId = derivePeerIdFromPublicKey(leafKey)
  if anchors.byPeerId.hasKey(legacyId) and
      not anchors.byPeerId[legacyId].isCa:
    return VerifiedLeaf(ok: true, hostId: legacyId, role: lrLegacy,
      leafPublicKey: leafKey, notBefore: window.notBefore,
      notAfter: window.notAfter)
  for _, anchor in anchors.byPeerId.pairs:
    if anchor.isCa and anchor.subjectDn == issuerDn and
        verifyCertSignatureWith(leafDer, anchor.publicKey):
      return VerifiedLeaf(ok: true, hostId: legacyId, role: lrLegacy,
        leafPublicKey: leafKey, notBefore: window.notBefore,
        notAfter: window.notAfter)
  fail("the leaf is neither pinned nor issued by a trusted CA")

proc legacyIdentityFromKey*(publicKey: PublicKeyBytes): VerifiedLeaf =
  ## The identity of a TLS peer that sent no `mkIdentityProof`: the host id
  ## its own (handshake-authenticated) key derives to, role `lrLegacy`.
  VerifiedLeaf(ok: true, hostId: derivePeerIdFromPublicKey(publicKey),
    role: lrLegacy, leafPublicKey: publicKey)
