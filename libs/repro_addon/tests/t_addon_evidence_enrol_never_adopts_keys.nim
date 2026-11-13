## ``repro system addon evidence-enrol`` and bootstrap create the evidence
## keys -- the attestation key and the sink write credential -- and never
## adopt or replace one that is already there (owner decision 2026-11-04;
## spec §6.2, §10.6). The enrol verb refuses a host that is not an add-on
## host. (The whole verb, on a host bootstrapped without a sink, is the VM
## cell of ``e2e_addon_evidence_credential_is_append_only``.)
##
## Falsifying build: ``evidence-keys-adopted`` -- existing keys are not
## looked for, and the second creation goes through; red.
##
## Mocks: none; the key files are real, under a scratch directory.

import std/[os, strutils, unittest]

import repro_addon/evidence_enrol
import repro_addon/evidence_keys

let root = getTempDir() / ("addon-enrol-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc keyPaths(name: string): EvidenceKeyPaths =
  ## A fresh key layout of its own for one case: each case runs in a process
  ## of its own, so none may rely on keys another case created.
  let dir = root / name
  result = EvidenceKeyPaths(attestationKey: dir / "agent" / "attestation.key",
    attestationPub: dir / "agent" / "attestation.pub",
    credentialKey: dir / "evidence" / "host-ca.key",
    credentialCert: dir / "evidence" / "host-ca.crt")
  createDir(dir / "agent")
  createDir(dir / "evidence")

suite "the evidence keys are created, never adopted":
  test "a first creation makes all four, private where they must be":
    let k = keyPaths("first")
    let keys = createEvidenceKeys(k)
    check keys.attestationPublicKeyHex.len == 130
    check keys.credentialHost.len == 64
    check keys.entries.len == 4
    for p in [k.attestationKey, k.credentialKey]:
      check (getFilePermissions(p) * {fpGroupRead, fpOthersRead}).len == 0

  test "a second creation is refused, naming what is there":
    let k = keyPaths("second")
    discard createEvidenceKeys(k)
    expect EvidenceKeysError:
      discard createEvidenceKeys(k)
    check existingEvidenceKeys(k).len == 4

  test "one key left over is enough to refuse":
    let k = keyPaths("left-over")
    discard createEvidenceKeys(k)
    removeFile(k.attestationPub)
    removeFile(k.credentialKey)
    removeFile(k.credentialCert)
    check existingEvidenceKeys(k).len == 1
    expect EvidenceKeysError:
      discard createEvidenceKeys(k)

  test "enrol refuses a host that is not an add-on host":
    expect EvidenceEnrolError:
      discard runEvidenceEnrol(EnrolOptions(stateDir: root / "not-addon",
        sink: "127.0.0.1:1", sinkCaPath: root / "none"))

removeDir(root)
