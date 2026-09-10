## The Scoop manifest producer.
##
## Scoop's package IS its manifest: a JSON file naming an archive, a
## hash to check it against, and the executables to shim onto PATH. So
## almost every way this producer can be wrong is a way of describing an
## archive incorrectly rather than of building one incorrectly, and
## these cases are about the description.
##
## Two of them matter more than the rest. `bin` must name the WRAPPERS,
## because under the §5 contract the wrapper is the file a user runs and
## the payload beside it has none of the twenty environment defaults —
## shimming the payload gives a `repro.exe` that works on the machine
## that built it and nowhere else. And the `hash` must be a TOKEN at
## graph time, because the archive does not exist yet; a producer that
## wrote a plausible digest would emit a manifest that fails
## verification for every user, and one that omitted the field would
## emit a manifest that verifies nothing at all.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging

proc sample(targetOs = toWindows): Distribution =
  result = newDistribution("sampletool", "0.2.0", targetOs,
    prefix = (if targetOs == toWindows: "" else: "/usr"),
    stagingRoot = "build/dist/sampletool-0.2.0",
    outputDir = "build/dist")
  result.components = @[
    executableComponent("build/bin/hello" &
      (if targetOs == toWindows: ".exe" else: "")),
    component(crDataFile, "build/gen/README.md")
  ]
  result.metadata = DistMetadata(
    summary: "A sample tool",
    description: "Longer text.",
    homepage: "https://example.invalid/sampletool",
    license: "MIT")

suite "packaging: the Scoop manifest":

  test "the manifest is named for the package, not for the artifact":
    # ``scoop install sampletool`` looks for ``sampletool.json`` in a
    # bucket, so the file name is the package's public identity rather
    # than a decorative artifact name with a version in it.
    check scoopManifestName(sample()) == "sampletool.json"

  test "the hash is a token at graph time and is prefixed sha256:":
    let dist = sample()
    let tree = stageInstallTree(dist, "tar")
    let text = scoopManifestText(dist, tree)
    check text.contains("\"hash\": \"sha256:" & ScoopHashToken & "\"")
    # And it is a DIFFERENT token from the prefix one, for the same
    # reason the glibc floor's is: ``@PREFIX@`` must survive into the
    # shipped artifact and be expanded at run time; this one must not
    # survive the build at all.
    check ScoopHashToken != PrefixToken
    check not ScoopHashToken.contains(PrefixToken)

  test "an absent URL is a visible token, never an invented address":
    # A manifest with a well-formed but wrong URL installs whatever is
    # at that address on the day someone points a bucket at it. A token
    # fails at DOWNLOAD, before any bytes are trusted.
    let dist = sample()
    let tree = stageInstallTree(dist, "tar")
    check scoopManifestText(dist, tree).contains(
      "\"url\": \"" & ScoopUrlToken & "\"")
    check not ScoopUrlToken.startsWith("http")
    let withUrl = scoopManifestText(dist, tree,
      downloadUrl = "https://example.invalid/a.tar.gz")
    check withUrl.contains("\"url\": \"https://example.invalid/a.tar.gz\"")
    check not withUrl.contains(ScoopUrlToken)

  test "bin names the WRAPPERS, with Windows separators":
    # The §5 failure this exists to stop: shimming the component would
    # put the unwrapped payload on PATH, i.e. a binary with none of the
    # environment defaults its wrapper sets.
    var dist = sample()
    dist.runtime.wrapExecutables = true
    let tree = stageInstallTree(dist, "tar")
    let bins = scoopBinEntries(dist, tree)
    check bins.len == 1
    check bins[0] == "bin\\hello.cmd"
    check not bins[0].contains("/")
    # ...and the DATA file is not a shim, however many files the tree has.
    for b in bins:
      check not b.contains("README")

  test "an unwrapped distribution shims the binary itself":
    # ``wrapExecutables = false`` is a real configuration (M0's
    # ``newDistribution`` default), and there the public entry point IS
    # the payload. The producer must follow the tree rather than assume
    # a wrapper exists.
    var dist = sample()
    dist.runtime.wrapExecutables = false
    let tree = stageInstallTree(dist, "tar")
    let bins = scoopBinEntries(dist, tree)
    check bins == @["bin\\hello.exe"]

  test "the architecture key is Scoop's vocabulary, not reprobuild's":
    # ``64bit`` rather than ``x86_64``: this is the key Scoop looks up,
    # so "close enough" is a manifest that installs on nothing.
    var dist = sample()
    let tree = stageInstallTree(dist, "tar")
    check scoopManifestText(dist, tree).contains("\"64bit\": {")
    dist.architecture = "aarch64"
    check scoopManifestText(dist, stageInstallTree(dist, "tar"))
      .contains("\"arm64\": {")

  test "the manifest is valid-looking JSON with balanced braces":
    # Hand-emitted rather than produced by a JSON library, for the same
    # reason deb's stanza and rpm's spec are: the text must be a pure
    # function of the Distribution. That makes a structural check worth
    # having.
    let dist = sample()
    let text = scoopManifestText(dist, stageInstallTree(dist, "tar"))
    var depth = 0
    var inString = false
    var escaped = false
    for ch in text:
      if inString:
        if escaped: escaped = false
        elif ch == '\\': escaped = true
        elif ch == '"': inString = false
      else:
        case ch
        of '"': inString = true
        of '{', '[': inc depth
        of '}', ']': dec depth
        else: discard
      check depth >= 0
    check depth == 0
    check not inString

  test "the producer's edges hash the archive and depend on it":
    # The one case that builds the EDGES rather than the text. It is
    # what makes "the hash is measured" a property of the graph rather
    # than of a comment: the manifest edge depends on a hash file, the
    # hash edge depends on the ARCHIVE, and both name the two tools an
    # action's PATH would otherwise not have.
    resetBuildActionRegistry()
    var dist = sample(toLinux)
    dist.runtime.vendorRuntimeClosure = false
    let tar = tarballPackage(dist)
    let scoop = scoopPackage(dist, tar)
    check scoop.format == "scoop"
    check scoop.path.endsWith("/sampletool.json")
    for selector in ScoopSelectors:
      check selector in scoop.toolSelectors
    # ...and the tarball's own tools ride along, because a manifest that
    # named an archive nothing built would be a graph with a hole in it.
    check TarSelector in scoop.toolSelectors
    # The manifest's tree IS the archive's tree: one staging, one answer
    # to "which files does this package contain".
    check scoop.tree.root == tar.tree.root

  test "a summary containing quotes or newlines cannot break the JSON":
    # reprobuild's own one-line summary already contains an em dash, and
    # that alone was enough to make the MSI producer fail on a codepage.
    # A quote in a description is the JSON-shaped version of that.
    var dist = sample()
    dist.metadata.summary = "a \"quoted\" tool\nwith a second line"
    let text = scoopManifestText(dist, stageInstallTree(dist, "tar"))
    check text.contains("\\\"quoted\\\"")
    # Only the FIRST line is the description, as in every other format.
    check not text.contains("second line")
