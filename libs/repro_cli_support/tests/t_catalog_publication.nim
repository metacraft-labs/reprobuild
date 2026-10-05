## The catalog publisher's checks (``repro_cli_support/catalog_publication``,
## ReproOS-Campaign-Completion M6 deliverable 5), on artifacts built in this
## process -- no provider is compiled here; the hermetic fixture test
## (``tests/integration/t_hermetic_published_catalog_fixture.nim``) runs the
## real extraction. Each case pins one refusal or rewrite, exact text.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_interface_artifacts/catalog_declaration
import repro_cli_support
import repro_project_dsl

package publishedTool:
  executable publishedTool:
    name "published-tool"

const Contributor = "github:example/catalog"

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

let root = createTempDir("repro-publish-unit-", "")
let catalogRoot = root / "catalog"
createDir(catalogRoot)

proc catalogArtifact(location: string): ProjectInterfaceArtifact =
  ## A contribution catalog as an extraction would record it, the
  ## contribution declared at ``location``.
  let pkgs = registeredPackages()
  let fp = canonicalPackageInterfaceFingerprint(findPackage("publishedTool"),
    pkgs)
  let def = ProvisioningContributionDef(targetPackage: "publishedTool",
    targetInterfaceFingerprint: fp, contributor: Contributor,
    tarballProvisioning: @[TarballProvisioningDef(
      url: "https://example.invalid/t.tar.gz", sha256: repeat('a', 64),
      archiveType: "tar.gz", executablePath: "bin/published-tool",
      stripComponents: 1, packageId: "published-tool@1",
      lockIdentity: "sha256:" & repeat('a', 64))],
    sourceFile: location, sourceLine: 7)
  var pi = ProjectInterface(projectName: "catalogProject",
    packageName: "catalogProject",
    location: SourceLocation(file: catalogRoot / "repro.nim", line: 3))
  pi.provisioningContributions = toProjectInterface(
    findPackage("publishedTool"), pkgs, @[def]).provisioningContributions
  artifactFor(pi)

proc good(): ProjectInterfaceArtifact =
  catalogArtifact(catalogRoot / "repro.nim")

when defined(windows):
  proc getShortPathNameW(long, short: WideCString; size: int32): int32 {.
    stdcall, dynlib: "kernel32", importc: "GetShortPathNameW".}
  proc shortPath(path: string): string =
    var buffer = newWideCString(newString(32768))
    let n = getShortPathNameW(newWideCString(path), buffer, 32768)
    if n > 0 and n < 32768: $buffer else: ""

proc refusal(artifact: ProjectInterfaceArtifact;
             hostPaths: seq[string] = @[]): string =
  try:
    discard publishableArtifact(artifact, catalogRoot, "repro.nim", hostPaths)
    ""
  except CatalogPublicationError as err:
    err.msg

suite "catalog publication":
  test "absolute locations inside the catalog become repository-relative":
    let extracted = catalogArtifact(catalogRoot / "sub" / "repro.nim")
    let f = publishableArtifact(extracted, catalogRoot, "repro.nim")
    check f.artifact.projectInterface.location.file == "repro.nim"
    check f.artifact.projectInterface.provisioningContributions[0].
      location.file == "sub/repro.nim"
    check f.fileName == "catalogProject.rbsz"
    check f.module == "repro.nim"
    # No identity moved, and the bytes name no host path.
    check f.artifact.interfaceFingerprint == extracted.interfaceFingerprint
    check catalogRoot notin f.bytes
    check catalogRoot.replace('\\', '/') notin f.bytes
    check decodePublishedArtifact("x", f.bytes) == f.artifact
    # A location that is already relative is kept.
    let relative = catalogArtifact("sub/repro.nim")
    check publishableArtifact(relative, catalogRoot, "repro.nim").artifact.
      projectInterface.provisioningContributions[0].location.file ==
        "sub/repro.nim"

  test "a location outside the catalog refuses":
    let outside = root / "elsewhere" / "repro.nim"
    check refusal(catalogArtifact(outside)) == "catalog " & catalogRoot &
      " cannot publish repro.nim:\n  source locations outside the catalog " &
      "repository " & catalogRoot & " would publish a host path: " & outside &
      ":7"
    # A sibling whose name only starts like the catalog's is outside too
    # (and its path, kept, contains the catalog root's spelling).
    let sibling = catalogRoot & "-other" / "repro.nim"
    check refusal(catalogArtifact(sibling)) == "catalog " & catalogRoot &
      " cannot publish repro.nim:\n  source locations outside the catalog " &
      "repository " & catalogRoot & " would publish a host path: " & sibling &
      ":7\n  the encoded artifact contains the host path " & catalogRoot

  test "a location that climbs out of the catalog with .. refuses; . and inner .. are normalized":
    # Starts with the catalog root's spelling, names a file outside it.
    let climbing = catalogRoot & DirSep & ".." & DirSep & "elsewhere" & DirSep &
      "repro.nim"
    check refusal(catalogArtifact(climbing)) == "catalog " & catalogRoot &
      " cannot publish repro.nim:\n  source locations outside the catalog " &
      "repository " & catalogRoot & " would publish a host path: " & climbing &
      ":7\n  the encoded artifact contains the host path " & catalogRoot
    check refusal(catalogArtifact("../elsewhere/repro.nim")) == "catalog " &
      catalogRoot & " cannot publish repro.nim:\n  source locations outside " &
      "the catalog repository " & catalogRoot & " would publish a host path: " &
      "../elsewhere/repro.nim:7"
    check refusal(catalogArtifact(r"sub\..\..\repro.nim")) == "catalog " &
      catalogRoot & " cannot publish repro.nim:\n  source locations outside " &
      "the catalog repository " & catalogRoot & " would publish a host path: " &
      r"sub\..\..\repro.nim:7"
    # One file, one spelling: ``.``, empty segments and an inner ``..`` that
    # stays inside are normalized away, absolute or relative.
    for (loc, expected) in [
        (catalogRoot & DirSep & "." & DirSep & "sub" & DirSep & DirSep &
           "repro.nim", "sub/repro.nim"),
        (catalogRoot & DirSep & "sub" & DirSep & "x" & DirSep & ".." & DirSep &
           "repro.nim", "sub/repro.nim"),
        ("./sub//repro.nim", "sub/repro.nim"),
        ("sub/x/../repro.nim", "sub/repro.nim")]:
      check publishableArtifact(catalogArtifact(loc), catalogRoot,
        "repro.nim").artifact.projectInterface.provisioningContributions[0].
          location.file == expected

  test "what a consumer refuses is not published":
    var develop = catalogArtifact(catalogRoot / "repro.nim")
    develop.projectInterface.provisioningContributions[0].developInterface =
      true
    develop = artifactFor(develop.projectInterface)
    check refusal(develop) == "catalog " & catalogRoot &
      " cannot publish repro.nim:\n  published artifact " &
      "published-interfaces/catalogProject.rbsz: contribution from \"" &
      Contributor & "\" for package \"publishedTool\" uses " &
      "developInterface, which is forbidden in a published catalog snapshot"
    var imported = catalogArtifact(catalogRoot / "repro.nim")
    imported.projectInterface.provisioningContributions[0].imported = true
    imported = artifactFor(imported.projectInterface)
    check refusal(imported) == "catalog " & catalogRoot &
      " cannot publish repro.nim:\n  published artifact " &
      "published-interfaces/catalogProject.rbsz: contribution from \"" &
      Contributor & "\" for package \"publishedTool\" is IMPORTED " &
      "(re-exported from another catalog); a catalog publishes only its own " &
      "records"

  test "a host path anywhere in the bytes refuses":
    var leaky = catalogArtifact(catalogRoot / "repro.nim")
    leaky.projectInterface.provisioningContributions[0].
      tarballProvisioning[0].url = "file:///" &
        catalogRoot.replace('\\', '/').toUpperAscii() & "/t.tar.gz"
    leaky = artifactFor(leaky.projectInterface)
    when defined(windows):
      # Separators and letter case folded: one host, one path.
      check refusal(leaky) == "catalog " & catalogRoot &
        " cannot publish repro.nim:\n  the encoded artifact contains the " &
        "host path " & catalogRoot
    let good = catalogArtifact(catalogRoot / "repro.nim")
    check refusal(good, @["https://example.invalid"]) == "catalog " &
      catalogRoot & " cannot publish repro.nim:\n  the encoded artifact " &
      "contains the host path https://example.invalid"
    check refusal(good) == ""

  test "a host path is found in every spelling a toolchain writes":
    proc leakyWith(url: string): ProjectInterfaceArtifact =
      var a = catalogArtifact(catalogRoot / "repro.nim")
      a.projectInterface.provisioningContributions[0].tarballProvisioning[0].
        url = url
      artifactFor(a.projectInterface)
    let spaced = root / "a dir with spaces"
    createDir(spaced)
    let refused = "catalog " & catalogRoot & " cannot publish repro.nim:\n  " &
      "the encoded artifact contains the host path "
    # Escaped / doubled separators.
    check refusal(leakyWith(catalogRoot.replace("\\", "\\\\") &
      "\\\\t.tar.gz")) == refused & catalogRoot
    check refusal(leakyWith("file:///" & catalogRoot.replace('\\', '/').
      replace("/", "//") & "/t.tar.gz")) == refused & catalogRoot
    # Percent-encoded inside a file URL.
    check refusal(leakyWith("file:///" & spaced.replace('\\', '/').
      replace(" ", "%20") & "/t.tar.gz"), @[spaced]) == refused & spaced
    when defined(windows):
      # The MSYS drive form.
      let msys = "/" & $catalogRoot[0].toLowerAscii() &
        catalogRoot[2 .. ^1].replace('\\', '/')
      check refusal(leakyWith("file://" & msys & "/t.tar.gz")) ==
        refused & catalogRoot
      # The 8.3 short form of a long path (when the volume generates short
      # names; reported, so a host without them is visible in the log).
      let short = shortPath(spaced)
      if short.len > 0 and cmpIgnoreCase(short, spaced) != 0:
        check refusal(leakyWith("file:///" & short.replace('\\', '/') &
          "/t.tar.gz"), @[spaced]) == refused & spaced
      else:
        echo "    (no 8.3 short name for ", spaced, "; short-form check skipped)"
    # A path the provider deliberately split across fields is NOT looked for
    # (stated in the module docstring): the scan guards against a
    # publisher's own host paths leaking, not against a provider encoding
    # one on purpose.
    check refusal(good()) == ""

  test "a project name that cannot name a file refuses":
    var named = catalogArtifact(catalogRoot / "repro.nim")
    named.projectInterface.projectName = "a/b"
    check refusal(artifactFor(named.projectInterface)) == "catalog " &
      catalogRoot & " cannot publish repro.nim:\n  project name \"a/b\" " &
      "contains \"/\" (a published artifact is named by its project name, " &
      "and only letters, digits, '.', '_' and '-' are accepted)"
    named.projectInterface.projectName = ".hidden"
    check refusal(artifactFor(named.projectInterface)) == "catalog " &
      catalogRoot & " cannot publish repro.nim:\n  project name " &
      "\".hidden\" starts with '.'"

  test "the publication is replaced whole, and refuses two files of one name or none":
    let f = publishableArtifact(catalogArtifact(catalogRoot / "repro.nim"),
      catalogRoot, "repro.nim")
    let dir = catalogRoot / "published-interfaces"
    createDir(dir)
    writeFile(dir / "stale.rbsz", "stale")
    writePublishedInterfaces(catalogRoot, @[f])
    check readFile(dir / "catalogProject.rbsz") == f.bytes
    check not fileExists(dir / "stale.rbsz")
    for (files, expected) in [(@[f, f], "catalog " & catalogRoot &
        ": two modules publish catalogProject.rbsz (one project name is one " &
        "published artifact)"), (newSeq[PublishedArtifactFile](), "catalog " &
        catalogRoot & " publishes nothing; a publication holds at least one " &
        "artifact")]:
      var raised = ""
      try:
        writePublishedInterfaces(catalogRoot, files)
      except CatalogPublicationError as err:
        raised = err.msg
      check raised == expected
      # A refused publication leaves the previous one in place.
      check readFile(dir / "catalogProject.rbsz") == f.bytes

  test "a missing provider module refuses before anything runs":
    var raised = ""
    try:
      discard publishCatalogInterfaces(catalogRoot, ["absent.nim"],
        getCurrentDir())
    except CatalogPublicationError as err:
      raised = err.msg
    check raised == "catalog " & catalogRoot & " has no provider module " &
      "absent.nim"
    raised = ""
    try:
      discard publishCatalogInterfaces(catalogRoot, [], getCurrentDir())
    except CatalogPublicationError as err:
      raised = err.msg
    check raised == "catalog " & catalogRoot & ": no provider module named"

removeDir(root)
