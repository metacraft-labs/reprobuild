## The ``.rpm`` producer.
##
## §6's table: ``dist.rpm  # dep: rpmbuild -> <name>-<ver>-<rel>.<arch>.rpm``.
##
## M0 shipped ``packages/rpmbuild.nim`` and left the producer for M1,
## and its note to whoever wrote it turned out to be the single most
## load-bearing sentence in that file: *"rpm resolves those macros
## against the process CWD in ways that make RELATIVE paths unreliable,
## which is the first thing to get right."* Measured here rather than
## taken on trust — with ``--buildroot buildroot`` and ``--define
## '_topdir top'`` rpm 4.20 does not resolve against the CWD at all, it
## prepends a slash, and the build fails with ``File not found:
## /buildroot/usr/bin/hello`` for a tree that is plainly there. See
## ``AbsolutePathMacro`` for the fix and why it is the only one
## available to a content-addressed graph.
##
## Like the deb and tarball producers, this file contains no part of the
## §5 contract: by the time it runs, ``stageInstallTree`` has patched
## the RPATHs, rewritten the interpreters, vendored the runtime closure,
## written the wrappers and set the modes. What is here is the part that
## is genuinely RPM — the spec-file grammar, the macro overrides that
## stop rpm from post-processing a payload it did not build, the
## scriptlet argument convention, and the architecture spelling.
##
## ## What rpm does to a payload if you let it, and why each override
##
## rpm's default ``%__os_install_post`` runs a dozen ``brp-*`` scripts
## over the buildroot: it STRIPS every ELF file, rewrites shebangs,
## compresses man pages, and generates build-id symlinks. Every one of
## those is wrong here. Stripping in particular would rewrite the exact
## binaries the closure walk had just finished patching — after their
## content hash was taken — so the ``.rpm`` would ship a payload no
## other format's package contains, and the "one Distribution, N
## artifacts, same tree" property would be quietly false. Disabling the
## post-processing is not a shortcut; it is the only way a producer that
## consumes an ALREADY-STAGED tree can be correct.
##
## The same argument applies to ``%__spec_install_pre``, whose default
## begins ``rm -rf "$RPM_BUILD_ROOT"``. rpm assumes it built the
## buildroot itself, in ``%install``; here the buildroot IS the staged
## tree, produced by other edges, and rpm deleting it would be one edge
## eating another's outputs — the failure ``stageInstallTree``'s
## no-in-place-rewrites rule exists to make structurally impossible.
##
## And ``AutoReqProv: no``: rpm's automatic dependency generator would
## scan the payload and emit ``Requires: libblake3.so.0()(64bit)`` for
## every VENDORED library. Those are shipped inside this package, so the
## requirement is either self-satisfied noise or, on a target whose rpm
## resolves per-file provides differently, an unsatisfiable dependency
## on a library nobody publishes. The package's real external
## requirement is exactly one thing — the C library, at the floor the
## interpreter rewrite binds it to — and stating that ONE dependency
## explicitly is what makes the floor load-bearing rather than
## decorative.

import std/[strutils]

import repro_project_dsl

import ../types
import ../runtime_contract
import ../services
import ../producer
import ../../packages/rpmbuild as rpmbuild_module
# Imported for their REGISTRATION side effect only: rpmbuild's own
# scriptlets exec these off PATH, so there is no typed wrapper to
# reference. Same pattern (and the same failure when it is missing) as
# ``producers/tarball.nim``'s ``gzip`` import.
{.push warning[UnusedImport]: off.}
import ../../packages/host_system_tools
{.pop.}

{.experimental: "callOperator".}

const rpmbuildTool = rpmbuild_module.rpmbuild

const RpmbuildSelector* = "rpmbuild"

const RpmScriptletSelectors* = ["install-file", "find", "diff", "sed"]
  ## The tools rpmbuild EXECS, which are invisible in this producer's
  ## argv and are therefore the one dependency set that cannot be read
  ## off the call it builds.
  ##
  ## rpm runs three shell scriptlets of its own around the packaging
  ## step: ``%mkbuilddir``, ``lib/rpm/check-files`` (the unpackaged-file
  ## check) and the build-directory teardown. Between them they need
  ## ``mktemp``, ``rm``, ``sort`` (coreutils, reached through the
  ## package that provides ``install``), ``find`` (findutils), ``diff``
  ## (diffutils) and ``sed`` (gnused) -- all three already reprobuild
  ## packages in ``packages/host_system_tools.nim``. An action's PATH holds only the
  ## tools its edge named, so without these the first real Linux rpm
  ## build fails with five ``command not found`` lines and a ``Bad exit
  ## status`` that names a temp file rather than the missing tool --
  ## which is exactly how it did fail.
  ##
  ## Switching ``%__check_files`` off would have removed four of them
  ## and was rejected: that check is what catches a file staged into the
  ## buildroot that ``%files`` does not list, i.e. the one class of
  ## mistake this producer's ``%files`` derivation could actually make.
  ##
  ## What rpm assumes and this cannot supply is ``/bin/sh``: every
  ## scriptlet is run as ``/bin/sh -e <tmpfile>`` by absolute path. That
  ## is rpm's assumption about its host, not this producer's, and no
  ## tool declaration can change it.

const AbsolutePathMacro* = "%(pwd)"
  ## How a relative build-tree path becomes the absolute one rpm
  ## insists on, WITHOUT putting a host path in the graph.
  ##
  ## rpm expands ``%(command)`` by running the command through a shell
  ## and substituting its output, at the moment the macro is used. So
  ## ``%(pwd)/build/dist/foo`` is a graph-time constant that becomes an
  ## absolute path at ACTION time, in the action's own working
  ## directory. The two alternatives are both worse: baking
  ## ``getCurrentDir()`` in at graph time would make the lowered graph —
  ## and therefore every cache key derived from it — a function of where
  ## the checkout happens to live, which is precisely what
  ## content-addressing must not be; and driving rpmbuild through a
  ## ``sh -c`` wrapper that computed ``$PWD`` would replace a typed tool
  ## call with an opaque one for the sake of a string.
  ##
  ## It does assume rpm can reach a shell, which rpm assumes about
  ## itself anyway — every scriptlet it runs is ``/bin/sh -e``.

proc rpmArtifactName*(dist: Distribution): string =
  ## RPM's own convention: ``<name>-<version>-<release>.<arch>.rpm``,
  ## dot-separated before the architecture where deb uses underscores,
  ## and with rpm's architecture spelling. Deliberately not
  ## ``artifactFileName``: dnf, createrepo and every repository tool
  ## parse this name.
  dist.name & "-" & dist.version & "-" &
    (if dist.release.len > 0: dist.release else: "1") & "." &
    dist.rpmArchitecture & ".rpm"

proc rpmDescriptionText(dist: Distribution): string =
  ## ``%description`` is free text terminated by the next section, so
  ## unlike deb's ``Description`` it needs no continuation-line
  ## discipline — but it must not be EMPTY, which rpmbuild rejects.
  let body =
    if dist.metadata.description.len > 0: dist.metadata.description
    elif dist.metadata.summary.len > 0: dist.metadata.summary
    else: dist.name
  for line in body.splitLines():
    result.add(line.strip(leading = false) & "\n")

proc rpmRequiresFields*(dist: Distribution; withGlibcFloor: bool): seq[string] =
  ## The ``Requires:`` list, with the C-library floor first when the
  ## tree computes one. ``glibc`` is rpm's name for what Debian calls
  ## ``libc6``; the floor arrives as a bare ``2.38`` and each producer
  ## says it in its own vocabulary.
  if withGlibcFloor:
    result.add("glibc >= " & GlibcFloorToken)
  for req in dist.metadata.rpmRequires:
    result.add(req)

proc rpmFilesSection*(dist: Distribution; tree: StagedTree): seq[string] =
  ## The ``%files`` entries, absolute-rooted.
  ##
  ## Every staged file is listed by name because every staged file is a
  ## build-edge output whose path is known when the graph is built. The
  ## VENDORED closure is not: it is discovered inside the closure action,
  ## so there is no graph-time list of it — the private libdir is named
  ## as a DIRECTORY instead, exactly as a shipped source tree is.
  ##
  ## ## Why a directory and not ``%dir`` plus ``<dir>/*``
  ##
  ## It used to be that pair, and the glob is what took every Linux
  ## channel of the first out-of-tree consumer down. rpm expands a
  ## ``%files`` glob against the buildroot at package time and a glob
  ## that matches NOTHING is a hard error — ``File not found by glob``
  ## — so a distribution whose ELF closure is legitimately empty (every
  ## component imports only ``libc``/``libm``-class system libraries,
  ## which the walk must never vendor) failed ``rpmbuild`` on a tree
  ## that was in every respect correct. deb, arch and tarball build in
  ## the same graph as rpm, so their already-written artifacts went down
  ## with it.
  ##
  ## The emptiness is not knowable here. This proc runs while the GRAPH
  ## is being built; the manifest it would have to consult is written by
  ## the closure action, which has not run and on a clean tree cannot
  ## have run — the binaries it reads ``DT_NEEDED`` from do not exist
  ## yet. So the choice is between deferring the decision to something
  ## that runs at package time and generating the ``%files`` fragment in
  ## a build-time edge of its own.
  ##
  ## Naming the directory defers it to rpm, which already does exactly
  ## this for the source trees below: a ``%files`` entry that names a
  ## directory owns that directory AND everything under it recursively,
  ## evaluated when rpm reads the buildroot. Populated, it lists the
  ## directory plus every vendored library — byte-for-byte the listing
  ## the ``%dir`` + glob pair produced. Empty, it lists the directory
  ## alone. One entry, no build-time conditional, and the case that
  ## failed is not a case any more rather than a case that is handled.
  ##
  ## ## Why the directory is still named when the closure is empty
  ##
  ## Because the package CREATES it: the walk's script opens with
  ## ``mkdir -p -- "$LIBDIR"`` and the RPATH patched into every staged
  ## binary points at it. Dropping the entry would leave a directory in
  ## the buildroot that ``%files`` does not name, which is rpm's
  ## unpackaged-file class of error, and — if it slipped past that — a
  ## directory no package owns, which ``rpm -e`` leaves standing. An rpm
  ## that declares a directory it does not create is its own defect and
  ## ``rpm -V`` reports it as ``missing``; the answer to both is to name
  ## the directory exactly when the graph contains the edge that makes
  ## it, which is what ``StagedTree.privateLibDirRootRel`` records.
  ##
  ## A staged ``crRuntimeLibrary`` component lands in that same
  ## directory and would then be listed twice, which rpmbuild rejects
  ## outright; those are filtered rather than deduplicated at the end,
  ## so the reason is visible at the point it applies.
  let privateLibRoot =
    if tree.privateLibDirRootRel.len > 0:
      "/" & tree.privateLibDirRootRel
    else:
      ""
  proc insideSourceTree(rootRel: string): bool =
    ## Whether a staged path is INSIDE one of the shipped source trees.
    ##
    ## Those are listed by their root instead, once each: naming a
    ## directory in ``%files`` owns it and everything below it, so the
    ## ~1,000 files of a mirrored ``libs/`` tree collapse to one line —
    ## and listing both the directory and its contents is a duplicate
    ## that rpmbuild rejects outright, the same way a staged
    ## ``crRuntimeLibrary`` inside the private libdir does above.
    for treeRoot in tree.sourceTreeRoots:
      if rootRel == treeRoot or rootRel.startsWith(treeRoot & "/"):
        return true
    false

  for f in tree.files:
    let abs = "/" & f.rootRelPath
    if privateLibRoot.len > 0 and abs.startsWith(privateLibRoot & "/"):
      continue
    if insideSourceTree(f.rootRelPath):
      continue
    if f.role == crConfigFile:
      # ``%config(noreplace)`` is rpm's answer to dpkg's ``conffiles``:
      # an admin-edited file is kept and the packaged one lands beside
      # it as ``.rpmnew``. Without it an upgrade silently overwrites
      # local configuration, which is the same defect the deb producer's
      # ``conffiles`` list exists to avoid.
      result.add("%config(noreplace) " & abs)
    else:
      result.add(abs)
  if privateLibRoot.len > 0:
    result.add(privateLibRoot)
  for treeRoot in tree.sourceTreeRoots:
    result.add("/" & treeRoot)
  # EVERY directory the package creates and the target does not already
  # own, not just the private libdir.
  #
  # dpkg tracks the directories it made and removes each one when it
  # empties, so a .deb needs no such list. rpm removes only what
  # ``%files`` NAMES: the first ``rpm -e`` of the reprobuild package left
  # ``/usr/libexec/reprobuild`` standing while the identical ``dpkg -r``
  # took it away. The set of system directories is CLOSED and named
  # (``types.SystemDirectories``) for the same reason the never-vendor
  # library set is: a rule that consulted the builder's filesystem would
  # make a package's contents a function of the builder, and the question
  # is about the TARGET anyway.
  var staged: seq[string] = @[]
  for f in tree.files:
    if insideSourceTree(f.rootRelPath):
      continue
    staged.add(f.rootRelPath)
  for treeRoot in tree.sourceTreeRoots:
    # The tree ROOT is owned by the ``%files`` entry above; what this
    # adds is its ANCESTORS (``usr/share/repro/src`` and friends),
    # which nothing else in the package creates.
    staged.add(treeRoot & "/.")
  if privateLibRoot.len > 0:
    # The vendored files are not staged paths -- the walk writes them --
    # so name the directory itself for the ancestor derivation. What
    # comes back is the libdir AND its non-system ancestors; the libdir
    # itself is dropped below because the recursive entry above already
    # owns it. How badly a duplicate hurts is DISTRIBUTION-DEPENDENT, so
    # do not relax this on the strength of one host: measured, rpm 6.0.2
    # dedups silently, rpm 4.20.1 emits ``warning: File listed twice``
    # and still builds -- but both turn it into ``error: File listed
    # twice`` with no package produced once
    # ``%_duplicate_files_terminate_build`` is 1, which is a macro a
    # distribution sets, not a property of the spec. Emitting one
    # spelling per path is the only formulation that is correct on all
    # of them.
    staged.add(privateLibRoot[1 .. ^1] & "/.")
  for dir in ownedDirectories(staged):
    if privateLibRoot.len > 0 and "/" & dir == privateLibRoot:
      continue
    result.add("%dir /" & dir)

proc rpmSpecText*(dist: Distribution; tree: StagedTree;
                  withGlibcFloor = false): string =
  ## The whole ``.spec``. Written as one function because a spec is one
  ## file with a fixed section order, and splitting it would only make
  ## the order easier to get wrong.
  result = ""
  result.add("# Generated by the reprobuild DSL packaging layer\n")
  result.add("# (Distribution-And-Packaging.md " & "SECT" & "6). Do not edit.\n")
  # --- the macro overrides; see this module's header for each ---------
  result.add("%global __os_install_post %{nil}\n")
  result.add("%global __spec_install_pre %{___build_pre}\n")
  result.add("%global _build_id_links none\n")
  result.add("%global _missing_build_ids_terminate_build 0\n")
  # rpm's own debuginfo split would carve the payload in half and put
  # the halves in packages this producer does not emit.
  result.add("%global debug_package %{nil}\n")
  result.add("\n")
  result.add("Name:           " & dist.name & "\n")
  result.add("Version:        " & dist.version & "\n")
  result.add("Release:        " &
    (if dist.release.len > 0: dist.release else: "1") & "\n")
  result.add("Summary:        " &
    (if dist.metadata.summary.len > 0: dist.metadata.summary.splitLines()[0]
     else: dist.name) & "\n")
  result.add("License:        " &
    (if dist.metadata.license.len > 0: dist.metadata.license
     else: "Unspecified") & "\n")
  if dist.metadata.homepage.len > 0:
    result.add("URL:            " & dist.metadata.homepage & "\n")
  if dist.metadata.vendor.len > 0:
    result.add("Vendor:         " & dist.metadata.vendor & "\n")
  if dist.metadata.section.len > 0:
    result.add("Group:          " & dist.metadata.section & "\n")
  result.add("BuildArch:      " & dist.rpmArchitecture & "\n")
  result.add("AutoReqProv:    no\n")
  for req in rpmRequiresFields(dist, withGlibcFloor):
    result.add("Requires:       " & req & "\n")
  result.add("\n%description\n")
  result.add(rpmDescriptionText(dist))
  # NO %prep / %build / %install. The buildroot arrives already staged;
  # see the header on ``%__spec_install_pre``.
  if dist.services.len > 0:
    result.add("\n%post\n")
    result.add(rpmPostText(dist))
    result.add("\n%preun\n")
    result.add(rpmPreUnText(dist))
    result.add("\n%postun\n")
    result.add(rpmPostUnText(dist))
  result.add("\n%files\n")
  result.add("%defattr(-,root,root,-)\n")
  for entry in rpmFilesSection(dist, tree):
    result.add(entry & "\n")
  # An empty %changelog is a section rpmbuild wants to see; without it
  # rpmlint complains and some rpm versions warn. Deliberately EMPTY
  # rather than synthesised: a generated changelog entry would carry a
  # date, and a date is the one thing a reproducible package must not
  # invent.
  result.add("\n%changelog\n")

proc rpmPackage*(dist: Distribution; site = noSite()): PackagedArtifact =
  ## Produce a ``.rpm`` from the one ``Distribution`` definition.
  var tree = stageInstallTree(dist, "rpm", site)

  # The systemd units, ROOT-relative for the same reason as in the deb
  # producer: systemd looks in fixed absolute locations, so this tree
  # is rooted at ``/`` and the tarball's is not.
  for svc in dist.services:
    tree.addGeneratedFile(systemdUnitPath(dist, svc),
      systemdUnitText(dist, svc), 0o644, site)

  let withFloor = tree.glibcFloorPath.len > 0
  # The spec goes BESIDE the tree, never inside it: anything inside the
  # buildroot that ``%files`` does not list is an unpackaged-file error,
  # and anything it does list would ship a .spec to the target.
  let spec = tree.addGeneratedIntermediate("rpm-spec.spec",
    rpmSpecText(dist, tree, withFloor), site,
    substitutions =
      (if withFloor: @[(GlibcFloorToken, tree.glibcFloorPath)]
       else: @[]))

  let topDir = AbsolutePathMacro & "/" & dist.stagingRoot & "/rpmtop"
  let buildRoot = AbsolutePathMacro & "/" & tree.root
  let outPath = dist.outputDir & "/" & rpmArtifactName(dist)
  let edge = rpmbuildTool(
    binaryOnly = true,
    defines = @[
      # Every _topdir-derived path, named individually. rpm derives
      # them from ``_topdir`` by default, but only some of them, and a
      # default that leaked would write into ``$HOME/rpmbuild`` — both
      # non-hermetic and outside the edge's declared output scope.
      "_topdir " & topDir,
      "_builddir " & topDir & "/BUILD",
      "_buildrootdir " & topDir & "/BUILDROOT",
      "_sourcedir " & topDir & "/SOURCES",
      "_specdir " & topDir & "/SPECS",
      "_srcrpmdir " & topDir & "/SRPMS",
      # rpm writes each scriptlet to ``%_tmppath`` before running it;
      # left at its default that is ``/var/tmp``, i.e. a write outside
      # anything this edge declared.
      "_tmppath " & topDir & "/tmp",
      # The finished package lands where the caller asked, under its
      # own name, rather than in rpm's ``<rpmdir>/<arch>/`` layout.
      # ``_rpmfilename`` is relative to ``_rpmdir``.
      "_rpmdir " & AbsolutePathMacro & "/" & dist.outputDir,
      "_rpmfilename " & rpmArtifactName(dist),
      # gzip rather than rpm's modern zstd default, for the same reason
      # the deb producer picks gzip: a zstd-compressed payload cannot be
      # read by the rpm in RHEL 8 or SLES 15, and a packaging layer's
      # default should be the one that installs everywhere.
      "_binary_payload w9.gzdio",
      # --- the four knobs that make the header reproducible ----------
      # Measured, not assumed: with only SOURCE_DATE_EPOCH set, two
      # otherwise identical builds still differ, because BUILDTIME is
      # wall-clock and BUILDHOST is gethostname(). With these four the
      # same tree gives the same bytes twice.
      "_buildhost reprobuild",
      "source_date_epoch_from_changelog 0",
      "use_source_date_epoch_as_buildtime 1",
      "build_mtime_policy clamp_to_source_date_epoch"
    ],
    specFile = spec.path,
    buildRoot = buildRoot,
    actionId = "pkg-rpm-" & dist.name,
    after = tree.terminal,
    # rpm reads SOURCE_DATE_EPOCH from the ENVIRONMENT, exactly as
    # dpkg-deb does, and has no argv equivalent. Declared here so the
    # value is graph data rather than shell state -- see
    # ``types.Distribution.sourceDateEpoch`` for why that distinction is
    # the difference between "reproducible" and "reproducible inside one
    # particular shell".
    extraEnv = @[("SOURCE_DATE_EPOCH", $dist.sourceDateEpoch)],
    # Naming every staged file as an input is what makes this edge
    # content-addressed over the tree's CONTENTS rather than over its
    # directory name. ``stagedPaths`` includes the closure manifest and
    # the generated spec.
    extraInputs = tree.stagedPaths(),
    extraOutputs = @[outPath])
  declareProducerTool(site, edge.id, RpmbuildSelector)
  # Declared on the SAME edge, because it is rpmbuild that execs them.
  var selectors = @[RpmbuildSelector]
  for selector in RpmScriptletSelectors:
    declareProducerTool(site, edge.id, selector)
    if selector notin selectors: selectors.add(selector)
  PackagedArtifact(
    format: "rpm",
    path: outPath,
    edge: edge,
    toolSelectors: selectors & tree.stagingSelectors,
    tree: tree)

proc rpmProducer(dist: Distribution;
                 site: ToolDependencySite): PackagedArtifact {.nimcall.} =
  rpmPackage(dist, site)

registerProducer("rpm",
  "RPM binary package (tool: rpmbuild)",
  rpmProducer)
