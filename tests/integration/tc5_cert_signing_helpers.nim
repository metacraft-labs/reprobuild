## TC-5 shared helpers for the daemon-signing + key-registration tests.
##
## This file is ``include``d (not imported and not a registered test) by the
## TC-5 integration tests and the reconciled TC-3 test. It centralises the
## hermetic ed25519 key generation (via the REAL ``ssh-keygen`` the issuance
## path itself uses), the ``REPRO_DAEMON_SIGNING_KEY`` / ``REPRO_DAEMON_KEY_ID``
## env overlay that hands a daemon key to ``repro test``'s issuance step, and
## the registered-keys store setup (rotation / revocation).
##
## NOTE: these helpers NEVER fabricate a signature — every signed certificate is
## produced by driving the real ``repro test`` issuance path, which calls
## ``signCertificateOnIssuance`` (ssh-keygen ed25519) internally.

import std/[os, osproc, strutils]
import repro_cli_support

proc sshKeygenExe(): string = findExe("ssh-keygen")

proc genEd25519Key*(dir, name, comment: string): tuple[priv, pub: string] =
  ## Generate a fresh ed25519 keypair with the real ssh-keygen. Returns the
  ## private-key path and the public-key LINE (``ssh-ed25519 AAAA... comment``).
  let keygen = sshKeygenExe()
  doAssert keygen.len > 0, "ssh-keygen not on PATH"
  if not dirExists(dir): createDir(dir)
  let priv = dir / name
  if fileExists(priv): removeFile(priv)
  if fileExists(priv & ".pub"): removeFile(priv & ".pub")
  let res = execCmdEx(quoteShellCommand(@[keygen, "-t", "ed25519",
    "-N", "", "-C", comment, "-f", priv]))
  doAssert res.exitCode == 0, "ssh-keygen keygen failed: " & res.output
  (priv: priv, pub: readFile(priv & ".pub").strip())

proc daemonKeyEnv*(privPath, keyId: string):
    seq[tuple[name, value: string]] =
  ## The env overlay that makes ``repro test``'s issuance path sign with this
  ## key under this key_id — modelling the privileged daemon injecting the
  ## signing capability it owns into the observed run.
  @[(name: "REPRO_DAEMON_SIGNING_KEY", value: privPath),
    (name: "REPRO_DAEMON_KEY_ID", value: keyId)]

proc writeRegistry*(workspaceRoot: string; entries: openArray[RegisteredKey]) =
  ## Write the registered-keys store for ``workspaceRoot`` (the allowed-signers
  ## set CI/the server owns) with the given entries.
  var store: RegisteredKeyStore
  for e in entries: store.keys.add(e)
  writeRegisteredKeyStore(store, registeredKeyStorePath(workspaceRoot))
