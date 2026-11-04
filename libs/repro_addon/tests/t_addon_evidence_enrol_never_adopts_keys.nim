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

suite "the evidence keys are created, never adopted":
  let k = EvidenceKeyPaths(attestationKey: root / "agent" / "attestation.key",
    attestationPub: root / "agent" / "attestation.pub",
    credentialKey: root / "evidence" / "host-ca.key",
    credentialCert: root / "evidence" / "host-ca.crt")
  createDir(root / "agent")
  createDir(root / "evidence")

  test "a first creation makes all four, private where they must be":
    let keys = createEvidenceKeys(k)
    check keys.attestationPublicKeyHex.len == 130
    check keys.credentialHost.len == 64
    check keys.entries.len == 4
    for p in [k.attestationKey, k.credentialKey]:
      check (getFilePermissions(p) * {fpGroupRead, fpOthersRead}).len == 0

  test "a second creation is refused, naming what is there":
    expect EvidenceKeysError:
      discard createEvidenceKeys(k)
    check existingEvidenceKeys(k).len == 4

  test "one key left over is enough to refuse":
    removeFile(k.attestationPub)
    removeFile(k.credentialKey)
    removeFile(k.credentialCert)
    expect EvidenceKeysError:
      discard createEvidenceKeys(k)

  test "enrol refuses a host that is not an add-on host":
    expect EvidenceEnrolError:
      discard runEvidenceEnrol(EnrolOptions(stateDir: root / "not-addon",
        sink: "127.0.0.1:1", sinkCaPath: root / "none"))

removeDir(root)
