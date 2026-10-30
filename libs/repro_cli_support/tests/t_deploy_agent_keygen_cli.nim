## `repro deploy-agent keygen` — the command surface over
## `ensureRecipientKeyFile` (Deploy-Agent.md §Recipient key generation).
##
## The library test (`repro_deploy_agent/tests/t_repro_deploy_agent_recipient_
## keygen.nim`) grades the key file. This one grades what the OPERATOR sees:
## the exit code for each class of outcome, that stdout carries the public key
## and nothing else (the command composes: `keygen ... > recipient-pubkey.txt`
## is what the Add-On bootstrap does with it), and that a usage error creates
## no file. The command is run through the dispatcher the engine uses, in
## this process, with stdout redirected to a file for the duration.
##
## Mocks: none.

import std/[os, strutils, tempfiles, unittest]
when defined(posix):
  import std/posix

import repro_cli_support/deploy_agent
import repro_peer_cache/auth as peerAuth

proc withStdoutTo(path: string; body: proc()) =
  ## Run `body` with fd 1 pointing at `path` (restored afterwards). The
  ## command writes its one stdout line through `echo`, which is fd 1.
  when defined(posix):
    stdout.flushFile()
    let saved = dup(1)
    let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_TRUNC, 0o600)
    doAssert fd >= 0 and saved >= 0
    discard dup2(fd, 1)
    discard posix.close(fd)
    try:
      body()
    finally:
      stdout.flushFile()
      discard dup2(saved, 1)
      discard posix.close(saved)
  else:
    body()

suite "repro deploy-agent keygen":
  let root = createTempDir("repro-keygen-cli-", "")
  let keyPath = root / "agent" / "recipient.key"
  let outPath = root / "stdout.txt"

  test "usage errors exit 2 and create nothing":
    for args in [@[], @["--secrets-key"], @["--bogus", keyPath],
                 @["--secrets-key", keyPath, "extra"]]:
      let full = @["keygen"] & args
      var code = -1
      withStdoutTo(outPath, proc() = code = runDeployAgentCommand(full))
      checkpoint($full & " -> " & $code)
      check code == 2
      check readFile(outPath).len == 0
    check not fileExists(keyPath)
    check not dirExists(root / "agent")

  test "a fresh key exits 0 and prints exactly its public half":
    var code = -1
    withStdoutTo(outPath, proc() =
      code = runDeployAgentCommand(@["keygen", "--secrets-key", keyPath]))
    check code == 0
    let lines = readFile(outPath).splitLines
    check lines.len == 2 and lines[1] == ""           # one line, newline-ended
    let priv = peerAuth.loadPrivateKeyFile(keyPath)
    check lines[0] == peerAuth.publicKeyHex(peerAuth.derivePublicKey(priv))
    check lines[0].len == 130

  test "the `--secrets-key=` spelling reads the same key, exit 0":
    let before = readFile(keyPath)
    var code = -1
    withStdoutTo(outPath, proc() =
      code = runDeployAgentCommand(@["keygen", "--secrets-key=" & keyPath]))
    check code == 0
    check readFile(keyPath) == before
    let priv = peerAuth.loadPrivateKeyFile(keyPath)
    check readFile(outPath).strip ==
      peerAuth.publicKeyHex(peerAuth.derivePublicKey(priv))

  test "an unusable key exits 1 with nothing on stdout":
    let bad = root / "bad.key"
    writeFile(bad, "not a key\n")
    when defined(posix):
      setFilePermissions(bad, {fpUserRead})
    var code = -1
    withStdoutTo(outPath, proc() =
      code = runDeployAgentCommand(@["keygen", "--secrets-key", bad]))
    check code == 1
    check readFile(outPath).len == 0
    check readFile(bad) == "not a key\n"

  removeDir(root)
