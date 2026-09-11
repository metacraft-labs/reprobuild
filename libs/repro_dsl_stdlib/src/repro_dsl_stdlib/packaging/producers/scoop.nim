## The Scoop manifest producer — the format with no archiver of its own.
##
## §6's table: ``dist.scoop  # manifest JSON over the archive, bin shims``.
##
## Scoop is a Windows package manager whose "package" is a single JSON
## file: it names an ARCHIVE by URL, a hash to check it against, and the
## executables to shim onto the user's PATH. There is nothing to build
## and no tool to fork — which makes this the cheapest producer in the
## layer, and also the one that has to say most plainly what it is NOT.
##
## ## It produces a manifest FOR an archive, and does not produce one
##
## `scoopPackage` takes the `PackagedArtifact` some other producer
## already returned (in practice the tarball's — Scoop's 7-Zip handles
## `.tar.gz` natively) rather than staging a second tree of its own.
## Two producers over one `Distribution` would stage two trees, which
## the layer supports, but the manifest must describe THE ARCHIVE THE
## USER DOWNLOADS, byte for byte, or its hash is a lie. Taking the
## artifact as a parameter is what makes that structural instead of a
## convention.
##
## ## The hash is measured, not asserted
##
## A manifest's `hash` is the one field that cannot be written at graph
## time: the archive does not exist until its edge has run. This is the
## same shape as the C-library floor and it reuses the same machinery —
## `types.ScoopHashToken` goes where the digest belongs and
## `runtime_contract.substitutionScript` re-assembles the text with the
## measured value inside an action. Writing the manifest with `writeText`
## and then editing it would be one edge rewriting another's output,
## which this layer does not do anywhere.
##
## ## The URL is a PARAMETER and defaults to nothing
##
## Where the archive will be published is a hosting fact (M3), not a
## build fact, and a producer that invented a plausible URL would emit a
## manifest that installs the wrong bytes on the day someone points a
## bucket at it. `downloadUrl` therefore defaults to empty and the
## manifest then carries `types.ScoopUrlToken`, which is visibly not a
## URL: a release pipeline substitutes it, and a manifest that reached a
## user unsubstituted fails loudly at download rather than quietly at
## verification.

import std/[strutils]

import repro_project_dsl

import ../types
import ../runtime_contract
import ../producer
import ../../packages/sh as sh_module
{.push warning[UnusedImport]: off.}
import ../../packages/coreutils_install
{.pop.}

{.experimental: "callOperator".}

# The two tools this producer's edges need. Both names are already
# exported by ``runtime_contract`` (the staging path uses them), so they
# are USED here rather than redeclared: two consts with one name in one
# import graph is an ambiguity waiting for the first recipe that spells
# it unqualified.
#
# ``sha256sum`` is coreutils, reached through the ``install``
# executable's package exactly as the runtime-closure walk reaches
# ``rm`` and ``sort``. An action's PATH holds only what its edge named,
# so without ``InstallSelector`` the hash edge dies with ``sha256sum:
# command not found`` -- the same lesson the rpm scriptlet selectors
# record, one tool further out.
const ScoopSelectors* = [ShSelector, InstallSelector]

proc scoopManifestName*(dist: Distribution): string =
  ## Scoop identifies a package by its manifest's FILE NAME (`scoop
  ## install repro` looks for `repro.json` in a bucket), so this is the
  ## package's public name and not a decorative artifact name.
  dist.name & ".json"

proc jsonString(value: string): string =
  ## Minimal JSON string escaping. Deliberately not a JSON library: the
  ## layer emits three formats' control files by hand already (deb's
  ## stanza, rpm's spec, WiX's XML) and a manifest whose text is a pure
  ## function of the `Distribution` is what makes the artifact
  ## reproducible.
  result = "\""
  for ch in value:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:
      if ch < ' ':
        result.add("\\u" & toHex(ord(ch), 4).toLowerAscii())
      else:
        result.add(ch)
  result.add("\"")

proc scoopBinEntries*(dist: Distribution; tree: StagedTree): seq[string] =
  ## The executables Scoop shims onto PATH, as archive-relative paths
  ## with Windows separators.
  ##
  ## Read off `StagedTree.publicEntryPoints` rather than off
  ## `dist.components`, and the difference matters: under the §5 contract
  ## the file a user runs is the WRAPPER, and the wrapper is a staged
  ## file that no component names. Shimming the components would put the
  ## unwrapped payload on the user's PATH, i.e. a `repro.exe` with none
  ## of the packaged environment defaults set — which works on the machine
  ## that built it and nowhere else.
  for f in tree.publicEntryPoints():
    result.add(f.rootRelPath.replace("/", "\\"))

proc scoopManifestText*(dist: Distribution; tree: StagedTree;
                        downloadUrl = ""): string =
  ## The manifest, with `ScoopHashToken` where the archive digest goes.
  let url = if downloadUrl.len > 0: downloadUrl else: ScoopUrlToken
  let arch =
    case dist.architecture
    of "x86_64", "amd64": "64bit"
    of "aarch64", "arm64": "arm64"
    of "i386", "i686": "32bit"
    else: dist.architecture
  result = "{\n"
  result.add("  \"version\": " & jsonString(dist.version) & ",\n")
  if dist.metadata.summary.len > 0:
    result.add("  \"description\": " &
      jsonString(dist.metadata.summary.splitLines()[0]) & ",\n")
  if dist.metadata.homepage.len > 0:
    result.add("  \"homepage\": " & jsonString(dist.metadata.homepage) & ",\n")
  if dist.metadata.license.len > 0:
    result.add("  \"license\": " & jsonString(dist.metadata.license) & ",\n")
  result.add("  \"architecture\": {\n")
  result.add("    " & jsonString(arch) & ": {\n")
  result.add("      \"url\": " & jsonString(url) & ",\n")
  # ``sha256:`` is Scoop's own prefix vocabulary; a bare hex string is
  # also accepted and means the same thing, but the prefixed form is
  # what ``scoop checkver``/``scoop update`` write, so a manifest a
  # human later edits by hand stays in one dialect.
  result.add("      \"hash\": " & jsonString("sha256:" & ScoopHashToken) &
    "\n")
  result.add("    }\n")
  result.add("  },\n")
  let bins = scoopBinEntries(dist, tree)
  result.add("  \"bin\": [\n")
  for i, b in bins:
    let comma = if i + 1 < bins.len: "," else: ""
    result.add("    " & jsonString(b) & comma & "\n")
  result.add("  ]\n")
  result.add("}\n")

proc scoopPackage*(dist: Distribution; archive: PackagedArtifact;
                   site = noSite();
                   downloadUrl = ""): PackagedArtifact =
  ## Emit `<name>.json` describing `archive`.
  ##
  ## `archive` is another producer's output — the tarball's, normally —
  ## and this producer neither stages nor archives anything. The returned
  ## `PackagedArtifact` reuses that producer's tree so a caller can ask
  ## the manifest which files the package contains and get the same
  ## answer the archive would give.
  let outPath = dist.outputDir & "/" & scoopManifestName(dist)
  let hashPath = archive.tree.genRoot & "/scoop-" & dist.name & ".sha256"

  # ---- 1. measure the archive -----------------------------------------
  #
  # ``cut`` rather than ``awk``: coreutils' sha256sum prints
  # ``<hex>  <path>`` and the path is an absolute build-tree path, so the
  # digest must be taken by FIELD rather than by line. Writing the whole
  # line would put the builder's directory layout inside the manifest.
  var hashScript = "set -euf\n"
  hashScript.add("mkdir -p -- \"$(dirname -- '" & hashPath & "')\"\n")
  hashScript.add("sha256sum -- '" & archive.path & "' | cut -d' ' -f1 > '" &
    hashPath & "'\n")
  let hashEdge = sh_module.shell(hashScript,
    actionId = "pkg-scoop-hash-" & dist.name,
    after = @[archive.edge],
    extraInputs = @[archive.path],
    extraOutputs = @[hashPath])
  declareProducerTool(site, hashEdge.id, ShSelector)
  declareProducerTool(site, hashEdge.id, InstallSelector)

  # ---- 2. write the manifest with the digest spliced in ---------------
  let text = scoopManifestText(dist, archive.tree, downloadUrl)
  let script = substitutionScript(text, outPath,
    [(ScoopHashToken, hashPath)])
  let edge = sh_module.shell(script,
    actionId = "pkg-scoop-" & dist.name,
    after = @[hashEdge],
    extraInputs = @[hashPath],
    extraOutputs = @[outPath])
  declareProducerTool(site, edge.id, ShSelector)

  PackagedArtifact(
    format: "scoop",
    path: outPath,
    edge: edge,
    toolSelectors: @ScoopSelectors & archive.toolSelectors,
    tree: archive.tree)
