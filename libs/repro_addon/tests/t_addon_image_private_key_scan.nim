## `key_material.scanForPrivateKeys`: private keys in the scanned
## directories are found by content and by location, never by file name (ReproOS Add-On Mode
## §6.5.2; owner review finding 1, 2026-11-13: a check by name missed a
## `cache-publisher.key` the `provisions-publisher-key` mutation left).
##
## No mocks: a scratch tree laid out as the files `repro infra image`
## copies out of an image with `debugfs rdump`, real keys from the real
## generators (`repro_peer_cache/auth`, `ssh-keygen` when present).

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip

import repro_addon/key_material
import repro_peer_cache/auth as peerAuth

proc put(path, content: string; mode = 0o644) =
  createDir(path.parentDir)
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite} +
    (if (mode and 0o044) != 0: {fpGroupRead, fpOthersRead} else: {}))

suite "private keys in an image are found by content and location":
  test "a clean image holds none":
    let r = createTempDir("repro-keyscan-", "")
    put(r / "var/lib/repro/agent/recipient.pub", "04abcd\n", 0o444)
    put(r / "etc/repro/caches.conf", "[addon]\n")
    put(r / "etc/ssh/sshd_config", "PermitRootLogin no\n")
    put(r / "root/.profile", "true\n")
    check scanForPrivateKeys(r).len == 0
    removeDir(r)

  test "a Reprobuild key under any name, in a scanned directory":
    let r = createTempDir("repro-keyscan-", "")
    let kp = peerAuth.generateKeypair()
    put(r / "var/lib/repro/system/notes.txt",
        peerAuth.privateKeyFileText(kp.privateKey), 0o644)
    let found = scanForPrivateKeys(r)
    check found.len == 1
    check found[0].startsWith("/var/lib/repro/system/notes.txt: Reprobuild")
    removeDir(r)

  test "the mutation's cache-publisher.key in the agent directory":
    let r = createTempDir("repro-keyscan-", "")
    let kp = peerAuth.generateKeypair()
    put(r / "var/lib/repro/agent/cache-publisher.key",
        peerAuth.privateKeyFileText(kp.privateKey), 0o400)
    let found = scanForPrivateKeys(r)
    check found.len == 1
    check "Reprobuild ecdsa-p256 private key" in found[0]
    check "others cannot read" in found[0]
    removeDir(r)

  test "a key with no marker is found by its location":
    let r = createTempDir("repro-keyscan-", "")
    put(r / "etc/wireguard/wg0", "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=\n",
        0o600)
    check scanForPrivateKeys(r) ==
      @["/etc/wireguard/wg0: a file others cannot read in a key directory"]
    removeDir(r)

  test "PEM, OpenSSH and age keys in home directories":
    let r = createTempDir("repro-keyscan-", "")
    put(r / "home/u/.ssh/backup", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blbg==\n" &
        "-----END OPENSSH PRIVATE KEY-----\n", 0o644)
    put(r / "root/tls.pem", "-----BEGIN EC PRIVATE KEY-----\nMHc=\n" &
        "-----END EC PRIVATE KEY-----\n", 0o644)
    put(r / "root/age.txt", "AGE-SECRET-KEY-1QQQ\n", 0o644)
    check scanForPrivateKeys(r).len == 3
    removeDir(r)

  test "an SSH host key from ssh-keygen":
    let keygen = findExe("ssh-keygen")
    if keygen.len == 0:
      skip("ssh-keygen not on PATH; this case needs a real OpenSSH host key")
    else:
      let r = createTempDir("repro-keyscan-", "")
      createDir(r / "etc/ssh")
      discard execCmd(quoteShell(keygen) & " -q -t ed25519 -N '' -f " &
                      quoteShell(r / "etc/ssh/ssh_host_ed25519_key"))
      let found = scanForPrivateKeys(r)
      check found.len == 1
      check found[0].startsWith("/etc/ssh/ssh_host_ed25519_key: OpenSSH")
      removeDir(r)

  test "a symbolic link is not followed out of the image":
    let r = createTempDir("repro-keyscan-", "")
    let outside = createTempDir("repro-keyscan-outside-", "")
    put(outside / "k", "-----BEGIN PRIVATE KEY-----\n", 0o644)
    createDir(r / "root")
    createSymlink(outside / "k", r / "root/link")
    check scanForPrivateKeys(r).len == 0
    removeDir(r)
    removeDir(outside)
