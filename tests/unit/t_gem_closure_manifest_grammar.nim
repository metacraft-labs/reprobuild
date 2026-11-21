## The gem-closure manifest grammar and the declaration around it: every
## refusal names the file and line and happens before any gem is fetched; the
## declaration travels in the interface artifact (envelope v36) and keys the
## realization; and the closure grammar's whole-file, ``tar.zst`` and
## root-overlay entries.
##
## What each case measures, and the mutation that turns it red:
##
##   * each malformed line is refused with its line number. Mutation: drop a
##     check in ``parseGemClosureManifestText`` -> its case fails.
##   * a prebuilt platform gem needs a substitution, and nokogiri can never
##     have one; a build argument may name only a step tool's prefix.
##     Mutation: skip ``validateGemClosureDeclaration`` -> those cases fail.
##   * a refusal happens when the provisioning edge is declared, before any
##     download: the tool store does not even exist afterwards. Mutation:
##     run the decl reader lazily, at execution -> "refused before any
##     fetch" fails.
##   * the step's fields survive the artifact codec, a v35 payload decodes
##     without them, a record without a step keeps its realization digest,
##     and a changed gem moves it. Mutation: drop the v36 block or write it
##     outside the fingerprint projection.
##   * the lift resolves each build tool into a tool use with its own
##     realizations and inlines the manifest; a contribution carrying a
##     step is refused.
##
## No mocks: the real grammar, the real edge declaration, the real codec and
## the real lift, over manifests and package definitions written by the test.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_tool_profiles

const
  Sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  Other = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

proc line(name, version, platform, sha, url: string): string =
  name & " " & version & " " & platform & " " & sha & " " & url

proc gemUrl(file: string): string = "https://rubygems.org/gems/" & file

proc good(): string =
  "# generated\n\n" &
  line("mini_portile2", "2.8.9", "ruby", Sha,
    gemUrl("mini_portile2-2.8.9.gem")) & "\n" &
  line("nokogiri", "1.18.10", "ruby", Other,
    gemUrl("nokogiri-1.18.10.gem")) & "\n"

proc refusal(text: string): string =
  try:
    discard parseGemClosureManifestText(text, "fx.manifest")
  except ValueError as err:
    return err.msg
  ""

proc ccUse(): InterfaceToolUse =
  var record = InterfaceTarballProvisioning(
    url: "https://example.invalid/cc.tar.gz", sha256: Sha,
    archiveType: "tar.gz", executablePath: "bin/gcc", stripComponents: 1,
    cpu: "any", os: "any", packageId: "fx-cc@1")
  InterfaceToolUse(rawConstraint: "fx-cc", packageSelector: "fx-cc",
    executableName: "gcc", tarballProvisioning: @[record])

proc sdkRecord(manifest: string): InterfaceTarballProvisioning =
  result = InterfaceTarballProvisioning(
    packageName: "fx-ruby", url: "https://example.invalid/ruby.7z",
    sha256: Sha, archiveType: "tar.gz", executablePath: "bin/ruby",
    stripComponents: 1, cpu: "any", os: "any", packageId: "fx-ruby@1",
    lockIdentity: "tarball:fx-ruby@1:sha256:" & Sha,
    gemClosure: manifest, gemBuildUses: @[ccUse()],
    location: SourceLocation(file: "repro.nim", line: 2))

proc sdkUse(record: InterfaceTarballProvisioning): InterfaceToolUse =
  InterfaceToolUse(rawConstraint: "fx-ruby", packageSelector: "fx-ruby",
    executableName: "ruby", tarballProvisioning: @[record],
    location: SourceLocation(file: "fixture", line: 1))

suite "gem closure manifest grammar":
  test "a well-formed manifest keeps its order and skips comments":
    let entries = parseGemClosureManifestText(good(), "fx.manifest")
    check entries.len == 2
    check entries[0].name == "mini_portile2"
    check entries[1].name == "nokogiri"
    check entries[1].platform == "ruby"
    check gemFileName(entries[1]) == "nokogiri-1.18.10.gem"
    check canonicalGemLine(entries[0]) == good().splitLines()[2]

  test "every malformed line is refused, naming the file and line":
    let base = line("rack", "3.2.4", "ruby", Sha, gemUrl("rack-3.2.4.gem"))
    check "fx.manifest:1" in refusal("rack 3.2.4 ruby " & Sha)
    check "5 fields" notin refusal(base)
    check "fx.manifest:3" in refusal("#\n\n" & base.replace("rack ", "ra/ck "))
    check "named twice" in refusal(base & "\n" & base)
    check "RubyGems version" in refusal(base.replace("3.2.4 ", "3.2.4-1 "))
    check "RubyGems version" in refusal(base.replace("3.2.4 ", "v3 "))
    check "platform" in refusal(base.replace(" ruby ", " x64/ucrt "))
    check "64 lowercase hex" in refusal(base.replace(Sha, Sha.toUpperAscii))
    check "64 lowercase hex" in refusal(base.replace(Sha, Sha[0 .. 62]))
    check "https://" in refusal(base.replace("https://", "http://"))
    check "must end in rack-3.2.4.gem" in
      refusal(base.replace("rack-3.2.4.gem", "rack-3.2.5.gem"))
    # A prebuilt gem's file name carries its platform.
    check "must end in rack-3.2.4-x64-mingw-ucrt.gem" in
      refusal(base.replace(" ruby ", " x64-mingw-ucrt "))
    check refusal(line("rack", "3.2.4", "x64-mingw-ucrt", Sha,
      gemUrl("rack-3.2.4-x64-mingw-ucrt.gem"))) == ""

  test "a prebuilt gem needs a reviewed substitution, and nokogiri never has one":
    let prebuilt = parseGemClosureManifestText(line("rack", "3.2.4",
      "x64-mingw-ucrt", Sha, gemUrl("rack-3.2.4-x64-mingw-ucrt.gem")), "m")
    expect ValueError:
      validateGemClosureDeclaration(prebuilt, [], [], [], "m")
    validateGemClosureDeclaration(prebuilt, ["rack"], [], [], "m")
    let noko = parseGemClosureManifestText(line("nokogiri", "1.18.10",
      "x64-mingw-ucrt", Sha, gemUrl("nokogiri-1.18.10-x64-mingw-ucrt.gem")),
      "m")
    try:
      validateGemClosureDeclaration(noko, ["nokogiri"], [], [], "m")
      check false
    except ValueError as err:
      check "always built from its source gem" in err.msg
    expect ValueError:
      validateGemClosureDeclaration(prebuilt, ["rack", "absent"], [], [], "m")

  test "build arguments name manifest gems and step tools only":
    let entries = parseGemClosureManifestText(good(), "m")
    let args = @[GemBuildArgs(gem: "nokogiri",
      args: @["--use-system-libraries",
              "--with-xml2-dir=$REPRO_PREFIX_LIBXML2_DEV"])]
    validateGemClosureDeclaration(entries, [], args, ["libxml2-dev"], "m")
    try:
      validateGemClosureDeclaration(entries, [], args, ["libxml2"], "m")
      check false
    except ValueError as err:
      check "$REPRO_PREFIX_LIBXML2_DEV" in err.msg
    expect ValueError:
      validateGemClosureDeclaration(entries, [],
        @[GemBuildArgs(gem: "absent", args: @[])], [], "m")
    expect ValueError:
      validateGemClosureDeclaration(entries, [], args & args,
        ["libxml2-dev"], "m")
    check gemPrefixVariableName("libxml2-dev") == "LIBXML2_DEV"
    check gemPrefixReferences("a=$REPRO_PREFIX_X_Y/b:$REPRO_PREFIX_Z") ==
      @["X_Y", "Z"]

  test "a refusal comes when the edge is declared, before any fetch":
    let root = createTempDir("repro-gem-grammar-", "")
    defer: removeDir(root)
    let manifest = root / "bad.manifest"
    writeFile(manifest, good() & "nokogiri 1.18.10 ruby " & Sha & "\n")
    var message = ""
    try:
      discard tarballProvisioningEdges(sdkUse(sdkRecord(manifest)),
        root / "store")
    except ToolPrefixDeclarationError as err:
      message = err.msg
    check (manifest & ":5") in message
    check not dirExists(root / "store")
    # The same with a prebuilt nokogiri the record does not admit.
    writeFile(manifest, line("nokogiri", "1.18.10", "x64-mingw-ucrt", Sha,
      gemUrl("nokogiri-1.18.10-x64-mingw-ucrt.gem")) & "\n")
    message = ""
    try:
      discard tarballProvisioningEdges(sdkUse(sdkRecord(manifest)),
        root / "store")
    except ToolPrefixDeclarationError as err:
      message = err.msg
    check "does not admit" in message
    check not dirExists(root / "store")
    # A good manifest declares the edge, with the build tool as a
    # dependency edge of it.
    writeFile(manifest, good())
    let edges = tarballProvisioningEdges(sdkUse(sdkRecord(manifest)),
      root / "store")
    check edges.actions.len == 2

  test "a manifest under a graph output is refused":
    let root = createTempDir("repro-gem-graph-", "")
    defer: removeDir(root)
    createDir(root / "build")
    writeFile(root / "build" / "gems.manifest", good())
    let use = sdkUse(sdkRecord(root / "build" / "gems.manifest"))
    try:
      refuseStepDeclarationsUnderGraphOutputs([use], [root / "build"])
      check false
    except ToolPrefixDeclarationError as err:
      check "output of the build graph" in err.msg
    refuseStepDeclarationsUnderGraphOutputs([use], [root / "other"])

suite "gem closure declaration in the interface artifact":
  proc interfaceWith(record: InterfaceTarballProvisioning): ProjectInterface =
    result.projectName = "fx"
    result.packageName = "fx"
    result.location = SourceLocation(file: "repro.nim", line: 1)
    result.toolUses = @[sdkUse(record)]

  let entries = parseGemClosureManifestText(good(), "m")

  test "the step survives the codec, and a v35 payload has none":
    var record = sdkRecord("gems.manifest")
    record.gemEntries = entries
    record.gemBuildArgs = @[GemBuildArgs(gem: "nokogiri",
      args: @["--use-system-libraries"])]
    record.gemSubstitutions = @["mini_portile2"]
    let back = decodeInterfacePayload(encodeInterfacePayload(
      interfaceWith(record)))
    let got = back.toolUses[0].tarballProvisioning[0]
    check got.gemClosure == "gems.manifest"
    check got.gemEntries == entries
    check got.gemBuildUses.len == 1
    check got.gemBuildUses[0].packageSelector == "fx-cc"
    check got.gemBuildUses[0].tarballProvisioning[0].executablePath ==
      "bin/gcc"
    check got.gemBuildArgs == record.gemBuildArgs
    check got.gemSubstitutions == @["mini_portile2"]
    check got == record
    let old = decodeInterfacePayload(encodeInterfacePayload(
      interfaceWith(record), 35'u16), 35'u16)
    check not hasGemClosureStep(old.toolUses[0].tarballProvisioning[0])
    check interfaceEnvelopeVersion() >= 36'u16

  test "a record without a step keeps its digest; a changed gem moves it":
    var plain = sdkRecord("")
    plain.gemBuildUses = @[]
    var unset = InterfaceTarballProvisioning(
      packageName: "fx-ruby", url: "https://example.invalid/ruby.7z",
      sha256: Sha, archiveType: "tar.gz", executablePath: "bin/ruby",
      stripComponents: 1, cpu: "any", os: "any", packageId: "fx-ruby@1",
      lockIdentity: "tarball:fx-ruby@1:sha256:" & Sha,
      location: SourceLocation(file: "repro.nim", line: 2))
    check toolUseRealizationDigest(sdkUse(plain)) ==
      toolUseRealizationDigest(sdkUse(unset))
    var a = sdkRecord("gems.manifest")
    a.gemEntries = entries
    var b = a
    b.gemEntries[1].sha256 = Sha
    check toolUseRealizationDigest(sdkUse(a)) !=
      toolUseRealizationDigest(sdkUse(b))
    check toolUseRealizationDigest(sdkUse(a)) !=
      toolUseRealizationDigest(sdkUse(unset))

  test "the lift resolves build tools and inlines the manifest":
    let root = createTempDir("repro-gem-lift-", "")
    defer: removeDir(root)
    writeFile(root / "gems.manifest", good())
    let cc = PackageDef(packageName: "fx-cc", tarballProvisioning: @[
      TarballProvisioningDef(url: "https://example.invalid/cc.tar.gz",
        sha256: Sha, archiveType: "tar.gz", executablePath: "bin/gcc",
        packageId: "fx-cc@1", lockIdentity: "x")])
    let ruby = PackageDef(packageName: "fx-ruby", tarballProvisioning: @[
      TarballProvisioningDef(url: "https://example.invalid/ruby.7z",
        sha256: Sha, archiveType: "7z", executablePath: "bin/ruby.exe",
        packageId: "fx-ruby@1", lockIdentity: "y",
        gemClosure: "gems.manifest", gemBuildUses: @["fx-cc"],
        gemBuildArgs: @[("nokogiri", @["--use-system-libraries"])],
        sourceFile: root / "repro.nim", sourceLine: 3)])
    let consumer = PackageDef(packageName: "consumer", toolUses: @[
      PackageUseDef(rawConstraint: "fx-ruby", packageSelector: "fx-ruby",
        executableName: "ruby")])
    let pi = toProjectInterface(consumer, [cc, ruby, consumer])
    let record = pi.toolUses[0].tarballProvisioning[0]
    check record.gemEntries == entries
    check record.gemBuildUses.len == 1
    check record.gemBuildUses[0].tarballProvisioning.len == 1
    check record.gemBuildUses[0].tarballProvisioning[0].executablePath ==
      "bin/gcc"
    check record.gemBuildArgs == @[GemBuildArgs(gem: "nokogiri",
      args: @["--use-system-libraries"])]
    let contribution = ProvisioningContributionDef(targetPackage: "fx-ruby",
      contributor: "elsewhere",
      tarballProvisioning: ruby.tarballProvisioning)
    expect ValueError:
      discard toProjectInterface(consumer, [cc, ruby, consumer],
        [contribution])

suite "closure grammar: whole-file, tar.zst and root-overlay entries":
  proc parse(text: string): seq[ClosureEntry] =
    parseClosureManifestText(text, "c.manifest")

  test "a file entry is copied, never stripped":
    let e = parse(".repro-gems/a-1.gem " & Sha & " https://x.invalid/a-1.gem file 0")
    check e[0].archiveType == ClosureFileKind
    expect ValueError:
      discard parse("a.gem " & Sha & " https://x.invalid/a.gem file 1")

  test "tar.zst entries and root overlays":
    let e = parse(". " & Sha & " https://x.invalid/a.pkg.tar.zst tar.zst 0\n" &
      ". " & Other & " https://x.invalid/b.pkg.tar.zst tar.zst 0\n" &
      "sub " & Sha & " https://x.invalid/c.tar.zst tar.zst 1")
    check e.len == 3
    check isClosureRootOverlay(e[0])
    check isClosureRootOverlay(e[1])
    check not isClosureRootOverlay(e[2])
    # The root needs the explicit five-field form, and an archive kind.
    expect ValueError:
      discard parse(". " & Sha & " https://x.invalid/a.tgz")
    expect ValueError:
      discard parse(". " & Sha & " https://x.invalid/a.gem file 0")
    # Two directory entries still may not share a destination.
    expect ValueError:
      discard parse("sub " & Sha & " https://x.invalid/a.tgz\n" &
        "sub " & Other & " https://x.invalid/b.tgz")
