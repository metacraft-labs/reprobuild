## The pacman harvester's external-gpg backend verifies a real detached
## signature with its ephemeral GNUPGHOME made where the agent's sockets fit.
##
## Even ``gpg --import`` of public keys starts gpg-agent. On an account with
## no ``/run/user/<uid>`` (a service or CI runner's system user) the agent
## binds its sockets in GNUPGHOME itself, and a GNUPGHOME under a deep TMPDIR
## made them longer than ``sun_path`` allows: every verification failed with
## "gpg --import failed" (as the apt harvester's did, t_c2_signature). Run it
## under ``unshare -r`` (no ``/run/user/0``) with a long TMPDIR to see the
## failure the fix removes; on a host with ``/run/user/<uid>`` it passes
## either way.
##
## Mocks: none. The key, its keyring and the signature are made by the real
## gpg, in a short directory of the fixture's own; the key bundle the
## harvester reads sits under TMPDIR, as a harvest's does.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support/process_fixtures
import repro_test_support/reasoned_skip

import repro_harvest_pacman/signature

proc signedFixture(gpgBin: string): tuple[data, signature, bundle: string] =
  ## A payload, its detached signature (binary, as a repo db .sig is) and a key bundle
  ## directory holding the signing key's public keyring.
  let home = shortSocketDirAtProcessExit("rgpg")
  let env = newStringTable()
  env["GNUPGHOME"] = home
  let common = gpgBin & " --batch --yes --pinentry-mode loopback" &
    " --passphrase '' --quiet "
  var (output, code) = execCmdEx(common & "--quick-gen-key " &
    "'Fixture <fixture@example.invalid>' default default never", env = env)
  doAssert code == 0, output
  let payload = home / "payload"
  writeFile(payload, "core.db\n")
  (output, code) = execCmdEx(common & "--detach-sign --output " &
    quoteShell(home / "payload.sig") & " " & quoteShell(payload), env = env)
  doAssert code == 0, output
  let bundle = createTempDir("pacman-gpg-bundle-", "")
  (output, code) = execCmdEx(common & "--export --output " &
    quoteShell(bundle / "keyring.gpg"), env = env)
  doAssert code == 0, output
  discard execCmdEx("gpgconf --kill all", env = env)
  (readFile(payload), readFile(home / "payload.sig"), bundle)

suite "the pacman harvester's gpg home fits sun_path":
  test "a real detached signature verifies through the external-gpg backend":
    let gpgBin = resolveGpgBin()
    if gpgBin.len == 0:
      skip("no gpg on PATH (set REPRO_GPG_BIN)")
    else:
      let f = signedFixture(gpgBin)
      let v = verifyDbViaExternalGpg(f.data, f.signature, f.bundle, gpgBin)
      check v.backend == sbExternalGpg
      check v.signerKeyId.len > 0
      removeDir(f.bundle)
