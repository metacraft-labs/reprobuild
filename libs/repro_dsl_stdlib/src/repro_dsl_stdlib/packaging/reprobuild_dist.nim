## Reprobuild's OWN distribution definition — the values behind
## ``runtime_contract.ReprobuildWrapperVariables``, the three daemon
## roles, and ``/etc/repro/caches.conf``.
##
## M0 put the wrapper-variable NAMES in the layer (twenty then,
## twenty-one now) and said in so
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
## splits the twenty-one names into four kinds:
##
## 1. **The library path** — the private libdir the closure walk fills.
## 2. **Library PREFIXES** (``BLAKE3_PREFIX``, ``SQLITE_PREFIX``,
##    ``XXHASH_PREFIX``, ``CLINGO_PREFIX``). In the flake these point at
##    whole nixpkgs outputs with ``lib/`` and ``include/`` inside. All
##    four therefore need a real PREFIX on the target too, not merely a
##    libdir: their consumer
##    (``repro_interface_artifacts.externalHashFlags``) accepts a
##    candidate only when it finds ``<prefix>/include/<header>`` AND
##    ``<prefix>/lib/lib<name>.so`` under it, and then emits
##    ``-I``/``-L``/``-l`` from it. So the package grows a private
##    prefix of its own (``ReprobuildPrivatePrefixSubdir``) with the
##    vendored closure in its ``lib`` and the three headers in its
##    ``include``. The first version of this module pointed all four at
##    the bare package prefix, and all four dangled.
## 3. **SOURCE trees** (``*_SRC``, ``REPROBUILD_SOURCE_ROOT``). These
##    are not a convenience — reprobuild compiles providers and
##    interface artifacts IN THE CALLER'S PROJECT, after installation,
##    so the sources have to be on the target machine. They land under
##    a single ``share/repro/src/<name>`` tree, one directory per
##    sibling input, mirroring what the flake's per-input store paths
##    do; ``REPROBUILD_SOURCE_ROOT`` is a reprobuild checkout rather
##    than one of those, and sits beside them at
##    ``share/repro/source``.
##
##    **THE VALUES AND THE PAYLOAD ARE NOW ONE LIST.** M1 shipped these
##    values with nothing behind them: the wrapper set thirteen
##    variables under ``share/repro/`` and ``dpkg -L reprobuild``
##    contained no ``share/repro`` at all, so an installed package
##    answered ``repro --version``, ran its daemon, served its cache and
##    COULD NOT BUILD ANYTHING — the first edge of every ``repro
##    build``, for any recipe including an empty one, is the
##    interface-extraction edge that compiles the recipe against these
##    sources. The fix is not "remember to add components": it is
##    ``reprobuildShippedTreeDirs``, which DERIVES the directory list
##    from the value list, so a recipe that ships what it returns ships
##    exactly what the wrapper names.
##
##    BOTH HALVES ARE LOAD-BEARING, and that was settled by REMOVAL
##    rather than by reading this resolver — the first attempt to
##    answer it from the resolver got it backwards. On an installed
##    package: move ``share/repro/src`` aside and the build dies with
##    ``cannot open file: repro_test_adapters/test_runner``; move
##    ``share/repro/source`` aside instead and it dies with ``cannot
##    open file: repro_interface_artifacts``.
##
##    The first is identifiable rather than mysterious.
##    ``reproPackagePathFlags`` gates every ``*_SRC`` on a MARKER FILE
##    and falls through to a copy vendored under ``libs/`` when the
##    variable's directory is absent — which is why nimcrypto, bearssl,
##    stew and the serialization family survive their variables being
##    wrong. ``REPRO_TEST_ADAPTERS_SRC`` is the one whose candidate
##    list is a SIBLING CHECKOUT and nothing else
##    (``../reprobuild-test-adapters/src``), so it has nothing to fall
##    through to.
##
##    Which of the remaining eleven is individually required was NOT
##    bisected. They ship because the wrapper names them, which is the
##    standard this module exists to hold the package to.
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
## THE FIRST ROW NO LONGER EXISTS, and a packaging layer is a bad place
## to find that out. §4 wrote it with no unit ON PURPOSE -- it was
## auto-spawned per action-cache root and self-reaped, so a service
## manager starting one would have been starting a second owner of a
## single-writer resource -- and M1's recipe duly shipped it as a plain
## ``crHelperExecutable``. But Action-Cache-Per-Edge-Store had already
## DELETED ``apps/repro-cache-daemon`` along with the shm control region
## it owned, so no build produces the binary and the flake installs
## none: what the .deb contained under that name was a stale artifact a
## hand-filled ``prebuilt/bin`` had picked up. The row is kept here,
## struck through in prose rather than quietly deleted, because §4 still
## says three and the next person to read both should be told which one
## moved rather than left to notice.
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

import std/strutils

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

  ReprobuildPrivatePrefixSubdir* = "lib/repro"
    ## The package's PRIVATE PREFIX, prefix-relative: a complete
    ## ``lib``/``include`` pair of its own.
    ##
    ## NOT ``<prefix>`` itself: a package whose private closure went
    ## straight into ``<prefix>/lib`` would put its own copies of
    ## libstdc++ and libgcc_s on top of the distribution's when the
    ## prefix is ``/usr``.
    ##
    ## It is a PREFIX rather than merely a libdir because of what the
    ## four ``*_PREFIX`` wrapper variables are for. They are consumed by
    ## ``repro_interface_artifacts.externalHashFlags``, which resolves
    ## each by looking for ``<prefix>/include/<header>`` AND
    ## ``<prefix>/lib/lib<name>.so``, then emits ``-I<prefix>/include
    ## -L<prefix>/lib -l<name>`` for the compile reprobuild runs AFTER
    ## installation. Pointing them at the bare package prefix -- which is
    ## what M1 shipped first -- makes all four dangle: ``/usr/include``
    ## has no ``blake3.h`` on any stock image and ``/usr/lib`` has no
    ## ``libblake3.so``, because the closure lives in the PRIVATE libdir
    ## under soname-only names. So the private area needs an
    ## ``include/`` next to its ``lib/``, and that is a prefix.

  ReprobuildPrivateLibSubdir* = ReprobuildPrivatePrefixSubdir & "/lib"
    ## Where the vendored runtime closure lands. The private prefix's
    ## own libdir, so ``$BLAKE3_PREFIX/lib`` and the DT_RPATH the payload
    ## carries are the same directory by construction rather than by two
    ## constants that happen to agree.

  ReprobuildPrivateIncludeSubdir* = ReprobuildPrivatePrefixSubdir & "/include"
    ## The headers the post-installation compile needs (``blake3.h``,
    ## ``xxhash.h``, ``clingo.h`` and their neighbours). Shipped for the
    ## same reason the libraries are: libblake3 is packaged by no stock
    ## Debian and libclingo by none at all, so "the target will have the
    ## -dev package" is not available as an answer.

  ReprobuildLinkerAliasLibraries* = [
    "libblake3.so", "libxxhash.so", "libsqlite3.so"
  ]
    ## Unversioned copies that ship ALONGSIDE the soname-named vendored
    ## originals in the private libdir.
    ##
    ## The runtime-closure walk vendors by SONAME -- ``libblake3.so.0``
    ## -- which is correct and is what the loader asks for. But the
    ## compile reprobuild runs after installation links with
    ## ``-lblake3``, and ``-l<name>`` is defined to look for
    ## ``lib<name>.so`` and ``lib<name>.a`` and nothing else: a directory
    ## holding only ``libblake3.so.0`` answers ``ld: cannot find
    ## -lblake3``. A distribution solves this with a ``-dev`` package's
    ## development symlink; this package has no ``-dev`` package and the
    ## layer has no symlink role, so it ships the unversioned name as an
    ## ordinary ``crRuntimeLibrary`` component. It lands in the SAME
    ## directory as the versioned original, which is what makes a plain
    ## copy correct rather than a trap: its ``$ORIGIN`` RPATH resolves
    ## against the same closure the original's does.
    ##
    ## ``libclingo`` is deliberately absent: it is dlopened rather than
    ## linked, so no ``-lclingo`` is ever emitted, and the walk already
    ## vendors it under the unversioned name its ``dlopen`` uses.

  ReprobuildNimToolchainSubdir* = "nim"
    ## The bundled Nim toolchain, relative to the package's ``libexec``
    ## directory (which is keyed on the package NAME, so the constant
    ## cannot be prefix-relative on its own).
    ##
    ## Laid out as a Nim PREFIX -- ``bin/nim`` beside ``lib/`` and
    ## ``config/`` -- because that is how the compiler finds its own
    ## standard library: it derives a prefix from its argv[0], and a
    ## binary that is not inside a ``bin`` directory makes its own
    ## directory the prefix. Dropping ``nim`` into ``libexec/reprobuild``
    ## directly would send it looking for ``libexec/reprobuild/lib``,
    ## which is the private-libdir's neighbour and not a Nim stdlib.

  ReprobuildNimToolchainTrees* = ["lib", "config"]
    ## The two directories the bundled compiler needs beside its binary.
    ##
    ## Named rather than derived, because they are a fact about NIM's
    ## layout and not about any wrapper variable: ``REPRO_NIM_COMPILER``
    ## points at the binary, and no variable points at these. What
    ## ``reprobuildShippedTreeDirs`` does with them is add them anyway,
    ## for the same reason it adds the private prefix's ``include``: a
    ## value that names a file whose siblings are missing is as dangling
    ## as one that names a directory that is not there.
    ##
    ## ``compiler``, ``tools``, ``dist`` and ``doc`` are DELIBERATELY
    ## ABSENT: they are the compiler's own sources, its auxiliary
    ## programs and its vendored third-party bundle, and they are 13 MB
    ## of the toolchain's 49 that nothing in a ``nim c`` invocation
    ## opens. ``lib`` + ``config`` + the binary is 15 MB.

  ReprobuildSourceSubdir* = "share/repro/src"
    ## The parent of the per-input source trees the ``*_SRC`` variables
    ## point at.

  ReprobuildSourceRootSubdir* = "share/repro/source"
    ## ``$REPROBUILD_SOURCE_ROOT``. Not one of the ``*_SRC`` trees and
    ## not under ``ReprobuildSourceSubdir``: it is a reprobuild checkout
    ## rather than a third-party package, and what
    ## ``repro_cli_support.reprobuildLibraryWorkDir`` requires of it is
    ## exactly one thing -- that ``<root>/libs/repro_project_dsl/src``
    ## exists.

  ReprobuildCachePort* = 7878
    ## §3: the network cache server's default listen port, and the one
    ## M1's gate curls for ``/healthz``.

proc reprobuildWrapperValues*(dist: Distribution): seq[(string, string)] =
  ## The ``ReprobuildWrapperVariables``, with values, in the
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
    ("REPROBUILD_SOURCE_ROOT", p & "/" & ReprobuildSourceRootSubdir),
    # The four library prefixes. One answer for all of them, because the
    # vendored closure is one directory -- see the header.
    ("BLAKE3_PREFIX", p & "/" & ReprobuildPrivatePrefixSubdir),
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
    ("SQLITE_PREFIX", p & "/" & ReprobuildPrivatePrefixSubdir),
    ("XXHASH_PREFIX", p & "/" & ReprobuildPrivatePrefixSubdir),
    ("CLINGO_PREFIX", p & "/" & ReprobuildPrivatePrefixSubdir),
    # The bundled Nim compiler. See the note on this variable in
    # ``runtime_contract.ReprobuildWrapperVariables`` for why a package
    # that could depend on a distribution's Nim would, and why it
    # cannot: neither debian:trixie-slim nor fedora:latest packages one
    # at all.
    ("REPRO_NIM_COMPILER",
     p & "/libexec/" & dist.name & "/" & ReprobuildNimToolchainSubdir &
       "/bin/nim" & (if dist.targetOs == toWindows: ".exe" else: ""))
  ]

proc reprobuildNimToolchainPrefixRel*(dist: Distribution): string =
  ## Prefix-relative root of the bundled Nim toolchain.
  "libexec/" & dist.name & "/" & ReprobuildNimToolchainSubdir

proc reprobuildNimDlopenLeafNames*(targetOs: TargetOs): seq[string] =
  ## What the BUNDLED COMPILER dlopens by leaf name, so the runtime
  ## closure walk vendors it.
  ##
  ## The Nim compiler binds PCRE through ``{.dynlib: "libpcre.so(.3|.1|)".}``
  ## and resolves it at MODULE-INIT time, before ``main``. So a shipped
  ## ``nim`` whose private libdir has no PCRE does not fail on some
  ## regex-using compile -- it fails on ``nim --version``, with
  ## ``could not load: libpcre.so(.3|.1|)``, which is what the first
  ## build-gate run of the bundled toolchain measured.
  ##
  ## It is invisible to the walk for exactly the reason ``zstd`` and
  ## ``clingo`` are: a dlopen leaves no DT_NEEDED entry. What makes this
  ## one resolvable at all is that the nim-fork binary's own RPATH names
  ## nixpkgs' pcre output, so the walk's search path -- which is built
  ## from the SEEDS' RPATHs -- contains it the moment the compiler is a
  ## seed. Declaring the leaf name is the whole of the fix.
  ##
  ## SEPARATE from ``reprobuildDlopenLeafNames`` rather than appended to
  ## it: that list is drift-guarded against the two modules that state
  ## reprobuild's OWN dlopen strings, and PCRE is not reprobuild's
  ## dlopen -- it is a property of a third-party toolchain this package
  ## happens to vendor. A package that stopped bundling the compiler
  ## would stop needing it, and the two lists should move independently.
  ##
  ## ``libpcre.so.1`` is the SONAME nixpkgs' pcre-8.45 provides, and Nim
  ## tries ``.3`` then ``.1`` then bare, so the second candidate is the
  ## one that resolves. Windows is EMPTY and that is not an omission:
  ## no Windows Nim toolchain is staged yet (see the milestone's
  ## residuals), and naming a ``pcre*.dll`` for a compiler this package
  ## does not ship would be a post-condition the walk would fail on.
  case targetOs
  of toLinux: @["libpcre.so.1"]
  of toDarwin: @["libpcre.1.dylib"]
  of toWindows: @[]

proc reprobuildShippedTreeDirs*(dist: Distribution): seq[string] =
  ## Every prefix-relative DIRECTORY the wrapper variables name that the
  ## package therefore has to contain, DERIVED from
  ## ``reprobuildWrapperValues`` rather than restated beside it.
  ##
  ## THE POINT IS THAT THE TWO CANNOT DIVERGE. M1 shipped a package
  ## whose wrapper set thirteen variables to paths under
  ## ``share/repro/`` and whose payload contained no ``share/repro`` at
  ## all -- every value correct, prefix-relative and free of store
  ## paths, and every one of them pointing at nothing. A recipe that
  ## derives its component list from this proc cannot make that mistake
  ## again, and ``t_packaging_reprobuild_dist`` asserts the derivation is
  ## TOTAL: every prefix-relative value is either one of these
  ## directories, or a directory the closure walk fills, or a file some
  ## component installs.
  ##
  ## The three exceptions are all "not a shipped source tree" rather
  ## than "not shipped":
  ##
  ## * the four ``*_PREFIX`` values name the PRIVATE PREFIX, whose
  ##   ``lib`` half is the closure walk's output; only its ``include``
  ##   half is a tree, and it contributes once however many variables
  ##   point at it;
  ## * ``REPROBUILD_RUNTIME_LIBRARY_PATH`` IS that libdir;
  ## * ``REPROBUILD_NIX_DAEMON_BIN`` is a FILE, and a component already.
  let p = PrefixToken
  var dirs: seq[string] = @[]
  for pair in reprobuildWrapperValues(dist):
    let name = pair[0]
    let value = pair[1]
    if not value.startsWith(p & "/"):
      continue
    let rel = value[p.len + 1 .. ^1]
    let noted =
      if name.endsWith("_PREFIX"): ReprobuildPrivateIncludeSubdir
      elif name == "REPROBUILD_NIX_DAEMON_BIN": ""
      elif name == "REPRO_NIM_COMPILER": ""
      elif name == "REPROBUILD_RUNTIME_LIBRARY_PATH": ""
      else: rel
    if noted.len > 0 and noted notin dirs:
      dirs.add(noted)
  # The bundled compiler's own two directories. ``REPRO_NIM_COMPILER``
  # names the BINARY -- a file, and a component of its own -- and no
  # variable names these, but a compiler without its standard library
  # is as dangling as a variable pointing at nothing: ``nim c`` on a
  # toolchain missing ``lib/`` fails on the first ``import``.
  let nimRoot = reprobuildNimToolchainPrefixRel(dist)
  for leaf in ReprobuildNimToolchainTrees:
    let rel = nimRoot & "/" & leaf
    if rel notin dirs:
      dirs.add(rel)
  result = dirs

proc reprobuildShippedTreeComponents*(dist: Distribution;
                                      buildTreeRoot: string):
    seq[DistComponent] =
  ## One ``crSourceTree`` component per directory
  ## ``reprobuildShippedTreeDirs`` names, with the build-tree payload
  ## laid out under ``buildTreeRoot`` at the SAME relative path it takes
  ## under the install prefix.
  ##
  ## In the layer rather than in the recipe for the same reason the
  ## wrapper values are: which directories exist is a fact about
  ## reprobuild's runtime contract and is identical on every host and in
  ## every format. What belongs to a particular build is only where the
  ## bytes came from, and that is the one parameter.
  for rel in reprobuildShippedTreeDirs(dist):
    let cut = rel.rfind('/')
    let parent = (if cut > 0: rel[0 ..< cut] else: "")
    let leaf = (if cut > 0: rel[cut + 1 .. ^1] else: rel)
    result.add(sourceTreeComponent(buildTreeRoot & "/" & rel,
      subdir = parent, installName = leaf))

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
