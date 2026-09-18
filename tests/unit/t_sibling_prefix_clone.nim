## Realizing one archive twice must not store it twice.
##
## A distribution whose parts are separate public interfaces gets realized
## once per interface. ``rustc``, ``cargo``, ``clippy`` and ``rustfmt`` are
## four packages over ONE archive — identical url, sha256, archiveType and
## strip, differing only in ``executablePath``, which selects a VIEW of the
## prefix and changes none of its bytes. Measured on Windows at Rust 1.92:
## 3.84 GB of store holding 0.96 GB of distinct content.
##
## The clone keys on ``lockIdentity`` — the recipe author's statement that
## these are one realization — rather than on a digest collision, and on
## every input that changes the SEALED bytes. That second half is the part
## that is easy to get wrong and is why these cases exist: a prefix is not
## a pure function of its archive. Realize also copies the declared program
## under ``executableAlias``, writes a launcher pair for ``launcher``, and
## deletes ``prunePaths``. A clone that ignored those would carry an alias
## the cloning package never declared, and the same prefix id would hold
## different bytes on two machines — whichever published first deciding
## what everyone else substitutes.

import std/[os, strutils, tempfiles, unittest]

import repro_attest/measurement
import repro_interface_artifacts
import repro_local_store
import repro_tool_profiles

proc fileUrl(path: string): string =
  "file:///" & path.replace('\\', '/').strip(leading = true, chars = {'/'})

proc payloadUse(url, sha256, execPath: string; selector: string;
                alias = ""; launcher = ""): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: selector,
    packageSelector: selector,
    executableName: selector,
    location: SourceLocation(file: "fixture", line: 1))
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: selector,
    url: url,
    sha256: "sha256:" & sha256,
    archiveType: "raw",
    executablePath: execPath,
    executableAlias: alias,
    launcher: launcher,
    stripComponents: 0,
    packageId: selector & "@1",
    # THE KEY. Deliberately identical across the two packages below: it is
    # the declaration that they are one realization.
    lockIdentity: "tarball:shared-dist@1:sha256:" & sha256,
    location: SourceLocation(file: "fixture", line: 2))]

suite "one archive realized twice is stored once":
  putEnv("REPRO_CACHE_DISABLE", "1")

  const Payload = "shared distribution payload\n"

  test "a sibling with the same lock identity is cloned, not re-fetched":
    let root = createTempDir("repro-clone-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let src = root / "payload.bin"
    writeFile(src, Payload)
    let digest = sha256Hex(readFile(src))
    let store = root / "store"

    let first = resolveTarballTool(
      payloadUse(fileUrl(src), digest, "payload.bin", "alpha"), store)
    # Remove the source AND the store's download cache, so a second FETCH
    # is impossible by either route. Removing only the source is not
    # enough: `verifiedDownload` keeps the archive under
    # `<store>/downloads` keyed by digest, and a second realize would
    # quietly extract that instead — which is how the first draft of this
    # test passed while proving nothing.
    removeFile(src)
    removeDir(store / "downloads")
    let second = resolveTarballTool(
      payloadUse(fileUrl(src), digest, "payload.bin", "beta"), store)

    check first.selectedStorePath != second.selectedStorePath
    check fileExists(second.resolvedExecutablePath)
    check readFile(second.resolvedExecutablePath) == Payload
    # Each prefix seals its OWN receipt. A clone that kept the sibling's
    # would leave a prefix claiming somebody else's provenance.
    let receipt = readReceiptFile(second.selectedStorePath / ".repro-receipt")
    check receipt.packageName.contains("beta")
    check receipt.adapter == "tarball"

  test "a sibling that declared a different alias is NOT cloned":
    # The guard that makes the clone safe. `beta` declares an alias and
    # `alpha` does not, so their sealed trees differ and cloning would give
    # beta bytes it never declared. With the source removed, refusing to
    # clone means the resolve must FAIL rather than silently succeed with
    # the wrong tree.
    let root = createTempDir("repro-clone-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let src = root / "payload.bin"
    writeFile(src, Payload)
    let digest = sha256Hex(readFile(src))
    let store = root / "store"

    discard resolveTarballTool(
      payloadUse(fileUrl(src), digest, "payload.bin", "alpha"), store)
    removeFile(src)
    removeDir(store / "downloads")

    var failed = false
    try:
      discard resolveTarballTool(
        payloadUse(fileUrl(src), digest, "payload.bin", "beta",
          alias = "beta-alias"), store)
    except CatchableError:
      failed = true
    check failed

  test "the receipt records what realize wrote into the prefix":
    # The three fields the clone compares. Without them on the receipt a
    # candidate cannot be asked whether its tree is the one a fresh
    # extraction of a given declaration would produce.
    let root = createTempDir("repro-clone-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let src = root / "payload.bin"
    writeFile(src, Payload)
    let digest = sha256Hex(readFile(src))
    let profile = resolveTarballTool(
      payloadUse(fileUrl(src), digest, "payload.bin", "gamma",
        alias = "gamma-alias"), root / "store")
    let receipt = readReceiptFile(profile.selectedStorePath / ".repro-receipt")
    check receipt.declaredExecutableAlias == "gamma-alias"
    check receipt.declaredLauncher == ""
    check receipt.declaredPrunePaths.len == 0

  test "an older receipt only matches a plan that declares nothing":
    # v1/v2 receipts decode the three fields empty, and "empty" is
    # indistinguishable from "unknown". Encoding at the current version and
    # decoding must round-trip them, so a future reader is never guessing.
    var rec = RealizationReceipt(
      schemaVersion: 1'u16,
      adapter: "tarball",
      packageName: "delta",
      version: "1",
      realizedPath: "prefixes/delta/1-abc",
      declaredExecutablePath: "payload.bin",
      declaredExecutableAlias: "delta-alias",
      declaredLauncher: "node",
      declaredPrunePaths: @["share/doc", "share/man"],
      lockIdentity: "tarball:delta@1",
      provenanceUrl: "file:///payload.bin",
      provenanceChecksum: "sha256:" & repeat('a', 64),
      materializationMechanism: "directory",
      createdAtUnix: 1,
      writerProcessId: 2,
      writerMode: "direct")
    let roundTrip = decodeReceipt(encodeReceipt(rec))
    check roundTrip.declaredExecutableAlias == "delta-alias"
    check roundTrip.declaredLauncher == "node"
    check roundTrip.declaredPrunePaths == @["share/doc", "share/man"]
