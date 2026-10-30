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

  test "a key readable by group or others is refused":
    when defined(posix):
      let root = createTempDir("repro-recipient-keygen-", "")
      defer: removeDir(root)
      let keyPath = root / "recipient.key"
      discard ensureRecipientKeyFile(keyPath)
      setFilePermissions(keyPath, {fpUserRead, fpUserWrite, fpGroupRead})
      expect SecretsError:
        discard ensureRecipientKeyFile(keyPath)

  test "opens what a producer seals to the printed public key":
    let root = createTempDir("repro-recipient-keygen-", "")
    defer: removeDir(root)
    let keyPath = root / "recipient.key"
    let key = ensureRecipientKeyFile(keyPath)
    let files = @[SecretFile(path: "token", mode: 0o600'u32,
                             content: bytesOf("registration-token"))]
    let sealed = sealSecrets(key.publicKey, "addon-host-1", files)
    let opened = openSecrets(peerAuth.loadPrivateKeyFile(keyPath), "addon-host-1",
                             sealed)
    check opened.len == 1
    check opened[0].path == "token"
    check opened[0].content == files[0].content

  test "an empty path is refused":
    expect SecretsError:
      discard ensureRecipientKeyFile("")
