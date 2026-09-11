## The AppImage producer — the fourth Linux format, and the first one
## that is not an INSTALLER at all.
##
## M1's format matrix carried AppImage as "not written, and with no
## external excuse": macOS is blocked on a Darwin host and *BSD on a
## ``TargetOs`` that has three values, and AppImage was blocked on
## neither. This is that item.
##
## ## What an AppImage IS, and why it is a different KIND of package
##
## deb, rpm and Arch all unpack a payload into ``/`` and hand the
## package manager a database row. An AppImage is one FILE: a ~950 KB
## static ELF stub (the *type-2 runtime*) with a squashfs image of an
## AppDir concatenated onto it. Running it mounts that squashfs — or
## unpacks it, with ``--appimage-extract-and-run``, where FUSE is
## unavailable — at a path chosen at RUN TIME and execs ``AppRun`` out
## of it. There is no install step, no uninstall step, no package
## database, no ``/etc``, and no service registration.
##
## That last clause is not a gap this producer left; it is what the
## format is. See "What an AppImage cannot do" below, which is asserted
## by ``t_packaging_appimage_authoring`` rather than merely stated.
##
## ## The mount path is random, which makes this the STRONGEST test of §5
##
## §5's wrapper contract says the package's environment is computed from
## the wrapper's own location at run time (``runtime_contract.
## PrefixToken`` / ``PosixPrefixExpr``), and the RPATH is
## ``$ORIGIN``-relative. Every other format lets a wrong implementation
## survive: a deb installed at ``/usr`` works just as well with a baked
## ``/usr`` as with a computed one, and only a second unpacking at
## ``/opt/alt`` tells them apart. An AppImage mounts at
## ``/tmp/.mount_<random>`` — a DIFFERENT path on every single run — so a
## baked prefix cannot work even once. If reprobuild's own AppImage
## answers ``repro --version``, the prefix was resolved at run time, and
## no other arrangement is consistent with the observation.
##
## ## TRAP 1: without ``--runtime-file`` the build reaches the network
##
## appimagetool does not fail when it is given no runtime. It downloads
## one, from ``AppImage/type2-runtime``'s ``continuous`` tag — a tag
## that MOVES. Measured in a container started ``--network none``::
##
##   Downloading runtime file from https://github.com/AppImage/
##       type2-runtime/releases/download/continuous/runtime-x86_64
##   Failed to download runtime: server returned status code 0
##
## It failed there only because there was no network. On any developer's
## machine it succeeds, and the artifact quietly becomes a function of
## the day it was built rather than of the graph — which is the same
## class of defect as the deb producer's missing ``SOURCE_DATE_EPOCH``
## and harder to see, because the bytes it changes are the first 950 KB
## rather than a header field.
##
## So the runtime is a PINNED PACKAGE (``packages/appimage_runtime.nim``)
## and this producer stages a copy of it as an ordinary build-tree file,
## then passes that file to ``--runtime-file``. The staging edge refuses
## the build when the runtime is not on its action's PATH, instead of
## letting appimagetool take the download path — see
## ``runtimeStageScript``.
##
## ## TRAP 1b: the tool is an AppImage, so ITS OWN AppRun needs coreutils
##
## ``--appimage-extract-and-run`` unpacks appimagetool and runs the
## ``AppRun`` inside it, which is a shell script that calls ``readlink``
## and ``dirname``. An action's PATH in reprobuild holds only the tools
## its edge NAMED, so an edge naming ``appimagetool`` and ``file`` and
## nothing else dies at ``AppRun: line 5: readlink: command not found``
## with exit 127 -- which is what the first real build of this producer
## did. The image edge therefore also names coreutils
## (``runtime_contract.InstallSelector``). Third instance of the same
## lesson in this layer, after ``gzip`` behind ``tar -z`` and the five
## scriptlet tools behind ``rpmbuild``.
##
## ## TRAP 2: appimagetool validates the AppDir, and fails on absence
##
## Measured against this tool, one removal at a time:
##
## * no ``*.desktop`` at the AppDir root — ``Desktop file not found,
##   aborting``;
## * a ``Icon=`` key whose file is absent — ``<name>{.png,.svg,.xpm}
##   defined in desktop file but not found``;
## * no ``AppRun`` — **exit 0**. appimagetool does not check for it.
##
## The third is the dangerous one: the AppImage builds, and the failure
## appears only when a user runs it. So ``AppRun`` is emitted
## unconditionally here and a case asserts it is in the tree.
##
## The icon is an SVG rather than a PNG, and that is a deliberate
## consequence of the layer's own rule that everything staged is the
## output of a build edge over text the layer authored: a PNG would have
## to arrive as a checked-in binary blob or be decoded from a base64
## literal, and neither is reviewable. The shipped mark is
## geometric and carries no wordmark — it is visibly a PLACEHOLDER
## rather than a logo, because inventing branding is worse than
## admitting there is none. A distribution that has artwork overrides
## ``DistMetadata.desktopIconSvg``.
##
## ## Reproducibility, measured rather than assumed
##
## appimagetool 1.9.1 already ignores the staged files' own mtimes: a
## payload file touched to 2031 produces a byte-identical AppImage. What
## ``SOURCE_DATE_EPOCH`` changes is WHICH fixed timestamp goes in — its
## default is 0 and a non-zero value produces different bytes
## (measured: epoch 315532800 and epoch 1000000000 give two different
## sha256s over one AppDir). So passing ``dist.sourceDateEpoch`` here is
## not what makes this format reproducible — it already is — it is what
## makes ONE number govern every format's timestamps, which is the
## property ``types.Distribution.sourceDateEpoch`` exists to hold.
##
## The compressor is named explicitly for the same reason: appimagetool's
## default has moved across releases (gzip, then xz, then zstd), and a
## default that moves is an ambient input.
##
## ## What an AppImage cannot do, stated rather than faked
##
## * **No services.** systemd reads units from fixed ABSOLUTE paths; a
##   unit file inside a squashfs image that is mounted somewhere new on
##   every run is read by nothing. This producer therefore stages NO
##   unit, where deb, rpm and Arch all stage one, and
##   ``appImageUnsupportedServices`` names what was dropped so a recipe
##   can see it. Shipping an inert unit would look like support.
## * **No ``/etc``.** ``types.escapesPrefix`` sends ``crConfigFile``
##   components to ``/etc/<name>/`` on a root-rooted tree, and the
##   AppDir IS root-rooted, so they land at ``<AppDir>/etc/…``. Nothing
##   reads them there: the running binary looks at the absolute
##   ``/etc``. They ride along as an extractable DEFAULT and that is all
##   they are.
## * **No uninstall to revert.** Deleting the file is the whole of it.
##
## ## Why it stages its own tree
##
## Same reason ``producers/arch.nim`` does, and the same measured
## failure behind it: the variant is the ACTION-ID NAMESPACE as well as
## the directory name, so two producers sharing one variant register two
## edges with one id, and the engine keys the ACTION CACHE by id — a
## collision serves one tree's outputs for the other.

import std/[strutils]

import repro_project_dsl

import ../types
import ../runtime_contract
import ../producer
import ../../packages/appimagetool as appimagetool_module
import ../../packages/sh as sh_module
{.push warning[UnusedImport]: off.}
# Imported for their REGISTRATION side effect: an action's PATH holds
# only the tools its edge NAMED.
#
# ``appimage-runtime`` is the pinned type-2 runtime the staging edge
# copies out of its provisioned prefix; ``file`` is libmagic's CLI,
# which appimagetool execs to decide the payload's architecture and
# without which it stops with ``file command is missing but required,
# please install it``. Neither is ever typed at a call site here, which
# is exactly the ``packages/gzip.nim`` shape.
import ../../packages/appimage_runtime
import ../../packages/file
{.pop.}

{.experimental: "callOperator".}

const appImageTool = appimagetool_module.appimagetool

const
  AppImageToolSelector* = "appimagetool"
  AppImageRuntimeSelector* = "appimage-runtime"
    ## The pinned type-2 runtime. A REAL build-graph dependency, not a
    ## convenience: without it on the staging edge's PATH the producer
    ## stops, and appimagetool's own fallback is an unpinned download.
  AppImageFileSelector* = "file"
    ## libmagic's CLI. appimagetool execs it by name to classify the
    ## payload's binaries, and refuses to run without it. Same class of
    ## dependency as ``producers/tarball.GzipSelector`` — invisible in
    ## the producer's argv, fatal under a hermetic PATH.
  AppImageShSelector* = "sh"

  AppImageCompression* = "zstd"
    ## The squashfs compressor, stated rather than defaulted. See the
    ## header: appimagetool's own default has changed across releases,
    ## and the type-2 runtime has supported zstd since 2020.

  AppImageDefaultCategories* = "Utility;"
    ## The freedesktop main category used when a distribution names
    ## none.
    ##
    ## ``Utility`` rather than ``Development`` deliberately: a
    ## ``.desktop`` file's ``Categories`` is a claim about where the
    ## application belongs in a menu, the layer knows nothing about the
    ## distribution it is packaging, and ``Utility`` is the main
    ## category that claims the least while still being valid. A
    ## distribution that knows better sets
    ## ``DistMetadata.desktopCategories``.

proc appImageArchitecture*(dist: Distribution): string =
  ## AppImage's architecture spelling — the value of the ``ARCH``
  ## environment variable appimagetool reads and the token that goes in
  ## the artifact's file name.
  ##
  ## A fourth vocabulary beside deb's, rpm's and pacman's, and mostly
  ## (not entirely) the kernel's: 32-bit ARM is ``armhf`` here, where
  ## Arch says ``armv7h`` and Debian also says ``armhf``.
  case dist.architecture
  of "x86_64", "amd64": "x86_64"
  of "aarch64", "arm64": "aarch64"
  of "armv7l", "armv7h", "armhf": "armhf"
  of "i686", "i386": "i686"
  else: dist.architecture

proc appImageArtifactName*(dist: Distribution): string =
  ## ``<name>-<version>-<release>-<arch>.AppImage``.
  ##
  ## The release segment is carried for ``producers/arch.nim``'s reason:
  ## a rebuild of one version must be distinguishable from a new
  ## version by anyone who only has the file name, and an AppImage is
  ## distributed as a bare file more often than any other format here.
  dist.name & "-" & dist.fullVersion & "-" & appImageArchitecture(dist) &
    ".AppImage"

proc appImageEntryPointNames*(tree: StagedTree): seq[string] =
  ## The leaf names of the tree's public entry points, in staged order.
  ##
  ## Read off ``StagedFile.isPublicEntryPoint`` rather than re-derived
  ## from the components, because what a user invokes is the WRAPPER
  ## when there is one and the binary when there is not, and only
  ## staging knows which it emitted.
  for f in publicEntryPoints(tree):
    result.add(extractFilenameSlashOnly(f.rootRelPath))

proc appRunText*(dist: Distribution; tree: StagedTree): string =
  ## ``AppRun`` — the AppDir's entry point, and the piece appimagetool
  ## does NOT check for (an AppDir without one builds, exits 0, and
  ## fails when a user runs it).
  ##
  ## ## Why it dispatches instead of exec'ing one binary
  ##
  ## An AppImage is one file with one entry point as far as the desktop
  ## is concerned, but a distribution may ship several public
  ## executables — M0's sample ships ``hello`` and ``adder``. The type-2
  ## runtime exports ``ARGV0`` holding the name the image was invoked
  ## as, which is what makes ``ln -s app.AppImage adder && ./adder``
  ## work. Dispatching on it costs four lines and is the difference
  ## between packaging the distribution and packaging its first binary.
  ##
  ## ## Why ``$APPDIR`` is not trusted
  ##
  ## The runtime exports it, and an AppDir run directly out of a
  ## directory (which is how ``--appimage-extract-and-run`` and every
  ## debugging session work) may not have it — or may have a stale one
  ## inherited from an outer AppImage. Computing it from ``$0`` is the
  ## same idiom the §5 wrapper uses for its own prefix and is correct in
  ## both cases.
  let names = appImageEntryPointNames(tree)
  result = "#!/bin/sh\n"
  result.add("# Generated by the reprobuild DSL packaging layer.\n")
  result.add("# AppDir entry point. See packaging/producers/appimage.nim.\n")
  result.add("__appdir=$(cd -- \"$(dirname -- \"$0\")\" && pwd)\n")
  # ``ARGV0`` is the runtime's; ``$0`` is the fallback for a directly
  # executed AppDir.
  result.add("__invoked=${ARGV0:-$0}\n")
  result.add("__invoked=${__invoked##*/}\n")
  if names.len > 0:
    result.add("case \"$__invoked\" in\n")
    for name in names:
      result.add("  " & name & ")\n")
      result.add("    exec \"$__appdir/" &
        prefixRelToRoot(dist, dist.layout.binDir & "/" & name) &
        "\" \"$@\" ;;\n")
    result.add("esac\n")
    # The default arm: invoked as ``<something>.AppImage``, which is the
    # ordinary case, so the FIRST public entry point is the app.
    result.add("exec \"$__appdir/" &
      prefixRelToRoot(dist, dist.layout.binDir & "/" & names[0]) &
      "\" \"$@\"\n")
  else:
    # A distribution with no public entry point has no app to run. Fail
    # loudly rather than exec'ing nothing: ``appImagePackage`` refuses
    # such a distribution outright, so reaching this text means the
    # refusal was removed and this is the second line of defence.
    result.add("printf '%s\\n' 'this AppImage has no entry point' >&2\n")
    result.add("exit 1\n")

proc appImageDesktopFileName*(dist: Distribution): string =
  dist.name & ".desktop"

proc appImageIconFileName*(dist: Distribution): string =
  dist.name & ".svg"

proc desktopEntryText*(dist: Distribution; tree: StagedTree): string =
  ## The ``.desktop`` file appimagetool requires at the AppDir root.
  ##
  ## ``Exec`` names the entry point by BARE NAME rather than by path:
  ## the desktop-integration tooling substitutes the AppImage's own path
  ## for it, and an absolute path here would be a path inside a squashfs
  ## that is mounted somewhere different on every run.
  let names = appImageEntryPointNames(tree)
  let exec = (if names.len > 0: names[0] else: dist.name)
  let summary =
    if dist.metadata.summary.len > 0: dist.metadata.summary.splitLines()[0]
    else: dist.name
  let categories =
    if dist.metadata.desktopCategories.len > 0:
      dist.metadata.desktopCategories
    else:
      AppImageDefaultCategories
  result = "[Desktop Entry]\n"
  result.add("Type=Application\n")
  result.add("Name=" & dist.name & "\n")
  result.add("Comment=" & summary & "\n")
  result.add("Exec=" & exec & "\n")
  # The ``Icon`` value is a NAME, never a file name: freedesktop looks
  # the name up in the icon theme, and appimagetool looks for
  # ``<name>{.png,.svg,.xpm}`` at the AppDir root. An ``Icon`` carrying
  # ``.svg`` would make it search for ``<name>.svg.svg``.
  result.add("Icon=" & dist.name & "\n")
  result.add("Categories=" & categories & "\n")
  # Every distribution this layer packages today is a command-line tool.
  # ``Terminal=false`` on one would make a double-click launch it with
  # no visible output at all.
  result.add("Terminal=true\n")
  result.add("X-AppImage-Version=" & dist.fullVersion & "\n")

proc placeholderIconSvg*(dist: Distribution): string =
  ## The default icon, and it is deliberately not a logo.
  ##
  ## appimagetool REFUSES an AppDir whose ``Icon`` key names a file that
  ## is not there, so some icon has to exist. The options were: ship a
  ## checked-in PNG (a binary blob in a layer whose every staged byte is
  ## otherwise the output of an edge over reviewable text), decode one
  ## from a base64 literal (the same blob, less legible), or author an
  ## SVG. An SVG is text, so it goes through ``addGeneratedFile`` like
  ## every other generated file and a reviewer can read it.
  ##
  ## It carries no wordmark and no glyph: it is two neutral rounded
  ## rectangles. A placeholder that LOOKS like branding is worse than
  ## one that looks like a placeholder, because the first gets shipped.
  discard dist
  "<svg xmlns=\"http://www.w3.org/2000/svg\" " &
    "width=\"256\" height=\"256\" viewBox=\"0 0 256 256\">\n" &
    "  <rect width=\"256\" height=\"256\" rx=\"48\" fill=\"#2f3640\"/>\n" &
    "  <rect x=\"56\" y=\"56\" width=\"144\" height=\"144\" rx=\"24\" " &
    "fill=\"none\" stroke=\"#dcdde1\" stroke-width=\"16\"/>\n" &
    "</svg>\n"

proc appImageUnsupportedServices*(dist: Distribution): seq[string] =
  ## Every service this format drops, by name.
  ##
  ## AppImage has no service-registration mechanism of any kind: systemd
  ## reads units from fixed absolute paths and an AppImage owns no
  ## absolute path. So this returns EVERY declared service, not a
  ## filtered subset — which is the point. ``services.
  ## darwinUnsupportedServices`` and ``droppedUserServices`` exist for
  ## the same reason and with the same shape: a format that cannot carry
  ## part of the data model says so by name instead of rendering it to
  ## nothing.
  for svc in dist.services:
    result.add(svc.name)

proc runtimeStageScript*(runtimeFileName, outPath: string): string =
  ## Copy the PINNED type-2 runtime out of its provisioned prefix and
  ## into the build tree, so the appimagetool edge can take it as an
  ## ordinary INPUT.
  ##
  ## ## Why a script rather than a path in the graph
  ##
  ## ``toolIdentityRefs`` hands an action a bin DIRECTORY on its PATH,
  ## not a prefix: there is no way for a lowered edge to address into
  ## the realization the engine chose (the same gap
  ## ``openssl_layout.resolvedOpensslExecutable`` records). So the
  ## runtime's location is discovered inside the action, by
  ## ``command -v`` over a PATH the engine composed from the tools this
  ## edge NAMED — which is a resolution of the provisioned package and
  ## not of the ambient host.
  ##
  ## ## EVERY WAY THIS CAN FAIL TO FIND THE RUNTIME IS A HARD ERROR
  ##
  ## Written that way because the fallback is silent and remote:
  ## appimagetool with no ``--runtime-file`` DOWNLOADS a runtime from a
  ## moving tag and exits 0. A producer that shrugged here would produce
  ## an artifact whose first 950 KB came off the internet on the day of
  ## the build. So the script asserts the tool is on PATH, asserts the
  ## copy is an ELF image, and asserts it is not implausibly small.
  result = "set -eu\n"
  result.add("# Generated by the reprobuild DSL packaging layer\n")
  result.add("rt=$(command -v " & shellSingleQuote(runtimeFileName) &
    " 2>/dev/null || true)\n")
  result.add("if [ -z \"$rt\" ]; then\n")
  result.add("  printf '%s\\n' 'packaging: the pinned AppImage type-2" &
    " runtime is not on this action PATH; appimagetool would silently" &
    " download an unpinned one from a moving tag' >&2\n")
  result.add("  exit 1\n")
  result.add("fi\n")
  result.add("mkdir -p -- \"$(dirname -- " & shellSingleQuote(outPath) &
    ")\"\n")
  result.add("cp -- \"$rt\" " & shellSingleQuote(outPath) & "\n")
  # The magic bytes, read with tools the edge already has. ``tr -cd``
  # keeps only the three letters, so anything that is not an ELF image
  # -- a shell script, an HTML error page a proxy substituted -- gives
  # something other than ``ELF`` and stops the build.
  result.add("magic=$(head -c 4 -- " & shellSingleQuote(outPath) &
    " | tr -cd 'ELF')\n")
  result.add("if [ \"$magic\" != \"ELF\" ]; then\n")
  result.add("  printf '%s\\n' 'packaging: the staged AppImage runtime" &
    " is not an ELF image; an AppImage built on it would not execute'" &
    " >&2\n")
  result.add("  exit 1\n")
  result.add("fi\n")
  # A truncated download is still an ELF. The real runtime is ~950 KB;
  # anything under 64 KB is not one.
  result.add("bytes=$(wc -c < " & shellSingleQuote(outPath) & ")\n")
  result.add("bytes=$(( bytes + 0 ))\n")
  result.add("if [ \"$bytes\" -lt 65536 ]; then\n")
  result.add("  printf 'packaging: the staged AppImage runtime is only" &
    " %s bytes; that is not a type-2 runtime\\n' \"$bytes\" >&2\n")
  result.add("  exit 1\n")
  result.add("fi\n")

proc appImagePackage*(dist: Distribution; site = noSite()): PackagedArtifact =
  ## Produce a self-contained ``.AppImage`` from the one
  ## ``Distribution`` definition.
  ##
  ## The tree is ROOT-relative (the ``appimage`` variant is not in
  ## ``stageInstallTree``'s prefix-rooted set), because an AppDir mirrors
  ## a filesystem root: ``usr/bin/<app>`` beside the AppDir's own
  ## ``AppRun``, ``.desktop`` and icon. That is also what makes the §5
  ## wrapper's run-time prefix resolution land on ``<mountpoint>/usr``,
  ## which is the only thing that can work when the mountpoint is
  ## different on every run.
  if dist.targetOs != toLinux:
    # §6.1: an unavailable format is an unresolvable tool dependency,
    # never a switch in the engine -- but a Windows or Darwin
    # ``Distribution`` reaching this producer is a RECIPE error rather
    # than a provisioning outcome, and it is worth a diagnostic that
    # says so. The AppImage format is Linux-only by construction: the
    # runtime is an ELF image and the payload is a squashfs of a
    # Linux filesystem tree.
    raise newException(ValueError,
      "the AppImage producer targets Linux only; '" & dist.name &
      "' is staged for " & $dist.targetOs)

  var tree = stageInstallTree(dist, "appimage", site)

  # NO SYSTEMD UNITS. deb, rpm and Arch all stage one here; see the
  # header. A unit inside a squashfs image mounted at a path that
  # changes every run is read by nothing, and shipping an inert one
  # would look like support for something the format cannot do.
  # ``appImageUnsupportedServices`` is how a recipe sees what was
  # dropped.

  let entryPoints = appImageEntryPointNames(tree)
  if entryPoints.len == 0:
    raise newException(ValueError,
      "the AppImage producer needs at least one public entry point; '" &
      dist.name & "' stages none, so its AppRun would exec nothing")

  # ---- the AppDir's own three files --------------------------------
  #
  # All three at the AppDir ROOT, which is where appimagetool looks.
  # ``AppRun`` is 0755 and the other two are 0644, through the same
  # write-then-install-with-a-mode pipeline every other staged file
  # uses -- the modes are not a thing this producer remembers.
  tree.addGeneratedFile("AppRun", appRunText(dist, tree), 0o755, site)
  tree.addGeneratedFile(appImageDesktopFileName(dist),
    desktopEntryText(dist, tree), 0o644, site)
  let iconSvg =
    if dist.metadata.desktopIconSvg.len > 0: dist.metadata.desktopIconSvg
    else: placeholderIconSvg(dist)
  tree.addGeneratedFile(appImageIconFileName(dist), iconSvg, 0o644, site)

  # ---- the pinned runtime, staged as a build-tree file -------------
  let runtimePath = tree.genRoot & "/" & tree.idPrefix & "runtime"
  let runtimeEdge = sh_module.shell(
    runtimeStageScript(AppImageRuntimeFileName, runtimePath),
    actionId = tree.idPrefix & "stage-runtime",
    extraOutputs = @[runtimePath])
  declareProducerTool(site, runtimeEdge.id, AppImageShSelector)
  # ``cp``/``mkdir``/``dirname``/``head``/``tr``/``wc`` -- coreutils,
  # reached through the ``install`` executable's package, the same
  # indirection the closure walk and the Arch size measurement use.
  declareProducerTool(site, runtimeEdge.id, InstallSelector)
  # ...and the runtime itself, which is the whole point: without this
  # selector the ``command -v`` above finds nothing and the edge stops,
  # which is the failure this producer prefers to the silent download.
  declareProducerTool(site, runtimeEdge.id, AppImageRuntimeSelector)
  tree.terminal.add(runtimeEdge)

  # ---- the image ---------------------------------------------------
  let outPath = dist.outputDir & "/" & appImageArtifactName(dist)
  let edge = appImageTool(
    # FIRST in the argv, because the AppImage runtime reads its own
    # options out of ``argv[1]``. appimagetool is itself an AppImage,
    # so without this it needs FUSE and a ``/dev/fuse`` that no
    # container has by default.
    extractAndRun = true,
    noAppstream = true,
    runtimeFile = runtimePath,
    compression = AppImageCompression,
    appDir = tree.root,
    output = outPath,
    actionId = "pkg-appimage-" & dist.name,
    after = tree.terminal & @[runtimeEdge],
    # ``ARCH`` is what appimagetool stamps into the image and what it
    # would otherwise GUESS by running ``file`` over the payload. The
    # guess is usually right and is still a guess; ``dist.architecture``
    # is the declaration, and a producer that let the tool infer it
    # would make the artifact depend on which binary ``file`` looked at
    # first.
    #
    # ``SOURCE_DATE_EPOCH``: see the header. It does not make this
    # format reproducible -- appimagetool already ignores staged mtimes
    # -- it makes this format's fixed timestamp the SAME number as every
    # other format's, which is the property the field exists to hold.
    extraEnv = @[
      ("ARCH", appImageArchitecture(dist)),
      ("SOURCE_DATE_EPOCH", $dist.sourceDateEpoch)
    ],
    extraInputs = tree.stagedPaths() & @[runtimePath])
  declareProducerTool(site, edge.id, AppImageToolSelector)
  # libmagic's CLI, which appimagetool execs by name. Declared on the
  # SAME edge, because it is appimagetool that runs it -- exactly the
  # ``tar``/``gzip`` relationship in ``producers/tarball.nim``.
  declareProducerTool(site, edge.id, AppImageFileSelector)
  # COREUTILS, AND THIS ONE IS A THIRD INSTANCE OF THE SAME LESSON,
  # FOUND BY THE FIRST REAL BUILD. appimagetool is not a binary this
  # edge execs; it is an AppImage, and ``--appimage-extract-and-run``
  # unpacks it and runs ITS OWN ``AppRun``, which is a shell script
  # whose fifth line calls ``readlink`` and ``dirname``. Under a
  # hermetic PATH holding only ``appimagetool`` and ``file`` the action
  # died with::
  #
  #   .../AppRun: line 5: readlink: command not found
  #   .../AppRun: line 5: dirname: command not found
  #   (exit code 127)
  #
  # Invisible in this producer's argv, invisible in appimagetool's
  # ``--help``, and visible only when the tool runs with the PATH the
  # engine composed. Same shape as ``gzip`` behind ``tar -z`` and the
  # rpm scriptlets behind ``rpmbuild``.
  declareProducerTool(site, edge.id, InstallSelector)
  PackagedArtifact(
    format: "AppImage",
    path: outPath,
    edge: edge,
    toolSelectors: @[AppImageToolSelector, AppImageFileSelector,
                     AppImageRuntimeSelector, AppImageShSelector] &
      tree.stagingSelectors,
    tree: tree)

proc appImageProducer(dist: Distribution;
                      site: ToolDependencySite): PackagedArtifact {.nimcall.} =
  appImagePackage(dist, site)

registerProducer("AppImage",
  "Self-contained AppImage type-2 image (tools: appimagetool, file)",
  appImageProducer)
