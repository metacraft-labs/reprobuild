## The MSI producer — the structurally different second format.
##
## The M0 gate was amended to require an ``.msi`` alongside the ``.deb``
## on the reasoning that a packaging abstraction's real risk is whether
## it survives contact with a format that disagrees with the first one
## STRUCTURALLY, and that rpm-vs-deb does not test that: both unpack a
## payload rooted at ``/``, both ship systemd units as files, both carry
## POSIX modes. MSI disagrees on all three.
##
## Each case below is one of those disagreements, checked at the place
## where the abstraction would have leaked if it had been written
## against deb alone.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc wxsFor(dist: Distribution): string =
  resetBuildActionRegistry()
  let tree = stageInstallTree(dist, "msi")
  wxsText(dist, tree)

suite "packaging: the MSI producer translates the same Distribution":

  test "the install location is chosen at install time, not at build time":
    # deb's prefix is fixed when the archive is built; MSI's is a
    # Directory-table row the installer resolves. This is why
    # ``installRelPath`` is prefix-relative and never absolute — a layer
    # written against deb alone would have stored absolute paths and had
    # nothing to give WiX.
    let wxs = wxsFor(sampleDistribution(toWindows))
    check wxs.contains("<Directory Id=\"ProgramFiles64Folder\">")
    check wxs.contains("<Directory Id=\"INSTALLFOLDER\" Name=\"sampletool\">")
    # The Directory Id now carries an ALLOCATOR ORDINAL in front of the
    # path tail. It has to: `msiIdentifier`'s 72-character truncation is
    # not injective, and two directories sharing a long prefix used to
    # collapse onto one id -- which makes the renderer emit their
    # components twice. See the uniqueness cases at the end of this
    # suite.
    check wxs.contains(" Name=\"bin\">")
    var binDirId = ""
    for line in wxs.splitLines():
      let t = line.strip()
      if t.startsWith("<Directory Id=\"") and t.contains(" Name=\"bin\">"):
        binDirId = t["<Directory Id=\"".len .. ^1].split('"')[0]
    check binDirId.startsWith("dir")
    check binDirId.endsWith("_bin")

  test "every file is a Component whose key path is that file":
    # The Windows Installer's component rules key identity on the
    # component GUID plus its key path, not on a path in an archive.
    # ``Guid=\"*\"`` asks WiX to derive a STABLE GUID from that key
    # path: a hand-written GUID that changed between builds would turn
    # every upgrade into a reinstall of a different component.
    let wxs = wxsFor(sampleDistribution(toWindows))
    check wxs.contains("<Component Id=\"cmp_")
    check wxs.contains("Guid=\"*\"")
    check wxs.contains("KeyPath=\"yes\"")
    check wxs.contains("hello-real.exe")
    check wxs.contains("hello.cmd")

  test "the service is registered through the SCM, not shipped as a file":
    # The whole point of the pairing. systemd reads a unit FILE the
    # package ships; the SCM has no file and is WRITTEN TO by the
    # installer. ``ServiceDef`` has to be renderable into both, and if
    # it carried anything systemd-shaped this is where it would show.
    let wxs = wxsFor(sampleDistribution(toWindows))
    check wxs.contains("<ServiceInstall Id=\"Svc_sampletool_daemon\"")
    check wxs.contains("Name=\"sampletool-daemon\"")
    check wxs.contains("DisplayName=\"Sample Tool Daemon\"")
    check wxs.contains("<ServiceControl Id=\"Svc_sampletool_daemon_ctl\"")
    check wxs.contains("Remove=\"uninstall\"")
    # No unit file anywhere in the Windows tree.
    resetBuildActionRegistry()
    let tree = stageInstallTree(sampleDistribution(toWindows), "msi")
    for path in stagedRelPaths(tree):
      check not path.contains("systemd")

  test "a service that does not start at boot is Start=demand":
    let wxs = wxsFor(sampleDistribution(toWindows))
    check wxs.contains("Start=\"demand\"")
    var booting = sampleDistribution(toWindows)
    booting.services[0].startAtBoot = true
    check wxsFor(booting).contains("Start=\"auto\"")

  test "the installer only STARTS a service the recipe wanted started":
    # ``ServiceControl Start="install"`` makes the install wait
    # synchronously on the SCM, and an executable that does not report
    # SERVICE_RUNNING makes the installer roll the WHOLE INSTALL BACK.
    # Starting a demand-start service would be wrong on its own terms;
    # that it also turns "registered but idle" into "the package will
    # not install" is what makes it worth a case of its own.
    let idle = wxsFor(sampleDistribution(toWindows))
    check idle.contains("<ServiceControl Id=\"Svc_sampletool_daemon_ctl\"")
    check not idle.contains("Start=\"install\"")
    # Stop and Remove are unconditional: an uninstall must take the
    # service away whether or not the install started it.
    check idle.contains("Stop=\"both\" Remove=\"uninstall\"")
    var booting = sampleDistribution(toWindows)
    booting.services[0].startAtBoot = true
    check wxsFor(booting).contains("Start=\"install\"")

  test "a restart policy is authored as util:ServiceConfig, not the core one":
    # This is a finding, not a preference. The core ``ServiceConfig``
    # element is the MSI 5.0 ``MsiServiceConfig`` table — DelayedAutoStart,
    # PreShutdownDelay, ServiceSid — and has no failure-action attributes
    # at all; candle rejects them with CNDL0004/CNDL0044. Service
    # RECOVERY is ``ChangeServiceConfig2(SERVICE_CONFIG_FAILURE_ACTIONS)``,
    # which Windows Installer never exposed as a table, so WiX
    # implements it as a custom action in WixUtilExtension. The first
    # draft of this producer used the core element and did not compile.
    let withRestart = wxsFor(sampleDistribution(toWindows))
    check withRestart.contains("<util:ServiceConfig ")
    check withRestart.contains("FirstFailureActionType=\"restart\"")
    # The xmlns and the ``-ext`` on BOTH tools have to agree with the
    # authoring: a .wxs declaring the namespace that candle was not
    # given the extension for fails to compile, and one that light was
    # not given it for fails to link on an unresolved custom action.
    check withRestart.contains(
      "xmlns:util=\"http://schemas.microsoft.com/wix/UtilExtension\"")
    check needsUtilExtension(sampleDistribution(toWindows))
    var plain = sampleDistribution(toWindows)
    plain.services[0].restartOnFailure = false
    let noRestart = wxsFor(plain)
    check not noRestart.contains("util:")
    check not needsUtilExtension(plain)

  test "the installer-version floor is not raised for a recovery policy":
    # A custom action imposes no InstallerVersion requirement, so
    # raising the floor would refuse to install on older Windows for a
    # requirement that does not exist.
    check wxsFor(sampleDistribution(toWindows)).contains(
      "InstallerVersion=\"200\"")

  test "service environment defaults go to the SCM's registry value":
    # The §5 env-default contract for a SERVICE cannot go through the
    # .cmd wrapper: the SCM must be pointed at a real executable. The
    # documented mechanism is a REG_MULTI_SZ ``Environment`` value under
    # the service's own key, which the SCM reads when it starts the
    # process. This is the Windows arm of the same requirement.
    let wxs = wxsFor(sampleDistribution(toWindows))
    check wxs.contains("Name=\"Environment\" Type=\"multiString\"")
    check wxs.contains(
      "<MultiStringValue>SAMPLETOOL_ROLE=daemon</MultiStringValue>")

  test "per-user services are dropped, not silently substituted":
    # The Windows SCM has no per-user services. The nearest equivalents
    # (a Run key, a scheduled task) are different mechanisms with
    # different lifetimes, and substituting one would ship a package
    # that installs something other than what the recipe asked for.
    var dist = sampleDistribution(toWindows)
    dist.services[0].scope = ssUser
    check msiServiceRows(dist).len == 0
    check droppedUserServices(dist) == @["sampletool-daemon"]
    let wxs = wxsFor(dist)
    check not wxs.contains("<ServiceInstall")

  test "the product version drops the packaging release":
    # Windows Installer IGNORES ProductVersion's fourth field when
    # comparing versions, so a packaging revision cannot live there:
    # two builds differing only in ``release`` would be
    # indistinguishable to the upgrade logic. It stays in the file name,
    # where nothing reinterprets it.
    var dist = sampleDistribution(toWindows)
    dist.release = "7"
    check msiProductVersion(dist) == "0.2.0"
    check msiArtifactName(dist) == "sampletool-0.2.0-7-x64.msi"
    var short = sampleDistribution(toWindows)
    short.version = "1.4"
    check msiProductVersion(short) == "1.4.0"
    var long = sampleDistribution(toWindows)
    long.version = "1.2.3.4"
    check msiProductVersion(long) == "1.2.3"

  test "the MSI adds its own bin directory to PATH":
    # Unlike a deb, which installs into a directory already on PATH, an
    # MSI installs into a product directory that is not. §6's table
    # calls out "service + PATH" for this arm specifically.
    let wxs = wxsFor(sampleDistribution(toWindows))
    check wxs.contains("<Environment Id=\"PathEntry\" Name=\"PATH\"")
    # The bin directory's own allocator-assigned id, read back rather
    # than spelled: it carries an ordinal now (see the uniqueness cases).
    var binId = ""
    for line in wxs.splitLines():
      let t = line.strip()
      if t.startsWith("<Directory Id=\"") and t.contains(" Name=\"bin\">"):
        binId = t["<Directory Id=\"".len .. ^1].split('"')[0]
    check binId.len > 0
    check wxs.contains("Value=\"[" & binId & "]\"")
    check wxs.contains("Part=\"last\"")
    check wxs.contains("System=\"yes\"")

  test "a missing UpgradeCode is refused rather than invented":
    # The UpgradeCode is what makes two releases an upgrade rather than
    # two side-by-side installs. It must be constant across versions and
    # unique to the product, so an auto-derived one would either be
    # unstable (breaking upgrades) or collide with another product of
    # the same name. Refusing, with an explanation, is the only correct
    # behaviour.
    var dist = sampleDistribution(toWindows)
    dist.metadata.upgradeCode = ""
    resetBuildActionRegistry()
    let tree = stageInstallTree(dist, "msi")
    var message = ""
    try:
      discard wxsText(dist, tree)
    except ValueError as err:
      message = err.msg
    check message.contains("requires metadata.upgradeCode")
    check message.contains("CONSTANT across every version")

  test "XML metacharacters in metadata are escaped":
    # A maintainer name containing ``&`` is not exotic, and unescaped it
    # makes candle fail with an XML parse error about a generated file
    # the recipe author never wrote.
    var dist = sampleDistribution(toWindows)
    dist.metadata.vendor = "Smith & Sons <\"Ltd\">"
    let wxs = wxsFor(dist)
    check wxs.contains("Smith &amp; Sons &lt;&quot;Ltd&quot;&gt;")
    check not wxs.contains("Smith & Sons")

  test "the two WiX steps are separate edges with the right ordering":
    resetBuildActionRegistry()
    let artifact = msiPackage(sampleDistribution(toWindows))
    check artifact.format == "msi"
    check artifact.path.endsWith("sampletool-0.2.0-1-x64.msi")
    let candles = edgesInvoking("wix-candle")
    check candles.len == 1
    check candles[0].outputs[0].endsWith(".wixobj")
    check candles[0].outputs[0] in artifact.edge.inputs
    let argv = argvOf(artifact.edge)
    # ICE validation runs the database through the local Windows
    # Installer service, which is host state the engine can neither see
    # nor fingerprint. It is a verification step against the artifact,
    # not a step in producing it.
    check "-sval" in argv

  test "the MSI tree is rooted at the prefix, not at the filesystem root":
    resetBuildActionRegistry()
    let tree = stageInstallTree(sampleDistribution(toWindows), "msi")
    let paths = stagedRelPaths(tree)
    check "bin/hello-real.exe" in paths
    for path in paths:
      check not path.startsWith("usr/")

  test "identifiers are unique even when paths share a long prefix":
    # FOUND BY THE FIRST WINDOWS BUILD WITH A REAL PAYLOAD. `msiIdentifier`
    # truncates at 72 characters and truncation is not injective, so two
    # deep directories sharing a long prefix collapsed onto ONE
    # `Directory Id` -- and `renderDirTree` emits a node's component list
    # per node, so the SAME components were emitted twice and `light`
    # stopped with hundreds of `Duplicate symbol 'File:fil_...'`.
    #
    # The case is built from paths whose first ninety characters agree,
    # which is what the real payload's `runquota/build/nimcache/...` tree
    # looked like.
    resetBuildActionRegistry()
    var dist = sampleDistribution(toWindows)
    let deep = "share/repro/src/runquota/build/nimcache/" &
      "t_observation_store_retention_crash"
    for leaf in ["alpha", "beta", "gamma"]:
      dist.components.add(component(crDataFile,
        "build/gen/" & leaf & ".c",
        subdir = deep & "/" & leaf,
        installName = "types.nim.c"))
      dist.components.add(component(crDataFile,
        "build/gen/" & leaf & "2.c",
        subdir = deep & "/" & leaf,
        installName = "writer.nim.c"))
    let text = wxsFor(dist)
    check text.len > 0
    var fileIds: seq[string] = @[]
    var dirIdList: seq[string] = @[]
    for line in text.splitLines():
      let t = line.strip()
      if t.startsWith("<File Id=\""):
        fileIds.add(t["<File Id=\"".len .. ^1].split('"')[0])
      elif t.startsWith("<Directory Id=\""):
        dirIdList.add(t["<Directory Id=\"".len .. ^1].split('"')[0])
    # Non-vacuity: the scan found the rows it is about to assert over,
    # and the tree really is deep enough to trip the old truncation.
    check fileIds.len >= 6
    check dirIdList.len >= 6
    var seenFile: seq[string] = @[]
    for id in fileIds:
      doAssert id notin seenFile,
        "two <File> rows share the identifier '" & id &
        "'; MSI identifiers are 72 characters and truncation is not " &
        "injective"
      doAssert id.len <= 72, "identifier over the MSI limit: " & id
      seenFile.add(id)
    var seenDir: seq[string] = @[]
    for id in dirIdList:
      doAssert id notin seenDir,
        "two <Directory> rows share the identifier '" & id &
        "'; every component under either would then be emitted twice"
      doAssert id.len <= 72, "identifier over the MSI limit: " & id
      seenDir.add(id)
    # ...and the distinguishing part of the path is what SURVIVES the
    # truncation, so a WiX error names a row a human can find.
    var sawLeaf = false
    for id in fileIds:
      if id.contains("types.nim.c") or id.contains("writer.nim.c"):
        sawLeaf = true
    check sawLeaf

  test "the ordinal identifier is injective and stays inside the limit":
    # The helper on its own, over the exact shape that broke: a common
    # 90-character prefix and a one-character difference at the end.
    let base = "share/repro/src/runquota/build/nimcache/" &
      "t_observation_store_retention_crash/very/deeply/nested/"
    var ids: seq[string] = @[]
    for i in 0 ..< 50:
      let id = msiOrdinalIdentifier("dir", i, base & "leaf" & $i)
      check id.len <= 72
      check id.startsWith("dir" & $i & "_")
      doAssert id notin ids, "collision at ordinal " & $i & ": " & id
      ids.add(id)
    # The OLD rule, shown failing on the same input, so the case is not
    # asserting a property the previous code also had.
    var old: seq[string] = @[]
    var collided = false
    for i in 0 ..< 50:
      let id = msiIdentifier("dir_" & base & "leaf" & $i)
      if id in old: collided = true
      old.add(id)
    check collided
