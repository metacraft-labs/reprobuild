## The two credentials an add-on host gets for its evidence (spec §6.2,
## §10.5, §10.6): the generation-attestation key and the Evidence sink write
## credential, created by bootstrap with a sink or, on a host bootstrapped
## without one, by ``repro system addon evidence-enrol``. Each is CREATED,
## never adopted and never replaced: a key that is already there is someone
## else's, or an earlier run's, and is refused by name.

import std/[os, posix]

import repro_peer_cache/identity
import repro_peer_cache/types

import ./attestation
import ./fingerprint
import ./generation0
import ./ledger
import ./mutations

type
  EvidenceKeysError* = object of CatchableError
  EvidenceKeys* = object
    attestationPublicKeyHex*: string
    credentialHost*: string          ## the sink credential's host id
    entries*: seq[LedgerEntry]       ## the keys, as ledger entries

  EvidenceKeyPaths* = object
    ## Where the keys go; ``defaultKeyPaths`` is the host's.
    attestationKey*, attestationPub*: string
    credentialKey*, credentialCert*: string

var ONoFollowK {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

proc defaultKeyPaths*(): EvidenceKeyPaths =
  EvidenceKeyPaths(attestationKey: AttestationKeyPath,
    attestationPub: AttestationPubPath,
    credentialKey: EvidenceCredentialKeyPath,
    credentialCert: EvidenceCredentialCertPath)

proc existingEvidenceKeys*(k = defaultKeyPaths()): seq[string] =
  ## The evidence key paths already present (a host that has any of them
  ## is refused).
  when mutated("evidence-keys-adopted"):
    # FALSIFYING BUILD: existing keys are not looked for.
    return @[]
  for p in [k.attestationKey, k.attestationPub, k.credentialKey,
            k.credentialCert]:
    if fileExists(p) or symlinkExists(p) or dirExists(p): result.add(p)

proc writeExclusive(path, content: string; mode: int) =
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL or
    ONoFollowK or O_CLOEXEC, Mode(mode))
  if fd < 0: raiseOSError(osLastError(), "create " & path)
  try:
    if fchmod(fd, Mode(mode)) != 0: raiseOSError(osLastError(), "fchmod " & path)
    if content.len > 0 and
        posix.write(fd, unsafeAddr content[0], content.len) != content.len:
      raiseOSError(osLastError(), "write " & path)
    if fsync(fd) != 0: raiseOSError(osLastError(), "fsync " & path)
  finally:
    discard posix.close(fd)

proc createEvidenceKeys*(k = defaultKeyPaths()): EvidenceKeys =
  ## Create both credentials under existing ``/var/lib/repro/agent`` and
  ## ``EvidenceStateDir`` (both ``0700 root``). Raises, writing nothing
  ## more, when any of their files exists already.
  let present = existingEvidenceKeys(k)
  if present.len > 0:
    raise newException(EvidenceKeysError, "refusing to adopt or replace " &
      "existing evidence keys: " & $present)
  let att = ensureAttestationKey(k.attestationKey)
  if not att.created:
    raise newException(EvidenceKeysError, k.attestationKey &
      " appeared while it was being created; refusing to adopt it")
  writeExclusive(k.attestationPub, att.publicKeyHex & "\n", 0o444)
  result.attestationPublicKeyHex = att.publicKeyHex
  let cred = loadOrCreateHostIdentity(k.credentialCert, k.credentialKey)
  discard posix.chmod(k.credentialKey.cstring, Mode(0o400))
  discard posix.chmod(k.credentialCert.cstring, Mode(0o444))
  result.credentialHost = $cred.hostId
  for p in [k.attestationKey, k.attestationPub, k.credentialKey,
            k.credentialCert]:
    let st = statOwner(p)
    result.entries.add(LedgerEntry(class: lcKey, path: p,
      sha256: sha256OfFile(p), mode: st.mode, owner: st.owner))

proc createEvidenceDirs*() =
  ## The outbox the shipping unit's path unit watches.
  createDir(EvidenceOutboxPath)
  setFilePermissions(EvidenceDirPath, {fpUserRead, fpUserWrite, fpUserExec})
  setFilePermissions(EvidenceOutboxPath, {fpUserRead, fpUserWrite, fpUserExec})
