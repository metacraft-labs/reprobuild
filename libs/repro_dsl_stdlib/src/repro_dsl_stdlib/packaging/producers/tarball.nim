## The ``.tar.gz`` producer — the simplest instance of the interface,
## and the control the other two are read against.
##
## §6's table: ``dist.tarball  # dep: tar -> <name>-<ver>-<os>-<arch>.tar.gz
## (relocatable, wrapper-baked)``.
##
## It is worth being explicit about how little is here, because that is
## the claim M0 is making. This producer is about forty lines of
## substance: stage the tree, run one tool, return the edge. Everything
## that makes the package *correct* — the RPATH, the wrappers, the
## modes, the layout — happened in ``stageInstallTree`` before this file
## ran, and would have happened identically for a producer someone else
## wrote. If the tarball producer were long, that would be evidence the
## §5 contract had leaked out of the layer and into the formats.

import repro_project_dsl

import ../types
import ../runtime_contract
import ../producer
import ../../packages/tar as tar_module
# Imported for its REGISTRATION side effect only. gzip is never CALLED
# from here -- ``tar -z`` execs it behind our back -- so there is no
# typed wrapper to reference and the compiler's unused-import heuristic
# does not apply. Same pattern as
# ``tests/t_openssl_windows_link_channel.nim``. See the header of
# ``packages/gzip.nim`` for why a tool nobody types is still a real
# build-graph dependency.
{.push warning[UnusedImport]: off.}
import ../../packages/gzip
{.pop.}

{.experimental: "callOperator".}

const tarTool = tar_module.tar

const TarSelector* = "tar"
const GzipSelector* = "gzip"
  ## The compressor ``tar -z`` forks. An action's PATH holds only the
  ## tools its edge named, so without this the tar action gets gnutar
  ## and no gzip and exits 2 with ``gzip: command not found``. This is
  ## the one tool dependency in the layer that cannot be read off a
  ## producer's argv.

proc tarballArtifactName*(dist: Distribution): string =
  let osTag =
    case dist.targetOs
    of toLinux: "linux"
    of toDarwin: "darwin"
    of toWindows: "windows"
  dist.name & "-" & dist.fullVersion & "-" & osTag & "-" &
    dist.architecture & ".tar.gz"

proc tarballPackage*(dist: Distribution;
                     site = noSite()): PackagedArtifact =
  ## Produce a relocatable, wrapper-baked ``.tar.gz`` of the install
  ## tree.
  ##
  ## The tree is rooted at the PREFIX rather than at ``/`` (the ``tar``
  ## variant in ``stageInstallTree``), so unpacking it anywhere gives a
  ## working ``bin/``+``lib/`` pair. That is only usable because the §5
  ## RPATH is ``$ORIGIN``-relative and the wrapper resolves its own
  ## directory at run time; an absolute-prefix implementation of either
  ## would make this producer's output a tarball you can only unpack in
  ## one place, which is not what a tarball is for.
  var tree = stageInstallTree(dist, "tar", site)
  let outPath = dist.outputDir & "/" & tarballArtifactName(dist)
  let edge = tarTool(
    create = true,
    gzip = true,
    file = outPath,
    directory = tree.root,
    # ``--sort=name`` + a fixed ``--mtime`` + root ownership are what
    # make two builds of the same tree produce the same bytes. Without
    # them the member order is readdir order and the timestamps are
    # whenever the staging edges happened to run, so the artifact would
    # differ run to run and "content-addressed build edge" would be true
    # of the edge and false of anything anyone could observe.
    sortByName = true,
    mtime = "@0",
    owner = "0",
    group = "0",
    numericOwner = true,
    members = @["."],
    actionId = "pkg-tarball-" & dist.name,
    after = tree.terminal,
    extraInputs = tree.stagedPaths())
  declareProducerTool(site, edge.id, TarSelector)
  # Same edge, second tool: gzip has to be on the PATH of the action that
  # runs tar, not of some action of its own, because it is tar that execs
  # it. Declaring it on a separate edge would put it in the wrong place.
  declareProducerTool(site, edge.id, GzipSelector)
  PackagedArtifact(
    format: "tar.gz",
    path: outPath,
    edge: edge,
    # See the note in ``deb.nim``: the staging tools are read off the
    # tree, only this producer's own two are named here.
    toolSelectors: @[TarSelector, GzipSelector] & tree.stagingSelectors,
    tree: tree)

proc tarballProducer(dist: Distribution;
                     site: ToolDependencySite): PackagedArtifact {.nimcall.} =
  tarballPackage(dist, site)

registerProducer("tar.gz",
  "Relocatable gzipped tar of the install tree (tool: tar)",
  tarballProducer)
