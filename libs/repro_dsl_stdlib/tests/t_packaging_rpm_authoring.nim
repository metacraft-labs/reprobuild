## The ``.rpm`` producer emits a spec rpmbuild will accept and a package
## rpm will install.
##
## M1's gate ends with ``rpm -i`` on a clean Fedora image, running the
## binaries and ``rpm -e``, which is the real verification. These cases
## are the parts of "valid rpm" that are cheap to check at graph level
## and expensive to diagnose from ``error: Installed (but unpackaged)
## file(s) found`` — each one is a concrete way a hand-rolled spec is
## rejected or, worse, produces a package that installs and misbehaves:
##
## * rpm STRIPS every ELF file in the buildroot unless
##   ``%__os_install_post`` is silenced, which would rewrite the exact
##   binaries the closure walk had just patched;
## * rpm's default ``%__spec_install_pre`` begins ``rm -rf
##   "$RPM_BUILD_ROOT"``, i.e. it deletes the staged tree before
##   packaging it;
## * the automatic dependency generator emits a ``Requires:`` per
##   vendored ``.so``, none of which any repository publishes;
## * a relative ``--buildroot`` is not resolved against the CWD, it is
##   given a leading slash, and the build fails naming a path nobody
##   wrote;
## * ``%preun`` fires on an UPGRADE as well as a removal, so a scriptlet
##   that stops the service unconditionally takes the daemon down and
##   leaves it down.
##
## ## Why rpm is a real second Linux format and not deb with dots
##
## M0 paired deb with MSI precisely because rpm-vs-deb agrees with deb
## on all three axes the abstraction could leak along, and that
## reasoning still holds — this producer is short for the same reason
## the deb one is. What it does exercise, and what nothing before it
## did, is the case where a format's METADATA lives outside the payload
## tree: ``addGeneratedIntermediate`` exists because a ``.spec`` inside
## the buildroot is either an unpackaged-file error or a file that
## ships, and neither is acceptable.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc reassembleSubstitutionScript(script: string): string =
  ## Rebuild the text a ``substitutionScript`` program will write, by
  ## reading its ``printf`` pieces back.
  ##
  ## Deliberately NOT a line scan. The pieces are POSIX single-quoted
  ## literals and the text they carry contains newlines, so a
  ## per-line ``startsWith`` matches the first line of a piece and
  ## silently drops the rest — which is exactly how the first version
  ## of this helper reported an empty spec for a spec that was there.
  const Quote = '\x27'
  const Backslash = '\x5C'
  const Marker = "printf '%s' "
  var i = 0
  while true:
    let at = script.find(Marker, i)
    if at < 0: break
    var j = at + Marker.len
    if j < script.len and script[j] == Quote:
      inc j
      while j < script.len:
        if script[j] == Quote:
          # ``'\''`` is a literal quote, anything else ends the literal.
          if j + 2 < script.len and script[j + 1] == Backslash and
              script[j + 2] == Quote:
            result.add(Quote)
            j += 3
            if j < script.len and script[j] == Quote: inc j
          else:
            inc j
            break
        else:
          result.add(script[j])
          inc j
    elif script.continuesWith("\"$SUBST", j):
      # The spliced value, put back as the token it stands for.
      result.add(GlibcFloorToken)
      j = script.find('\n', j)
      if j < 0: j = script.len
    i = j

proc stagedTextOf(act: BuildActionDef): string =
  ## The text an aux-file edge will actually write, reconstructed from
  ## the edge rather than by re-calling the renderer.
  ##
  ## Reading the EDGE is what makes these cases tests of the staging
  ## path: a spec that rendered correctly and was staged in the wrong
  ## place, or for the wrong distribution, would still pass a direct
  ## call to ``rpmSpecText``. Without a floor the edge is a plain
  ## ``writeText``; with one it is the ``sh`` program that assembles the
  ## same text, so the literal pieces are re-joined here and the spliced
  ## value is put back as its token.
  for arg in act.call.arguments:
    if arg.name == "text": return arg.encodedValue
  for arg in act.call.arguments:
    if arg.name == "command":
      return reassembleSubstitutionScript(arg.encodedValue)
  ""

proc specTextOf(dist: Distribution): string =
  resetBuildActionRegistry()
  discard rpmPackage(dist)
  for act in registeredBuildActions():
    if act.id.contains("gen-aux"): return stagedTextOf(act)
  ""

proc rpmEdge(): BuildActionDef =
  for act in registeredBuildActions():
    if act.call.packageName == "rpmbuild": return act
  BuildActionDef()

suite "packaging: the rpm producer's authoring is rpmbuild-shaped":

  test "the artifact is named the way dnf and createrepo parse it":
    # ``<name>-<version>-<release>.<arch>.rpm`` — dots where deb uses
    # underscores, and rpm's architecture spelling.
    let dist = sampleDistribution(toLinux)
    check rpmArtifactName(dist) == "sampletool-0.2.0-1.x86_64.rpm"
    var arm = sampleDistribution(toLinux)
    arm.architecture = "aarch64"
    check rpmArtifactName(arm) == "sampletool-0.2.0-1.aarch64.rpm"

  test "the spec carries the mandatory preamble fields":
    let text = specTextOf(sampleDistribution(toLinux))
    for field in ["Name:           sampletool", "Version:        0.2.0",
                  "Release:        1", "Summary:        ",
                  "License:        MIT", "BuildArch:      x86_64"]:
      check text.contains(field)

  test "rpm is told not to post-process a payload it did not build":
    # The sharpest of the overrides. rpm's default
    # ``%__os_install_post`` STRIPS every ELF file in the buildroot —
    # after the closure walk has patched the RPATHs and the interpreter,
    # and after the artifact edge's inputs were hashed. Left on, the
    # .rpm would ship a payload no other format's package contains and
    # "one Distribution, N artifacts, one tree" would be quietly false.
    let text = specTextOf(sampleDistribution(toLinux))
    check text.contains("%global __os_install_post %{nil}")
    check text.contains("%global debug_package %{nil}")
    check text.contains("%global _build_id_links none")

  test "rpm is told not to delete the buildroot it was handed":
    # The default ``%__spec_install_pre`` begins ``rm -rf
    # "$RPM_BUILD_ROOT"`` because rpm assumes it filled the buildroot
    # itself in ``%install``. Here the buildroot IS the staged tree,
    # produced by other edges; rpm deleting it would be one edge eating
    # another's outputs.
    let text = specTextOf(sampleDistribution(toLinux))
    check text.contains("%global __spec_install_pre %{___build_pre}")
    # And there is no %install section at all to trigger it.
    check not text.contains("\n%install\n")
    check not text.contains("\n%build\n")
    check not text.contains("\n%prep\n")

  test "the automatic dependency generator is off":
    # It would emit ``Requires: libblake3.so.0()(64bit)`` for every
    # VENDORED library — shipped inside this very package, so either
    # self-satisfied noise or an unsatisfiable dependency on something
    # no repository publishes. The package's one real external
    # requirement is the C library, at the floor the interpreter rewrite
    # binds it to.
    let text = specTextOf(sampleDistribution(toLinux))
    check text.contains("AutoReqProv:    no")

  test "the payload compressor is the one every rpm can read":
    # Same reasoning as the deb producer's gzip default: a
    # zstd-compressed payload cannot be read by the rpm in RHEL 8 or
    # SLES 15, and a packaging layer's default should install
    # everywhere rather than compress best.
    resetBuildActionRegistry()
    discard rpmPackage(sampleDistribution(toLinux))
    check "_binary_payload w9.gzdio" in argvOf(rpmEdge())

  test "the header is reproducible, which takes four knobs and not one":
    # Measured rather than assumed: with only SOURCE_DATE_EPOCH set, two
    # otherwise identical builds still differ, because BUILDTIME is
    # wall-clock and BUILDHOST is gethostname().
    resetBuildActionRegistry()
    discard rpmPackage(sampleDistribution(toLinux))
    let argv = argvOf(rpmEdge())
    check "_buildhost reprobuild" in argv
    check "use_source_date_epoch_as_buildtime 1" in argv
    check "source_date_epoch_from_changelog 0" in argv
    check "build_mtime_policy clamp_to_source_date_epoch" in argv

  test "every _topdir-derived path is named, so none defaults to $HOME":
    # rpm derives some of them from ``_topdir`` and not others; a
    # default that leaked would write into ``$HOME/rpmbuild`` — both
    # non-hermetic and outside the edge's declared output scope.
    resetBuildActionRegistry()
    discard rpmPackage(sampleDistribution(toLinux))
    let argv = argvOf(rpmEdge())
    for macroName in ["_topdir", "_builddir", "_buildrootdir", "_sourcedir",
                      "_specdir", "_srcrpmdir", "_tmppath", "_rpmdir",
                      "_rpmfilename"]:
      var found = false
      for a in argv:
        if a.startsWith(macroName & " "): found = true
      check found

  test "every rpm path is made absolute at ACTION time, not graph time":
    # rpm 4.20 does not resolve a relative ``--buildroot`` against the
    # CWD; it prepends a slash and then fails naming a path nobody
    # wrote. Baking ``getCurrentDir()`` in at graph time would fix that
    # and break content-addressing, because the lowered graph — and
    # every cache key derived from it — would become a function of where
    # the checkout lives.
    resetBuildActionRegistry()
    discard rpmPackage(sampleDistribution(toLinux))
    let argv = argvOf(rpmEdge())
    var buildRootIdx = -1
    for i, a in argv:
      if a == "--buildroot": buildRootIdx = i
    check buildRootIdx >= 0
    check argv[buildRootIdx + 1].startsWith(AbsolutePathMacro & "/")
    for a in argv:
      if a.startsWith("_topdir ") or a.startsWith("_rpmdir "):
        check a.contains(AbsolutePathMacro & "/")
    # And nothing in the graph names this machine.
    for a in argv:
      check not a.contains(":/")
      check not a.startsWith("/")

  test "the spec lives BESIDE the tree, never inside it":
    # Anything inside the buildroot that ``%files`` does not list is an
    # unpackaged-file error; anything it does list ships. A spec is
    # neither.
    resetBuildActionRegistry()
    let artifact = rpmPackage(sampleDistribution(toLinux))
    for f in artifact.tree.files:
      check not f.rootRelPath.contains(".spec")
    var specPath = ""
    for p in artifact.tree.producerExtraInputs:
      if p.endsWith(".spec"): specPath = p
    check specPath.len > 0
    check specPath.startsWith(artifact.tree.genRoot & "/")
    check not specPath.startsWith(artifact.tree.root & "/")
    # ...and the artifact edge still depends on it, so a spec whose
    # Requires changed rebuilds the package even though no staged file
    # moved.
    check specPath in artifact.edge.inputs

  test "%files lists every staged file plus the private libdir":
    # The staged files are graph-time known; the VENDORED set is not, so
    # it contributes a glob rpm expands against the buildroot at package
    # time, plus a ``%dir`` so the package OWNS the directory and an
    # uninstall takes it away.
    resetBuildActionRegistry()
    let artifact = rpmPackage(sampleDistribution(toLinux))
    let entries = rpmFilesSection(sampleDistribution(toLinux), artifact.tree)
    check "/usr/bin/hello" in entries
    check "/usr/bin/adder" in entries
    check "%dir /usr/lib/sampletool" in entries
    check "/usr/lib/sampletool/*" in entries
    check "/lib/systemd/system/sampletool-daemon.service" in entries

  test "%files owns every directory the package creates, and no other":
    # dpkg removes the directories it made when they empty; rpm removes
    # only what ``%files`` NAMES. The first ``rpm -e`` of the reprobuild
    # package left ``/usr/libexec/reprobuild`` standing while the
    # identical ``dpkg -r`` took it away.
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.components.add(component(crHelperExecutable, "build/bin/helper"))
    dist.components.add(component(crConfigFile, "build/etc/sampletool.conf"))
    let artifact = rpmPackage(dist)
    let entries = rpmFilesSection(dist, artifact.tree)
    check "%dir /usr/libexec/sampletool" in entries
    check "%dir /usr/lib/sampletool" in entries
    # ...and NOT the directories the target owns. Claiming /usr/bin would
    # apply this package's mode and ownership to it and ask rpm to remove
    # a directory every other package is using.
    for shared in ["%dir /usr", "%dir /usr/bin", "%dir /usr/lib",
                   "%dir /usr/libexec", "%dir /etc", "%dir /lib",
                   "%dir /lib/systemd", "%dir /lib/systemd/system"]:
      check shared notin entries

  test "nothing under the private libdir is also listed by name":
    # rpmbuild rejects a file listed twice outright, and a declared
    # ``crRuntimeLibrary`` component lands in exactly the directory the
    # glob covers.
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.components.add(runtimeLibraryComponent("build/lib/libsample.so"))
    let artifact = rpmPackage(dist)
    let entries = rpmFilesSection(dist, artifact.tree)
    check "/usr/lib/sampletool/libsample.so" notin entries
    check "/usr/lib/sampletool/*" in entries

  test "a config file is %config(noreplace), not a plain file":
    # rpm's answer to dpkg's ``conffiles``. Without it an upgrade
    # silently overwrites an admin's edits — the same defect the deb
    # producer's conffiles list exists to avoid, in rpm's spelling.
    resetBuildActionRegistry()
    var dist = sampleDistribution(toLinux)
    dist.components.add(component(crConfigFile, "build/etc/sampletool.conf"))
    let artifact = rpmPackage(dist)
    let entries = rpmFilesSection(dist, artifact.tree)
    var found = false
    for e in entries:
      if e.startsWith("%config(noreplace) ") and e.endsWith("sampletool.conf"):
        found = true
    check found

  test "the scriptlets use rpm's argument convention, not deb's":
    # rpm's ``$1`` counts INSTANCES, deb's names an ACTION, and the
    # difference is not cosmetic: ``%preun`` fires during an upgrade
    # too, so an unconditional stop takes the daemon down and leaves it
    # down.
    let dist = sampleDistribution(toLinux)
    let post = rpmPostText(dist)
    let preun = rpmPreUnText(dist)
    check preun.contains("if [ \"$1\" = \"0\" ]")
    check preun.contains("systemctl stop sampletool-daemon.service")
    check preun.contains("systemctl disable sampletool-daemon.service")
    # This fixture is startAtBoot=false, so %post enables nothing --
    # which is what the fixture asks for and what the deb postinst does.
    check not post.contains("systemctl enable")
    check post.contains("daemon-reload")

  test "an enabled service is enabled on install and not on upgrade":
    var dist = sampleDistribution(toLinux)
    dist.services[0].startAtBoot = true
    let post = rpmPostText(dist)
    check post.contains("if [ \"$1\" = \"1\" ]")
    check post.contains("systemctl enable sampletool-daemon.service")

  test "the scriptlets are guarded on systemd actually running":
    # Without ``/run/systemd/system`` there is no systemd, and inside a
    # container systemctl would either fail or talk to the host's.
    let dist = sampleDistribution(toLinux)
    for text in [rpmPostText(dist), rpmPreUnText(dist), rpmPostUnText(dist)]:
      check text.contains("[ -d /run/systemd/system ]") or text == "/bin/true\n"

  test "a distribution with no services emits inert scriptlets":
    let dist = sampleDistribution(toLinux, withService = false)
    check rpmPostText(dist) == "/bin/true\n"
    check rpmPreUnText(dist) == "/bin/true\n"
    let text = specTextOf(dist)
    check not text.contains("\n%post\n")
    check not text.contains("\n%preun\n")

  test "%description is never empty, which rpmbuild rejects":
    var dist = sampleDistribution(toLinux)
    dist.metadata.description = ""
    dist.metadata.summary = ""
    let text = specTextOf(dist)
    let afterDesc = text[text.find("%description") + "%description\n".len .. ^1]
    check afterDesc.strip().len > 0

  test "the changelog is present and EMPTY":
    # rpmbuild wants the section; a synthesised entry would carry a
    # DATE, and a date is the one thing a reproducible package must not
    # invent.
    let text = specTextOf(sampleDistribution(toLinux))
    check text.contains("%changelog")
    check text.strip().endsWith("%changelog")

  test "the producer declares rpmbuild plus every staging tool":
    resetBuildActionRegistry()
    let artifact = rpmPackage(sampleDistribution(toLinux))
    check artifact.format == "rpm"
    check RpmbuildSelector in artifact.toolSelectors
    for staging in [PatchelfSelector, InstallSelector, ShSelector,
                    ReadelfSelector]:
      check staging in artifact.toolSelectors

  test "the producer is discoverable through the registry like any other":
    check hasProducer("rpm")
    check "rpm" in registeredProducerFormats()
    resetBuildActionRegistry()
    let viaRegistry = produce("rpm", sampleDistribution(toLinux))
    check viaRegistry.format == "rpm"
    check viaRegistry.path.endsWith("sampletool-0.2.0-1.x86_64.rpm")

  test "rpm and deb stage two trees, not one":
    # The deb tree carries a ``DEBIAN/`` directory that must not appear
    # in the rpm payload, and the two producers' per-file edges would
    # otherwise be handed the same action ids — a collision the engine
    # resolves by serving one tree's outputs for the other.
    resetBuildActionRegistry()
    let dist = sampleDistribution(toLinux)
    let deb = debPackage(dist)
    let rpm = rpmPackage(dist)
    check deb.tree.root != rpm.tree.root
    check deb.tree.idPrefix != rpm.tree.idPrefix
    var ids: seq[string] = @[]
    for act in registeredBuildActions():
      check act.id notin ids
      ids.add(act.id)
    var debHasControl = false
    for f in deb.tree.files:
      if f.rootRelPath.startsWith("DEBIAN/"): debHasControl = true
    check debHasControl
    for f in rpm.tree.files:
      check not f.rootRelPath.startsWith("DEBIAN/")
