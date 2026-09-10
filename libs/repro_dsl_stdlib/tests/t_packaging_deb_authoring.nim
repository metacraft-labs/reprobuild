## The ``.deb`` producer emits an archive dpkg will actually accept.
##
## The M0 gate ends with a container installing the produced ``.deb``
## and running the binary, which is the real verification. These cases
## are the parts of "valid ``.deb``" that are cheap to check at graph
## level and expensive to diagnose from ``dpkg: error processing
## archive`` — each one is a concrete way a hand-rolled deb is rejected
## or, worse, installs and misbehaves:
##
## * a ``control`` stanza whose ``Description`` continuation lines are
##   not space-indented swallows every field after it;
## * a maintainer script that is not mode 0755 fails the install;
## * a payload whose members are owned by the building user installs
##   files owned by a uid that does not exist on the target;
## * a systemd unit shipped under the PREFIX rather than under
##   ``/lib/systemd`` is never found by systemd, and the package looks
##   installed and does nothing.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

suite "packaging: the deb producer's authoring is dpkg-shaped":

  test "the artifact is named the way apt and dpkg parse it":
    # ``<name>_<version>_<arch>.deb``, underscore-separated, Debian's
    # architecture spelling. Every repository tool parses this name, so
    # "close enough" produces a package the repo indexer files wrongly.
    let dist = sampleDistribution(toLinux)
    check debArtifactName(dist) == "sampletool_0.2.0-1_amd64.deb"
    var arm = sampleDistribution(toLinux)
    arm.architecture = "aarch64"
    check debArtifactName(arm) == "sampletool_0.2.0-1_arm64.deb"

  test "the control stanza carries the mandatory fields":
    let text = debControlText(sampleDistribution(toLinux))
    for field in ["Package: sampletool", "Version: 0.2.0-1",
                  "Architecture: amd64", "Maintainer: ", "Section: devel",
                  "Priority: optional"]:
      check text.contains(field)

  test "the Description continuation lines are space-indented":
    # deb's Description is ONE field whose continuation lines must begin
    # with a space, and a blank line must be a lone " .". A stanza that
    # gets this wrong does not fail the build; it produces a package
    # whose description renders as garbage and whose following fields
    # may be absorbed into it.
    var dist = sampleDistribution(toLinux)
    dist.metadata.summary = "One-line synopsis"
    dist.metadata.description = "First paragraph.\n\nSecond paragraph."
    let text = debControlText(dist)
    check text.contains("Description: One-line synopsis\n")
    check text.contains("\n First paragraph.\n")
    check text.contains("\n .\n")
    check text.contains("\n Second paragraph.\n")

  test "Description is the last field in the stanza":
    # Because a malformed continuation line would otherwise swallow
    # whatever follows it, the field with continuation lines goes last
    # by construction rather than by the author remembering.
    let text = debControlText(sampleDistribution(toLinux))
    let descAt = text.find("Description:")
    check descAt >= 0
    for field in ["Package:", "Version:", "Architecture:", "Maintainer:",
                  "Section:", "Priority:", "Homepage:"]:
      check text.find(field) < descAt

  test "the maintainer scripts are staged at mode 0755":
    # dpkg refuses to run a maintainer script that is not executable,
    # and ``fs.writeText`` necessarily creates its output with the
    # process umask default. This is the single most common way a
    # hand-rolled .deb is rejected at install time.
    resetBuildActionRegistry()
    discard debPackage(sampleDistribution(toLinux))
    var postinstMode = ""
    var controlMode = ""
    for act in edgesInvoking("install-file"):
      let argv = argvOf(act)
      var target = ""
      var mode = ""
      for i, value in argv:
        if value == "-m" and i + 1 < argv.len: mode = argv[i + 1]
        if value.endsWith("/DEBIAN/postinst"): target = value
        if value.endsWith("/DEBIAN/control"): controlMode = mode
      if target.len > 0: postinstMode = mode
    check postinstMode == "0755"
    check controlMode == "0644"

  test "the payload is forced to root ownership":
    # Without ``--root-owner-group`` dpkg-deb stamps the BUILDING user's
    # uid/gid into the ar members: the produced archive would depend on
    # who ran the build (fatal for a content-addressed edge) and would
    # install files owned by a uid that need not exist on the target.
    resetBuildActionRegistry()
    let artifact = debPackage(sampleDistribution(toLinux))
    let argv = argvOf(artifact.edge)
    check "--root-owner-group" in argv
    check "--build" in argv

  test "the payload compressor is pinned to one every dpkg can read":
    # dpkg's modern default is zstd, and a zstd-compressed .deb cannot
    # be installed by the dpkg in Debian 11 or Ubuntu 20.04. A packaging
    # layer's default should be the one that installs everywhere.
    resetBuildActionRegistry()
    let artifact = debPackage(sampleDistribution(toLinux))
    let argv = argvOf(artifact.edge)
    check "-Z" in argv
    check "gzip" in argv

  test "systemd units are staged root-relative, not prefix-relative":
    # systemd looks in fixed absolute locations. A unit under
    # ``/usr/lib/systemd`` reached through the package's own prefix
    # would be found; one under ``/opt/sampletool/lib/systemd`` would
    # not, and the package would install cleanly and do nothing.
    resetBuildActionRegistry()
    let artifact = debPackage(sampleDistribution(toLinux))
    let paths = stagedRelPaths(artifact.tree)
    check "lib/systemd/system/sampletool-daemon.service" in paths
    check "usr/bin/hello" in paths

  test "the unit runs the wrapper, not the unwrapped binary":
    # A service started on the real binary would run WITHOUT the §5
    # environment defaults — the exact failure §5 exists to prevent, and
    # the hardest to diagnose from a unit that otherwise looks right.
    let dist = sampleDistribution(toLinux)
    let unit = systemdUnitText(dist, dist.services[0])
    check unit.contains("ExecStart=/usr/bin/hello --serve")
    check not unit.contains("hello.real")
    check unit.contains("Environment=SAMPLETOOL_ROLE=daemon")
    check unit.contains("Restart=on-failure")
    check unit.contains("After=network.target")

  test "the maintainer scripts survive a host with no systemd":
    # Debian policy requires a maintainer script to succeed where the
    # init system is not systemd — which is also the environment the M0
    # gate installs the package in. An unguarded ``systemctl`` would
    # fail the whole ``dpkg -i``.
    let dist = sampleDistribution(toLinux)
    let postinst = debPostInstText(dist)
    check postinst.startsWith("#!/bin/sh\n")
    check postinst.contains("if [ -d /run/systemd/system ]")
    check postinst.contains("command -v systemctl")
    check debPreRmText(dist).contains("systemctl stop")

  test "a distribution with no services still gets valid scripts":
    resetBuildActionRegistry()
    let dist = sampleDistribution(toLinux, withService = false)
    let postinst = debPostInstText(dist)
    check postinst.startsWith("#!/bin/sh\n")
    check postinst.strip().endsWith("exit 0")
    check not postinst.contains("systemctl")

  test "config ships at /etc, not under the prefix":
    # POSIX configuration lives at ``/etc`` whatever the prefix is —
    # the FHS, what dpkg's conffiles mechanism assumes, and where an
    # administrator will look. A package built with ``prefix = "/usr"``
    # that shipped its config at ``/usr/etc`` would install cleanly and
    # its config would never be found. Reprobuild's own
    # ``/etc/repro/caches.conf`` (§4) is exactly this case, so M1 needs
    # the rule already right.
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.components.add(component(crConfigFile, "sampletool.conf"))
    let artifact = debPackage(dist)
    let paths = stagedRelPaths(artifact.tree)
    check "etc/sampletool.conf" in paths
    check "usr/etc/sampletool.conf" notin paths
    # The conffiles entry must be the SAME absolute path dpkg unpacked;
    # a mismatch parses fine and silently disables the protection.
    check "DEBIAN/conffiles" in paths
    check writtenText("DEBIAN-conffiles").contains("/etc/sampletool.conf")
    check not writtenText("DEBIAN-conffiles").contains("/usr/etc/")

  test "a prefix-rooted tree keeps its config under the prefix":
    # A relocatable tarball, and an MSI installed under Program Files,
    # genuinely cannot own ``/etc``. Writing outside the tree to
    # pretend otherwise would be worse than shipping it under the
    # prefix and leaving placement to whatever installs the archive.
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.components.add(component(crConfigFile, "sampletool.conf"))
    let artifact = tarballPackage(dist)
    check "etc/sampletool.conf" in stagedRelPaths(artifact.tree)
    for path in stagedRelPaths(artifact.tree):
      check not path.startsWith("..")

  test "Windows has no /etc, so config stays under the prefix":
    var win = sampleDistribution(toWindows)
    check not escapesPrefix(win, crConfigFile)
    let linux = sampleDistribution(toLinux)
    check escapesPrefix(linux, crConfigFile)
    check not escapesPrefix(linux, crExecutable)

  test "the artifact edge depends on the tree's contents, not its name":
    # Without every staged file as an input, the edge's only input would
    # be a directory NAME: a changed binary inside the tree would not
    # invalidate the .deb, and the producer would be content-addressed
    # over the wrong thing.
    resetBuildActionRegistry()
    let artifact = debPackage(sampleDistribution(toLinux))
    for f in artifact.tree.files:
      check (artifact.tree.root & "/" & f.rootRelPath) in artifact.edge.inputs

  test "two components never collide on one install path":
    # The validator refuses at the point the recipe made the mistake,
    # rather than letting one staged copy silently overwrite the other
    # and shipping a package with a binary missing.
    var dist = sampleDistribution(toLinux)
    dist.components.add(executableComponent("build/other/hello"))
    var raised = false
    try:
      dist.validate()
    except ValueError as err:
      raised = err.msg.contains("both install to")
    check raised

  test "a service naming a component that does not exist is rejected":
    var dist = sampleDistribution(toLinux)
    dist.services[0].execComponent = "not-a-binary"
    var raised = false
    try:
      dist.validate()
    except ValueError as err:
      raised = err.msg.contains("which is not an executable component")
    check raised
