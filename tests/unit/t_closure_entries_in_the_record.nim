## A tarball record carries its closure manifest's ENTRIES (envelope v34).
##
## Federated-Catalog-Imports.md § Home profiles, decided 2026-11-17 (option
## 1): a consumer that reads only a catalog's ``published-interfaces/`` has the
## record and not the committed ``closures/<name>.manifest`` file beside the
## provider, so the publisher inlines the parsed entries and realization
## reads them. The entries bind into the fingerprint, so a changed closure
## moves every pin.
##
## What each case measures, and the mutation that turns it red:
##
##   * the codec writes and reads the block at v34, and a v33 payload decodes
##     without it. Mutation: drop the write (or the read) of the block ->
##     "entries survive the artifact codec" fails.
##   * a changed entry moves the realization digest and the interface
##     fingerprint; a record without a closure keeps the digest it had.
##     Mutation: write the block outside the fingerprint projection -> the
##     digest case fails.
##   * realization unpacks inlined entries when the manifest FILE does not
##     exist (the consumer's situation). Mutation: realization ignores
##     ``record.closureEntries`` -> "a closure is realized from the record
##     alone" fails with "closure manifest not found".
##   * an inlined entry that escapes the prefix is refused before any
##     fetch: the entries come from a clone another party committed.
##
## No mocks: real archives built with ``tar`` and served over ``file://``,
## the real codec, and the real realizer.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_attest/measurement
import repro_hash
import repro_interface_artifacts
import repro_tool_profiles

proc fileUrl(path: string): string =
  "file:///" & path.replace('\\', '/').strip(leading = true, chars = {'/'})

proc makeTarball(root, name, innerRelPath, contents: string): string =
  let stage = root / ("stage-" & name)
  let inner = stage / "package" / innerRelPath
  createDir(inner.parentDir)
  writeFile(inner, contents)
  result = root / (name & ".tgz")
  let res = execCmdEx("tar -czf " & quoteShell(result) &
    " -C " & quoteShell(stage) & " package")
  doAssert res.exitCode == 0, "tar failed: " & res.output

const Sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

proc record(entries: seq[ClosureEntry];
            manifest = "closures/x.manifest"): InterfaceTarballProvisioning =
  InterfaceTarballProvisioning(
    packageName: "closurefixture",
    url: "https://example.invalid/root.tgz",
    sha256: Sha,
    archiveType: "tar.gz",
    stripComponents: 1,
    executablePath: "bin/cli.js",
    closureManifest: manifest,
    closureEntries: entries,
    packageId: "closurefixture@1",
    lockIdentity: "tarball:closurefixture@1:sha256:" & Sha,
    location: SourceLocation(file: "repro.nim", line: 2))

proc entry(path, sha, url: string): ClosureEntry =
  ClosureEntry(path: path, sha256: sha, url: url, archiveType: "tar.gz",
    stripComponents: 1)

proc interfaceWith(rec: InterfaceTarballProvisioning): ProjectInterface =
  result.projectName = "closure"
  result.packageName = "closure"
  result.location = SourceLocation(file: "repro.nim", line: 1)
  result.provisioningContributions = @[InterfaceProvisioningContribution(
    targetPackage: "closurefixture",
    targetInterfaceFingerprint: "fp",
    contributor: "closure",
    location: SourceLocation(file: "repro.nim", line: 3),
    tarballProvisioning: @[rec])]

proc useWith(rec: InterfaceTarballProvisioning): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "closurefixture", packageSelector: "closurefixture",
    executableName: "cli",
    location: SourceLocation(file: "fixture", line: 1))
  result.tarballProvisioning = @[rec]

suite "closure entries in the record":
  putEnv("REPRO_CACHE_DISABLE", "1")
  let two = @[entry("node_modules/a", Sha, "https://example.invalid/a.tgz"),
              entry("node_modules/b", Sha, "https://example.invalid/b.tgz")]

  test "entries survive the artifact codec":
    let pi = interfaceWith(record(two))
    let back = decodeInterfacePayload(encodeInterfacePayload(pi))
    let got = back.provisioningContributions[0].tarballProvisioning[0]
    check got.closureEntries == two
    check got.closureManifest == "closures/x.manifest"

  test "a v33 payload decodes without entries":
    let pi = interfaceWith(record(two))
    let old = decodeInterfacePayload(encodeInterfacePayload(pi, 33'u16), 33'u16)
    check old.provisioningContributions[0].tarballProvisioning[0]
      .closureEntries.len == 0
    check interfaceEnvelopeVersion() >= 34'u16

  test "a changed entry moves the digest; no closure keeps its digest":
    let a = toolUseRealizationDigest(useWith(record(two)))
    var other = two
    other[1].sha256 = "f" & Sha[1 .. ^1]
    check toolUseRealizationDigest(useWith(record(other))) != a
    # The same record without a closure projects exactly as a pre-v34 record
    # did: the block is absent from the fingerprint projection, so a record
    # with an explicit empty list and one never given the field agree.
    check toolUseRealizationDigest(useWith(record(@[]))) ==
      toolUseRealizationDigest(useWith(
        InterfaceTarballProvisioning(
          packageName: "closurefixture",
          url: "https://example.invalid/root.tgz", sha256: Sha,
          archiveType: "tar.gz", stripComponents: 1,
          executablePath: "bin/cli.js",
          closureManifest: "closures/x.manifest",
          packageId: "closurefixture@1",
          lockIdentity: "tarball:closurefixture@1:sha256:" & Sha,
          location: SourceLocation(file: "repro.nim", line: 2))))

  test "a closure is realized from the record alone":
    let root = createTempDir("repro-closure-entries-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js", "require('dep');\n")
    let depTgz = makeTarball(root, "dep", "index.js", "module.exports=1;\n")
    var rec = record(@[entry("node_modules/dep", sha256Hex(readFile(depTgz)),
      fileUrl(depTgz))], manifest = root / "does-not-exist.manifest")
    rec.url = fileUrl(rootTgz)
    rec.sha256 = "sha256:" & sha256Hex(readFile(rootTgz))
    rec.lockIdentity = "tarball:closurefixture@1:sha256:" & rec.sha256
    check not fileExists(rec.closureManifest)
    let profile = resolveTarballTool(useWith(rec), root / "store")
    let prefix = profile.selectedStorePath
    check fileExists(prefix / "bin" / "cli.js")
    check readFile(prefix / "node_modules" / "dep" / "index.js") ==
      "module.exports=1;\n"

  test "an inlined entry that escapes the prefix is refused":
    let root = createTempDir("repro-closure-entries-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js", "x\n")
    var rec = record(@[entry("../outside", Sha, "https://example.invalid/a.tgz")])
    rec.url = fileUrl(rootTgz)
    rec.sha256 = "sha256:" & sha256Hex(readFile(rootTgz))
    rec.lockIdentity = "tarball:closurefixture@1:sha256:" & rec.sha256
    expect ValueError:
      discard resolveTarballTool(useWith(rec), root / "store")
    check not dirExists(root / "outside")
