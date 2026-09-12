## Reprobuild's own distribution — the values M0 left for M1.
##
## M0 put the wrapper-variable NAMES in the layer and said why it
## stopped: "M0's job is to have the list in the layer, under one name,
## so M1 supplies values for it instead of rediscovering it."
## ``reprobuild_dist`` is that supply, and these cases are what keeps it
## honest — because the failure it prevents is invisible on the build
## host. Every developer has all of them exported in their dev
## shell, so a package that shipped the wrong value, or dropped one
## entirely, works everywhere it is tested and dies on the first machine
## that is not a developer's.

import std/[strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc reprobuildSample(targetOs = toLinux): Distribution =
  ## The distribution with a plausible component set attached, so
  ## ``validate`` has something to check the services against.
  let sfx = (if targetOs == toWindows: ".exe" else: "")
  result = newReprobuildDistribution("0.1.3", targetOs,
    prefix = (if targetOs == toWindows: "" else: "/usr"))
  result.components = @[
    executableComponent("build/bin/repro" & sfx),
    component(crHelperExecutable, "build/bin/repro-standard-provider" & sfx),
    component(crConfigFile, "build/gen/caches.conf",
      installName = "caches.conf", subdir = "repro")
  ]

suite "packaging: reprobuild's own distribution":

  test "every wrapper variable is supplied, in flake order":
    # A DROPPED variable is the failure mode this case exists for, and
    # it is silent: the wrapper simply does not set it, the binary falls
    # back to whatever the environment has, and on the build host the
    # environment has it.
    let values = reprobuildWrapperValues(reprobuildSample())
    check values.len == ReprobuildWrapperVariables.len
    for i, name in ReprobuildWrapperVariables:
      check values[i][0] == name

  test "no value is a Nix store path":
    # The whole reason the values could not be copied. A store path that
    # leaked through would produce a package whose wrapper points at a
    # directory that does not exist on the target — and that still works
    # on the machine that built it.
    for (name, value) in reprobuildWrapperValues(reprobuildSample()):
      check not value.contains("/nix/store")
      check not value.startsWith("/")

  test "every path value is expanded at RUN time, not baked in":
    # One staged tree serves a .deb rooted at /usr, an .rpm and a
    # relocatable tarball the user unpacks wherever. A value that named
    # a prefix would make the tarball a tarball you can only unpack in
    # one place.
    for (name, value) in reprobuildWrapperValues(reprobuildSample()):
      if value == "1": continue
      check value.startsWith(PrefixToken)

  test "the library path is the private libdir the closure walk fills":
    let dist = reprobuildSample()
    check dist.runtime.privateLibSubdir == ReprobuildPrivateLibSubdir
    var libraryPath = ""
    for (name, value) in dist.runtime.envDefaults:
      if name == "REPROBUILD_RUNTIME_LIBRARY_PATH": libraryPath = value
    check libraryPath == PrefixToken & "/" & ReprobuildPrivateLibSubdir
    # ...and it is NOT the default ``lib``, which under prefix=/usr
    # would drop the package's private libstdc++ on top of the
    # distribution's.
    check ReprobuildPrivateLibSubdir != DefaultPrivateLibSubdir

  test "the dlopen list is non-empty and is the loader's names":
    # M0's fixture declared ``dlopenLeafNames = @[]`` and documented it
    # as a true statement about two binaries that open nothing. This is
    # the first distribution for which it is a real list: the solver's
    # clingo bindings dlopen at module-init time and the binary-cache
    # client's zstd decoder on first use, so neither appears in any
    # DT_NEEDED and the walk cannot discover either.
    let dist = reprobuildSample()
    check dist.runtime.dlopenLeafNames.len == 2
    check dist.runtime.dlopenLeafNames == reprobuildDlopenLeafNames(toLinux)
    for leaf in dist.runtime.dlopenLeafNames:
      check leaf.contains(".so")

  test "the daemon roles that have units are exactly two":
    # §4 warns "do not conflate them" and names three. The third, the shm
    # action-cache owner, was DELETED by Action-Cache-Per-Edge-Store
    # along with the control region it owned -- see the module header --
    # so what is left to pin is the shape the layer models: a helper
    # process that ships WITHOUT a unit, which is what a role that is
    # spawned by the engine rather than by a service manager needs.
    let cli = reprobuildSample()
    let cache = newReprobuildCacheDistribution("0.1.3", toLinux)
    check cli.services.len == 1
    check cli.services[0].scope == ssUser
    check cli.services[0].execComponent == "repro"
    check cache.services.len == 1
    check cache.services[0].scope == ssSystem
    check cache.services[0].execComponent == "repro-binary-cache"
    # A helper ships as an executable and names no service.
    var sawHelper = false
    for c in cli.components:
      if c.role == crHelperExecutable: sawHelper = true
    check sawHelper
    for svc in cli.services & cache.services:
      check not svc.name.contains("cache-daemon")

  test "the user daemon's unit lands where systemd looks for user units":
    let dist = reprobuildSample()
    check systemdUnitPath(dist, dist.services[0]) ==
      "lib/systemd/user/repro-daemon.service"
    let text = systemdUnitText(dist, dist.services[0])
    check text.contains("ExecStart=/usr/bin/repro daemon serve")
    check text.contains("WantedBy=default.target")

  test "neither service starts at boot, and the reasons differ":
    # A user unit cannot be enabled for users who do not exist yet; a
    # cache server that started listening on 0.0.0.0:7878 at dpkg -i
    # time would be a security decision the package is not entitled to
    # make.
    let cli = reprobuildSample()
    let cache = newReprobuildCacheDistribution("0.1.3", toLinux)
    check not cli.services[0].startAtBoot
    check not cache.services[0].startAtBoot
    # ...so the maintainer scripts enable nothing.
    check not debPostInstText(cli).contains("systemctl enable")
    check not debPostInstText(cache).contains("systemctl enable")

  test "the cache server's unit names the port the gate curls":
    let cache = newReprobuildCacheDistribution("0.1.3", toLinux)
    let text = systemdUnitText(cache, cache.services[0])
    check text.contains("0.0.0.0:" & $ReprobuildCachePort)
    check ReprobuildCachePort == 7878

  test "the cache server's arguments are in the form its parser accepts":
    # ``--root=PATH``, not ``--root PATH``: repro-binary-cache takes the
    # concat form only and answers a separated one with ``unexpected
    # positional argument``. This case cannot PROVE the parser's shape --
    # only the gate can, and it is what caught the mistake -- but it can
    # pin the answer so it does not silently regress to the form that
    # reads more naturally and does not work.
    let cache = newReprobuildCacheDistribution("0.1.3", toLinux)
    let text = systemdUnitText(cache, cache.services[0])
    check text.contains(
      "ExecStart=/usr/bin/repro-binary-cache " &
      "--root=/var/lib/repro-binary-cache --listen=0.0.0.0:7878" & "\n")
    for arg in cache.services[0].execArgs:
      check arg.startsWith("--")
      check arg.contains("=")

  test "caches.conf lands at /etc/repro/, never under the prefix":
    # ``escapesPrefix``. A package installed with prefix=/usr that
    # shipped its config at /usr/etc/repro/caches.conf would install
    # cleanly and its config would never be found or edited.
    let dist = reprobuildSample()
    var conf = DistComponent()
    for c in dist.components:
      if c.role == crConfigFile: conf = c
    check installRelPath(dist, conf) == "etc/repro/caches.conf"
    check escapesPrefix(dist, crConfigFile)
    check debConffilesText(dist).contains("/etc/repro/caches.conf")

  test "the shipped caches.conf trusts nothing":
    # A trusted-public-keys entry authorises reprobuild to install
    # anything that key signed. Shipping one would make that decision at
    # install time on the administrator's behalf.
    let text = reprobuildCachesConfText()
    check text.contains("trusted-public-keys")
    for line in text.splitLines():
      let trimmed = line.strip()
      if trimmed.len == 0: continue
      check trimmed.startsWith("#")

  test "the source root is keyed on the PRODUCT, not on the package":
    # The same source tree serves the packages that HAVE one. A value
    # keyed on ``dist.name`` would give a second reprobuild-role package
    # a source root nothing installs -- which is a different mistake
    # from the cache package's, and still worth pinning: the constant
    # says ``share/repro`` rather than ``share/<dist.name>``.
    var cliRoot = ""
    for (name, value) in reprobuildSample().runtime.envDefaults:
      if name == "REPROBUILD_SOURCE_ROOT": cliRoot = value
    check cliRoot == PrefixToken & "/share/repro/source"
    check ReprobuildSourceRootSubdir == "share/repro/source"
    check not ReprobuildSourceRootSubdir.contains(ReprobuildPackageName)

  test "the cache package sets NO wrapper variables, and that is measured":
    # M1's N9. The cache package carried the CLI's whole value list
    # because ``reprobuildWrapperValues`` was keyed on the PRODUCT.
    # Installed alone on a stock image -- a supported installation, its
    # ``Depends:`` being ``libc6`` and nothing else -- twenty of twenty
    # prefix-relative values named a path that was not there; installed
    # beside the CLI, eighteen resolved into the SIBLING's prefix and
    # two dangled anyway, being rooted at
    # ``libexec/reprobuild-binary-cache/``, which nothing creates.
    #
    # The fix is the third of the three available (ship the payload,
    # depend on ``reprobuild``, drop the variables) and it rests on a
    # measurement of the BINARY: not one of the names occurs as a
    # string in ``repro-binary-cache``, while ``repro`` carries thirteen
    # of them. That evidence is narrower than it reads and the narrowing
    # is recorded at ``reprobuildCacheWrapperValues``: "occurs as a
    # string in the binary" is the wrong test in general, because
    # fourteen of the twenty are read by ``config.nims`` and would never
    # appear as a literal anywhere. It is the right test for THIS
    # binary, which compiles nothing. The server's whole runtime environment surface
    # is ``REPRO_BINARY_CACHE_*`` plus OpenSSL's ``SSL_CERT_*``, every
    # one an operator's choice rather than a path into its own prefix.
    let cache = newReprobuildCacheDistribution("0.1.3", toLinux)
    check cache.runtime.envDefaults.len == 0
    check reprobuildCacheWrapperValues(cache).len == 0
    # ...and therefore no wrapper at all, which is what
    # ``wrapExecutables``' own contract prescribes for a distribution
    # with no env defaults. A wrapper here would resolve a prefix, set
    # nothing and exec.
    check not cache.runtime.wrapExecutables
    # The dispatch is on the ROLE, not on a flag the caller passes: ask
    # the same proc with the CLI's distribution and the full list comes
    # back, so the flake drift guard's one-list property is untouched.
    check reprobuildWrapperValues(reprobuildSample()).len ==
      ReprobuildWrapperVariables.len
    check reprobuildToolWrapperValues(cache).len ==
      ReprobuildWrapperVariables.len

  test "the cache package ships no source trees and no compiler":
    # The other half of dropping the variables: the derived component
    # list follows, so nobody has to remember not to add 38 MB of Nim
    # sources and a compiler to a package that compiles nothing.
    let cache = newReprobuildCacheDistribution("0.1.3", toLinux)
    check reprobuildShippedTreeDirs(cache).len == 0
    check reprobuildShippedTreeComponents(cache, "prebuilt/tree").len == 0
    # ...while the CLI's list is unchanged by the same code path.
    check reprobuildShippedTreeDirs(reprobuildSample()).len > 0

  test "the cache package still gets the rest of the SECT5 contract":
    # Dropping the wrapper is not dropping the contract. What makes the
    # server independently runnable on a machine that installed no other
    # reprobuild package is its own private libdir, its own vendored
    # closure and its own rewritten interpreter -- none of which the
    # wrapper ever carried.
    let cache = newReprobuildCacheDistribution("0.1.3", toLinux)
    check cache.runtime.privateLibSubdir == "lib/repro-binary-cache"
    check cache.runtime.vendorRuntimeClosure
    check cache.runtime.dlopenLeafNames == reprobuildDlopenLeafNames(toLinux)
    check cache.runtime.requireEnvDefaultPayload

  test "the two packages have distinct private libdirs":
    # Each must be independently runnable: a machine may install the
    # server without the CLI. A cache server whose RPATH pointed into
    # reprobuild's libdir would work on the builder and fail there.
    let cli = reprobuildSample()
    let cache = newReprobuildCacheDistribution("0.1.3", toLinux)
    check cli.runtime.privateLibSubdir != cache.runtime.privateLibSubdir

  test "the two packages have distinct upgrade codes":
    # Sharing one would make installing the cache server an UPGRADE of
    # the CLI on Windows, i.e. an uninstall of the thing you already had.
    let a = reprobuildSample().metadata.upgradeCode
    let b = newReprobuildCacheDistribution("0.1.3", toLinux)
      .metadata.upgradeCode
    check a.len > 0
    check b.len > 0
    check a != b

  test "the distribution validates, services and all":
    # ``validate`` refuses a service whose execComponent is not an
    # executable of the same distribution -- the failure where the
    # package installs and `systemctl start` fails on a path nobody
    # wrote.
    reprobuildSample().validate()
    var broken = reprobuildSample()
    broken.components = @[executableComponent("build/bin/not-repro")]
    var raised = false
    try:
      broken.validate()
    except ValueError as err:
      raised = true
      check err.msg.contains("repro-daemon")
    check raised

  test "a service names its component by its INSTALL name, suffix and all":
    # ``validate`` matches a service against the distribution's
    # executables by install name, and on Windows that carries ``.exe``.
    # The first Windows build of the reprobuild distribution was refused
    # with "service 'repro-daemon' names execComponent 'repro' which is
    # not an executable component of this distribution" -- which is
    # ``validate`` doing exactly its job, and the reason this is a
    # per-target function rather than a constant.
    check reprobuildUserDaemonService(toLinux).execComponent == "repro"
    check reprobuildUserDaemonService(toWindows).execComponent == "repro.exe"
    check reprobuildCacheService(toLinux).execComponent ==
      "repro-binary-cache"
    check reprobuildCacheService(toWindows).execComponent ==
      "repro-binary-cache.exe"
    var win = newReprobuildDistribution("0.1.3", toWindows, prefix = "")
    win.components = @[executableComponent("build/bin/repro.exe")]
    win.validate()

  test "the wrapper-variable NAMES still match the reprobuild derivation":
    # The drift guard one level up: ``ReprobuildWrapperVariables`` is
    # already pinned against the derivation by
    # t_packaging_wrapper_vars_match_flake, and this asserts the VALUES
    # list is keyed by exactly that list rather than by a second
    # transcription of it.
    #
    # THE FILE IS ``package.nix``, NOT ``flake.nix``, and this case is
    # why the reading of it is no longer written out here.
    # Distribution-And-Packaging M4 moved the ``--set-default`` loop into
    # the nixpkgs-format derivation; the sibling suite and
    # ``scripts/check_repo_requirements.sh`` were repointed and this case
    # was not, so it went red against a ``flake.nix`` that now mentions
    # ``--set-default`` in two comments and nowhere else -- red on a
    # contract that had not changed. Both Nim readers now go through
    # ``packaging_test_support``, so a fourth move is one edit.
    let text = packageNixText()
    let values = reprobuildWrapperValues(reprobuildSample())
    # NON-VACUITY, and it is the point rather than a nicety. What follows
    # is a ``for`` loop over a sequence and a substring search in a file:
    # an empty value list, or a derivation the extractor can no longer
    # find the loop in, would make this case pass without comparing
    # anything -- the same false green that let the missed repoint go
    # unnoticed until the suite ran. ``packageNixWrapperVariables``
    # asserts its own non-emptiness too; it is restated here because it
    # is THIS case's precondition and a reader should not have to go and
    # look somewhere else to find that out.
    check values.len > 0
    check packageNixWrapperVariables().len > 0
    for (name, _) in values:
      check text.contains("--set-default " & name & " ")

  test "the reprobuild tree stages through the ordinary layer":
    # Nothing about reprobuild's own package is a special case: the same
    # ``stageInstallTree`` that made the M0 fixture makes this one, and
    # the same producers consume it.
    resetBuildActionRegistry()
    var dist = reprobuildSample()
    # This sample carries a PLAUSIBLE component set, not the whole
    # payload -- it exists so ``validate`` has services to check against
    # -- so the env-default post-condition would (correctly) refuse it.
    # Switched off HERE, named, rather than weakened where it lives:
    # ``t_packaging_shipped_payload`` stages the real payload on disk
    # and is where that property is asserted, in both directions.
    dist.runtime.requireEnvDefaultPayload = false
    let deb = debPackage(dist)
    check deb.format == "deb"
    check deb.path.endsWith("reprobuild_0.1.3-1_amd64.deb")
    var relPaths: seq[string] = @[]
    for f in deb.tree.files:
      relPaths.add(f.rootRelPath)
    check "usr/bin/repro" in relPaths
    check "usr/bin/repro.real" in relPaths
    check "usr/libexec/reprobuild/repro-standard-provider" in relPaths
    check "etc/repro/caches.conf" in relPaths
    check "lib/systemd/user/repro-daemon.service" in relPaths
    # ...and the floor is computed for it, like any other Linux package.
    check deb.tree.glibcFloorPath.len > 0

  test "the cache package produces its own artifact":
    resetBuildActionRegistry()
    var cache = newReprobuildCacheDistribution("0.1.3", toLinux)
    cache.components = @[executableComponent("build/bin/repro-binary-cache")]
    let rpm = rpmPackage(cache)
    check rpm.path.endsWith("reprobuild-binary-cache-0.1.3-1.x86_64.rpm")
    var relPaths: seq[string] = @[]
    for f in rpm.tree.files:
      relPaths.add(f.rootRelPath)
    check "lib/systemd/system/repro-binary-cache.service" in relPaths

  test "a WINDOWS package omits the six values nothing on Windows reads":
    # M1's N3, and the shape of the answer is the same one N9 gave for
    # the cache package one axis over: a value that names nothing on the
    # machine the package lands on is worse than no value at all.
    #
    # The refusal this closes was precise and was NOT about staging:
    # with a fully staged Windows payload (7,666 files: the six
    # executables, the two DLLs, eleven source trees, reprobuild's own
    # libs and a Windows Nim toolchain) the build stopped with
    # ``crSourceTree component 'prebuilt/tree/lib/repro/include'
    # contains no files`` -- a directory that exists only because four
    # ``*_PREFIX`` variables name it.
    let win = newReprobuildDistribution("0.1.3", toWindows, prefix = "")
    var names: seq[string] = @[]
    for (name, _) in reprobuildWrapperValues(win): names.add(name)
    for omitted in reprobuildWindowsOmittedVariables():
      doAssert omitted notin names,
        "the Windows wrapper still sets '" & omitted &
        "', which nothing on Windows reads"
    check names.len == ReprobuildWrapperVariables.len -
      reprobuildWindowsOmittedVariables().len
    # ...and the LINUX list is untouched, which is what makes this a
    # target key rather than a deletion.
    let linux = newReprobuildDistribution("0.1.3", toLinux)
    var linuxNames: seq[string] = @[]
    for (name, _) in reprobuildWrapperValues(linux): linuxNames.add(name)
    check linuxNames == @ReprobuildWrapperVariables
    for omitted in reprobuildWindowsOmittedVariables():
      check omitted in linuxNames

  test "and therefore ships no private include directory on Windows":
    # The derivation doing its job: drop the four ``*_PREFIX`` values
    # and the directory they were the only reason for disappears from
    # the component list, with nobody editing a second list.
    let win = newReprobuildDistribution("0.1.3", toWindows, prefix = "")
    let dirs = reprobuildShippedTreeDirs(win)
    for d in dirs:
      check not d.endsWith("include")
    # The source trees and the bundled compiler's own two directories
    # are still there, so this is not "Windows ships nothing".
    check dirs.len > 8
    # ``bin/nim/lib`` and not ``libexec/reprobuild/nim/lib``: on Windows
    # a ``crHelperExecutable`` lands in ``bin``, and
    # ``reprobuildNimToolchainPrefixRel`` derives the toolchain root
    # from that same rule rather than spelling the POSIX answer.
    check "bin/nim/lib" in dirs
    check "bin/nim/config" in dirs
    let linuxDirs = reprobuildShippedTreeDirs(
      newReprobuildDistribution("0.1.3", toLinux))
    var linuxHasInclude = false
    for d in linuxDirs:
      if d.endsWith("include"): linuxHasInclude = true
    check linuxHasInclude
