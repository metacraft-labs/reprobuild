## The Arch Linux ``.pkg.tar.gz`` producer.
##
## §6's table names deb, rpm, MSI, tarball and Scoop; Arch was left in
## M1's ":what-was-not-attempted:" list. It is here now because it is the
## cheapest remaining format that is a genuinely DIFFERENT packaging
## model, and because the two things that make it different are both
## traps a "close enough" implementation walks into.
##
## ## What an Arch package IS
##
## A tar archive of the install tree rooted at ``/``, with metadata as
## ORDINARY MEMBERS at the archive root rather than in a side database:
## ``.PKGINFO`` (required), ``.MTREE`` and ``.INSTALL`` (optional). There
## is no control area, no spec file, no maintainer-script protocol of
## deb's shape — pacman reads ``.PKGINFO`` out of the same stream it
## unpacks.
##
## ## TRAP 1: ``tar .`` writes ``./.PKGINFO``, and libalpm looks for
## ## ``.PKGINFO``
##
## Every other producer in this layer hands ``tar`` a single ``.``
## member and lets it walk the tree. That is correct for the relocatable
## tarball and it is WRONG here: GNU tar records the member as
## ``./.PKGINFO``, and libalpm's ``_alpm_pkg_load_internal`` compares the
## entry name against the literal ``.PKGINFO`` (``strcmp``, after a
## single leading-``/`` strip — not a path normalisation). A package
## built with ``tar -c .`` therefore installs nothing and reports
## ``missing package metadata``: pacman never finds the file that is
## demonstrably inside the archive.
##
## So this producer names its top-level members EXPLICITLY -- ``.PKGINFO``
## first, then each top-level directory of the staged tree -- which
## records them without the ``./`` prefix and, as a second benefit,
## makes ``.PKGINFO`` the first entry in the stream, where makepkg puts
## it and where a reader that stops at the first metadata entry finds it
## immediately.
##
## ## TRAP 2: ``size`` is a MEASUREMENT, not a field you fill in
##
## ``.PKGINFO``'s ``size`` is what ``pacman -Si`` reports and what
## pacman checks the filesystem's free space against before unpacking.
## It cannot be known when the text is authored: the vendored runtime
## closure is DISCOVERED at build time by walking ``DT_NEEDED``, so the
## bytes that dominate this number do not exist yet. Authoring a
## plausible constant would be worse than omitting the field, because
## pacman would believe it.
##
## It is therefore measured by an edge over the finished tree and
## spliced in through ``types.InstalledSizeToken`` — the same mechanism
## the C-library floor and the Scoop digest use, and the third
## independent use of it, which is what makes ``substitutionScript`` a
## layer facility rather than a deb-specific workaround.
##
## ## Why ``.pkg.tar.gz`` rather than ``.pkg.tar.zst``
##
## pacman accepts gz, xz and zst and has since 5.x; ``zst`` is only
## makepkg's DEFAULT. Choosing gz costs some size and buys the producer
## the tool set the layer already declares (``tar`` + ``gzip``, the
## tarball producer's two) instead of adding a zstd dependency for a
## first Arch package nobody has installed yet. A distribution that
## wants zstd changes one flag once ``packages/zstd.nim`` grows a typed
## CLI surface.
##
## ## What is NOT here, and is recorded rather than faked
##
## * ``.MTREE`` — pacman uses it for ``pacman -Qkk`` verification and
##   installs fine without it. Generating one needs ``bsdtar
##   --format=mtree``, which is libarchive's tar and not GNU's, so it
##   would be a second archiver dependency for a verification feature.
## * ``.INSTALL`` — Arch's post-install hook script. This package's
##   services are not enabled at install time on ANY format (see
##   ``ServiceDef.startAtBoot``), so there is nothing for it to do.
## * Signatures — M2.

import std/[algorithm, strutils]

import repro_project_dsl

import ../types
import ../runtime_contract
import ../services
import ../producer
import ../../packages/tar as tar_module
import ../../packages/sh as sh_module
{.push warning[UnusedImport]: off.}
import ../../packages/gzip
# Imported for its REGISTRATION side effect: the installed-size edge
# execs ``find``, which is findutils and not the coreutils that
# ``install`` brings, and an action's PATH holds only the tools its edge
# NAMED. See ``ArchFindSelector``.
import ../../packages/host_system_tools
{.pop.}

{.experimental: "callOperator".}

const tarTool = tar_module.tar

const
  ArchTarSelector* = "tar"
  ArchGzipSelector* = "gzip"
  ArchShSelector* = "sh"
  ArchFindSelector* = "find"
    ## findutils, for the installed-size measurement, and NOT part of
    ## the coreutils the ``install-file`` package brings.
    ##
    ## Declared because the first Arch package this producer built
    ## reported ``size = 0``. See ``installedSizeScript`` for how an
    ## absent tool became a plausible number rather than a failure.

proc archArtifactName*(dist: Distribution): string =
  ## makepkg's own convention:
  ## ``<pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.gz``.
  ##
  ## Deliberately not ``artifactFileName``: pacman, ``repo-add`` and
  ## every AUR helper parse this name, and the ``-<pkgrel>-`` segment is
  ## what distinguishes a rebuild from a new version.
  dist.name & "-" & dist.version & "-" & dist.release & "-" &
    dist.archArchitecture & ".pkg.tar.gz"

proc archDependFields*(dist: Distribution; withGlibcFloor: bool): seq[string] =
  ## pacman's dependency spelling. No spaces and no parentheses:
  ## ``glibc>=2.38``, where deb says ``libc6 (>= 2.38)`` and rpm says
  ## ``glibc >= 2.38``. Same fact, third vocabulary — which is why
  ## ``DistMetadata`` carries three named lists rather than one abstract
  ## one.
  if withGlibcFloor:
    result.add("glibc>=" & GlibcFloorToken)
  for dep in dist.metadata.archDepends:
    result.add(dep)

proc archPkgInfoText*(dist: Distribution; withGlibcFloor = false): string =
  ## The ``.PKGINFO`` member.
  ##
  ## Field order follows makepkg's, which is not required by libalpm but
  ## makes a produced package diffable against one built by makepkg —
  ## the only cheap way to review this file without an Arch host.
  ##
  ## ``pkgver`` carries the RELEASE (``0.1.3-1``); the file name carries
  ## the two separately. That asymmetry is pacman's, not this layer's.
  let summary =
    if dist.metadata.summary.len > 0: dist.metadata.summary.splitLines()[0]
    else: dist.name
  result = "# Generated by the reprobuild DSL packaging layer.\n"
  result.add("pkgname = " & dist.name & "\n")
  # ``pkgbase`` equals ``pkgname`` for a package that is not one of
  # several built from a shared PKGBUILD. Stated rather than omitted:
  # ``repo-add`` records it, and a missing one reads as "unknown" in
  # tooling that groups split packages.
  result.add("pkgbase = " & dist.name & "\n")
  result.add("pkgver = " & dist.fullVersion & "\n")
  result.add("pkgdesc = " & summary & "\n")
  if dist.metadata.homepage.len > 0:
    result.add("url = " & dist.metadata.homepage & "\n")
  # The BUILD DATE is the reproducibility epoch, not the wall clock.
  # makepkg writes ``date +%s`` here, which is exactly the kind of
  # ambient input that makes two builds of one tree differ; the layer
  # already has one number that governs every format's timestamps.
  result.add("builddate = " & $dist.sourceDateEpoch & "\n")
  if dist.metadata.maintainer.len > 0:
    result.add("packager = " & dist.metadata.maintainer & "\n")
  result.add("size = " & InstalledSizeToken & "\n")
  result.add("arch = " & dist.archArchitecture & "\n")
  if dist.metadata.license.len > 0:
    result.add("license = " & dist.metadata.license & "\n")
  for dep in archDependFields(dist, withGlibcFloor):
    result.add("depend = " & dep & "\n")
  # ``backup`` is pacman's conffile mechanism: a listed path is not
  # overwritten on upgrade when its hash has changed, and the new one
  # lands as ``.pacnew``. Same role as deb's ``conffiles`` and rpm's
  # ``%config(noreplace)``, and like deb's it is stated WITHOUT a
  # leading slash — pacman stores it tree-relative, and an entry that
  # began with ``/`` matches no file and silently disables the
  # protection it was asking for.
  for c in dist.components:
    if c.role == crConfigFile:
      result.add("backup = " & installRelPath(dist, c) & "\n")

proc installedSizeScript*(treeRoot, outPath: string): string =
  ## Sum the apparent size of every regular file under ``treeRoot``.
  ##
  ## ``find`` piped through ``cat`` into ``wc -c`` rather than ``du -sb``
  ## or ``find -printf '%s'``: those count directory entries too, so the
  ## number would depend on the filesystem the build ran on.
  ## Concatenating is exactly the quantity wanted -- apparent bytes, not
  ## blocks -- and it is immune to file names containing spaces,
  ## newlines or quotes, which a parse of per-file ``wc -c`` output is
  ## not. It reads the payload once, which is cheap against the
  ## archiving that follows.
  ##
  ## ## Every way this can fail to measure is a HARD ERROR
  ##
  ## Written that way because the first Arch package built with it said
  ## ``size = 0`` and exited 0. ``find`` was not on the action's PATH --
  ## an action's PATH holds only the tools its edge NAMED, and findutils
  ## is not the coreutils that ``install`` brings -- so the head of the
  ## pipeline printed ``command not found`` to stderr and nothing to
  ## stdout, ``wc -c`` counted zero bytes, and ``set -e`` did not fire,
  ## because the failure was inside a pipeline inside a command
  ## substitution. The number pacman would then have been given is one
  ## it acts on: it is what ``pacman -Si`` reports and what pacman
  ## checks free space against before unpacking.
  ##
  ## So the script asserts its own tool, asserts that it found any files
  ## at all, and refuses a zero. A packaging step that cannot measure
  ## must stop the build rather than publish a plausible number.
  result = "set -eu\n"
  result.add("# Generated by the reprobuild DSL packaging layer\n")
  result.add("mkdir -p -- \"$(dirname -- " & shellSingleQuote(outPath) &
    ")\"\n")
  result.add("if ! command -v find > /dev/null 2>&1; then\n")
  result.add("  printf '%s\\n' 'packaging: find is not on this action" &
    " PATH; the installed size cannot be measured' >&2\n")
  result.add("  exit 1\n")
  result.add("fi\n")
  result.add("files=$(find " & shellSingleQuote(treeRoot) &
    " -type f | wc -l)\n")
  result.add("if [ \"$(( files + 0 ))\" -eq 0 ]; then\n")
  result.add("  printf 'packaging: no regular files under %s; refusing" &
    " to report an installed size of 0\\n' " &
    shellSingleQuote(treeRoot) & " >&2\n")
  result.add("  exit 1\n")
  result.add("fi\n")
  result.add("bytes=$(find " & shellSingleQuote(treeRoot) &
    " -type f -exec cat -- {} + | wc -c)\n")
  # ``$(( ))`` both normalises ``wc``'s leading whitespace and forces
  # the value to be a number: a non-numeric one makes the shell exit
  # here rather than reaching the write.
  result.add("bytes=$(( bytes + 0 ))\n")
  result.add("if [ \"$bytes\" -le 0 ]; then\n")
  result.add("  printf 'packaging: measured %s bytes across %s files;" &
    " refusing to publish it\\n' \"$bytes\" \"$files\" >&2\n")
  result.add("  exit 1\n")
  result.add("fi\n")
  result.add("printf '%s\\n' \"$bytes\" > " &
    shellSingleQuote(outPath) & "\n")

proc archTopLevelMembers*(tree: StagedTree): seq[string] =
  ## The distinct first path segment of every staged file, sorted.
  ##
  ## This is what gets handed to ``tar`` instead of ``.``. See TRAP 1 in
  ## the header: a ``.`` member makes GNU tar record ``./.PKGINFO``, and
  ## libalpm matches the literal ``.PKGINFO``.
  for f in tree.files:
    let cut = f.rootRelPath.find('/')
    let top = if cut > 0: f.rootRelPath[0 ..< cut] else: f.rootRelPath
    if top.len > 0 and top notin result:
      result.add(top)
  result.sort()

proc archPackage*(dist: Distribution; site = noSite()): PackagedArtifact =
  ## Produce a ``.pkg.tar.gz`` from the one ``Distribution`` definition.
  ##
  ## Stages its OWN tree, under the variant name ``arch``, and that is
  ## not a stylistic choice. ``stageInstallTree``'s only format-shaped
  ## decision is whether the tree is rooted at ``/`` or at the prefix
  ## (``variant in ["tar", "msi"]``), so ``arch`` and ``deb`` produce
  ## structurally identical trees and reusing deb's looked free.
  ## It is not: the variant is also the ACTION-ID NAMESPACE, so a
  ## recipe that produced both formats from one distribution registered
  ## two edges with the id ``pkg-deb-<name>-rpath-bin-<binary>`` and the
  ## build stopped with ``duplicate graph node id``. Two producers over
  ## one ``Distribution`` are two trees with two sets of edges, and the
  ## engine keys the ACTION CACHE by id — sharing them would serve one
  ## tree's outputs for the other.
  var tree = stageInstallTree(dist, "arch", site)

  # systemd units, UNDER ``usr/lib`` rather than ``lib``.
  #
  # Arch is a systemd distribution and systemd reads both paths -- they
  # are the same directory, since ``/lib`` is a symlink to ``usr/lib``.
  # pacman does not: the symlink is owned by the ``filesystem`` package,
  # and an archive containing a ``lib/`` DIRECTORY stops the
  # transaction with ``/lib exists in filesystem (owned by
  # filesystem)``. Measured, on archlinux:latest, with this producer's
  # first package.
  #
  # Deb and rpm keep the ``lib/`` spelling they have always shipped.
  # Which of two identical paths a package may NAME is a fact about the
  # package manager, not about systemd, so the producer that knows its
  # package manager is the one that says.
  for svc in dist.services:
    tree.addGeneratedFile(systemdUnitPath(dist, svc, underUsr = true),
      systemdUnitText(dist, svc), 0o644, site)

  # ---- the measured size ------------------------------------------
  #
  # AFTER the units and BEFORE ``.PKGINFO``, and both halves of that
  # matter. After, because the units are payload and pacman's number
  # must count them. Before, because ``.PKGINFO`` is metadata: makepkg
  # does not count it either, and a size that included the file the size
  # is written into could not be computed at all.
  let sizePath = tree.genRoot & "/" & tree.idPrefix & "installed-size.txt"
  let sizeEdge = sh_module.shell(installedSizeScript(tree.root, sizePath),
    actionId = tree.idPrefix & "installed-size",
    after = tree.terminal,
    # The payload is a real input: a binary that grew must change this
    # number, and without this the edge would have no reason to re-run.
    # The vendored closure has no per-file staged paths (it is a write
    # root), which is why ``after`` carries the whole terminal set as
    # well.
    extraInputs = tree.stagedPaths(),
    extraOutputs = @[sizePath])
  declareProducerTool(site, sizeEdge.id, ArchShSelector)
  # ``cat``/``wc``/``mkdir``/``dirname`` -- coreutils, reached through
  # the ``install`` executable's package, the same indirection the
  # closure walk uses.
  declareProducerTool(site, sizeEdge.id, InstallSelector)
  # ``find`` is FINDUTILS and is not in that set. Omitting it is what
  # made the first Arch package report ``size = 0``.
  declareProducerTool(site, sizeEdge.id, ArchFindSelector)
  tree.terminal.add(sizeEdge)

  let withFloor = tree.glibcFloorPath.len > 0
  var substitutions = @[(InstalledSizeToken, sizePath)]
  if withFloor:
    substitutions.add((GlibcFloorToken, tree.glibcFloorPath))
  tree.addGeneratedFile(".PKGINFO", archPkgInfoText(dist, withFloor),
    0o644, site, substitutions = substitutions)

  # ---- the archive -------------------------------------------------
  let outPath = dist.outputDir & "/" & archArtifactName(dist)
  var members = @[".PKGINFO"]
  for top in archTopLevelMembers(tree):
    if top != ".PKGINFO":
      members.add(top)
  let edge = tarTool(
    create = true,
    gzip = true,
    file = outPath,
    directory = tree.root,
    # NOT ``--sort=name`` over a ``.`` member: the member list is
    # explicit and ordered, with ``.PKGINFO`` first. Sorting still
    # applies WITHIN each named directory, which is what makes the
    # archive byte-identical across builds; it does not reorder the
    # top-level operands.
    sortByName = true,
    mtime = "@" & $dist.sourceDateEpoch,
    owner = "0",
    group = "0",
    numericOwner = true,
    members = members,
    actionId = "pkg-arch-" & dist.name,
    after = tree.terminal,
    extraInputs = tree.stagedPaths())
  declareProducerTool(site, edge.id, ArchTarSelector)
  declareProducerTool(site, edge.id, ArchGzipSelector)
  PackagedArtifact(
    format: "pkg.tar.gz",
    path: outPath,
    edge: edge,
    toolSelectors: @[ArchTarSelector, ArchGzipSelector, ArchShSelector,
                     ArchFindSelector] & tree.stagingSelectors,
    tree: tree)

proc archProducer(dist: Distribution;
                  site: ToolDependencySite): PackagedArtifact {.nimcall.} =
  archPackage(dist, site)

registerProducer("pkg.tar.gz",
  "Arch Linux package (tools: tar, gzip)",
  archProducer)
