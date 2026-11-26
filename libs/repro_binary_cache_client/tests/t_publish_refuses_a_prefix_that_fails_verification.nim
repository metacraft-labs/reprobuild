## Publishing a macOS application prefix re-runs the trust checks and refuses a
## prefix that fails them (Store-And-Installation-Layout.md § macOS
## Application Bundles, "Cached prefixes", rule 4).
##
## A vendor updater can rewrite a cached bundle in place after it was
## realized. A prefix published from that copy would serve the rewritten bytes
## under the pinned archive's cache key to every host that substitutes it, so
## `publishInProcess` -- the one function `repro cache publish`, the apply's
## publish step and the engine publisher all call -- verifies the bytes it is
## about to upload.
##
## Real tools throughout: the prefix is laid out the way the tarball realizer
## lays one out (a bundle and the adapter receipt that declares it), the
## checks are the real `codesign`, and the refusal is read from the real
## `publishInProcess`. No server runs: every refusal happens before a byte
## leaves the process, which is what is asserted (`statusCode == 0`,
## `bytesUploaded == 0`).
##
## TRUST POLICY. A fixture bundle built at test time is not signed by Apple,
## so the guard's own function is exercised with the same relaxation the
## GM4c tests use (`appPrefixPublishRefusal(prefix, policy)`), and
## `publishInProcess` -- which never relaxes -- is shown to REFUSE the very
## same pristine fixture: strict trust is what production runs.
##
## Vacuity guards: the pristine prefix passes (positive control) and a prefix
## holding no application passes through to the next stage of the publish
## (it fails later, on the unreachable endpoint, not in the guard), so the
## refusals below are the guard's and not a broken probe.
##
## Falsifying mutation (performed): removing the guard call from
## `publishInProcess` fails "publishInProcess refuses an application prefix".

when defined(macosx):
  import std/[json, os, osproc, strutils, tempfiles, unittest]

  import ../src/repro_binary_cache_client
  import ../src/repro_binary_cache_client/app_prefix_guard
  import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth
  import repro_home_resources/drivers/app_bundle
  import repro_test_support/macos_app_fixtures

  const
    AppName = "PublishGuard"
    AppId = "dev.reprobuild.publishguard.fixture"
    Relaxed = {atrUnanchoredTeamIdentifier, atrSkipNotarization}

  let root = createTempDir("repro-publish-guard-", "")
  var counter = 0

  proc stubIdentity(rev: string): CacheEntryIdentity =
    newCacheEntryIdentity(packageName = "publish-guard",
      packageVersion = "1.0.0", platform = PlatformTriple(cpu: "aarch64", os: "darwin", abi: "",
        libcVariant: ""),
      toolchain = ToolchainIdentity(name: "stub", version: "1",
        hostLdSoAbi: "", extraFingerprint: ""),
      providerRevision = rev)

  proc appPrefix(version = "1.0.0"; declare = true): string =
    ## A prefix as the realizer writes one: the bundle at its root and the
    ## adapter receipt, which (from this change on) declares the bundle.
    inc counter
    let prefix = root / ("prefix-" & $counter)
    discard makeFixtureApp(prefix, AppName, AppId, "1.0.0")
    var receipt = %*{
      "installMethod": "tarball",
      "declaredExecutablePath": AppName & ".app/Contents/MacOS/" & AppName}
    if declare:
      receipt["appBundle"] = %*{"item": AppName & ".app", "bundleId": AppId,
        "version": version, "teamId": FixtureTeamId}
    writeFile(prefix / ".reprobuild-tarball-receipt.json", receipt.pretty())
    prefix

  proc publishRequest(prefix, rev: string): PublishInProcessRequest =
    let identity = stubIdentity(rev)
    PublishInProcessRequest(entryKeyHex: deriveCacheEntryKeyHex(identity),
      prefixDir: prefix, identity: identity, endpoint: "http://127.0.0.1:1",
      keypair: peerAuth.generateKeypair())

  suite "publishing an application prefix":

    test "a pristine prefix passes the guard (positive control)":
      check appPrefixPublishRefusal(appPrefix(), Relaxed) == ""

    test "a bundle that no longer verifies is refused, naming the check":
      let prefix = appPrefix()
      doAssert execCmdEx("/bin/chmod -R u+w " & quoteShell(prefix)).exitCode == 0
      tamperFixtureApp(prefix / (AppName & ".app"))
      let refusal = appPrefixPublishRefusal(prefix, Relaxed)
      checkpoint refusal
      check "fails verification (signature)" in refusal

    test "a bundle of another version than the record declares is refused":
      # An updater's output: intact, validly signed, and newer than the
      # archive the cache key names.
      let prefix = appPrefix(version = "9.9.9")
      let refusal = appPrefixPublishRefusal(prefix, Relaxed)
      checkpoint refusal
      check "fails verification (version)" in refusal

    test "a prefix written before the receipt declared the bundle is held to " &
        "its own identity":
      let pristine = appPrefix(declare = false)
      check appPrefixPublishRefusal(pristine, Relaxed) == ""
      let broken = appPrefix(declare = false)
      doAssert execCmdEx("/bin/chmod -R u+w " & quoteShell(broken)).exitCode == 0
      tamperFixtureApp(broken / (AppName & ".app"))
      check "fails verification (signature)" in
        appPrefixPublishRefusal(broken, Relaxed)

    test "an application item that is a symbolic link is refused":
      let prefix = appPrefix()
      let real = prefix / "elsewhere"
      moveDir(prefix / (AppName & ".app"), real)
      createSymlink(real, prefix / (AppName & ".app"))
      check "symbolic link" in appPrefixPublishRefusal(prefix, Relaxed)

    test "a prefix that holds no application is not the guard's business":
      inc counter
      let prefix = root / ("plain-" & $counter)
      createDir(prefix)
      writeFile(prefix / "tool", "#!/bin/sh\n")
      writeFile(prefix / ".reprobuild-tarball-receipt.json", $(%*{
        "installMethod": "tarball", "declaredExecutablePath": "tool"}))
      check appPrefixPublishRefusal(prefix) == ""
      let res = publishInProcess(publishRequest(prefix, "plain-prefix"))
      check not res.ok
      # It got past the guard and failed on the unreachable endpoint.
      check "fails verification" notin res.error

    test "publishInProcess refuses an application prefix before any upload":
      # Strict trust, as in production: a fixture bundle is not Developer ID
      # signed, so the same prefix that passed the relaxed guard is refused.
      let prefix = appPrefix()
      check appPrefixPublishRefusal(prefix, Relaxed) == ""
      let res = publishInProcess(publishRequest(prefix, "app-prefix"))
      checkpoint res.error
      check not res.ok
      check res.statusCode == 0
      check res.bytesUploaded == 0
      check "fails verification" in res.error
      check "nothing is published" in res.error

  discard execCmdEx("/bin/chmod -R u+w " & quoteShell(root))
  removeDir(root)
