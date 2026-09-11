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
## ## TRAP 3: ``pacman -Qkk`` without a ``.MTREE`` EXITS 0
##
## M1's N15, and the reason this producer now has a second archiver
## dependency. A package with no ``.MTREE`` member is not rejected and
## does not warn: ``pacman -Qk`` answers ``N total files, 0 missing
## files`` and exits 0, and ``pacman -Qkk`` — the FULL check, the one a
## user runs when they want file properties verified — answers
## ``reprobuild: no mtree file`` AND ALSO EXITS 0. The package does not
## visibly lack file-property verification; it quietly forfeits it.
##
## So the member is generated, and generating it turned out to be the
## interesting part, because an mtree is a RECORD OF THE STAGED TREE
## and the staged tree's own file metadata is exactly what the rest of
## this producer refuses to let into the artifact:
##
## * **``time``** cannot be omitted. ``pacman -Qkk`` compares
##   ``st_mtime`` against the mtree's ``time`` UNCONDITIONALLY
##   (``check_file_time`` in pacman's ``src/pacman/check.c``), so an
##   mtree without the field reads as time 0 and every file reports
##   ``Modification time mismatch``. It also cannot be the staged
##   files' real mtimes, because ``tar --mtime=@<epoch>`` rewrites them
##   in the archive — the INSTALLED mtime is the epoch. So the mtree is
##   written with ``bsdtar --mtime '@<epoch>'``, the same one number.
## * **``uid``/``gid``** are forced to 0 with ``--uid 0 --gid 0``, for
##   the same reason: the archive is written ``--owner=0 --group=0
##   --numeric-owner``, so the installed files are root's and the
##   builder's own uid must not reach the record.
## * **member ORDER** is ours. libarchive's tar has no ``--sort=name``,
##   so letting it recurse would record readdir order and two builds of
##   one tree would emit different mtrees. The list is built with
##   ``find | sort`` and passed with ``-T``/``-n``.
## * **the gzip wrapper** is written by ``gzip -n`` rather than by
##   ``bsdtar -z``, because bsdtar's gzip writer stamps the WALL CLOCK
##   into the gzip header (measured: ``1f 8b 08 00 e9 54 a3 6a``) and
##   ``gzip -n`` writes a zero there.
##
## ``md5digest`` is deliberately not emitted — ``sha256digest`` is, and
## pacman checks whichever is present.
##
## ## What is NOT here, and is recorded rather than faked
##
## * ``.BUILDINFO`` — what ``devtools`` and Arch's reproducible-builds
##   tooling read. It records the exact package set of the build
##   CHROOT, which is a fact about an Arch build host; this package is
##   not built on one.
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
# libarchive's tar, for the ``.MTREE`` member and for nothing else. Never
# typed at a call site here -- see ``packages/bsdtar.nim`` for why the
# mtree step is a script rather than a typed CLI.
import ../../packages/bsdtar
# GNU grep, for the mtree post-conditions. A generated metadata member
# that is checked only for existence is the shape of check this
# milestone has already found three vacuous instances of.
import ../../packages/host_system_tools as arch_host_tools
# ``host_system_tools`` above is imported for its REGISTRATION side
# effect: the installed-size edge execs ``find``, which is findutils and
# not the coreutils that ``install`` brings, and an action's PATH holds
# only the tools its edge NAMED. See ``ArchFindSelector``.
{.pop.}

{.experimental: "callOperator".}

const tarTool = tar_module.tar

const
  ArchTarSelector* = "tar"
  ArchGzipSelector* = "gzip"
  ArchShSelector* = "sh"
  ArchFindSelector* = "find"
    ## findutils, for the installed-size measurement and for the
    ## ``.MTREE`` member list, and NOT part of the coreutils the
    ## ``install-file`` package brings.
    ##
    ## Declared because the first Arch package this producer built
    ## reported ``size = 0``. See ``installedSizeScript`` for how an
    ## absent tool became a plausible number rather than a failure.
  ArchBsdtarSelector* = "bsdtar"
    ## libarchive's tar, the only one that writes an mtree. A SECOND
    ## archiver dependency, taken deliberately: see TRAP 3 in the
    ## header for what the package forfeits without it.
  ArchGrepSelector* = "grep"
    ## For the ``.MTREE`` post-conditions. The member is metadata
    ## nothing downstream parses at build time, so "it exists" is the
    ## easiest check to write and the least informative one — the same
    ## shape as the three vacuous assertions this milestone has already
    ## found.

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

const
  ArchPkgInfoMember* = ".PKGINFO"
  ArchMtreeMember* = ".MTREE"
    ## The two metadata members. Named as constants because three
    ## separate steps have to agree about them: the size measurement
    ## must EXCLUDE them, the mtree must record ``.PKGINFO`` and not
    ## itself, and the archive must name them first and in this order.

proc metadataExclusions*(treeRoot: string): string =
  ## ``find`` predicates that skip the two metadata members.
  ##
  ## The installed size is a measurement of the PAYLOAD: makepkg does
  ## not count ``.PKGINFO`` or ``.MTREE`` either, and pacman reports the
  ## number as the space the package occupies once unpacked — neither
  ## metadata member is unpacked anywhere.
  ##
  ## Stated as an exclusion rather than relied on through ordering, and
  ## that is a correction rather than a precaution. The size edge is
  ## created BEFORE ``.PKGINFO`` is staged and is ordered before it by
  ## the substitution's own input edge, so on a clean build ``find``
  ## never saw it. On an INCREMENTAL rebuild into a tree that still held
  ## the previous run's metadata it would have, and the number would
  ## have drifted by the size of those files — six hundred bytes for
  ## ``.PKGINFO``, which the gate's tolerance hid, and rather more for
  ## a ``.MTREE`` over four thousand files, which it would not.
  " ! -path " & shellSingleQuote(treeRoot & "/" & ArchPkgInfoMember) &
    " ! -path " & shellSingleQuote(treeRoot & "/" & ArchMtreeMember)

proc mtreeScript*(treeRoot, listPath, rawPath: string;
                  sourceDateEpoch: int64): string =
  ## Write the ``.MTREE`` member: libarchive's mtree over a SORTED
  ## member list, with every ambient field overridden, gzipped by
  ## ``gzip -n``.
  ##
  ## See TRAP 3 in this module's header for why each override is there.
  ## What follows is why each POST-CONDITION is there, which is a
  ## different question: an mtree is metadata that nothing downstream
  ## parses at build time, so every way of getting it wrong produces a
  ## package that builds, installs and runs — and whose ``pacman -Qkk``
  ## then reports four thousand mismatches, or silently verifies
  ## nothing, on a user's machine.
  ##
  ## So the script asserts: that it found files to record at all; that
  ## what bsdtar wrote is an mtree (first line ``#mtree``); that it has
  ## at least as many entry lines as the list had members; and that
  ## EVERY entry carries the one epoch. The last is the one that
  ## matters, because ``--mtime`` silently doing nothing is exactly the
  ## failure that would put the builder's wall clock into a record
  ## ``pacman -Qkk`` compares against.
  let quotedRoot = shellSingleQuote(treeRoot)
  let quotedList = shellSingleQuote(listPath)
  let quotedRaw = shellSingleQuote(rawPath)
  let outPath = treeRoot & "/" & ArchMtreeMember
  result = "set -eu\n"
  result.add("# Generated by the reprobuild DSL packaging layer\n")
  # THE MEMBER LIST HAS TO BE NAMED ABSOLUTELY, and this is the first
  # real build's finding rather than a precaution. Every path in the
  # graph is relative to the build tree, and bsdtar reads the list from
  # INSIDE a ``cd`` into the staged tree -- so a relative ``-T`` operand
  # is resolved against the wrong directory and the step dies with
  # ``bsdtar: Couldn't open build/dist/.../mtree-members.txt: No such
  # file or directory``. The ``case`` keeps an absolute path absolute,
  # so this does not become a rule about where graph paths may point.
  result.add("__wd=$(pwd)\n")
  for tool in ["find", "sort", "bsdtar", "gzip", "grep"]:
    result.add("if ! command -v " & tool & " > /dev/null 2>&1; then\n")
    result.add("  printf '%s\\n' 'packaging: " & tool &
      " is not on this action PATH; the .MTREE member cannot be" &
      " written, and a package without one makes pacman -Qkk verify" &
      " nothing and exit 0' >&2\n")
    result.add("  exit 1\n")
    result.add("fi\n")
  result.add("mkdir -p -- \"$(dirname -- " & quotedList & ")\"\n")
  # ``! -path <root>/.MTREE``: on a rebuild into a tree that still holds
  # the previous run's member, an mtree that recorded ITSELF would carry
  # a stale digest and would differ between a clean and an incremental
  # build.
  result.add("(cd " & quotedRoot & " && find . -mindepth 1 ! -path " &
    shellSingleQuote("./" & ArchMtreeMember) &
    " -print) | LC_ALL=C sort > " & quotedList & "\n")
  result.add("__list=" & quotedList & "\n")
  result.add("case \"$__list\" in\n")
  result.add("  /*) __list_abs=\"$__list\" ;;\n")
  result.add("  *) __list_abs=\"$__wd/$__list\" ;;\n")
  result.add("esac\n")
  result.add("members=$(wc -l < " & quotedList & ")\n")
  result.add("members=$(( members + 0 ))\n")
  result.add("if [ \"$members\" -le 0 ]; then\n")
  result.add("  printf '%s\\n' 'packaging: the staged tree has no" &
    " members to record in .MTREE' >&2\n")
  result.add("  exit 1\n")
  result.add("fi\n")
  # ``!all,use-set`` starts from nothing and turns on exactly the
  # keywords pacman compares. ``md5`` is left off: pacman checks
  # whichever digest is present and sha256 is the one it prefers.
  result.add("(cd " & quotedRoot & " && bsdtar -cf - --format=mtree" &
    " --options=" &
    shellSingleQuote("!all,use-set,type,uid,gid,mode,time,size," &
      "sha256,link") &
    " --uid 0 --gid 0 --uname root --gname root" &
    " --mtime " & shellSingleQuote("@" & $sourceDateEpoch) &
    " -n -T \"$__list_abs\") > " & quotedRaw & "\n")
  result.add("read -r first < " & quotedRaw & " || first=''\n")
  result.add("if [ \"$first\" != '#mtree' ]; then\n")
  result.add("  printf 'packaging: bsdtar did not write an mtree" &
    " (first line was %s)\\n' \"$first\" >&2\n")
  result.add("  exit 1\n")
  result.add("fi\n")
  result.add("entries=$(grep -c " & shellSingleQuote("^\\./") & " " &
    quotedRaw & " || true)\n")
  result.add("entries=$(( entries + 0 ))\n")
  result.add("if [ \"$entries\" -lt \"$members\" ]; then\n")
  result.add("  printf 'packaging: .MTREE records %s entries for a tree" &
    " of %s members\\n' \"$entries\" \"$members\" >&2\n")
  result.add("  exit 1\n")
  result.add("fi\n")
  # EVERY entry carries the one epoch. pacman compares this field
  # against the installed file's mtime, and the installed mtime is what
  # ``tar --mtime=@<epoch>`` wrote -- so an entry with any other value
  # is a mismatch this package would report on a user's machine.
  result.add("stamped=$(grep -c " &
    shellSingleQuote("^\\./.*time=" & $sourceDateEpoch & "\\.") &
    " " & quotedRaw & " || true)\n")
  result.add("stamped=$(( stamped + 0 ))\n")
  result.add("if [ \"$stamped\" -ne \"$entries\" ]; then\n")
  result.add("  printf 'packaging: %s of %s .MTREE entries carry the" &
    " build epoch; pacman -Qkk compares this field against the" &
    " installed mtime\\n' \"$stamped\" \"$entries\" >&2\n")
  result.add("  exit 1\n")
  result.add("fi\n")
  # ``gzip -n`` rather than ``bsdtar -z``: bsdtar's gzip writer stamps
  # the wall clock into the gzip header.
  result.add("gzip -n -9 -c " & quotedRaw & " > " &
    shellSingleQuote(outPath) & "\n")
  result.add("gzip -t " & shellSingleQuote(outPath) & "\n")

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
    " -type f" & metadataExclusions(treeRoot) & " | wc -l)\n")
  result.add("if [ \"$(( files + 0 ))\" -eq 0 ]; then\n")
  result.add("  printf 'packaging: no regular files under %s; refusing" &
    " to report an installed size of 0\\n' " &
    shellSingleQuote(treeRoot) & " >&2\n")
  result.add("  exit 1\n")
  result.add("fi\n")
  result.add("bytes=$(find " & shellSingleQuote(treeRoot) &
    " -type f" & metadataExclusions(treeRoot) &
    " -exec cat -- {} + | wc -c)\n")
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
  tree.addGeneratedFile(ArchPkgInfoMember, archPkgInfoText(dist, withFloor),
    0o644, site, substitutions = substitutions)

  # ---- the .MTREE --------------------------------------------------
  #
  # AFTER ``.PKGINFO``, because makepkg's mtree records it and pacman
  # would otherwise have a member the record does not mention. BEFORE
  # the archive, obviously, and ordered by ``after = tree.terminal``,
  # which at this point includes ``.PKGINFO``'s own install edge.
  #
  # NOT staged through ``addGeneratedFile``: that path writes TEXT into
  # the tree through an install edge, and this member is a gzip stream
  # produced by two tools from the finished tree. It is written
  # directly into the tree root and named as an explicit archive
  # member and as an explicit input of the archive edge.
  let mtreeListPath = tree.genRoot & "/" & tree.idPrefix & "mtree-members.txt"
  let mtreeRawPath = tree.genRoot & "/" & tree.idPrefix & "mtree.txt"
  let mtreePath = tree.root & "/" & ArchMtreeMember
  let mtreeEdge = sh_module.shell(
    mtreeScript(tree.root, mtreeListPath, mtreeRawPath,
      dist.sourceDateEpoch),
    actionId = tree.idPrefix & "mtree",
    after = tree.terminal,
    # Every staged file is an input: the mtree carries each one's size
    # and sha256, so a changed byte anywhere must rewrite it.
    extraInputs = tree.stagedPaths(),
    extraOutputs = @[mtreePath, mtreeRawPath, mtreeListPath])
  declareProducerTool(site, mtreeEdge.id, ArchShSelector)
  declareProducerTool(site, mtreeEdge.id, ArchBsdtarSelector)
  declareProducerTool(site, mtreeEdge.id, ArchGzipSelector)
  declareProducerTool(site, mtreeEdge.id, ArchFindSelector)
  declareProducerTool(site, mtreeEdge.id, ArchGrepSelector)
  # ``sort``/``wc``/``mkdir``/``dirname`` -- coreutils, through the
  # ``install`` executable's package.
  declareProducerTool(site, mtreeEdge.id, InstallSelector)
  tree.terminal.add(mtreeEdge)

  # ---- the archive -------------------------------------------------
  let outPath = dist.outputDir & "/" & archArtifactName(dist)
  # ``.PKGINFO`` first, ``.MTREE`` second, then the payload -- makepkg's
  # order, and the order a reader that stops at the first metadata
  # entry needs.
  var members = @[ArchPkgInfoMember, ArchMtreeMember]
  for top in archTopLevelMembers(tree):
    if top notin members:
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
    # ``.MTREE`` is not a staged FILE (it is written into the tree by
    # the edge above rather than installed into it), so it has no entry
    # in ``stagedPaths`` and has to be named here -- without it the
    # archive edge would not re-run when the record changed.
    extraInputs = tree.stagedPaths() & @[mtreePath])
  declareProducerTool(site, edge.id, ArchTarSelector)
  declareProducerTool(site, edge.id, ArchGzipSelector)
  PackagedArtifact(
    format: "pkg.tar.gz",
    path: outPath,
    edge: edge,
    toolSelectors: @[ArchTarSelector, ArchGzipSelector, ArchShSelector,
                     ArchFindSelector, ArchBsdtarSelector,
                     ArchGrepSelector] & tree.stagingSelectors,
    tree: tree)

proc archProducer(dist: Distribution;
                  site: ToolDependencySite): PackagedArtifact {.nimcall.} =
  archPackage(dist, site)

registerProducer("pkg.tar.gz",
  "Arch Linux package (tools: tar, gzip)",
  archProducer)
