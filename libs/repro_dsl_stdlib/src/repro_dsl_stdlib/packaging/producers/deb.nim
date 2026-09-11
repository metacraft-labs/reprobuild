## The ``.deb`` producer.
##
## §6's table: ``dist.deb  # dep: dpkg -> <name>_<ver>_<arch>.deb
## (control, postinst: service enable)``.
##
## Like the tarball producer, this file contains no part of the §5
## contract: by the time it runs, ``stageInstallTree`` has patched the
## RPATHs, written the wrappers and set the modes. What is here is the
## part that is genuinely Debian — the ``control`` stanza's field
## grammar, the ``conffiles`` list, the maintainer scripts, and the
## architecture spelling.

import std/[strutils]

import repro_project_dsl

import ../types
import ../runtime_contract
import ../services
import ../producer
import ../../packages/dpkg_deb as dpkg_deb_module

{.experimental: "callOperator".}

const dpkgDebTool = dpkg_deb_module.dpkg_deb

const DpkgDebSelector* = "dpkg-deb"

proc debArtifactName*(dist: Distribution): string =
  ## Debian's own convention: ``<name>_<version>_<arch>.deb``,
  ## underscore-separated, with Debian's architecture spelling.
  ## Deliberately not ``artifactFileName`` — apt, dpkg and every
  ## repository tool parse this name, so "close enough" is wrong.
  dist.name & "_" & dist.fullVersion & "_" & dist.debArchitecture & ".deb"

proc debDescriptionField(dist: Distribution): string =
  ## deb's ``Description`` is a single field whose first line is the
  ## synopsis and whose continuation lines are indented by one space,
  ## with a lone ``.`` standing in for a blank line. Getting this wrong
  ## does not fail the build — it produces a package whose description
  ## renders as garbage in ``apt show``.
  let summary =
    if dist.metadata.summary.len > 0: dist.metadata.summary
    else: dist.name
  result = "Description: " & summary.splitLines()[0] & "\n"
  for line in dist.metadata.description.splitLines():
    let trimmed = line.strip(leading = false)
    if trimmed.len == 0: result.add(" .\n")
    else: result.add(" " & trimmed & "\n")

proc debDependsFields*(dist: Distribution; withGlibcFloor: bool): seq[string] =
  ## The ``Depends:`` list, with the C-library floor first when the tree
  ## computes one.
  ##
  ## ``libc6`` is Debian's name for the glibc runtime on every
  ## architecture this producer can spell (``debArchitecture``), and
  ## ``>=`` on a version is Debian's relation grammar. Neither belongs
  ## in the walk that computed the number — rpm says ``glibc >= X`` for
  ## the same fact — which is why the floor arrives as a bare ``2.38``
  ## and each producer says it in its own vocabulary.
  ##
  ## FIRST in the list rather than appended, because ``Depends:`` is
  ## read by humans as often as by dpkg and the C library is the
  ## dependency that decides whether the package can run at all.
  if withGlibcFloor:
    result.add("libc6 (>= " & GlibcFloorToken & ")")
  for dep in dist.metadata.debDepends:
    result.add(dep)

proc debControlText*(dist: Distribution; withGlibcFloor = false): string =
  ## The ``DEBIAN/control`` stanza.
  ##
  ## When ``withGlibcFloor`` the ``Depends:`` line carries
  ## ``types.GlibcFloorToken`` where the version goes; the staging step
  ## replaces it with the value the closure edge measured. The token
  ## never survives into the package — a build in which it did would
  ## mean the substitution edge had not run, and dpkg-deb refuses a
  ## ``Depends`` version it cannot parse, so the failure is loud.
  result = "Package: " & dist.name & "\n"
  result.add("Version: " & dist.fullVersion & "\n")
  result.add("Architecture: " & dist.debArchitecture & "\n")
  result.add("Maintainer: " &
    (if dist.metadata.maintainer.len > 0: dist.metadata.maintainer
     else: "unknown <unknown@invalid>") & "\n")
  result.add("Section: " &
    (if dist.metadata.section.len > 0: dist.metadata.section
     else: "utils") & "\n")
  result.add("Priority: " &
    (if dist.metadata.priority.len > 0: dist.metadata.priority
     else: "optional") & "\n")
  let depends = debDependsFields(dist, withGlibcFloor)
  if depends.len > 0:
    result.add("Depends: " & depends.join(", ") & "\n")
  if dist.metadata.homepage.len > 0:
    result.add("Homepage: " & dist.metadata.homepage & "\n")
  for (name, value) in dist.metadata.debControlExtraFields:
    if name.len > 0:
      result.add(name & ": " & value & "\n")
  # ``Description`` is last because a malformed continuation line would
  # otherwise swallow every field after it.
  result.add(debDescriptionField(dist))

proc debConffilesText*(dist: Distribution): string =
  ## Absolute paths of the files dpkg must treat as configuration —
  ## i.e. must not overwrite on upgrade when the admin has edited them.
  for c in dist.components:
    if c.role != crConfigFile:
      continue
    # NOT prefix-joined. POSIX config lives at ``/etc`` whatever the
    # prefix is (``types.escapesPrefix``), and dpkg matches a conffile
    # by the exact absolute path it unpacked. A ``/usr/etc`` entry
    # against an ``/etc`` payload would parse fine and silently disable
    # the conffile protection the entry exists to request.
    result.add("/" & installRelPath(dist, c) & "\n")

proc debPackage*(dist: Distribution; site = noSite()): PackagedArtifact =
  ## Produce a ``.deb`` from the one ``Distribution`` definition.
  var tree = stageInstallTree(dist, "deb", site)

  # The systemd units, if any. These are ROOT-relative rather than
  # prefix-relative — systemd looks in fixed absolute locations — which
  # is exactly why the deb tree is rooted at ``/`` and the tarball's is
  # not, and why the two producers cannot share one staged tree.
  for svc in dist.services:
    tree.addGeneratedFile(systemdUnitPath(dist, svc),
      systemdUnitText(dist, svc), 0o644, site)

  # The control stanza is the one generated file whose text is not fully
  # knowable at graph time: the C-library floor is read out of
  # ``.gnu.version_r`` of files the closure edge has only just produced.
  # ``substitutions`` is how the value gets in without a second edge
  # rewriting a file this one wrote.
  let withFloor = tree.glibcFloorPath.len > 0
  tree.addGeneratedFile("DEBIAN/control", debControlText(dist, withFloor),
    0o644, site,
    substitutions =
      (if withFloor: @[(GlibcFloorToken, tree.glibcFloorPath)]
       else: @[]))
  let conffiles = debConffilesText(dist)
  if conffiles.len > 0:
    tree.addGeneratedFile("DEBIAN/conffiles", conffiles, 0o644, site)
  # Maintainer scripts are emitted unconditionally, even for a
  # distribution with no services. They are cheap, they make the
  # produced package's shape independent of whether services happen to
  # be declared, and — the reason that matters — the 0755 requirement on
  # them is the single most common way a hand-rolled .deb is rejected at
  # install time. Emitting them always means the mode path is exercised
  # by every build rather than only by the ones that ship a daemon.
  tree.addGeneratedFile("DEBIAN/postinst", debPostInstText(dist), 0o755, site)
  tree.addGeneratedFile("DEBIAN/prerm", debPreRmText(dist), 0o755, site)

  let outPath = dist.outputDir & "/" & debArtifactName(dist)
  let edge = dpkgDebTool(
    rootOwnerGroup = true,
    # gzip rather than dpkg's modern default of zstd: a .deb whose
    # payload is zstd-compressed cannot be installed by the dpkg in
    # Debian 11 or Ubuntu 20.04, and a packaging layer's default should
    # be the one that installs everywhere rather than the one that
    # compresses best. A distribution that wants zstd changes one
    # argument.
    compression = "gzip",
    build = true,
    tree = tree.root,
    archive = outPath,
    actionId = "pkg-deb-" & dist.name,
    after = tree.terminal,
    # THE PRODUCER DECIDES THE TIMESTAMPS; NOTHING AMBIENT LEAKS IN.
    #
    # dpkg-deb takes its member mtimes and its ar header timestamps from
    # SOURCE_DATE_EPOCH in the ENVIRONMENT. It has no command-line
    # equivalent, so unlike ``tar --mtime`` this cannot be an argv flag
    # — but it can still be graph data, and that is the whole point:
    # ``extraEnv`` lands in ``BuildActionDef.env``, is keyed into the
    # action's fingerprint, and is layered OVER the inherited
    # environment when the action launches, so a caller's value is
    # overridden rather than consulted.
    #
    # Without it the archive was reproducible because of the SHELL
    # rather than because of the graph: inside ``nix develop`` the
    # variable is 315532800 and three passes of M0 produced identical
    # bytes; with it unset the same tree gives wall-clock mtimes and a
    # different .deb every run. That is the same failure in kind as
    # letting the builder's installed packages decide a package's
    # contents, and it defeats content-addressing, which is the layer's
    # core property.
    extraEnv = @[("SOURCE_DATE_EPOCH", $dist.sourceDateEpoch)],
    # Naming every staged file as an input is what makes this edge
    # content-addressed over the tree's CONTENTS. Without it the edge's
    # only input would be a directory name, and a changed binary inside
    # the tree would not invalidate the .deb.
    extraInputs = tree.stagedPaths())
  declareProducerTool(site, edge.id, DpkgDebSelector)
  PackagedArtifact(
    format: "deb",
    path: outPath,
    edge: edge,
    # The staging half of the list is READ OFF the tree rather than
    # transcribed. A staging step that grows a tool -- the runtime-
    # closure walk's ``sh`` did -- would otherwise have to be copied
    # into every producer, which is the per-producer hand-writing the
    # layer exists to prevent.
    toolSelectors: @[DpkgDebSelector] & tree.stagingSelectors,
    tree: tree)

proc debProducer(dist: Distribution;
                 site: ToolDependencySite): PackagedArtifact {.nimcall.} =
  debPackage(dist, site)

registerProducer("deb",
  "Debian binary package (tool: dpkg-deb)",
  debProducer)
