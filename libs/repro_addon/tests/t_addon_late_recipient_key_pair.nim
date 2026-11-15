## The deferred recipient key's public half is always the key's own
## (`reassert.ensureLateKeyPair`; ReproOS Add-On Mode §6.2 step 3, owner
## review finding 5, 2026-11-13): a `recipient.pub` left from a key that is
## gone, or edited, is rewritten from the key, so the half an operator
## registers is never one no key on the host matches.
##
## No mocks: the real key generator and file writes in a scratch
## directory (the add-on's paths are root-owned; the procedure takes them
## as parameters).

import std/[os, strutils, tempfiles, unittest]

import repro_addon/reassert
import repro_peer_cache/auth as peerAuth
from repro_deploy_agent/secrets import ensureRecipientKeyFile

proc pubOf(keyPath: string): string =
  peerAuth.publicKeyHex(ensureRecipientKeyFile(keyPath).publicKey)

suite "the late recipient key and its public half":
  test "a first creation writes the key 0400 and its public half":
    let d = createTempDir("repro-latekey-", "")
    let r = ensureLateKeyPair(d / "recipient.key", d / "recipient.pub")
    check r.created and not r.pubRewritten
    check readFile(d / "recipient.pub").strip() == r.pubHex
    check pubOf(d / "recipient.key") == r.pubHex
    check getFilePermissions(d / "recipient.key") == {fpUserRead}
    removeDir(d)

  test "a stale recipient.pub without its key is replaced":
    let d = createTempDir("repro-latekey-", "")
    writeFile(d / "recipient.pub", "04deadbeef\n")
    let r = ensureLateKeyPair(d / "recipient.key", d / "recipient.pub")
    check r.created and r.pubRewritten
    check readFile(d / "recipient.pub").strip() == r.pubHex
    check r.pubHex != "04deadbeef"
    removeDir(d)

  test "a key whose recipient.pub is missing or wrong keeps the key":
    let d = createTempDir("repro-latekey-", "")
    let first = ensureLateKeyPair(d / "recipient.key", d / "recipient.pub")
    removeFile(d / "recipient.pub")
    let again = ensureLateKeyPair(d / "recipient.key", d / "recipient.pub")
    check not again.created and not again.pubRewritten
    check again.pubHex == first.pubHex
    # (0444: replaced the way an editor saves, not written in place)
    removeFile(d / "recipient.pub")
    writeFile(d / "recipient.pub", "04edited\n")
    let fixed = ensureLateKeyPair(d / "recipient.key", d / "recipient.pub")
    check not fixed.created and fixed.pubRewritten
    check readFile(d / "recipient.pub").strip() == first.pubHex
    let same = ensureLateKeyPair(d / "recipient.key", d / "recipient.pub")
    check not same.created and not same.pubRewritten
    removeDir(d)

  test "a symbolic link at recipient.pub is replaced, not written through":
    let d = createTempDir("repro-latekey-", "")
    writeFile(d / "elsewhere", "untouched\n")
    createSymlink(d / "elsewhere", d / "recipient.pub")
    let r = ensureLateKeyPair(d / "recipient.key", d / "recipient.pub")
    check r.pubRewritten
    check not symlinkExists(d / "recipient.pub")
    check readFile(d / "recipient.pub").strip() == r.pubHex
    check readFile(d / "elsewhere") == "untouched\n"
    removeDir(d)
