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

proc seedManifestLockStore*(gitBin, workspaceRoot: string;
                            reproBin = ""; upstreamBare = "") =
  ## Make ``<workspaceRoot>/.repro/manifests`` a real git checkout.
  ##
  ## Certificate issuance binds a run to a COMMITTED manifest lock, which only
  ## exists in a workspace that DECLARES a manifest-backed route
  ## (Unified-Locking-And-Hooks.md §10, "No implicit team route": a workspace
  ## that never declares one is public-only and writes only ``repro.lock``).
  ## The gate used to synthesize the store from the mere path, so these
  ## fixtures got a lock record they had never asked for; now the route has to
  ## be declared, and for a flat native-layout fixture that means the store DB
  ## is its own checkout.
  proc git(args: string) =
    let res = execCmdEx(quoteShell(gitBin) & " " & args)
    doAssert res.exitCode == 0, "git " & args & " failed: " & res.output
  let lockStore = workspaceRoot / ".repro" / "manifests"
  if not dirExists(lockStore): createDir(lockStore)
  git("init -b main " & quoteShell(lockStore))
  git("-C " & quoteShell(lockStore) & " config user.email tester@example.invalid")
  git("-C " & quoteShell(lockStore) & " config user.name \"Lock Store Tester\"")
  writeFile(lockStore / ".gitkeep", "")
  git("-C " & quoteShell(lockStore) & " add -A")
  git("-C " & quoteShell(lockStore) & " commit -m \"seed lock store\"")
  if upstreamBare.len > 0:
    # A store the gate can actually PUBLISH to: a local bare origin plus the
    # tracking branch ``publishWorkspaceLock`` resolves through ``@{u}``.
    git("init --bare -b main " & quoteShell(upstreamBare))
    git("-C " & quoteShell(lockStore) & " remote add origin " &
      quoteShell(upstreamBare))
    git("-C " & quoteShell(lockStore) & " push -u origin main")
  if reproBin.len > 0:
    # ``repro push`` preflights every routed lock backend and refuses when the
    # backend checkout is missing the Reprobuild pre-push hook. Fixtures that
    # drive the real push have to install it, exactly as the printed remedy
    # (``repro hooks ensure --vcs <store>``) tells an operator to.
    let res = execCmdEx(quoteShellCommand(
      @[reproBin, "hooks", "ensure", "--vcs", lockStore]))
    doAssert res.exitCode == 0,
      "repro hooks ensure on the lock store failed: " & res.output
