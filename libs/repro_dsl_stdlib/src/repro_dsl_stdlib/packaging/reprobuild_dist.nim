## Reprobuild's OWN distribution definition — the values behind
## ``runtime_contract.ReprobuildWrapperVariables``, the three daemon
## roles, and ``/etc/repro/caches.conf``.
##
## M0 put the twenty wrapper-variable NAMES in the layer and said in so
## many words why it stopped there: "It lives here as data rather than
## being spelled into a producer because M1 is the milestone that
## packages reprobuild; M0's job is to have the list in the layer, under
## one name, so M1 supplies values for it instead of rediscovering it."
## This module is that supply.
##
## ## Why the VALUES could not simply be copied from the flake
##
## Every one of them is a ``/nix/store`` path in the flake, and a native
## package has no store. The flake's ``postFixup`` loop reads
##
## ```nix
##   --set-default XXHASH_PREFIX ${pkgs.xxHash}
##   --set-default IO_MON_SRC ${io-mon-src}/src
## ```
##
## and both right-hand sides are absolute paths into a directory that
## does not exist on a Debian box. A native package's answer to the same
## question is a path inside ITS OWN prefix — which is not known at
## build time either, because the same staged tree serves a ``.deb``
## rooted at ``/usr``, a ``.rpm`` rooted wherever ``--prefix`` said, and
## a relocatable tarball the user unpacks in ``/opt/whatever``. That is
## exactly what ``runtime_contract.PrefixToken`` exists for: the wrapper
## expands ``@PREFIX@`` at RUN time against its own location, so one
## tree gives the right answer in every one of those places.
##
## So the mapping is not a transcription, it is a translation, and it
## splits the twenty names into four kinds:
##
## 1. **The library path** — the private libdir the closure walk fills.
## 2. **Library PREFIXES** (``BLAKE3_PREFIX``, ``SQLITE_PREFIX``,
##    ``XXHASH_PREFIX``, ``CLINGO_PREFIX``). In the flake these point at
##    whole nixpkgs outputs with ``lib/`` and ``include/`` inside. In a
##    native package the vendored libraries are all in one private
##    libdir, so all four point at the same place: the package's own
##    prefix.
## 3. **SOURCE trees** (``*_SRC``, ``REPROBUILD_SOURCE_ROOT``). These
##    are not a convenience — reprobuild compiles providers and
##    interface artifacts IN THE CALLER'S PROJECT, after installation,
##    so the sources have to be on the target machine. They land under
##    a single ``share/repro/src/<name>`` tree, one directory per
##    sibling input, mirroring what the flake's per-input store paths
##    do.
##
##    **The VALUES are here; the PAYLOAD is not.** This module names
##    where each source tree goes, and a package that ships them will
##    put them there — but the recipe has to add the components, and
##    doing that means bringing TWELVE sibling checkouts into the build
##    graph as inputs (the eleven in the block below plus
##    ``RUNQUOTA_SRC``), and ``REPROBUILD_SOURCE_ROOT`` — which is a
##    reprobuild checkout, at ``share/repro/source``, NOT one of the
##    ``share/repro/src/<name>`` trees — on top of them. Until it does,
##    an installed package answers ``repro --version``, runs its daemon
##    and serves its cache, and CANNOT BUILD ANYTHING AT ALL: the FIRST
##    edge of every ``repro build``, for any recipe including an empty
##    one, is the interface-extraction edge that compiles the recipe
##    against these sources, and it looks for
##    ``$REPROBUILD_SOURCE_ROOT/build/lib/librepro_monitor_shim.so``
##    before it gets that far. That is a real gap and it is named
##    rather than papered over; see the milestone's residual list.
## 4. **Two that are neither** — ``REPROBUILD_USE_SYSTEM_HASH_LIBS``,
##    which is the literal ``1`` in both worlds, and
##    ``REPROBUILD_NIX_DAEMON_BIN``, which is already
##    ``$out/libexec/...`` in the flake and becomes the same
##    prefix-relative path here.
##
## ## The three daemon roles, and why only two get units
##
## §4's table names three roles and warns "do not conflate them":
##
## | role | transport | scope | unit |
## |---|---|---|---|
## | ``repro-cache-daemon`` | POSIX shm, no port | per action-cache root | **none** |
## | ``repro daemon serve`` | unix socket | per-USER | systemd *user* unit |
## | ``repro-binary-cache`` | HTTP ``:7878`` | system | systemd *system* unit |
##
## The first has no unit ON PURPOSE and that is the interesting one: it
## is auto-spawned by the engine per action-cache root and self-reaps,
## so a service manager starting one would be starting a second owner of
## a single-writer resource. It ships as a plain ``crHelperExecutable``.
##
## (``reprobuild-nix-daemon`` is a fourth helper and is not a daemon
## ROLE at all; it is the ``tool-provisioning=nix`` bridge, and it is a
## SCRIPT rather than an ELF image, which is why ``crHelperScript``
## exists — see that role's note.)
## A packaging layer that assumed "daemon implies unit" would have got
## this wrong in a way that looks fine until two builds run at once.
##
## The other two differ in SCOPE, which the layer already models
## (``ServiceScope``) and which the deb/rpm producers already render to
## different unit directories (``lib/systemd/user`` vs
## ``lib/systemd/system``). Neither is enabled at boot by the package:
## a user daemon cannot be enabled for users who do not exist yet, and
## a cache server that started listening on ``0.0.0.0:7878`` the moment
## it was installed would be a security decision the package is not
## entitled to make.

import ./types
import ./runtime_contract

const
  ReprobuildPackageName* = "reprobuild"
  ReprobuildCachePackageName* = "reprobuild-binary-cache"
    ## §3's split: the ``repro`` CLI + runtime + helpers in one package,
    ## the network cache SERVER in another. Split because the server is
    ## the thing that opens a port and wants a system service, and a
    ## developer laptop should be able to install the CLI without
    ## acquiring either.

  ReprobuildPrivateLibSubdir* = "lib/repro"
    ## Where the vendored runtime closure lands, prefix-relative.
    ## NOT the default ``lib``: a package whose private closure went
    ## straight into ``<prefix>/lib`` would put its own copies of
    ## libstdc++ and libgcc_s on top of the distribution's when the
    ## prefix is ``/usr``.

  ReprobuildSourceSubdir* = "share/repro/src"
    ## The parent of the per-input source trees the ``*_SRC`` variables
    ## point at.

  ReprobuildCachePort* = 7878
    ## §3: the network cache server's default listen port, and the one
    ## M1's gate curls for ``/healthz``.

proc reprobuildWrapperValues*(dist: Distribution): seq[(string, string)] =
  ## The twenty ``ReprobuildWrapperVariables``, with values, in the
  ## flake's declaration order.
  ##
  ## Order matters only for reviewability — ``envDefaults`` is a set as
  ## far as the wrapper is concerned — but keeping it means this list
  ## can be read side by side with ``flake.nix``'s ``wrapProgram`` loop,
  ## which is the only way to see at a glance that nothing was dropped.
  ## ``t_packaging_reprobuild_dist`` asserts the two lists have the same
  ## names in the same order, so the review is mechanised as well.
  let p = PrefixToken
  let src = p & "/" & ReprobuildSourceSubdir
  @[
    ("REPROBUILD_RUNTIME_LIBRARY_PATH", p & "/" & ReprobuildPrivateLibSubdir),
    # ``share/repro/...`` rather than ``share/<dist.name>/...``: the
    # SAME tree serves the ``reprobuild`` and ``reprobuild-binary-cache``
    # packages, and a value keyed on the package name would give the
    # cache server a source root nothing ever installs.
    ("REPROBUILD_SOURCE_ROOT", p & "/share/repro/source"),
    # The four library prefixes. One answer for all of them, because the
    # vendored closure is one directory -- see the header.
    ("BLAKE3_PREFIX", p),
    ("NIMCRYPTO_SRC", src & "/nimcrypto"),
    ("BEARSSL_SRC", src & "/bearssl"),
    ("STACKABLE_HOOKS_SRC", src & "/nim-stackable-hooks/src"),
    ("CODETRACER_TRACE_FORMAT_NIM_SRC", src & "/codetracer-trace-format-nim"),
    ("IO_MON_SRC", src & "/io-mon/src"),
    ("SHM_GSET_SRC", src & "/nim-shm-gset/src"),
    ("SHM_QUEUE_SRC", src & "/nim-shm-queue/src"),
    ("CODETRACER_PINNED_SRC", src & "/codetracer/src"),
    ("REPRO_CT_TEST_RUNNER_SRC", src & "/reprobuild-ct-test-runner"),
    ("REPRO_TEST_ADAPTERS_SRC", src & "/reprobuild-test-adapters/src"),
    ("CT_INTERPOSE_SRC", src & "/ct-interpose"),
    # Literal in both worlds.
    ("REPROBUILD_USE_SYSTEM_HASH_LIBS", "1"),
    # ``$out/libexec/...`` in the flake; the same shape here, with the
    # layer's own helper-executable directory.
    ("REPROBUILD_NIX_DAEMON_BIN",
     p & "/libexec/" & dist.name & "/reprobuild-nix-daemon"),
    ("RUNQUOTA_SRC", src & "/runquota"),
    ("SQLITE_PREFIX", p),
    ("XXHASH_PREFIX", p),
    ("CLINGO_PREFIX", p)
  ]

proc reprobuildCachesConfText*(): string =
  ## ``/etc/repro/caches.conf`` — §4's client trust configuration.
  ##
  ## Shipped with every cache COMMENTED OUT, which is the only defensible
  ## default: a ``trusted-public-keys`` entry is an authorisation to
  ## execute whatever that key signs, and a package that installed one
  ## on the user's behalf would be making a trust decision at
  ## ``dpkg -i`` time. The file exists anyway, and is a ``conffile`` /
  ## ``%config(noreplace)``, so an administrator who edits it keeps the
  ## edit across upgrades — which is the whole reason to ship an empty
  ## one rather than to document a path and create nothing.
  result = """# Reprobuild client cache trust configuration.
#
# Each [cache.<name>] section names a binary cache this machine is
# willing to SUBSTITUTE from, the public keys whose signatures it will
# accept for that cache's manifests, and a priority (lower is tried
# first). A cache with no trusted key is never substituted from.
#
# Adding a key here authorises reprobuild to install anything that key
# has signed, so the shipped file deliberately trusts nothing.
#
# [cache.example]
# url = "https://cache.example.invalid"
# priority = 10
# trusted-public-keys = ["example-1:BASE64=="]
"""

proc reprobuildUserDaemonService*(targetOs: TargetOs): ServiceDef =
  ## §4's second role: ``repro daemon serve`` over a unix socket,
  ## PER-USER.
  ##
  ## ``ssUser`` rather than ``ssSystem``, and the distinction is load
  ## bearing rather than stylistic: the daemon owns per-user build
  ## sessions, leases and a store under ``~/.cache/repro``, so one
  ## system-wide instance would either run as the wrong user or need a
  ## privilege model the daemon does not have. The unit therefore lands
  ## in ``lib/systemd/user`` and the package does not enable it — a
  ## package cannot enable a user unit for users who do not exist yet.
  ## M1's gate starts it explicitly and asks ``repro daemon status``.
  ServiceDef(
    name: "repro-daemon",
    displayName: "Reprobuild build daemon",
    description: "Reprobuild per-user build, watch and lease daemon",
    scope: ssUser,
    # The component's INSTALL NAME, which carries the platform's
    # executable suffix. ``validate`` matches a service against the
    # distribution's executables by that name and refuses a mismatch --
    # and it caught this one: the first Windows build of the reprobuild
    # distribution stopped with "service 'repro-daemon' names
    # execComponent 'repro' which is not an executable component of this
    # distribution". A refusal, rather than a package whose service
    # points at a file that is not there.
    execComponent: "repro" & (if targetOs == toWindows: ".exe" else: ""),
    execArgs: @["daemon", "serve"],
    startAtBoot: false,
    restartOnFailure: true,
    after: @[])

proc reprobuildCacheService*(targetOs: TargetOs): ServiceDef =
  ## §4's third role: the network binary-cache SERVER, system scope.
  ##
  ## Not started at boot. The flake's NixOS module runs it hardened,
  ## with ``DynamicUser`` and an explicit ``--root``; a package that
  ## started it on install would open ``0.0.0.0:7878`` on a machine
  ## whose administrator had not yet chosen a root, a key or a network
  ## boundary. Installing the software and deciding to serve from it are
  ## two decisions and the package makes only the first.
  ServiceDef(
    name: "repro-binary-cache",
    displayName: "Reprobuild binary cache server",
    description: "Reprobuild network binary-cache server (HTTP :" &
      $ReprobuildCachePort & ")",
    scope: ssSystem,
    execComponent: "repro-binary-cache" &
      (if targetOs == toWindows: ".exe" else: ""),
    # ``--root=PATH``, not ``--root PATH``. repro-binary-cache's parser
    # takes the concat form ONLY and answers a separated one with
    # ``unexpected positional argument: /var/lib/repro-binary-cache``.
    # Written the wrong way first, and caught by the gate rather than by
    # a unit case -- which is the point: a unit case can only assert
    # that the unit says what this proc says, and both would have been
    # wrong together. A package whose unit fails to start is installed,
    # enabled, and dead.
    execArgs: @["--root=/var/lib/repro-binary-cache",
                "--listen=0.0.0.0:" & $ReprobuildCachePort],
    environment: @[("REPRO_BINARY_CACHE_ROLE", "server")],
    startAtBoot: false,
    restartOnFailure: true,
    after: @["network.target"])

proc newReprobuildDistribution*(version: string; targetOs: TargetOs;
                                prefix = "/usr";
                                release = "1";
                                architecture = "x86_64";
                                stagingRoot = "";
                                outputDir = ""): Distribution =
  ## The ``reprobuild`` package's ``Distribution``, with the §5 contract
  ## filled in and no components yet — the recipe adds those, because
  ## only the recipe has the build edges that produce them.
  ##
  ## Splitting it this way is deliberate: everything here is a fact
  ## about reprobuild's RUNTIME CONTRACT and is the same on every host,
  ## so it belongs in the layer beside the variable-name list it
  ## answers. Which binaries exist, and which edges built them, is a
  ## fact about a particular build and belongs in the recipe.
  result = newDistribution(ReprobuildPackageName, version, targetOs,
    prefix = prefix, release = release, architecture = architecture,
    layout = (if targetOs == toWindows: plWindowsTree else: plUnix),
    stagingRoot = stagingRoot, outputDir = outputDir)
  result.runtime.envDefaults = reprobuildWrapperValues(result)
  result.runtime.privateLibSubdir = ReprobuildPrivateLibSubdir
  # THE POINT OF THE FIELD, finally used for real. ``DT_NEEDED`` cannot
  # see a dlopen, so the walk cannot DISCOVER these two -- and unlike
  # the M0 fixture, whose empty list was an honest statement about two
  # binaries that open nothing, reprobuild genuinely opens both by leaf
  # name: the solver's clingo bindings at module-init time and the
  # binary-cache client's zstd decoder on first use. If either is
  # missing from the private libdir the package installs and then dies
  # with "could not load", which is precisely the failure the checked
  # post-condition converts into a build error.
  result.runtime.dlopenLeafNames = reprobuildDlopenLeafNames(targetOs)
  result.runtime.wrapExecutables = true
  # The per-user build daemon's unit. Declared HERE rather than by the
  # recipe because which services a package wires is part of the same
  # runtime contract as the wrapper variables -- and because `validate`
  # then refuses a recipe that ships the unit without the binary it
  # names, which is the failure mode where the package installs and
  # `systemctl --user start` fails with a path nobody wrote.
  result.services = @[reprobuildUserDaemonService(targetOs)]
  result.metadata = DistMetadata(
    summary: "Reprobuild — a reproducible, content-addressed build system",
    description: "Reprobuild is a build system with content-addressed " &
      "action caching, a hermetic tool-provisioning model and a " &
      "first-class binary-cache server.\n" &
      "This package ships the repro CLI, the engine's helper " &
      "processes and the per-user build daemon.",
    maintainer: "Reprobuild Developers <dev@reprobuild.invalid>",
    vendor: "Metacraft Labs",
    license: "MIT",
    homepage: "https://github.com/metacraft-labs/reprobuild",
    section: "devel",
    priority: "optional",
    # Generated once and pasted, per the MSI producer's refusal to
    # invent one: it is what makes two releases of this product an
    # upgrade rather than two side-by-side installs.
    upgradeCode: "{2B7F4E19-8C63-4A05-9D71-5E0C3A8F4B62}")

proc newReprobuildCacheDistribution*(version: string; targetOs: TargetOs;
                                     prefix = "/usr";
                                     release = "1";
                                     architecture = "x86_64";
                                     stagingRoot = "";
                                     outputDir = ""): Distribution =
  ## The ``reprobuild-binary-cache`` package: the server, its system
  ## unit, and nothing else.
  ##
  ## It repeats the §5 contract rather than sharing the other package's,
  ## and that is not duplication: the two packages install into two
  ## private libdirs and each must be independently runnable, because a
  ## machine may have either without the other. A cache server whose
  ## RPATH pointed into ``reprobuild``'s libdir would work on the
  ## builder and fail on a host that installed only the server.
  result = newDistribution(ReprobuildCachePackageName, version, targetOs,
    prefix = prefix, release = release, architecture = architecture,
    layout = (if targetOs == toWindows: plWindowsTree else: plUnix),
    stagingRoot = stagingRoot, outputDir = outputDir)
  result.runtime.envDefaults = reprobuildWrapperValues(result)
  result.runtime.privateLibSubdir = "lib/repro-binary-cache"
  result.runtime.dlopenLeafNames = reprobuildDlopenLeafNames(targetOs)
  result.runtime.wrapExecutables = true
  result.services = @[reprobuildCacheService(targetOs)]
  result.metadata = DistMetadata(
    summary: "Reprobuild network binary-cache server",
    description: "The reprobuild binary-cache server: an HTTP service " &
      "that publishes and substitutes content-addressed build " &
      "artifacts, with ECDSA-P256 manifest verification.\n" &
      "Reprobuild's differentiator from Nix is that the cache server " &
      "is first class rather than an afterthought.",
    maintainer: "Reprobuild Developers <dev@reprobuild.invalid>",
    vendor: "Metacraft Labs",
    license: "MIT",
    homepage: "https://github.com/metacraft-labs/reprobuild",
    section: "devel",
    priority: "optional",
    upgradeCode: "{4D19A6C7-2F80-4E3B-B5A9-71C6E20D8F35}")
