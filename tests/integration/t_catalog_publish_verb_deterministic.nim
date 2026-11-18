## ``repro catalog publish`` (Federated-Catalog-Imports.md § Publishing, the
## verb; spec/CLI/catalog.md), measured through the verb's own entry point
## ``runCatalogPublishCommand`` on a real catalog layout
## (``packages/interfaces/<n>/repro.nim`` and ``packages/vendor/<n>/repro.nim``):
## the providers are compiled and run by the production extraction; nothing
## is mocked.
##
##   * Two checkouts of one catalog at different paths publish byte-identical
##     ``published-interfaces/`` (module discovery included: the verb is given
##     no module list).
##   * ``--check`` is green on a current directory and red, writing nothing,
##     once the provider source moved (a stale artifact), once a file is
##     missing and once an unexpected file is there; republishing makes it
##     green again.
##   * A closure record publishes with its entries, and the verb refuses to
##     publish one whose manifest file is not there.
##
## Falsifying mutations: the verb writes a host path-dependent name or reads
## the working tree order -> the byte comparison is red; the check always
## answers 0 -> the stale cases are red.

import std/[algorithm, os, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_cli_support

import ./federated_catalog_fixture

proc writeModule(root, kind, name, source: string) =
  let dir = root / "packages" / kind / name
  createDir(dir)
  writeFile(dir / "repro.nim", source)

proc vendorSource(fingerprint, sha: string; closure = false): string =
  "import repro_project_dsl\n\n" &
  "package vtoolRealizations:\n  discard\n\n" &
  "provisioningFor \"vtool\":\n" &
  "  interfaceFingerprint " & fingerprint.escape() & "\n" &
  "  contributor \"github:example/verb-fixture\"\n" &
  "  tarball url = \"https://example.invalid/vtool.tar.gz\",\n" &
  "    sha256 = " & sha.escape() & ",\n" &
  "    archiveType = \"tar.gz\",\n" &
  (if closure: "    closureManifest = \"closures/vtool.manifest\",\n" else: "") &
  "    executablePath = \"bin/vtool\",\n" &
  "    stripComponents = 1,\n" &
  "    packageId = \"vtool@1\",\n" &
  "    lockIdentity = " & ("sha256:" & sha).escape() & "\n"

proc listing(root: string): seq[(string, string)] =
  let dir = root / "published-interfaces"
  for entry in walkDir(dir):
    result.add((entry.path.extractFilename, readFile(entry.path)))
  result.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))

const ShaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const ShaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const Dep = "node_modules/dep"

suite "repro catalog publish":
  let scratch = createTempDir("repro-catalog-verb-", "")
  putEnv("REPROBUILD_SOURCE_ROOT", FixtureReproRoot)
  putEnv("REPRO_PROVIDER_NIMCACHE_MODE", "per-binary")
  defer:
    try: removeDir(scratch) except CatchableError: discard

  proc makeCatalog(name, sha: string): string =
    ## A catalog checkout at ``scratch/<name>``: the interface first, its
    ## fingerprint read back from what the verb published, then the
    ## contribution pinned to it.
    result = scratch / name / "deeper-so-the-path-differs"
    createDir(result)
    writeModule(result, "interfaces", "vtool",
      canonicalToolSource("vtool", "vtool"))
    check runCatalogPublishCommand(result, @["packages/interfaces/vtool/repro.nim"],
      false) == 0
    var fp = ""
    for (file, bytes) in listing(result):
      fp = fingerprintHexOf(decodeProjectInterfaceArtifact(
        cast[seq[byte]](bytes)))
    check fp.len == 64
    writeModule(result, "vendor", "vtool", vendorSource(fp, sha))

  test "two checkouts at different paths publish byte-identical directories":
    let a = makeCatalog("one", ShaA)
    let b = makeCatalog("two-with-a-longer-name", ShaA)
    check runCatalogPublishCommand(a, @[], false) == 0
    check runCatalogPublishCommand(b, @[], false) == 0
    let la = listing(a)
    check la.len == 2
    check la == listing(b)
    for (_, bytes) in la:
      check a notin bytes
      check b notin bytes

  test "--check is current, then stale, missing and unexpected":
    let root = makeCatalog("check", ShaA)
    check runCatalogPublishCommand(root, @[], false) == 0
    check runCatalogPublishCommand(root, @[], true) == 0
    # A provider change the committed directory does not reflect.
    let vendorPath = root / "packages" / "vendor" / "vtool" / "repro.nim"
    let original = readFile(vendorPath)
    writeFile(vendorPath, original.replace(ShaA, ShaB))
    let before = listing(root)
    check runCatalogPublishCommand(root, @[], true) == 1
    check listing(root) == before            # --check writes nothing
    check runCatalogPublishCommand(root, @[], false) == 0
    check runCatalogPublishCommand(root, @[], true) == 0
    # A deleted artifact and a stray file.
    let first = walkDir(root / "published-interfaces").toSeq()[0].path
    let keep = readFile(first)
    removeFile(first)
    check runCatalogPublishCommand(root, @[], true) == 1
    writeFile(first, keep)
    writeFile(root / "published-interfaces" / "stray.rbsz", "x")
    check runCatalogPublishCommand(root, @[], true) == 1

  test "a closure record publishes with its entries; a missing manifest refuses":
    let root = makeCatalog("closure", ShaA)
    let vendorPath = root / "packages" / "vendor" / "vtool" / "repro.nim"
    var fp = ""
    for (file, bytes) in listing(root):
      fp = fingerprintHexOf(decodeProjectInterfaceArtifact(
        cast[seq[byte]](bytes)))
    writeFile(vendorPath, vendorSource(fp, ShaA, closure = true))
    # No manifest beside the provider: refused, and nothing is replaced.
    let before = listing(root)
    check runCatalogPublishCommand(root, @[], false) == 1
    check listing(root) == before
    createDir(root / "packages" / "vendor" / "vtool" / "closures")
    writeFile(root / "packages" / "vendor" / "vtool" / "closures" /
      "vtool.manifest", Dep & " " & ShaB & " https://example.invalid/dep.tgz\n")
    check runCatalogPublishCommand(root, @[], false) == 0
    var seen = 0
    for (file, bytes) in listing(root):
      let art = decodeProjectInterfaceArtifact(cast[seq[byte]](bytes))
      for c in art.projectInterface.provisioningContributions:
        for t in c.tarballProvisioning:
          check t.closureEntries.len == 1
          check t.closureEntries[0].path == Dep
          inc seen
    check seen == 1
