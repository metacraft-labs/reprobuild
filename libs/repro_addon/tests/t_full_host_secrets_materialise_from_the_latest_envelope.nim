## ``t_full_host_secrets_materialise_from_the_latest_envelope``: a host
## realised in full serves a unit's ``credentials`` the way an add-on host
## does, through the add-on's own secrets library (``full_host_secrets``).
##
## - the recipient key is created when absent (0400, its public half
##   beside it) and kept when present;
## - an entry sealed into the latest envelope (``addEntry``, the put's
##   sealing step) is materialised at ``<run>/<service>/<name>`` with mode
##   0400 and exactly its bytes, and the call names the service as changed;
## - a second materialisation of the same envelope changes nothing; a
##   re-sealed value is a change;
## - an undeclared entry is not written, and a file no declaration covers
##   any longer is removed; a profile with no declaration clears the run
##   directory and needs no key;
## - a declaration the envelope does not carry refuses before anything is
##   written;
## - ``consumersOf`` names exactly the units that load a changed service's
##   credentials.
##
## The VM half -- the ramfs, the locks, the CLI and a real unit loading the
## credential on a re-identified full host -- is the parity gate's
## (``e2e_addon_reproos_service_parity``).
##
## *Mocking.* None: the production code on real files. The required owner
## is the test's own uid and the filesystem check is off (a scratch
## directory is not a ramfs), as in the A7 unit tests.

import std/[os, posix, unittest]

import repro_infra/profile
import repro_addon/addon_secrets
import repro_addon/full_host_secrets
import repro_addon/locked_buffer
import repro_addon/secrets_ops

proc bytesOf(s: string): LockedBytes =
  result = newLockedBytes(s.len, requireLock = false)
  result.len = s.len
  for i, c in s: result.data[i] = byte(c)

proc newLayout(tag: string): (string, SecretsLayout) =
  let root = getTempDir() / ("t-full-host-secrets-" & tag & "-" &
                             $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  (root, SecretsLayout(agentDir: root / "agent", runDir: root / "run" / "secrets",
                       owner: int(geteuid()), fs: sfAny))

proc modeOf(path: string): int =
  var st: Stat
  doAssert lstat(path.cstring, st) == 0
  int(st.st_mode and 0o7777)

suite "full-host secrets":
  test "the key is created once and its public half written beside it":
    let (root, l) = newLayout("key")
    defer: removeDir(root)
    check ensureFullHostRecipientKey(l)
    check modeOf(recipientKeyPath(l)) == 0o400
    check fileExists(recipientPubPath(l))
    let pub = readFile(recipientPubPath(l))
    check not ensureFullHostRecipientKey(l)
    check readFile(recipientPubPath(l)) == pub

  test "a sealed entry is materialised exactly, and only what is declared":
    let (root, l) = newLayout("mat")
    defer: removeDir(root)
    discard ensureFullHostRecipientKey(l)
    discard addEntry(l, latestEnvelopePath(l), "vaultwarden/admin-token",
                     bytesOf("token-1"), "host-a", createIfAbsent = true)
    discard addEntry(l, latestEnvelopePath(l), "other/undeclared",
                     bytesOf("nope"), "host-a", createIfAbsent = false)
    let decls = @[SecretFileDecl(service: "vaultwarden", name: "admin-token")]
    check materialiseFullHostSecrets(l, decls) == @["vaultwarden"]
    let f = l.runDir / "vaultwarden" / "admin-token"
    check readFile(f) == "token-1"
    check modeOf(f) == 0o400
    check modeOf(l.runDir / "vaultwarden") == 0o700
    check not fileExists(l.runDir / "other" / "undeclared")
    # Unchanged envelope: nothing changes.
    check materialiseFullHostSecrets(l, decls).len == 0
    # A re-sealed value is a change.
    discard addEntry(l, latestEnvelopePath(l), "vaultwarden/admin-token",
                     bytesOf("token-2"), "host-a", createIfAbsent = false)
    check materialiseFullHostSecrets(l, decls) == @["vaultwarden"]
    check readFile(f) == "token-2"
    # No declaration any more: the run directory is cleared.
    check materialiseFullHostSecrets(l, []) == @["vaultwarden"]
    check not fileExists(f)

  test "a declaration the envelope does not carry refuses, writing nothing":
    let (root, l) = newLayout("missing")
    defer: removeDir(root)
    discard ensureFullHostRecipientKey(l)
    discard addEntry(l, latestEnvelopePath(l), "a/x", bytesOf("1"), "h",
                     createIfAbsent = true)
    expect AddonSecretsFailed:
      discard materialiseFullHostSecrets(l, @[
        SecretFileDecl(service: "a", name: "x"),
        SecretFileDecl(service: "b", name: "y")])
    check not fileExists(l.runDir / "a" / "x")

  test "no declaration and no run directory needs no key":
    let (root, l) = newLayout("none")
    defer: removeDir(root)
    check materialiseFullHostSecrets(l, []).len == 0
    check not fileExists(recipientKeyPath(l))

  test "consumersOf names the units that load a changed service's secrets":
    let units = @[(name: "vaultwarden.service", credentials: @["admin-token"]),
                  (name: "geth.service", credentials: newSeq[string]()),
                  (name: "beacon.service", credentials: @["jwt"]),
                  (name: "x.timer", credentials: @["t"])]
    check consumersOf(units, ["vaultwarden"]) == @["vaultwarden.service"]
    check consumersOf(units, ["geth"]).len == 0
    check consumersOf(units, ["vaultwarden", "beacon", "x"]) ==
      @["beacon.service", "vaultwarden.service"]
