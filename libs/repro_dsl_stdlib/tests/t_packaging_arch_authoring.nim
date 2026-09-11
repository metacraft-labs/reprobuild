## The Arch producer emits an archive pacman will actually accept.
##
## No Arch host is packaging anything yet, so these cases carry more
## weight than the deb suite's equivalents do — there is no container
## run behind them to catch what they miss. They are written against the
## two things that make an Arch package different from a tarball, both
## of which are silent failures rather than loud ones:
##
## * ``tar -c .`` records ``./.PKGINFO`` and libalpm matches the literal
##   ``.PKGINFO``, so the package installs nothing and pacman reports
##   metadata it cannot find inside an archive that demonstrably has it;
## * ``size`` is a MEASUREMENT of a tree whose largest part (the
##   vendored runtime closure) is discovered at build time, so a
##   plausible constant would be a number pacman believes and acts on.
##
## Both are asserted through the EDGES the producer registered rather
## than by re-calling the renderers, because the failure in each case is
## a producer that renders correctly and wires it wrongly.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc archSample(targetOs = toLinux): Distribution =
  result = sampleDistribution(targetOs)
  result.components.add(component(crConfigFile, "build/gen/sampletool.conf",
    installName = "sampletool.conf"))
  result.metadata.archDepends = @["sh"]

proc tarArgvOf(artifact: PackagedArtifact): seq[string] =
  argvOf(artifact.edge)

suite "packaging: the Arch producer's authoring is pacman-shaped":

  test "the artifact is named the way pacman and repo-add parse it":
    # ``<pkgname>-<pkgver>-<pkgrel>-<arch>.pkg.tar.gz``. The ``pkgrel``
    # segment is what distinguishes a rebuild from a new version, and a
    # name that folded it into the version would make every rebuild look
    # like an upgrade to the same tooling that reads the file name.
    let dist = archSample()
    check archArtifactName(dist) ==
      "sampletool-0.2.0-1-x86_64.pkg.tar.gz"
    var arm = archSample()
    arm.architecture = "aarch64"
    check archArtifactName(arm) == "sampletool-0.2.0-1-aarch64.pkg.tar.gz"
    var arm32 = archSample()
    arm32.architecture = "armv7l"
    # Arch has no soft-float ARM port; the ``h`` is part of the name.
    check archArchitecture(arm32) == "armv7h"

  test "the architecture spelling is Arch's, not Debian's":
    var dist = archSample()
    dist.architecture = "x86_64"
    check archArchitecture(dist) == "x86_64"
    check debArchitecture(dist) == "amd64"
    dist.architecture = "aarch64"
    check archArchitecture(dist) == "aarch64"
    check debArchitecture(dist) == "arm64"

  test "the PKGINFO carries the fields libalpm reads":
    let text = archPkgInfoText(archSample())
    for field in ["pkgname = sampletool", "pkgbase = sampletool",
                  "pkgver = 0.2.0-1", "pkgdesc = ", "arch = x86_64",
                  "license = MIT", "url = "]:
      check text.contains(field)
    # ``builddate`` is the reproducibility epoch and NOT the wall clock.
    # makepkg writes ``date +%s`` there, which is exactly the ambient
    # input that makes two builds of one tree differ.
    check text.contains("builddate = " & $archSample().sourceDateEpoch)
    check not text.contains("builddate = 0\n")

  test "size is a TOKEN in the authored text, never a number":
    # The whole point of TRAP 2. If this text ever carries a literal
    # number, that number was invented at graph time — before the
    # vendored closure, which dominates it, existed.
    let text = archPkgInfoText(archSample())
    check text.contains("size = " & InstalledSizeToken & "\n")
    for line in text.splitLines():
      if not line.startsWith("size = "): continue
      let value = line["size = ".len .. ^1]
      check value == InstalledSizeToken
      # ...and it is not merely non-numeric: it is the token the
      # substitution step knows, so a renamed token fails here rather
      # than shipping a `.PKGINFO` whose size pacman reads as zero.
      check value.startsWith("@") and value.endsWith("@")

  test "the size is MEASURED by an edge over the finished tree":
    # The producer wires a script edge whose output is the value file
    # the substitution reads. Asserted through the registry rather than
    # by calling the renderer, because a producer that generated the
    # script and never attached it would pass a text-only check and ship
    # a package whose size field never got filled in.
    resetBuildActionRegistry()
    let artifact = archPackage(archSample())
    var sizeEdges = 0
    var sizeScript = ""
    for act in registeredBuildActions():
      if act.id.endsWith("installed-size"):
        inc sizeEdges
        for arg in act.call.arguments:
          if arg.encodedValue.contains("wc -c"):
            sizeScript = arg.encodedValue
    check sizeEdges == 1
    check sizeScript.len > 0
    # It walks the STAGED TREE, not the source, and it counts regular
    # files only.
    check sizeScript.contains(artifact.tree.root)
    check sizeScript.contains("-type f")
    # EVERY WAY IT CAN FAIL TO MEASURE IS A HARD ERROR, and this is the
    # case that pins that. The first Arch package built by this producer
    # said ``size = 0`` and exited 0, because ``find`` was not on the
    # action's PATH: the pipeline's head printed ``command not found``,
    # ``wc -c`` counted nothing, and ``set -e`` does not fire inside a
    # pipeline inside a command substitution. pacman acts on that
    # number.
    check sizeScript.contains("command -v find")
    check sizeScript.contains("refusing to report an installed size of 0")
    check sizeScript.contains("refusing to publish it")
    check not sizeScript.contains("${bytes:-0}")
    # ...and the tool it needs is DECLARED, which is the other half.
    # findutils is not the coreutils that ``install`` brings.
    var sizeEdgeId = ""
    for act in registeredBuildActions():
      if act.id.endsWith("installed-size"): sizeEdgeId = act.id
    check sizeEdgeId.len > 0
    check ArchFindSelector in artifact.toolSelectors
    check ArchShSelector in artifact.toolSelectors

  test "the PKGINFO is written by the substitution edge, not writeText":
    # The wiring that makes the token disappear. A ``.PKGINFO`` produced
    # by a plain ``writeText`` would ship the literal ``@INSTALLED_SIZE@``
    # — which pacman does not reject; it parses it as zero.
    resetBuildActionRegistry()
    discard archPackage(archSample())
    var substScripts: seq[string] = @[]
    var plainWrites = 0
    for act in registeredBuildActions():
      if act.id.contains("gen-subst--PKGINFO"):
        for arg in act.call.arguments:
          if arg.name == "script" or arg.encodedValue.contains("printf"):
            substScripts.add(arg.encodedValue)
      if act.id.contains("gen-text--PKGINFO"):
        inc plainWrites
    check plainWrites == 0
    check substScripts.len == 1
    # The script splits the text on the token and re-assembles it around
    # a value read from a file, so the token cannot survive.
    check not substScripts[0].contains(InstalledSizeToken)
    check substScripts[0].contains("installed-size.txt")

  test "the archive names .PKGINFO FIRST and never a bare dot":
    # TRAP 1, and the one case in this suite that a container run would
    # have caught. ``tar -c .`` writes ``./.PKGINFO``; libalpm compares
    # the entry name against the literal ``.PKGINFO``.
    resetBuildActionRegistry()
    let artifact = archPackage(archSample())
    let argv = tarArgvOf(artifact)
    check "-c" in argv
    check "-z" in argv
    # The positional members, in order. ``.`` must not be among them and
    # ``.PKGINFO`` must be the first.
    var members: seq[string] = @[]
    var seenDirFlag = false
    for i, a in argv:
      if a == "-C": seenDirFlag = true
      if a.startsWith("-") or a == artifact.tree.root or
          a == artifact.path:
        continue
      if seenDirFlag and (a == "usr" or a == "etc" or a == "lib" or
          a.startsWith(".")):
        members.add(a)
    check members.len > 0
    check members[0] == ".PKGINFO"
    check "." notin members
    for m in members:
      check not m.startsWith("./")

  test "every top-level directory of the tree is archived":
    # The other half of naming members explicitly: naming them means
    # forgetting one is possible, so the list is DERIVED from the staged
    # files rather than written down.
    resetBuildActionRegistry()
    let artifact = archPackage(archSample())
    let tops = archTopLevelMembers(artifact.tree)
    check "usr" in tops
    check "etc" in tops
    check ".PKGINFO" in tops
    # ...and NOT ``lib``. On Arch that is a symlink to ``usr/lib`` owned
    # by the ``filesystem`` package, and an archive containing a ``lib/``
    # directory stops the transaction with ``/lib exists in filesystem``.
    # Measured on archlinux:latest with this producer's first package.
    check "lib" notin tops
    # ...and nothing is staged whose top-level segment is missing.
    for f in artifact.tree.files:
      let cut = f.rootRelPath.find('/')
      let top = if cut > 0: f.rootRelPath[0 ..< cut] else: f.rootRelPath
      check top in tops

  test "backup entries are tree-relative, and name the conffiles":
    # pacman stores ``backup`` paths without a leading slash. An entry
    # that began with ``/`` matches no file and silently disables the
    # very protection it asks for — the same trap deb's ``conffiles``
    # has in the opposite direction, where the slash is required.
    let text = archPkgInfoText(archSample())
    var backups: seq[string] = @[]
    for line in text.splitLines():
      if line.startsWith("backup = "): backups.add(line["backup = ".len .. ^1])
    check backups == @["etc/sampletool.conf"]
    for b in backups:
      check not b.startsWith("/")

  test "the dependency spelling is pacman's, and differs from the other two":
    # One fact, three vocabularies, three named metadata fields. A layer
    # that abstracted them into one list would be inventing a
    # cross-distro dependency ontology.
    var dist = archSample()
    dist.metadata.debDepends = @["libc6-dev"]
    dist.metadata.rpmRequires = @["glibc-devel"]
    let archDeps = archDependFields(dist, withGlibcFloor = true)
    check archDeps[0] == "glibc>=" & GlibcFloorToken
    check not archDeps[0].contains(" ")
    check not archDeps[0].contains("(")
    check "sh" in archDeps
    check debDependsFields(dist, withGlibcFloor = true)[0] ==
      "libc6 (>= " & GlibcFloorToken & ")"

  test "the produced tree is the root-relative one, with no DEBIAN dir":
    # Arch reuses the deb STAGING VARIANT because an Arch payload is
    # also rooted at ``/``. What it must not inherit is deb's control
    # area, which the deb PRODUCER adds and staging does not.
    resetBuildActionRegistry()
    let artifact = archPackage(archSample())
    let paths = stagedRelPaths(artifact.tree)
    check "usr/bin/hello" in paths
    check ".PKGINFO" in paths
    for p in paths:
      check not p.startsWith("DEBIAN/")
    # The unit is at the ``usr/lib`` spelling here and at the ``lib``
    # spelling in the deb tree. Same directory on a merged-usr system,
    # and only one of the two is a path pacman will accept.
    check "usr/lib/systemd/system/sampletool-daemon.service" in paths
    check "lib/systemd/system/sampletool-daemon.service" notin paths
    resetBuildActionRegistry()
    let deb = debPackage(archSample())
    check "lib/systemd/system/sampletool-daemon.service" in
      stagedRelPaths(deb.tree)

  test "the producer is registered under the name pacman uses":
    resetBuildActionRegistry()
    let artifact = archPackage(archSample())
    check artifact.format == "pkg.tar.gz"
    check artifact.path.endsWith("sampletool-0.2.0-1-x86_64.pkg.tar.gz")
    # §6 rule 2: the edge takes a real build-graph dependency on its
    # tools, and the staging half is read off the tree rather than
    # transcribed.
    check "tar" in artifact.toolSelectors
    check "gzip" in artifact.toolSelectors
    check "sh" in artifact.toolSelectors
    for s in artifact.tree.stagingSelectors:
      check s in artifact.toolSelectors

  test "deb and Arch from one distribution stage two trees, not one":
    # FOUND BY BUILDING IT. The Arch producer first reused the ``deb``
    # staging variant, on the reasoning that the two trees are
    # structurally identical -- both rooted at ``/`` -- and staging's
    # only format-shaped decision is that root. They ARE identical, and
    # sharing them still broke: the variant is also the action-id
    # namespace, so a recipe producing both registered two edges named
    # ``pkg-deb-<name>-rpath-bin-<binary>`` and the build stopped with
    # ``duplicate graph node id``. Worse than stopping would have been
    # not stopping: the engine keys the action cache by id, so a
    # collision serves one tree's outputs for the other and the wrong
    # bytes get packaged.
    resetBuildActionRegistry()
    let deb = debPackage(archSample())
    let arch = archPackage(archSample())
    check deb.tree.idPrefix != arch.tree.idPrefix
    check deb.tree.root != arch.tree.root
    var ids: seq[string] = @[]
    for act in registeredBuildActions():
      doAssert act.id notin ids,
        "two edges registered the id '" & act.id &
        "'; the engine keys the action cache by id, so one tree's " &
        "outputs would be served for the other"
      ids.add(act.id)
    # Non-vacuity: both producers really did register edges.
    check ids.len > 20

  test "the patchelf edge is ordered after the directory it writes into":
    # FOUND BY BUILDING IT, SECOND TIME. ``patchelf --output <path>``
    # does not create ``<path>``'s parent and reports ``patchelf: open:
    # No such file or directory``, naming neither. Every tree until now
    # also had a ``writeText`` into the same genRoot -- the §5 wrapper,
    # or a control file -- and ``fs.writeText`` creates parents, so the
    # directory existed whenever the scheduler ran that edge first.
    #
    # A race won by luck. It lost for the first distribution whose only
    # genRoot writer was patchelf: ``wrapExecutables = false``, so no
    # wrapper text, and the Arch tree stopped the build while its deb
    # and rpm trees -- identical in every other way -- passed.
    resetBuildActionRegistry()
    var unwrapped = archSample()
    unwrapped.runtime.wrapExecutables = false
    let artifact = archPackage(unwrapped)
    var genRootId = ""
    var rpathEdges = 0
    for act in registeredBuildActions():
      if act.id.endsWith("gen-root"): genRootId = act.id
      if act.id.contains("rpath-bin-"): inc rpathEdges
    check genRootId.len > 0
    check rpathEdges > 0
    # Every rpath edge names it as a predecessor, not merely some of
    # them.
    for act in registeredBuildActions():
      if not act.id.contains("rpath-bin-"): continue
      doAssert genRootId in act.deps,
        "the patchelf edge '" & act.id & "' is not ordered after '" &
        genRootId & "'; its --output directory would exist only by luck"
    check artifact.tree.genRoot.endsWith("gen-arch")

  test "two builds of one distribution name the same bytes":
    # Everything ambient is pinned: member order (explicit + --sort=name
    # inside each), timestamps (--mtime from the one epoch field),
    # ownership (0/0 numeric). Without these the archive would differ
    # run to run and "content-addressed edge" would be true of the edge
    # and false of anything observable.
    resetBuildActionRegistry()
    let first = tarArgvOf(archPackage(archSample()))
    resetBuildActionRegistry()
    let second = tarArgvOf(archPackage(archSample()))
    check first == second
    check "--sort=name" in first
    check "--numeric-owner" in first
    check "--owner=0" in first
    check "--group=0" in first
    check "--mtime=@" & $archSample().sourceDateEpoch in first
