## The AppImage producer emits an AppDir appimagetool accepts and an
## image whose bytes are a function of the graph.
##
## Each case below is written against something that was MEASURED
## against appimagetool 1.9.1 rather than read out of documentation,
## because three of the four traps are silent:
##
## * **no ``--runtime-file`` → a network download from a MOVING tag**,
##   and exit 0 on any machine with a network. This is the one that
##   would make the artifact a function of the day.
## * **no ``AppRun`` → exit 0.** appimagetool does not check for it; the
##   AppImage builds and fails when a user runs it.
## * **``Icon=`` naming a file that is not there → exit 1**, and
##   **no ``.desktop`` → exit 1**. These two are loud, and are pinned
##   here so the producer cannot quietly stop emitting either.
##
## The fourth is not a trap but a property: an AppImage mounts at
## ``/tmp/.mount_<random>``, so nothing about a baked install prefix can
## work even once. That is asserted end to end by the container gate
## rather than here.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc appImageSample(targetOs = toLinux): Distribution =
  result = sampleDistribution(targetOs)
  result.components.add(component(crConfigFile, "build/gen/sampletool.conf",
    installName = "sampletool.conf"))

proc envOf(act: BuildActionDef): seq[(string, string)] =
  for reg in registeredBuildActions():
    if reg.id == act.id: return reg.env
  @[]

proc envValue(act: BuildActionDef; name: string): string =
  for (n, v) in envOf(act): (if n == name: return v)
  ""

proc scriptOfEdgeWithIdSuffix(suffix: string): string =
  ## NOTE the generated intermediates are located by their SANITISED
  ## name: ``addGeneratedFile`` runs ``sanitizeIdPart`` over the
  ## tree-relative path, which maps ``.`` to ``-``, so the file behind
  ## ``sampletool.desktop`` is ``...sampletool-desktop.gen``.
  for act in registeredBuildActions():
    if not act.id.endsWith(suffix): continue
    for arg in act.call.arguments:
      if arg.name == "command": return arg.encodedValue
  ""

suite "packaging: the AppImage producer's AppDir is one appimagetool takes":

  test "the architecture spelling is AppImage's, and is a FOURTH vocabulary":
    # One fact, now four vocabularies. The 32-bit ARM row is the one
    # that proves this is not just a rename of an existing mapping:
    # Arch says ``armv7h``, AppImage and Debian both say ``armhf``, and
    # rpm says ``armv7hl``.
    var dist = appImageSample()
    check appImageArchitecture(dist) == "x86_64"
    dist.architecture = "aarch64"
    check appImageArchitecture(dist) == "aarch64"
    check debArchitecture(dist) == "arm64"
    dist.architecture = "armv7l"
    check appImageArchitecture(dist) == "armhf"
    check archArchitecture(dist) == "armv7h"

  test "the artifact name carries the release, like Arch's does":
    let dist = appImageSample()
    check appImageArtifactName(dist) == "sampletool-0.2.0-1-x86_64.AppImage"

  test "the AppDir root carries AppRun, one .desktop and the named icon":
    # TRAP 2, both halves. A missing ``.desktop`` and an ``Icon`` key
    # whose file is absent are both hard failures in appimagetool;
    # a missing ``AppRun`` is NOT, which is why it is asserted here
    # rather than left to the tool.
    resetBuildActionRegistry()
    let artifact = appImagePackage(appImageSample())
    let paths = stagedRelPaths(artifact.tree)
    check "AppRun" in paths
    check "sampletool.desktop" in paths
    check "sampletool.svg" in paths
    # ...at the ROOT, not nested. appimagetool looks at the AppDir's own
    # directory and nowhere else.
    for p in ["AppRun", "sampletool.desktop", "sampletool.svg"]:
      check not p.contains("/")
    # Exactly one desktop file: appimagetool takes the first it finds,
    # so a second one would make which-app-is-this a directory-order
    # question.
    var desktops = 0
    for p in paths:
      if p.endsWith(".desktop") and not p.contains("/"): inc desktops
    check desktops == 1

  test "AppRun is 0755, because a 0644 one is not an entry point":
    resetBuildActionRegistry()
    discard appImagePackage(appImageSample())
    var appRunModes: seq[string] = @[]
    for act in registeredBuildActions():
      if not act.id.contains("gen-install-AppRun"): continue
      for arg in act.call.arguments:
        if arg.name == "mode": appRunModes.add(arg.encodedValue)
    check appRunModes == @["0755"]

  test "AppRun dispatches on ARGV0 and names EVERY public entry point":
    # The sample ships two public binaries. A producer that exec'd the
    # first one unconditionally would package the distribution's first
    # binary rather than the distribution.
    resetBuildActionRegistry()
    let artifact = appImagePackage(appImageSample())
    let text = writtenText("AppRun")
    check text.len > 0
    check text.startsWith("#!/bin/sh\n")
    check text.contains("${ARGV0:-$0}")
    let names = appImageEntryPointNames(artifact.tree)
    check names.len == 2
    for name in names:
      check text.contains("\n  " & name & ")\n")
      check text.contains("$__appdir/usr/bin/" & name & "\" \"$@\"")
    # The default arm -- invoked as ``<something>.AppImage``, which is
    # the ordinary case -- is the FIRST entry point.
    check text.strip().endsWith(
      "exec \"$__appdir/usr/bin/" & names[0] & "\" \"$@\"")
    # ``$APPDIR`` is NOT trusted: an AppDir run directly out of a
    # directory may have none, or may inherit a stale one.
    check text.contains("__appdir=$(cd -- \"$(dirname -- \"$0\")\" && pwd)")

  test "the desktop entry's Icon is a NAME and its Exec is a bare name":
    # Two different mistakes that both produce a file appimagetool
    # accepts. ``Icon=sampletool.svg`` makes freedesktop look for
    # ``sampletool.svg.svg``; an absolute ``Exec`` names a path inside a
    # squashfs that is mounted somewhere different on every run.
    resetBuildActionRegistry()
    discard appImagePackage(appImageSample())
    let text = writtenText("sampletool-desktop")
    check text.len > 0
    check text.startsWith("[Desktop Entry]\n")
    check text.contains("\nType=Application\n")
    check text.contains("\nName=sampletool\n")
    check text.contains("\nIcon=sampletool\n")
    check not text.contains("Icon=sampletool.svg")
    check text.contains("\nExec=hello\n")
    check not text.contains("Exec=/")
    check text.contains("\nTerminal=true\n")

  test "Categories defaults to the least informative valid main category":
    resetBuildActionRegistry()
    discard appImagePackage(appImageSample())
    check writtenText("sampletool-desktop").contains("\nCategories=Utility;\n")
    # ...and a distribution that knows better overrides it VERBATIM.
    resetBuildActionRegistry()
    var dist = appImageSample()
    dist.metadata.desktopCategories = "Development;Building;"
    discard appImagePackage(dist)
    check writtenText("sampletool-desktop").contains(
      "\nCategories=Development;Building;\n")

  test "the icon is SVG source and is visibly a placeholder":
    resetBuildActionRegistry()
    discard appImagePackage(appImageSample())
    let svg = writtenText("sampletool-svg")
    check svg.startsWith("<svg ")
    check svg.contains("viewBox=")
    # No wordmark and no glyph: a placeholder that looks like branding
    # is the one that gets shipped.
    check not svg.contains("<text")
    # ...and a distribution with real artwork replaces it wholesale.
    resetBuildActionRegistry()
    var dist = appImageSample()
    dist.metadata.desktopIconSvg = "<svg id=\"real\"></svg>\n"
    discard appImagePackage(dist)
    check writtenText("sampletool-svg") == "<svg id=\"real\"></svg>\n"

  test "--appimage-extract-and-run is the FIRST argument":
    # Not cosmetic. The AppImage type-2 runtime reads its own
    # ``--appimage-*`` options out of ``argv[1]`` and hands everything
    # else to the payload, so this flag anywhere later is inert --
    # and inert means appimagetool needs FUSE, which no container has
    # by default.
    resetBuildActionRegistry()
    let artifact = appImagePackage(appImageSample())
    let argv = argvOf(artifact.edge)
    check argv.len > 0
    check argv[0] == "--appimage-extract-and-run"
    check "-n" in argv
    check "--comp" in argv
    check "zstd" in argv

  test "the runtime is PINNED, staged by an edge, and passed by path":
    # TRAP 1, and the reason this producer has a second tool package at
    # all. Without ``--runtime-file`` appimagetool downloads a runtime
    # from a tag that moves, and exits 0.
    resetBuildActionRegistry()
    let artifact = appImagePackage(appImageSample())
    let argv = argvOf(artifact.edge)
    let idx = argv.find("--runtime-file")
    check idx >= 0
    let runtimeArg = argv[idx + 1]
    check runtimeArg.endsWith("runtime")
    check runtimeArg.contains(artifact.tree.genRoot)
    # It is an OUTPUT of a real edge, so the image edge depends on its
    # contents rather than on a name.
    var stagingEdges = 0
    for act in registeredBuildActions():
      if act.id.endsWith("stage-runtime"): inc stagingEdges
    check stagingEdges == 1
    # ...and the pinned package is a declared tool of the recipe.
    check AppImageRuntimeSelector in artifact.toolSelectors
    check AppImageToolSelector in artifact.toolSelectors
    # libmagic's CLI, which appimagetool execs by name and refuses to
    # run without. Invisible in the argv above, which is exactly why it
    # has to be named.
    check AppImageFileSelector in artifact.toolSelectors
    # ...and COREUTILS, on the image edge. appimagetool is itself an
    # AppImage: ``--appimage-extract-and-run`` runs ITS OWN AppRun,
    # a shell script calling ``readlink`` and ``dirname``. Under a PATH
    # holding only appimagetool and file the first real build died with
    # ``AppRun: line 5: readlink: command not found`` and exit 127.
    var imageRefs: seq[string] = @[]
    for act in registeredBuildActions():
      if act.id == artifact.edge.id: imageRefs = act.toolIdentityRefs
    check InstallSelector in imageRefs
    check AppImageToolSelector in imageRefs
    check AppImageFileSelector in imageRefs

  test "the runtime staging script treats every failure to find it as fatal":
    # The alternative is not a broken build, it is a SUCCESSFUL one
    # whose first 950 KB came off the internet.
    resetBuildActionRegistry()
    discard appImagePackage(appImageSample())
    let script = scriptOfEdgeWithIdSuffix("stage-runtime")
    check script.len > 0
    check script.startsWith("set -eu\n")
    check script.contains("command -v 'runtime-x86_64'")
    check script.contains("is not on this action PATH")
    # It refuses a non-ELF file, which is what a proxy's HTML error page
    # or a shell-script stand-in would be...
    check script.contains("tr -cd 'ELF'")
    check script.contains("not an ELF image")
    # ...and a truncated one, which would still be an ELF.
    check script.contains("-lt 65536")
    # The guards are not decorative: the script must not contain a
    # fallback that proceeds without the runtime.
    check not script.contains("|| true\ncp")
    check not script.contains("continuous")

  test "NO systemd unit is staged, and the dropped services are NAMED":
    # An AppImage owns no absolute path, so a unit inside it is read by
    # nothing. Shipping an inert one would look like support.
    resetBuildActionRegistry()
    let dist = appImageSample()
    let artifact = appImagePackage(dist)
    for p in stagedRelPaths(artifact.tree):
      doAssert not p.contains("systemd"),
        "the AppImage tree staged '" & p & "'; an AppImage owns no " &
        "absolute path, so a systemd unit inside one is read by nothing"
    check appImageUnsupportedServices(dist) == @["sampletool-daemon"]
    # NON-VACUITY, both directions. The distribution really does declare
    # a service, and the format that CAN carry one really does stage it
    # -- otherwise the loop above would be asserting nothing.
    check dist.services.len == 1
    resetBuildActionRegistry()
    var debStaged = false
    for p in stagedRelPaths(debPackage(dist).tree):
      if p.contains("systemd"): debStaged = true
    check debStaged

  test "the tree is ROOT-rooted, which is what makes @PREFIX@ land right":
    # An AppDir mirrors a filesystem root: ``usr/bin/<app>`` beside the
    # AppDir's own AppRun. That is what puts the §5 wrapper at
    # ``<mountpoint>/usr/bin`` and makes its run-time prefix
    # ``<mountpoint>/usr``.
    resetBuildActionRegistry()
    let artifact = appImagePackage(appImageSample())
    let paths = stagedRelPaths(artifact.tree)
    check "usr/bin/hello" in paths
    check "usr/bin/hello.real" in paths
    # The conffile lands at the AppDir's ``etc``, where nothing reads
    # it -- carried as an extractable default, which is all an AppImage
    # can do with a file that belongs to ``/etc``.
    check "etc/sampletool.conf" in paths

  test "the epoch and the architecture are graph data, not guesses":
    resetBuildActionRegistry()
    let artifact = appImagePackage(appImageSample())
    check artifact.edge.envValue("SOURCE_DATE_EPOCH") == "315532800"
    check artifact.edge.envValue("ARCH") == "x86_64"
    # One number governs every format.
    resetBuildActionRegistry()
    var dist = appImageSample()
    dist.sourceDateEpoch = 1000000000
    check appImagePackage(dist).edge.envValue("SOURCE_DATE_EPOCH") ==
      "1000000000"

  test "a non-Linux distribution is refused rather than staged":
    # §6.1 makes an unavailable format an unresolvable TOOL dependency,
    # but a Windows Distribution reaching this producer is a recipe
    # error, and the diagnostic should say which.
    resetBuildActionRegistry()
    var raised = false
    try:
      discard appImagePackage(appImageSample(toWindows))
    except ValueError as e:
      raised = true
      check e.msg.contains("AppImage producer targets Linux only")
    check raised

  test "a distribution with no public entry point is refused":
    # AppRun would exec nothing. Refusing is better than emitting a
    # script whose failure only appears when a user runs the image.
    resetBuildActionRegistry()
    var dist = appImageSample()
    dist.components = @[
      component(crHelperExecutable, "build/bin/helper")
    ]
    dist.services = @[]
    var raised = false
    try:
      discard appImagePackage(dist)
    except ValueError as e:
      raised = true
      check e.msg.contains("public entry point")
    check raised

  test "deb and AppImage from one distribution stage two trees, not one":
    # ``producers/arch.nim``'s lesson, re-asserted for the fourth
    # producer: the variant is the ACTION-ID NAMESPACE, and the engine
    # keys the action cache by id, so a collision serves one tree's
    # outputs for the other.
    resetBuildActionRegistry()
    let deb = debPackage(appImageSample())
    let img = appImagePackage(appImageSample())
    check deb.tree.idPrefix != img.tree.idPrefix
    check deb.tree.root != img.tree.root
    var ids: seq[string] = @[]
    for act in registeredBuildActions():
      doAssert act.id notin ids,
        "two edges registered the id '" & act.id &
        "'; the engine keys the action cache by id, so one tree's " &
        "outputs would be served for the other"
      ids.add(act.id)
    check ids.len > 20

  test "two builds of one distribution name the same argv":
    resetBuildActionRegistry()
    let first = argvOf(appImagePackage(appImageSample()).edge)
    resetBuildActionRegistry()
    let second = argvOf(appImagePackage(appImageSample()).edge)
    check first == second

  test "the producer is registered under the extension users type":
    resetBuildActionRegistry()
    let artifact = appImagePackage(appImageSample())
    check artifact.format == "AppImage"
    check "AppImage" in registeredProducerFormats()
    check artifact.path.endsWith("sampletool-0.2.0-1-x86_64.AppImage")
    for s in artifact.tree.stagingSelectors:
      check s in artifact.toolSelectors
