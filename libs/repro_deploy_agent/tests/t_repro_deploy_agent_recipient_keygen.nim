## Deploy agent — the sealed-secrets recipient key is generated ON THE HOST.
##
## Deploy-Agent.md §Recipient key generation: `repro deploy-agent keygen`
## (`ensureRecipientKeyFile`) creates the private key where the agent will
## read it, prints only the public half, and never replaces a key a producer
## may already be sealing to. These cases pin each of those properties against
## the real filesystem, and close the loop through the real seal/open code:
## a key this generates must open what the producer seals to its public half.
##
## NO MOCKS: real files in a temp directory, the real BearSSL key generation
## and the real ECIES construction.

import std/[os, strutils, tempfiles, unittest]

import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
import ../src/repro_deploy_agent/secrets

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s:
    result[i] = byte(ch)

suite "deploy-agent recipient key generation":

  test "generates a loadable key and reports its public half":
    let root = createTempDir("repro-recipient-keygen-", "")
    defer: removeDir(root)
    let keyPath = root / "agent" / "recipient.key"
    let key = ensureRecipientKeyFile(keyPath)
    check key.created
    check fileExists(keyPath)
    check readFile(keyPath).startsWith("ecdsa-p256:")
    # The file is exactly what `--secrets-key` loads, and its public half is
    # the one reported.
    let priv = peerAuth.loadPrivateKeyFile(keyPath)
    check peerAuth.derivePublicKey(priv) == key.publicKey
    let hex = peerAuth.publicKeyHex(key.publicKey)
    check hex.len == 130
    check hex.startsWith("04")      # uncompressed SEC1 point

  test "the private key is owner-read-only and a created parent owner-only":
    when defined(posix):
      let root = createTempDir("repro-recipient-keygen-", "")
      defer: removeDir(root)
      let keyPath = root / "agent" / "recipient.key"
      discard ensureRecipientKeyFile(keyPath)
      check getFilePermissions(keyPath) == {fpUserRead}
      check getFilePermissions(root / "agent") ==
        {fpUserRead, fpUserWrite, fpUserExec}
      # No staging file is left beside it.
      var names: seq[string] = @[]
      for kind, path in walkDir(root / "agent"):
        names.add(path.extractFilename)
      check names == @["recipient.key"]

  test "an existing key is kept, never replaced":
    let root = createTempDir("repro-recipient-keygen-", "")
    defer: removeDir(root)
    let keyPath = root / "recipient.key"
    let first = ensureRecipientKeyFile(keyPath)
    let bytesBefore = readFile(keyPath)
    let second = ensureRecipientKeyFile(keyPath)
    check not second.created
    check second.publicKey == first.publicKey
    check readFile(keyPath) == bytesBefore

  test "an unusable existing key is refused and left untouched":
    let root = createTempDir("repro-recipient-keygen-", "")
    defer: removeDir(root)
    let keyPath = root / "recipient.key"
    writeFile(keyPath, "not a key\n")
    when defined(posix):
      setFilePermissions(keyPath, {fpUserRead})
    expect SecretsError:
      discard ensureRecipientKeyFile(keyPath)
    check readFile(keyPath) == "not a key\n"

  test "a key readable by group or others is refused and left untouched":
    when defined(posix):
      let root = createTempDir("repro-recipient-keygen-", "")
      defer: removeDir(root)
      let keyPath = root / "recipient.key"
      discard ensureRecipientKeyFile(keyPath)
      setFilePermissions(keyPath, {fpUserRead, fpUserWrite, fpGroupRead})
      let before = readFile(keyPath)
      expect SecretsError:
        discard ensureRecipientKeyFile(keyPath)
      # Refused is not rotated: the bytes and the (wrong) mode are as found,
      # for the operator to decide between chmod and rotate.
      check readFile(keyPath) == before
      check getFilePermissions(keyPath) == {fpUserRead, fpUserWrite, fpGroupRead}

  test "two keygens racing for one path agree on the winner's key":
    when defined(posix):
      # The loser's `link(2)` finds the name taken and reads the winner's
      # file instead of failing. The competitor is planted at the one point a
      # real race would put it: after this keygen staged its own key and
      # before it linked it.
      let root = createTempDir("repro-recipient-keygen-", "")
      defer: removeDir(root)
      let keyPath = root / "recipient.key"
      var winner: RecipientKey
      let loser = ensureRecipientKeyFile(keyPath, proc() {.gcsafe.} =
        {.cast(gcsafe).}:
          winner = ensureRecipientKeyFile(keyPath))
      check winner.created
      check not loser.created
      check loser.publicKey == winner.publicKey
      check peerAuth.derivePublicKey(peerAuth.loadPrivateKeyFile(keyPath)) ==
        winner.publicKey
      var names: seq[string] = @[]
      for kind, path in walkDir(root):
        names.add(path.extractFilename)
      check names == @["recipient.key"]        # no staging file left behind

  test "a crashed keygen's staging file is swept, a live one's is kept":
    when defined(posix):
      let root = createTempDir("repro-recipient-keygen-", "")
      defer: removeDir(root)
      let keyPath = root / "recipient.key"
      # pid 2^22 + 1 is above PID_MAX_LIMIT on Linux, so it names no process;
      # pid 1 always exists (and belongs to another user, which must count as
      # live too). One with this process's own pid is a leftover of an earlier
      # holder of the pid -- this process has staged nothing yet -- so it is
      # swept as well.
      let stale = keyPath & ".keygen-4194305"
      let reused = keyPath & ".keygen-" & $getCurrentProcessId()
      let live = keyPath & ".keygen-1"
      writeFile(stale, "ecdsa-p256:" & repeat('a', 64) & "\n")
      writeFile(reused, "ecdsa-p256:" & repeat('c', 64) & "\n")
      writeFile(live, "ecdsa-p256:" & repeat('b', 64) & "\n")
      discard ensureRecipientKeyFile(keyPath)
      check not fileExists(stale)
      check not fileExists(reused)
      check fileExists(live)
      removeFile(live)

  test "every missing parent is created owner-only":
    when defined(posix):
      let root = createTempDir("repro-recipient-keygen-", "")
      defer: removeDir(root)
      let keyPath = root / "a" / "b" / "c" / "recipient.key"
      discard ensureRecipientKeyFile(keyPath)
      for dir in [root / "a", root / "a" / "b", root / "a" / "b" / "c"]:
        check getFilePermissions(dir) == {fpUserRead, fpUserWrite, fpUserExec}

  test "a directory or a symbolic link at the path is refused by name":
    when defined(posix):
      let root = createTempDir("repro-recipient-keygen-", "")
      defer: removeDir(root)
      createDir(root / "isdir")
      try:
        discard ensureRecipientKeyFile(root / "isdir")
        check false
      except SecretsError as e:
        check "is a directory" in e.msg
      check not fileExists(root / "isdir" / "recipient.key")
      createSymlink(root / "nowhere", root / "dangling")
      try:
        discard ensureRecipientKeyFile(root / "dangling")
        check false
      except SecretsError as e:
        check "symbolic link" in e.msg
        check "nowhere" in e.msg
      check not fileExists(root / "nowhere")

  test "opens what a producer seals to the printed public key":
    let root = createTempDir("repro-recipient-keygen-", "")
    defer: removeDir(root)
    let keyPath = root / "recipient.key"
    let key = ensureRecipientKeyFile(keyPath)
    let files = @[SecretFile(path: "token", mode: 0o600'u32,
                             content: bytesOf("registration-token"))]
    let sealed = sealSecrets(key.publicKey, "addon-host-1", files, noRevokedRecipientKeys("test"))
    let opened = openSecrets(peerAuth.loadPrivateKeyFile(keyPath), "addon-host-1",
                             sealed)
    check opened.len == 1
    check opened[0].path == "token"
    check opened[0].content == files[0].content

  test "an empty path is refused":
    expect SecretsError:
      discard ensureRecipientKeyFile("")
