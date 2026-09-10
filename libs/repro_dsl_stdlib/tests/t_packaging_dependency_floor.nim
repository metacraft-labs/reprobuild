## The two properties that make a produced package a function of the
## GRAPH rather than of the shell and the host it was built on.
##
## M0 recorded both as residuals and both are here:
##
## **R7 — the deb producer had an undeclared environment input.** M0's
## gate says "producers are content-addressed build edges (rebuild is
## cache-hit-identical)". The ``.deb``'s bytes were a function of the
## ambient ``SOURCE_DATE_EPOCH``, which ``producers/deb.nim`` neither
## set nor declared, so dpkg-deb inherited whatever the caller had.
## Inside ``nix develop`` that is 315532800 and three passes never saw
## it; unset, the archive takes wall-clock mtimes and differs run to
## run. The archive was reproducible because of the SHELL rather than
## because of the graph — the same failure in kind as letting the
## builder's installed packages decide a package's CONTENTS, which the
## system/private rule exists to forbid.
##
## **R1 — the glibc floor was not expressed.** Rewriting ``PT_INTERP``
## binds the package to the TARGET's C library, so a target whose glibc
## is older than the builder's installs the package cleanly and cannot
## start it: measured on Ubuntu 22.04 (glibc 2.35) against a builder on
## 2.40, ``libc.so.6: version 'GLIBC_2.38' not found``, required by the
## VENDORED libtbb and libstdc++ rather than by the payload. Expressing
## "I need glibc >= X" is what ``Depends:``/``Requires:`` are for.
##
## ## What these cases can and cannot see
##
## The floor's VALUE is measured inside an action, so no unit case can
## assert it — that is the end-to-end gate's job. What is checkable here
## is everything around it: that the edge exists, that it names the tool
## that reads ``.gnu.version_r``, that the token reaches each format's
## own dependency grammar, that the splice is wired to the file the walk
## writes, and that switching the floor off removes all of it rather
## than leaving a half-configured edge behind.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc edgesWithIdSuffix(suffix: string): seq[BuildActionDef] =
  for act in registeredBuildActions():
    if act.id.endsWith(suffix): result.add(act)

proc closureScriptOf(act: BuildActionDef): string =
  for arg in act.call.arguments:
    if arg.name == "command": return arg.encodedValue
  ""

proc envOf(act: BuildActionDef): seq[(string, string)] =
  for reg in registeredBuildActions():
    if reg.id == act.id: return reg.env
  @[]

proc envValue(act: BuildActionDef; name: string): string =
  for (n, v) in envOf(act):
    if n == name: return v
  ""

suite "packaging: the timestamp is graph data, not shell state":

  test "the deb edge SETS SOURCE_DATE_EPOCH rather than inheriting it":
    # The whole of R7. ``extraEnv`` lands in ``BuildActionDef.env``, is
    # keyed into the action's fingerprint, and is layered OVER the
    # inherited environment at launch -- so a caller's value is
    # overridden rather than consulted.
    resetBuildActionRegistry()
    let artifact = debPackage(sampleDistribution(toLinux))
    check artifact.edge.envValue("SOURCE_DATE_EPOCH") == "315532800"

  test "the rpm edge does too, for the same reason":
    # rpm reads SOURCE_DATE_EPOCH from the environment exactly as
    # dpkg-deb does and has no argv equivalent either. Measured: with it
    # varying and everything else fixed, the .rpm's bytes move.
    resetBuildActionRegistry()
    let artifact = rpmPackage(sampleDistribution(toLinux))
    check artifact.edge.envValue("SOURCE_DATE_EPOCH") == "315532800"

  test "the tarball takes its mtime from the same field":
    # tar was never the producer with the hole -- it always passed its
    # own ``--mtime``, which is why the .tar.gz reproduced across the
    # epochs that moved the .deb. The point of reading the field is that
    # ONE number governs every format, so the field is not a
    # deb-specific setting wearing a general name.
    resetBuildActionRegistry()
    let artifact = tarballPackage(sampleDistribution(toLinux))
    check "--mtime=@315532800" in argvOf(artifact.edge)

  test "a recipe can move the epoch and every format follows":
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.sourceDateEpoch = 1000000000
    let deb = debPackage(dist)
    let rpm = rpmPackage(dist)
    let tar = tarballPackage(dist)
    check deb.edge.envValue("SOURCE_DATE_EPOCH") == "1000000000"
    check rpm.edge.envValue("SOURCE_DATE_EPOCH") == "1000000000"
    check "--mtime=@1000000000" in argvOf(tar.edge)

  test "the vendored libraries are pinned to that epoch too":
    # dpkg-deb CLAMPS member mtimes to SOURCE_DATE_EPOCH rather than
    # setting them, so a file left at an older timestamp keeps its own
    # -- deterministic, but a second answer to a question the layer now
    # has one field for.
    resetBuildActionRegistry()
    discard stageInstallTree(sampleDistribution(toLinux), "deb")
    let script = closureScriptOf(edgesWithIdSuffix("runtime-closure")[0])
    check script.contains("EPOCH='315532800'")
    check script.contains("touch -d @\"$EPOCH\"")

  test "epoch zero is REFUSED, because it looks right and is not":
    # The one value that reads as "epoch start, maximally
    # deterministic" and reproduces the bug: dpkg-deb clamps, so at zero
    # nothing is older and every staged file keeps the wall-clock mtime
    # the build gave it.
    var dist = sampleDistribution(toLinux)
    dist.sourceDateEpoch = 0
    var raised = false
    try:
      dist.validate()
    except ValueError as err:
      raised = true
      check err.msg.contains("sourceDateEpoch")
    check raised

suite "packaging: the C-library floor is computed and expressed":

  test "the closure edge writes a floor file and names readelf":
    resetBuildActionRegistry()
    let tree = stageInstallTree(sampleDistribution(toLinux), "deb")
    check tree.glibcFloorPath.endsWith("deb-glibc-floor.txt")
    let edge = edgesWithIdSuffix("runtime-closure")[0]
    check tree.glibcFloorPath in edge.outputs
    var refs: seq[string] = @[]
    for act in registeredBuildActions():
      if act.id == edge.id: refs = act.toolIdentityRefs
    check ReadelfSelector in refs

  test "the floor is read from .gnu.version_r, not from DT_NEEDED":
    # The reason this needed a new tool at all. patchelf edits DT_*
    # entries; the version requirements live in a different section it
    # has no reader for.
    resetBuildActionRegistry()
    discard stageInstallTree(sampleDistribution(toLinux), "deb")
    let script = closureScriptOf(edgesWithIdSuffix("runtime-closure")[0])
    check script.contains("readelf -V -W")
    check script.contains("Name: GLIBC_")

  test "the floor covers the vendored closure, not only the payload":
    # On the M0 fixture the payload asks for 2.34 and the VENDORED
    # libtbb and libstdc++ ask for 2.38, so a floor that scanned only
    # the components would be wrong by exactly the amount that made the
    # package fail on Ubuntu 22.04. ``$seen`` is the seeds plus
    # everything vendored -- a system library the walk resolved and left
    # to the target is never pushed onto it.
    resetBuildActionRegistry()
    discard stageInstallTree(sampleDistribution(toLinux), "deb")
    let script = closureScriptOf(edgesWithIdSuffix("runtime-closure")[0])
    check script.contains("for floor_obj in $seen")

  test "an empty result fails the build rather than emitting a blank":
    # ``Depends: libc6 (>= )`` is a stanza dpkg rejects in the good case
    # and reads as an UNVERSIONED dependency in the bad one -- which is
    # exactly the "installs cleanly, cannot start" failure the floor
    # exists to stop.
    resetBuildActionRegistry()
    discard stageInstallTree(sampleDistribution(toLinux), "deb")
    let script = closureScriptOf(edgesWithIdSuffix("runtime-closure")[0])
    check script.contains("no GLIBC_x.y version reference found")

  test "deb says it in Debian's vocabulary":
    resetBuildActionRegistry()
    discard debPackage(sampleDistribution(toLinux))
    let control = writtenText("DEBIAN-control")
    # ``writtenText`` reads ``writeText`` edges; with a substitution the
    # control file is written by an ``sh`` edge instead, so read that.
    let substEdges = edgesWithIdSuffix("gen-subst-DEBIAN-control")
    check substEdges.len == 1
    let script = closureScriptOf(substEdges[0])
    check control.len == 0
    check script.contains("Depends: libc6 (>= ")
    check script.contains("glibc-floor.txt")

  test "rpm says the same fact in rpm's vocabulary":
    resetBuildActionRegistry()
    discard rpmPackage(sampleDistribution(toLinux))
    let substEdges = edgesWithIdSuffix("gen-aux-subst-rpm-spec-spec")
    check substEdges.len == 1
    let script = closureScriptOf(substEdges[0])
    check script.contains("Requires:       glibc >= ")
    check script.contains("glibc-floor.txt")

  test "the token itself never reaches the assembled file":
    # The splice is done by SPLITTING the text at graph time and
    # re-assembling it with printf, so the token appears in the
    # generator's source and in no piece the generator emits.
    resetBuildActionRegistry()
    discard debPackage(sampleDistribution(toLinux))
    let script = closureScriptOf(
      edgesWithIdSuffix("gen-subst-DEBIAN-control")[0])
    for line in script.splitLines():
      if line.strip().startsWith("printf '%s' '"):
        check not line.contains(GlibcFloorToken)

  test "the floor file is a declared INPUT of the edge that splices it":
    # Without this the control stanza would not be rewritten when a
    # vendored library grew a newer symbol version -- the floor would go
    # stale silently, which is worse than not having one.
    resetBuildActionRegistry()
    let tree = stageInstallTree(sampleDistribution(toLinux), "deb")
    discard debPackage(sampleDistribution(toLinux))
    var found = false
    for act in registeredBuildActions():
      if act.id.endsWith("gen-subst-DEBIAN-control"):
        for i in act.inputs:
          if i.endsWith("glibc-floor.txt"): found = true
    check found
    check tree.glibcFloorPath.len > 0

  test "switching the floor off removes the edge's tool and the field":
    # Not a half-configured edge: no readelf on the walk, no floor file,
    # no token in the stanza, and no ``sh`` substitution edge either.
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.runtime.computeDependencyFloor = false
    let artifact = debPackage(dist)
    check artifact.tree.glibcFloorPath.len == 0
    check edgesWithIdSuffix("gen-subst-DEBIAN-control").len == 0
    let control = writtenText("DEBIAN-control")
    check control.len > 0
    check not control.contains(GlibcFloorToken)
    check not control.contains("Depends:")
    var refs: seq[string] = @[]
    for act in registeredBuildActions():
      if act.id.endsWith("runtime-closure"): refs = act.toolIdentityRefs
    check ReadelfSelector notin refs

  test "a distribution that vendors nothing computes no floor":
    # Three conditions, each real: ELF, a closure to scan, and the
    # recipe's consent. Without the walk there is no edge to compute it
    # on and no vendored set for it to be about.
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.runtime.vendorRuntimeClosure = false
    check not dist.computesDependencyFloor()
    let artifact = debPackage(dist)
    check artifact.tree.glibcFloorPath.len == 0

  test "Windows stages neither a walk nor a floor":
    resetBuildActionRegistry()
    let dist = sampleDistribution(toWindows)
    check not dist.computesDependencyFloor()
    let tree = stageInstallTree(dist, "msi")
    check tree.glibcFloorPath.len == 0
    check ReadelfSelector notin tree.stagingSelectors

  test "the recipe's own Depends entries survive beside the floor":
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.metadata.debDepends = @["adduser", "ca-certificates"]
    let text = debControlText(dist, withGlibcFloor = true)
    check text.contains(
      "Depends: libc6 (>= " & GlibcFloorToken & "), adduser, ca-certificates")

  test "and rpm's do too":
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.metadata.rpmRequires = @["shadow-utils"]
    let reqs = rpmRequiresFields(dist, withGlibcFloor = true)
    check reqs == @["glibc >= " & GlibcFloorToken, "shadow-utils"]

suite "packaging: the substitution mechanism itself":

  test "a token is replaced at every occurrence, not only the first":
    let script = substitutionScript(
      "A@X@B@X@C", "out.txt", @[("@X@", "value.txt")])
    var printfCount = 0
    for line in script.splitLines():
      if line.strip().startsWith("printf '%s' \"$SUBST0\""): inc printfCount
    check printfCount == 2

  test "text with no token still writes the file verbatim":
    let script = substitutionScript(
      "no tokens here", "out.txt", @[("@X@", "value.txt")])
    check script.contains("printf '%s' 'no tokens here'")

  test "an empty value file is a named failure, not an empty splice":
    # A floor file the walk failed to write would otherwise produce
    # ``Depends: libc6 (>= )`` silently.
    let script = substitutionScript("A@X@B", "out.txt", @[("@X@", "v.txt")])
    check script.contains("substitution value file")
    check script.contains("exit 1")

  test "single quotes in the text survive the shell round trip":
    let script = substitutionScript(
      "it's a @X@ thing", "out.txt", @[("@X@", "v.txt")])
    check script.contains("'it'\\''s a '")
