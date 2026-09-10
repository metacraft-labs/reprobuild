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

proc debControlText*(dist: Distribution): string =
  ## The ``DEBIAN/control`` stanza.
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
  if dist.metadata.debDepends.len > 0:
    result.add("Depends: " & dist.metadata.debDepends.join(", ") & "\n")
  if dist.metadata.homepage.len > 0:
    result.add("Homepage: " & dist.metadata.homepage & "\n")
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

  tree.addGeneratedFile("DEBIAN/control", debControlText(dist), 0o644, site)
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
