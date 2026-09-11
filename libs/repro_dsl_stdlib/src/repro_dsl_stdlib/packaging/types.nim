## The one typed install-tree definition every format producer reads.
##
## Distribution-And-Packaging.md §6 — the CPack analog, entirely in user
## space. One ``Distribution`` value names the components, the runtime
## closure, the services and the metadata; the per-format producers only
## translate it. Nothing in this module knows what a ``.deb``, an
## ``.rpm`` or an ``.msi`` is, and nothing in the engine does either.
##
## ## Why a plain object and not a DSL macro
##
## §6's sketch is written as an object literal
## (``package.distribution "reprobuild" { … }``) and the spec says in so
## many words that the literal is *illustrative*, not a DSL macro form.
## Authoring it as an ordinary typed Nim value is not a shortcut, it is
## the point: a producer's "interface" is then just a proc signature
## over a public type (see ``producer.nim``), which is what lets a third
## party add a format **without touching the DSL macros, let alone the
## engine**. A macro form would have had to enumerate the fields the
## built-in producers need, and every new producer with a new field
## would then be a macro change — the closed-enum failure mode §6 rule 3
## exists to prevent.
##
## ## The three axes a package format varies along
##
## Writing this type against deb alone would have produced something
## that fits deb. The M0 gate deliberately pairs deb with **MSI**
## instead of with rpm, because rpm-vs-deb agrees on all three of the
## axes below and MSI disagrees on all three:
##
## 1. **Install model.** deb/rpm unpack a payload archive rooted at
##    ``/``; MSI is a relational database of Components keyed by GUID
##    that the installer *executes*, with its own directory table. So a
##    component's location is modelled as (prefix-relative directory,
##    file name), never as an absolute path — the absolute path only
##    exists once a producer has chosen the prefix, and on Windows the
##    prefix is not even fixed at build time (``ProgramFiles64Folder``).
## 2. **Service registration.** systemd/launchd read a unit FILE shipped
##    in the payload; the Windows Service Control Manager is written to
##    by the installer through the MSI ``ServiceInstall`` table. So
##    ``ServiceDef`` is abstract — the units and the ``ServiceInstall``
##    rows are both *generated from* it, and neither shape leaks into
##    the type.
## 3. **File modes.** deb/rpm carry POSIX mode bits and reject a
##    maintainer script that is not 0755; MSI has no concept of them.
##    So ``mode`` is a "0 means the role default" int and the Windows
##    staging path simply never applies it (see ``runtime_contract.nim``).

import std/[algorithm, strutils, tables]

import repro_project_dsl

import ../prefix_layout

export prefix_layout

type
  TargetOs* = enum
    ## Which OS the *staged install tree* is being shaped for.
    ##
    ## Deliberately a property of the distribution being staged rather
    ## than of the host running the build, exactly as
    ## ``prefix_layout.PrefixLayout`` is a property of the prefix rather
    ## than of the host. A cross-staged tree is then expressible without
    ## the layer consulting ``defined(windows)`` anywhere.
    toLinux
    toDarwin
    toWindows

  ComponentRole* = enum
    ## What a file in the install tree *is*, which is the only thing
    ## the layer needs in order to place it, mode it and decide whether
    ## the §5 wrapper contract applies to it.
    crExecutable
      ## A user-facing entry point. Goes under the prefix's bin dir,
      ## mode 0755, and IS subject to the §5 wrapper / RPATH / env-
      ## default contract.
    crHelperExecutable
      ## An internal helper the package's own binaries spawn — §3's
      ## ``reprobuild-nix-daemon`` and the provider helpers. Goes
      ## under ``libexec/<package>``, mode 0755, RPATH-patched but NOT
      ## wrapped — a wrapper on a helper would double-apply the env
      ## defaults its parent already exported.
      ##
      ## The example used to name ``repro-cache-daemon``, which no
      ## build produces any more: ``apps/repro-cache-daemon`` was
      ## deleted by Action-Cache-Per-Edge-Store along with the shared
      ## control region it owned. Naming a component that does not
      ## exist in the doc comment for the role that ships components is
      ## exactly how the recipe came to package a stale binary under
      ## that name (M1 :residuals: N2).
    crHelperScript
      ## An internal helper that is NOT an ELF image — a shell script,
      ## a Python entry point, anything the loader never sees.
      ##
      ## Same location and mode as ``crHelperExecutable``
      ## (``libexec/<package>``, 0755) and deliberately a separate role
      ## rather than a flag on that one, because the difference is not a
      ## preference: ``stageInstallTree`` runs ``patchelf`` over every
      ## Linux executable component to rewrite its RPATH and its ELF
      ## interpreter, and patchelf on a shell script exits 1 with
      ## ``not an ELF executable: Invalid argument``. Found by packaging
      ## reprobuild itself: the flake installs
      ## ``libexec/reprobuild-nix-daemon`` as a SCRIPT, and the first
      ## build of the reprobuild distribution failed on it in all three
      ## formats at once.
      ##
      ## It is also not merely "skip patchelf". A script has no
      ## DT_NEEDED, so it contributes nothing to the runtime-closure
      ## walk either — and a script that needs a library would have to
      ## say so through ``runtime.dlopenLeafNames``, because nothing can
      ## read it out of the file.
    crRuntimeLibrary
      ## A vendored shared library from the runtime closure (§5). Goes
      ## under the package's PRIVATE libdir and is what the RPATH points
      ## at. Mode 0644 on POSIX; on Windows it goes next to the
      ## executables instead, because that is where the loader looks.
    crConfigFile
      ## Ships under ``etc/``; a native package marks these as
      ## conffiles so a local edit survives upgrade.
    crDataFile
      ## Anything else — docs, licences, completion scripts.
    crSourceTree
      ## A whole DIRECTORY of source the installed package must be able
      ## to compile against — reprobuild's own ``libs/`` and the
      ## sibling package trees the ``*_SRC`` wrapper variables name.
      ##
      ## ## Why a directory role rather than N file components
      ##
      ## Every other role names ONE file, and that is right for them: a
      ## binary, a unit, a config file each have an identity the recipe
      ## states. A source tree does not. What the recipe knows — and
      ## all it knows — is that ``$NIMCRYPTO_SRC`` must be a directory
      ## Nim can put on ``--path:``, and Nim resolves imports across it
      ## by NAME, so the set of files that matter is a property of the
      ## recipe being compiled rather than of this package. Enumerating
      ## the files here would make the recipe restate a directory
      ## listing it does not own, and would put ~2,900 per-file edges in
      ## a graph whose meaning is 13 directories.
      ##
      ## Staged by ``fs.preserveTree`` — an ENGINE BUILTIN, not a tool —
      ## so the role needs no ``uses:`` entry and works identically on
      ## Windows, where the ``sh``/``find``/``install`` trio the POSIX
      ## staging path leans on does not exist. It preserves the source
      ## mode bits, which is what keeps an executable helper script
      ## inside such a tree executable.
      ##
      ## Mode is therefore NOT a property of this role (the tree carries
      ## its own), and neither is the §5 wrapper contract: nothing in a
      ## source tree is an ELF image the loader ever sees, so it is
      ## RPATH-patched no more than a ``crHelperScript`` is, and it
      ## contributes nothing to the runtime-closure walk.

  DistComponent* = object
    ## One file in the install tree.
    role*: ComponentRole
    buildPath*: string
      ## Where the file is in the BUILD tree — the path some upstream
      ## edge produced. Project-relative, exactly as every other DSL
      ## path is.
    installName*: string
      ## The file's name in the INSTALL tree. Empty means "same
      ## basename as ``buildPath``". Distinct from ``buildPath`` because
      ## the §5 wrapper contract renames the real binary out of the way
      ## and puts a wrapper at the public name.
    subdir*: string
      ## Extra directory nesting under the role's default directory.
      ## Empty for the common case.
    mode*: int
      ## POSIX mode bits. ``0`` means "the role's default". Ignored
      ## entirely on ``toWindows`` — see the header note on axis 3.
    producedBy*: seq[BuildActionDef]
      ## The edges that produce ``buildPath``. The staging copy depends
      ## on these, which is how a producer ends up ordered after the
      ## compile that made the binary without the recipe author wiring
      ## it up.

  ServiceScope* = enum
    ssSystem
      ## systemd system unit / launchd daemon / Windows service under
      ## LocalSystem.
    ssUser
      ## systemd --user unit / launchd agent. Has no MSI analogue: the
      ## Windows SCM has no per-user services, so an MSI producer must
      ## either skip these or express them as a Run-key / Task-Scheduler
      ## entry. M0 skips them and says so at the call site rather than
      ## silently dropping them.

  ServiceDef* = object
    ## An abstract service, from which the systemd unit, the launchd
    ## plist, the rc.d script and the MSI ``ServiceInstall`` row are all
    ## GENERATED. §6: "post-install service hooks … are generated from
    ## the abstract ``services`` list, so the systemd/launchd/etc.
    ## wiring is authored once."
    ##
    ## M1 is what actually bakes reprobuild's three daemon roles into
    ## every package. M0's obligation is only that a service-installing
    ## package be *expressible* — that this record carry everything the
    ## four target mechanisms need, so M1 is a producer change and not a
    ## data-model change.
    name*: string
      ## Unit/service name without an extension (``repro-daemon``).
    displayName*: string
      ## Human-facing name. The SCM shows it; systemd puts it in
      ## ``Description=``.
    description*: string
    scope*: ServiceScope
    execComponent*: string
      ## ``installName`` of the ``crExecutable`` this service runs.
      ## Named indirectly, not as a path, because the absolute path
      ## differs per format and per prefix.
    execArgs*: seq[string]
    environment*: seq[(string, string)]
    startAtBoot*: bool
    restartOnFailure*: bool
    after*: seq[string]
      ## Ordering hints (``network.target``, ``RPCSS``). Carried
      ## verbatim; each producer maps or drops them.

  RuntimeContract* = object
    ## §5 — "the hard constraint" — as data.
    ##
    ## The flake wraps every installed binary with ``--set-default`` for
    ## ~18 env vars and sets a DT_RPATH to the runtime library closure;
    ## **every non-Nix package must reproduce this** or the binary does
    ## not run off-Nix. This record is that requirement in a form a
    ## producer cannot get wrong, because no producer reads it: the
    ## staging step in ``runtime_contract.nim`` applies it ONCE and
    ## hands every producer an install tree that already satisfies it.
    envDefaults*: seq[(string, string)]
      ## The ``wrapProgram --set-default NAME VALUE`` pairs. "Default"
      ## is load-bearing: an already-set variable must win, so a
      ## developer's explicit override still works against an installed
      ## package.
    privateLibSubdir*: string
      ## Prefix-relative directory the vendored runtime libraries go
      ## into, e.g. ``lib/reprobuild``. Private (not bare ``lib/``)
      ## so the package cannot collide with, or be shadowed by, the
      ## distro's own copies of blake3/xxhash/sqlite.
    dlopenLeafNames*: seq[string]
      ## Libraries opened by LEAF NAME at run time (§5 calls out zstd
      ## and clingo). These are the reason an RPATH is required rather
      ## than merely nice: a leaf-name ``dlopen`` consults the loader
      ## search path and nothing else, so if the private libdir is not
      ## on it the call fails at run time with the binary otherwise
      ## looking perfectly linked.
      ##
      ## It is a CHECKED POST-CONDITION, not a hint. ``DT_NEEDED`` cannot
      ## see a ``dlopen``, so the closure walk cannot discover these
      ## names; what it CAN do is refuse to finish unless every one of
      ## them resolves into the private libdir. A name that cannot be
      ## resolved fails the build with the name in the message, instead
      ## of shipping a package that loads until the first code path that
      ## opens it. That is what makes an EMPTY list an honest statement
      ## ("this distribution opens nothing by leaf name") rather than an
      ## unexamined default: an empty list has nothing to check, and a
      ## non-empty one is checked.
    vendorRuntimeClosure*: bool
      ## Walk each component's ``DT_NEEDED`` closure at BUILD time and
      ## vendor the non-system part of it into ``privateLibSubdir``.
      ##
      ## §5's first bullet — "vendored runtime libraries bundled into the
      ## package under a private libdir, with RPATH/``@loader_path``/
      ## ``$ORIGIN`` … so ``dlopen``-by-leaf-name resolves" — is not
      ## satisfied by the RPATH alone. An RPATH that points at a
      ## directory the package does not ship is strictly WORSE than no
      ## RPATH at all, because ``--set-rpath`` REPLACES whatever the
      ## linker wrote: the binary loses the paths it was linked against
      ## and gains an empty directory. Off the build host it then dies in
      ## the loader before ``main``, which a shell reports as exit 127
      ## with the *wrapper's* name in the message.
      ##
      ## Default ``true`` from ``newDistribution``. A distribution whose
      ## components link only against the platform C library can turn it
      ## off and save an edge; nothing else should.
    interpreterPath*: string
      ## The ELF interpreter (``PT_INTERP``) the staged executables ask
      ## for. Empty means "derive it from ``architecture``" via
      ## ``defaultInterpreterPath``.
      ##
      ## It has to be rewritten for the same reason the libraries have to
      ## be vendored, and it is the same bug seen one layer lower: a
      ## binary built under Nix names a loader inside the build
      ## toolchain's store path, and on a target with no ``/nix/store``
      ## the kernel cannot map it. The failure is indistinguishable from
      ## a missing binary — ``execve`` returns ``ENOENT`` for a missing
      ## INTERPRETER just as it does for a missing image — which is why
      ## the symptom reads as ``exec: /usr/bin/hello.real: not found``
      ## for a file that is demonstrably there.
      ##
      ## THE TRADEOFF, stated where the field is. Rewriting binds the
      ## package to the TARGET's C library: the loader at that path and
      ## the ``libc.so.6`` beside it are the target's, so the target's
      ## glibc must be at least the build's, and the recipe owes its
      ## package manager a floor (``metadata.debDepends``' ``libc6 (>=
      ## …)``). The alternative — vendoring the loader and the whole
      ## glibc set beside it — is self-contained but strictly worse for a
      ## DISTRO-NATIVE format: ``getaddrinfo`` and ``iconv_open``
      ## ``dlopen`` NSS and gconv modules found through the SYSTEM
      ## glibc's configuration, so a vendored glibc loads the target's
      ## modules built against a different one; and every package would
      ## carry its own C library. Expressing "I need glibc >= X" is
      ## exactly what ``Depends:``/``Requires:`` are for, so the
      ## dependency is expressed rather than evaded.
    extraLibrarySearchDirs*: seq[string]
      ## Additional absolute directories the closure walk may resolve a
      ## library from, on top of the ``DT_RPATH``/``DT_RUNPATH`` of every
      ## object it visits. Needed only for a ``dlopenLeafNames`` entry
      ## that no walked object references, since such a name appears in
      ## no ``DT_NEEDED`` and therefore in no object's search path.
    extraSystemLibraryLeafNames*: seq[string]
      ## Leaf names to ADD to the never-vendor set
      ## (``isSystemLibraryLeafName``). Additive only: there is no way to
      ## remove a name from the built-in set, because every name in it is
      ## a member of the C library's own version-locked group and
      ## vendoring one is a target crash rather than a preference.
    wrapExecutables*: bool
      ## When false the layer patches the RPATH but emits no wrapper —
      ## the right choice for a distribution with no env defaults, and
      ## the reason ``envDefaults`` being empty is not by itself taken
      ## as "no wrapper wanted".
    requireEnvDefaultPayload*: bool
      ## Make "every prefix-relative ``envDefaults`` value names
      ## something this package actually installs" a CHECKED
      ## POST-CONDITION of ``stageInstallTree``, in the same sense
      ## ``dlopenLeafNames`` is one.
      ##
      ## The failure it closes is M1's, measured twice. The first
      ## ``reprobuild`` .deb set twenty variables, every one of them
      ## correct, prefix-relative and free of store paths, and thirteen
      ## of them named directories the payload did not contain: the
      ## package installed, answered ``--version``, ran its daemon, and
      ## could not build anything. The second — ``reprobuild-binary-
      ## cache`` — carried the SAME twenty and shipped fourteen files,
      ## so installed alone it had twenty of twenty dangling.
      ##
      ## What makes this check different from the derivation that
      ## produces the reprobuild package's tree components is that the
      ## two sides are INDEPENDENT. The wrapper side is parsed back out
      ## of the text ``posixWrapperText`` actually emits; the payload
      ## side is the staged file list, which is enumerated from the
      ## build tree ON DISK. A value that gained no payload therefore
      ## fails here even when the same list produced both — which the
      ## derivation-versus-derivation form of this assertion could not
      ## do, and did not do (M1 :residuals:, the totality case that
      ## measured nothing).
      ##
      ## Default FALSE, and that is not a hedge — it is what the field
      ## is for. ``envDefaults`` may legitimately name a directory the
      ## package does not create: M0's ``sampletool`` fixture sets
      ## ``SAMPLETOOL_DATA_DIR`` to a prefix-relative data directory
      ## that whoever deploys it is expected to fill. A distribution
      ## whose variables are all "here is a payload I ship" says so by
      ## turning this on, and then cannot ship one that is not there.
    computeDependencyFloor*: bool
      ## Compute the minimum C-library version the produced package
      ## needs and hand it to each format's native dependency syntax.
      ##
      ## **Why this is not optional in practice, and why it is a field
      ## anyway.** Rewriting ``PT_INTERP`` to the target's canonical
      ## loader path (``interpreterPathFor``) binds the package to the
      ## TARGET's C library. A target whose glibc is older than the
      ## builder's then installs the package cleanly and cannot start
      ## it — measured, not predicted: a tree built against glibc 2.40
      ## installs on Ubuntu 22.04 (glibc 2.35) and dies with
      ## ``libc.so.6: version 'GLIBC_2.38' not found``, required by the
      ## VENDORED ``libtbb``/``libstdc++`` rather than by the payload.
      ## Expressing "I need glibc >= X" is precisely what ``Depends:``
      ## and ``Requires:`` are for, and it is the half of the
      ## interpreter-rewrite decision that makes the other half
      ## honest.
      ##
      ## It is a field rather than an unconditional behaviour for one
      ## reason: the floor is read out of ``.gnu.version_r`` by a
      ## ``readelf`` on the closure edge, so switching it off is how a
      ## distribution that must not take that tool dependency (a
      ## non-glibc target, a cross-staged tree whose objects the
      ## builder's readelf cannot read) says so. Defaults to true via
      ## ``newDistribution``; inert on non-Linux targets and on a
      ## distribution with ``vendorRuntimeClosure = false``, since both
      ## mean there is no closure edge to compute it on.

  DistMetadata* = object
    summary*: string
      ## One line. deb ``Description``'s first line, rpm ``Summary``,
      ## MSI ``Package/@Comments``.
    description*: string
      ## Long form, free text with newlines.
    maintainer*: string
      ## ``Name <email>``.
    vendor*: string
    license*: string
      ## SPDX identifier.
    homepage*: string
    section*: string
      ## deb ``Section`` / rpm ``Group``.
    priority*: string
      ## deb ``Priority``.
    debDepends*: seq[string]
    rpmRequires*: seq[string]
      ## Native package-manager dependency expressions, VERBATIM per
      ## format. Deliberately not abstracted into one list:
      ## ``libc6 (>= 2.34)`` and ``glibc >= 2.34`` are different
      ## vocabularies over different package universes, and a layer that
      ## pretended otherwise would be inventing a cross-distro
      ## dependency ontology — a much larger problem than packaging, and
      ## not one M0 is solving. Two named fields say that honestly; one
      ## abstract field would have hidden it.
    archDepends*: seq[string]
      ## The same fact in pacman's vocabulary: ``glibc>=2.38``, no
      ## spaces, no parentheses. A third named field rather than a third
      ## reader of one abstract list, for the reason the two above give.
    debControlExtraFields*: seq[(string, string)]
      ## Extra ``DEBIAN/control`` fields, VERBATIM, appended after the
      ## producer's own. For the fields the layer has no opinion about
      ## — ``Conflicts``, ``Replaces``, ``Provides``, ``Recommends`` — a
      ## producer that grew a named field per Debian policy stanza would
      ## be a closed enum of exactly the kind §6 rule 3 forbids, and the
      ## list of stanzas Debian policy defines is long and still
      ## growing. Same reasoning as ``debDepends``/``rpmRequires``:
      ## VERBATIM per format, not abstracted across them.
    upgradeCode*: string
      ## MSI only: the stable GUID that makes two versions of the
      ## package a single upgradeable product. It MUST be constant
      ## across versions and unique per product; generating one per
      ## build would make every release install alongside the last
      ## instead of upgrading it. There is no cross-format analogue —
      ## deb and rpm identify a product by its name — which is why it
      ## sits here as a named field rather than being conjured by the
      ## MSI producer.

  Distribution* = object
    ## The single definition §6 promises: "one source of truth for
    ## package metadata, components, service wiring, and the runtime
    ## contract; per-format producers only translate."
    name*: string
    version*: string
    release*: string
      ## Packaging revision within a version (deb's ``-1``, rpm's
      ## ``Release``). Defaults to ``"1"`` via ``newDistribution``.
    architecture*: string
      ## In the DECLARING vocabulary, i.e. reprobuild's own
      ## (``x86_64`` / ``aarch64``); each producer maps it to its
      ## format's spelling (deb says ``amd64``, MSI says ``x64``).
      ## Mapping in the producer rather than storing three spellings
      ## keeps the single-source-of-truth property honest.
    targetOs*: TargetOs
    prefix*: string
      ## Install prefix, POSIX-shaped and WITHOUT a trailing slash
      ## (``/usr``, ``/opt/reprobuild``). On ``toWindows`` it is
      ## relative to the chosen program-files directory and the MSI
      ## producer turns it into directory-table rows.
    layout*: PrefixLayout
      ## Where bin/lib/include sit inside the prefix. Reuses
      ## ``prefix_layout.nim`` rather than re-deriving the same
      ## conventions — that module exists precisely so this fact is
      ## named once.
    components*: seq[DistComponent]
    runtime*: RuntimeContract
    services*: seq[ServiceDef]
    metadata*: DistMetadata
    stagingRoot*: string
      ## Build-tree directory the install tree is staged into. Every
      ## staged file is an output of an ordinary build edge under this
      ## root, which is what makes the producers content-addressed.
    outputDir*: string
      ## Build-tree directory the finished artifacts land in.
    sourceDateEpoch*: int64
      ## The one timestamp every producer stamps into its archive.
      ##
      ## **Why this is graph data and not an environment variable.** A
      ## producer is a content-addressed build edge, so its output must
      ## be a function of the graph and of nothing else. ``tar`` was
      ## always fine here — the tarball producer passes its own
      ## ``--mtime`` — but ``dpkg-deb`` reads ``SOURCE_DATE_EPOCH`` out
      ## of the ENVIRONMENT, and the deb producer used to pass nothing,
      ## so the archive inherited whatever the calling shell had.
      ## Inside ``nix develop`` that is 315532800 and three passes of
      ## the milestone never saw the problem; unset, the archive takes
      ## wall-clock mtimes and differs run to run. That is the same
      ## failure in kind as letting the builder's installed packages
      ## decide a package's CONTENTS, which the system/private rule
      ## exists to forbid — the bytes were reproducible because of the
      ## SHELL rather than because of the graph.
      ##
      ## Naming it here rather than in each producer is what makes the
      ## property uniform: every format's timestamps come from this one
      ## number, and a recipe that wants a different one changes it
      ## once. ``DefaultSourceDateEpoch`` explains the value.

const
  DefaultPrivateLibSubdir* = "lib"

  DefaultSourceDateEpoch* = 315532800'i64
    ## 1980-01-01T00:00:00Z, the ``SOURCE_DATE_EPOCH`` the
    ## reproducible-builds ecosystem converged on and the value
    ## ``nix develop`` exports in this repository.
    ##
    ## It is NOT zero, and that is the whole reason a default has to be
    ## chosen deliberately rather than picked for tidiness.
    ## ``dpkg-deb`` does not SET member mtimes from
    ## ``SOURCE_DATE_EPOCH``, it CLAMPS them to it (``tar
    ## --clamp-mtime --mtime=@N``): a file older than the epoch keeps
    ## its own timestamp. At epoch 0 nothing is older, so every staged
    ## file would keep the wall-clock mtime the build gave it and the
    ## archive would still differ run to run — a fix that reproduces
    ## the bug. Any epoch later than the build tree's files works; 1980
    ## is the conventional one, and it is also the value the M0
    ## measurements were taken at, so the recorded artifact hashes
    ## remain the hashes this default produces.
    ##
    ## 1980 rather than 1970 for a second, independent reason: the ZIP
    ## format (and therefore MSI cabinets and every archive that
    ## borrows its date encoding) cannot represent a year before 1980
    ## at all.

  GlibcFloorToken* = "@GLIBC_FLOOR@"
    ## Placeholder a producer writes into a dependency field for the
    ## C-library floor that only an ACTION can know.
    ##
    ## The floor is the maximum ``GLIBC_x.y`` version reference across
    ## the payload and the vendored closure, and both of those are
    ## files no edge has produced at the moment the graph is built — the
    ## same reason the closure walk is a script rather than Nim code.
    ## So the control stanza is authored at graph time with this token
    ## in it and the value is spliced in by the edge that computed it
    ## (``StagedTree.glibcFloorPath``). Deliberately the same shape as
    ## ``PrefixToken``, and deliberately a DIFFERENT token: ``@PREFIX@``
    ## is expanded by the shipped wrapper at RUN time and must survive
    ## into the package, this one must not survive past the build.

  InstalledSizeToken* = "@INSTALLED_SIZE@"
    ## Placeholder for the installed size, in bytes, of a staged tree.
    ##
    ## ``GlibcFloorToken``'s shape and its reason. ``.PKGINFO``'s
    ## ``size`` field is what ``pacman -Si`` reports and what pacman
    ## checks free space against before it unpacks, and it is a
    ## measurement of files that no edge has produced when the
    ## ``.PKGINFO`` text is authored -- the vendored runtime closure in
    ## particular is DISCOVERED at build time. So the text carries this
    ## token and the edge that walked the finished tree splices the
    ## number in. Like the floor and the Scoop digest, it must not
    ## survive into the artifact: a ``size`` field holding a literal
    ## ``@INSTALLED_SIZE@`` is not a number, and pacman's parser would
    ## read it as zero rather than refuse it -- which is the quiet
    ## failure, so the producer asserts the substitution instead of
    ## trusting it.

  ScoopHashToken* = "@SCOOP_SHA256@"
    ## Placeholder for the SHA-256 of the archive a Scoop manifest
    ## points at.
    ##
    ## Exactly ``GlibcFloorToken``'s shape and for exactly its reason:
    ## the value is a digest of a file no edge has produced when the
    ## manifest text is authored, so the text carries a token and the
    ## action that measured the archive splices the value in
    ## (``runtime_contract.substitutionScript``). Like the floor and
    ## unlike ``PrefixToken``, it must NOT survive into the artifact --
    ## a manifest still carrying it would make Scoop reject every
    ## download with a hash mismatch, which is the loud failure rather
    ## than the quiet one.

  ScoopUrlToken* = "@SCOOP_URL@"
    ## Placeholder for the URL a Scoop manifest downloads from, used
    ## when the recipe supplies none.
    ##
    ## Where an artifact will be PUBLISHED is a hosting fact (M3), not a
    ## build fact, and this layer has no way to know it. The honest
    ## options were to refuse a manifest without a URL, to invent a
    ## plausible one, or to emit a token. Inventing one is the dangerous
    ## answer -- a manifest with a well-formed but wrong URL installs
    ## whatever is at that address on the day someone points a bucket at
    ## it -- and refusing would make the producer unusable before M3
    ## lands. A token is visibly not a URL, so a release pipeline
    ## substitutes it and a manifest that reached a user unsubstituted
    ## fails at DOWNLOAD, before any bytes are trusted.

proc extractFilenameSlashOnly*(path: string): string =
  ## Basename over ``/`` AND ``\``.
  ##
  ## Not ``os.extractFilename``: that one is host-conditional (on a
  ## POSIX host it does not treat ``\`` as a separator), and the paths
  ## here describe a *target* tree that may well be Windows-shaped while
  ## the build runs on Linux. A host-conditional basename would make the
  ## staged tree depend on which machine staged it, which is exactly the
  ## property a content-addressed producer must not have.
  var cut = -1
  for i in countdown(path.high, 0):
    if path[i] == '/' or path[i] == '\\':
      cut = i
      break
  if cut < 0: path else: path[cut + 1 .. path.high]

proc newDistribution*(name, version: string;
                      targetOs: TargetOs;
                      prefix = "/usr";
                      release = "1";
                      architecture = "x86_64";
                      layout = plUnix;
                      stagingRoot = "";
                      outputDir = ""): Distribution =
  ## Construct a distribution with the defaults that are right for the
  ## overwhelming majority of packages, so a recipe states only what is
  ## actually specific to it.
  ##
  ## ``stagingRoot`` defaults to ``build/dist/<name>-<version>`` — under
  ## ``build/`` because that is the repo-wide convention for generated
  ## trees, and versioned so two versions staged in one build tree
  ## cannot overwrite each other's files and silently produce two
  ## packages from one tree.
  let root =
    if stagingRoot.len > 0: stagingRoot
    else: "build/dist/" & name & "-" & version
  let outs =
    if outputDir.len > 0: outputDir
    else: "build/dist"
  Distribution(
    name: name,
    version: version,
    release: release,
    architecture: architecture,
    targetOs: targetOs,
    prefix: prefix.strip(leading = false, trailing = true, chars = {'/'}),
    layout: layout,
    stagingRoot: root,
    outputDir: outs,
    sourceDateEpoch: DefaultSourceDateEpoch,
    runtime: RuntimeContract(
      privateLibSubdir: DefaultPrivateLibSubdir,
      vendorRuntimeClosure: true,
      computeDependencyFloor: true,
      wrapExecutables: false))

proc defaultInstallName*(component: DistComponent): string =
  ## The component's name in the install tree.
  if component.installName.len > 0:
    component.installName
  else:
    extractFilenameSlashOnly(component.buildPath)

proc roleDefaultMode*(role: ComponentRole): int =
  ## POSIX mode for a role. Consulted only on POSIX targets.
  case role
  of crExecutable, crHelperExecutable, crHelperScript: 0o755
  of crRuntimeLibrary, crConfigFile, crDataFile: 0o644
  # ``crSourceTree``'s mode is never consulted: that role is staged by
  # ``preserveTree``, which mirrors each file's own mode bits. The
  # branch exists because the case is exhaustive, and answers 0644
  # rather than 0755 because that is what the overwhelming majority of
  # the files in such a tree are.
  of crSourceTree: 0o644

proc roleDefaultSubdir*(dist: Distribution; role: ComponentRole): string =
  ## Prefix-relative directory for a role, under ``dist.layout``.
  case role
  of crExecutable:
    binDir(dist.layout)
  of crHelperExecutable, crHelperScript:
    if dist.targetOs == toWindows: binDir(dist.layout)
    else: "libexec/" & dist.name
  of crRuntimeLibrary:
    # On Windows the loadable image must sit next to the executables
    # that open it — ``prefix_layout``'s ``runtimeLibDir`` already
    # encodes exactly that rule, so a private subdir would be wrong
    # rather than merely unusual. On POSIX the RPATH makes a private
    # directory work, and a private directory is what keeps the
    # vendored copies from colliding with the distro's.
    if dist.targetOs == toWindows: runtimeLibDir(dist.layout)
    elif dist.runtime.privateLibSubdir.len > 0:
      dist.runtime.privateLibSubdir
    else: runtimeLibDir(dist.layout)
  of crConfigFile: "etc"
  of crDataFile: "share/" & dist.name
  # ``crSourceTree`` has NO default at all: the component's ``subdir``
  # carries the whole prefix-relative directory. It is the one role
  # whose location is not derivable from the role, because a source
  # tree's install path is DICTATED by the wrapper variable that names
  # it — ``$NIMCRYPTO_SRC`` is ``<prefix>/share/repro/src/nimcrypto``
  # and ``$BLAKE3_PREFIX``'s headers are ``<prefix>/lib/repro/include``,
  # which are not even under the same top-level directory, so a default
  # would have to be overridden every time it was used.
  #
  # It also could not be ``share/<dist.name>`` the way ``crDataFile``
  # is: those values are the SAME for the ``reprobuild`` and
  # ``reprobuild-binary-cache`` packages, because one installed source
  # tree serves both, and a default keyed on the package name would
  # give two answers to a question that has one.
  of crSourceTree: ""

proc installRelPath*(dist: Distribution; component: DistComponent): string =
  ## Where the component lands, RELATIVE TO THE PREFIX, with ``/``
  ## separators. Every producer derives its own paths from this one
  ## function, so "where does this file go" has exactly one answer
  ## across all formats.
  var parts: seq[string] = @[]
  let base = roleDefaultSubdir(dist, component.role)
  if base.len > 0 and base != ".":
    parts.add(base)
  if component.subdir.len > 0:
    parts.add(component.subdir.strip(chars = {'/'}))
  parts.add(defaultInstallName(component))
  parts.join("/")

proc escapesPrefix*(dist: Distribution; role: ComponentRole): bool =
  ## Whether a role's install location is fixed at the FILESYSTEM ROOT
  ## rather than relative to the package's prefix.
  ##
  ## POSIX configuration lives at ``/etc`` whatever the prefix is. That
  ## is not a convention this layer is choosing — it is the FHS, it is
  ## what dpkg's ``conffiles`` mechanism assumes, and it is what an
  ## administrator will look for. A package installed with
  ## ``prefix = "/usr"`` that shipped its config at ``/usr/etc`` would
  ## install cleanly, and its config would never be found or edited.
  ## Reprobuild's own ``/etc/repro/caches.conf`` (§4) is exactly this
  ## case, so M1 needs the rule to already be right.
  ##
  ## It is the same rule that puts systemd units under
  ## ``/lib/systemd`` regardless of prefix, and it applies for the same
  ## reason: some locations belong to the SYSTEM, not to the package.
  ##
  ## Windows has no such location, so the answer there is always no —
  ## another instance of the two targets needing different mechanisms
  ## for the same intent rather than one mechanism with a flag.
  dist.targetOs != toWindows and role == crConfigFile

proc prefixRelToRoot*(dist: Distribution; prefixRel: string): string =
  ## Prefix-relative path → path relative to the STAGED ROOT (which is
  ## the filesystem root a deb/rpm payload is rooted at). Empty prefix
  ## means the staged root IS the prefix, which is the shape both the
  ## tarball and the MSI producer want.
  let p = dist.prefix.strip(chars = {'/'})
  if p.len == 0: prefixRel else: p & "/" & prefixRel

proc executables*(dist: Distribution): seq[DistComponent] =
  for c in dist.components:
    if c.role == crExecutable: result.add(c)

proc component*(role: ComponentRole; buildPath: string;
                producedBy: openArray[BuildActionDef] = [];
                installName = ""; subdir = ""; mode = 0): DistComponent =
  DistComponent(
    role: role,
    buildPath: buildPath,
    installName: installName,
    subdir: subdir,
    mode: mode,
    producedBy: @producedBy)

proc executableComponent*(buildPath: string;
                          producedBy: openArray[BuildActionDef] = [];
                          installName = ""): DistComponent =
  component(crExecutable, buildPath, producedBy, installName)

proc runtimeLibraryComponent*(buildPath: string;
                              producedBy: openArray[BuildActionDef] = [];
                              installName = ""): DistComponent =
  component(crRuntimeLibrary, buildPath, producedBy, installName)

proc sourceTreeComponent*(buildPath: string;
                          subdir: string;
                          installName = "";
                          producedBy: openArray[BuildActionDef] = []):
    DistComponent =
  ## A ``crSourceTree`` component. ``buildPath`` is a DIRECTORY in the
  ## build tree; ``subdir`` is its prefix-relative PARENT directory and
  ## ``installName`` its name there (defaulting, as everywhere else, to
  ## ``buildPath``'s own basename).
  component(crSourceTree, buildPath, producedBy, installName, subdir)

proc sourceTrees*(dist: Distribution): seq[DistComponent] =
  for c in dist.components:
    if c.role == crSourceTree: result.add(c)

proc debArchitecture*(dist: Distribution): string =
  ## reprobuild's architecture vocabulary → Debian's.
  case dist.architecture
  of "x86_64", "amd64": "amd64"
  of "aarch64", "arm64": "arm64"
  of "i386", "i686": "i386"
  of "riscv64": "riscv64"
  else: dist.architecture

proc rpmArchitecture*(dist: Distribution): string =
  case dist.architecture
  of "amd64": "x86_64"
  of "arm64": "aarch64"
  else: dist.architecture

proc archArchitecture*(dist: Distribution): string =
  ## reprobuild's architecture vocabulary → Arch Linux's.
  ##
  ## Arch's spelling agrees with rpm's for the two that matter here and
  ## disagrees for 32-bit ARM (``armv7h``, with the ``h`` for hard-float
  ## — Arch has no soft-float ARM port and the suffix is part of the
  ## name rather than a variant of it). Spelled out rather than
  ## delegated to ``rpmArchitecture`` so the day a third architecture
  ## disagrees, the disagreement has somewhere to live.
  case dist.architecture
  of "amd64", "x86_64": "x86_64"
  of "arm64", "aarch64": "aarch64"
  of "armv7l", "armv7h": "armv7h"
  of "i386", "i686": "i686"
  else: dist.architecture

proc msiArchitecture*(dist: Distribution): string =
  case dist.architecture
  of "x86_64", "amd64": "x64"
  of "aarch64", "arm64": "arm64"
  of "i386", "i686": "x86"
  else: dist.architecture

proc fullVersion*(dist: Distribution): string =
  ## ``<version>-<release>`` where a release is meaningful.
  if dist.release.len > 0 and dist.release != "0":
    dist.version & "-" & dist.release
  else:
    dist.version

# ---------------------------------------------------------------------------
# The system / private rule.
#
# §5 makes vendoring the runtime library closure a HARD constraint, and
# a closure walk is worthless without a rule for where to stop. The rule
# is a CLOSED, NAMED set, and both halves of that matter:
#
# * A library in the set is part of the C library's own version-locked
#   group and MUST NOT be vendored. glibc is not one library but a set
#   whose members are matched to each other and to the loader
#   (``ld.so`` <-> ``libc.so.6`` <-> ``libpthread``) at build time;
#   dropping one of them next to a target's loader gives
#   ``version `GLIBC_2.xx' not found`` at best and two allocators in one
#   address space at worst. It is also self-defeating: ``getaddrinfo``
#   and ``iconv_open`` ``dlopen`` NSS and gconv modules named by the
#   TARGET's ``/etc/nsswitch.conf`` and gconv cache, which were built
#   against the target's glibc. Every portable-bundle tool that has met
#   this reaches the same conclusion (AppImage's excludelist,
#   linuxdeployqt, auditwheel's manylinux policy).
# * Everything NOT in the set is vendored. That is the direction the
#   M0 defect pointed: ``libblake3.so.0`` and ``libtbb.so.12`` exist on
#   no stock Debian at all, so a package that ships neither is a package
#   that cannot start. Note the rule does NOT ask whether the target
#   happens to have a copy -- ``libxxhash`` and ``libstdc++`` are on a
#   current Debian and are vendored anyway, because "which distributions
#   already carry this" is a moving fact about the world and a package's
#   contents must not depend on it.
#
# CLOSED, and not "whatever the build host also happens to have in
# /usr/lib". A rule that consulted the builder would make the package's
# CONTENTS a function of which distro packages the builder had
# installed, which is precisely the property a content-addressed
# producer must not have.
#
# Note what is deliberately NOT in the set: ``libgcc_s`` and
# ``libstdc++``. They are the GCC runtime, not the platform ABI, and a
# native package has no minimum-distro pin to lean on the way a
# manylinux wheel does. Both are upward-compatible, so vendoring a newer
# copy is safe, and NOT vendoring one is a run-time failure on any
# target whose toolchain is older than the builder's. Vendored is the
# fail-safe direction; system is not.
#
# ``libcrypt`` is absent for the same reason: on a modern distribution
# it comes from libxcrypt, a package in its own right that a minimal
# image need not carry, so it is a private library that happens to have
# a C-library-looking name.
# ---------------------------------------------------------------------------

const
  SystemLibraryStems* = [
    "libc", "libm", "libdl", "librt", "libpthread", "libutil",
    "libnsl", "libresolv", "libanl", "libthread_db", "libmvec",
    "libBrokenLocale", "libSegFault", "libmemusage", "libpcprofile"
  ]
    ## The glibc set, by SONAME stem (the part before ``.so``).

const
  SystemDirectories* = [
    "", "bin", "sbin", "lib", "lib64", "libexec", "etc", "opt", "srv",
    "var", "usr", "usr/bin", "usr/sbin", "usr/lib", "usr/lib64",
    "usr/libexec", "usr/share", "usr/include", "usr/local", "usr/src",
    "var/lib", "var/log", "var/cache", "var/run",
    "lib/systemd", "lib/systemd/system", "lib/systemd/user",
    "usr/lib/systemd", "usr/lib/systemd/system", "usr/lib/systemd/user",
    "usr/share/man", "usr/share/doc", "usr/share/applications",
    "usr/share/licenses", "usr/share/bash-completion",
    "usr/share/bash-completion/completions"
  ]
    ## Root-relative directories a package must never claim OWNERSHIP
    ## of, however many of its files land in them.
    ##
    ## ## Why this exists, and why only rpm needs it
    ##
    ## dpkg tracks the directories it creates and removes each one at
    ## uninstall time when nothing is left in it, so a .deb needs no
    ## directory list at all. rpm removes only what its ``%files`` list
    ## NAMES, so a package that lists its files and not the directories
    ## it made leaves them behind — measured, not predicted: the first
    ## ``rpm -e`` of the reprobuild package left ``/usr/libexec/reprobuild``
    ## standing while the identical ``dpkg -r`` did not.
    ##
    ## ## Why a CLOSED set rather than "whatever the target has"
    ##
    ## The same argument as ``SystemLibraryStems``. A rule that consulted
    ## the BUILDER's filesystem would make the package's contents a
    ## function of which distro packages the builder happened to have,
    ## which a content-addressed producer must not be — and the answer
    ## would be wrong in both directions anyway, since the question is
    ## about the TARGET.
    ##
    ## Owning ``/usr/bin`` is not a cosmetic error: rpm would then apply
    ## this package's mode and ownership to it, and removing the package
    ## would ask rpm to remove a directory every other package on the
    ## system is using.

proc isSystemDirectory*(rootRelDir: string): bool =
  ## Whether ``rootRelDir`` (root-relative, no leading slash) is a
  ## directory the target owns rather than the package.
  for d in SystemDirectories:
    if d == rootRelDir: return true
  false

proc ownedDirectories*(rootRelPaths: openArray[string]): seq[string] =
  ## Every directory a package must own, given the root-relative paths
  ## of the files it ships: each file's ancestor directories, minus the
  ## system ones, deepest-last so a caller can emit them in creation
  ## order and remove them in reverse.
  var seen = initTable[string, bool]()
  for path in rootRelPaths:
    var parts: seq[string] = @[]
    for part in path.split('/'):
      if part.len == 0: continue
      parts.add(part)
    # The last part is the FILE; every prefix of the rest is a directory.
    for i in 0 ..< parts.len - 1:
      let dir = parts[0 .. i].join("/")
      if isSystemDirectory(dir): continue
      if dir in seen: continue
      seen[dir] = true
      result.add(dir)
  result.sort()

proc libraryStem*(leafName: string): string =
  ## ``libxxhash.so.0.8.3`` -> ``libxxhash``; ``ld-linux-x86-64.so.2`` ->
  ## ``ld-linux-x86-64``. Cutting at the FIRST ``.so`` rather than at the
  ## last dot is what makes the version suffix irrelevant, which it must
  ## be: the rule is about which library it is, never about which
  ## soversion the builder happened to link.
  let cut = leafName.find(".so")
  if cut < 0: leafName else: leafName[0 ..< cut]

proc isSystemLibraryLeafName*(leafName: string;
                              extra: openArray[string] = []): bool =
  ## Whether ``leafName`` must be left to the target rather than
  ## vendored. See the header block above for the rule and its
  ## justification.
  for name in extra:
    if name == leafName or name == libraryStem(leafName):
      return true
  let stem = libraryStem(leafName)
  # The loader itself, and the kernel's virtual objects. The loader is
  # named by PT_INTERP rather than by DT_NEEDED, but it also appears as
  # a NEEDED entry on some architectures, so both spellings are covered
  # in one place.
  if stem.startsWith("ld-linux") or stem == "ld" or stem.startsWith("ld64") or
      stem.startsWith("linux-vdso") or stem.startsWith("linux-gate"):
    return true
  # NSS service modules. Never a DT_NEEDED entry -- glibc opens them by
  # name at run time -- but naming them keeps a hand-written
  # ``dlopenLeafNames`` from asking for one.
  if stem.startsWith("libnss_"):
    return true
  for name in SystemLibraryStems:
    if stem == name:
      return true
  false

proc defaultInterpreterPath*(architecture: string): string =
  ## The canonical absolute path of the glibc dynamic loader for an
  ## architecture, in reprobuild's own architecture vocabulary.
  ##
  ## These are the paths the ABI supplements fix and every glibc
  ## distribution therefore provides; they are not a Debian convention.
  ## An unknown architecture answers "" and ``validate`` turns that into
  ## a refusal, because the alternative is shipping a package whose
  ## binaries name the BUILDER's loader.
  case architecture
  of "x86_64", "amd64": "/lib64/ld-linux-x86-64.so.2"
  of "aarch64", "arm64": "/lib/ld-linux-aarch64.so.1"
  of "i386", "i686": "/lib/ld-linux.so.2"
  of "riscv64": "/lib/ld-linux-riscv64-lp64d.so.1"
  of "armv7l", "armhf": "/lib/ld-linux-armhf.so.3"
  of "ppc64le", "powerpc64le": "/lib64/ld64.so.2"
  of "s390x": "/lib/ld64.so.1"
  of "loongarch64": "/lib64/ld-linux-loongarch-lp64d.so.1"
  else: ""

proc interpreterPathFor*(dist: Distribution): string =
  ## The interpreter the staged executables get, recipe override first.
  if dist.runtime.interpreterPath.len > 0: dist.runtime.interpreterPath
  else: defaultInterpreterPath(dist.architecture)

proc privateLibPrefixRelDir*(dist: Distribution): string =
  ## Prefix-relative directory the vendored closure lands in. One name
  ## for it, so the RPATH the payload gets and the directory the walk
  ## fills cannot drift apart -- which is exactly how they drifted
  ## apart in the first place.
  roleDefaultSubdir(dist, crRuntimeLibrary)

proc computesDependencyFloor*(dist: Distribution): bool =
  ## Whether this distribution's staging emits the C-library floor.
  ##
  ## Three conditions, and each is a real one rather than a guard for
  ## tidiness. ELF ``.gnu.version_r`` is what the floor is read from, so
  ## the target must be Linux. The vendored closure is half of what the
  ## floor covers (on the M0 fixture it is the ENTIRE reason the floor
  ## is 2.38 rather than 2.34 — the payload asks for far less than
  ## ``libtbb`` does), so a distribution that vendors nothing has no
  ## closure edge to compute it on. And the recipe has to want it.
  dist.targetOs == toLinux and dist.runtime.vendorRuntimeClosure and
    dist.runtime.computeDependencyFloor

proc validate*(dist: Distribution) =
  ## Reject a distribution no producer could translate, at the point the
  ## recipe made the mistake rather than inside whichever producer was
  ## asked for first — otherwise the same missing ``version`` reads as a
  ## dpkg error in one build and a WiX error in another.
  if dist.name.len == 0:
    raise newException(ValueError, "distribution: name is required")
  if dist.version.len == 0:
    raise newException(ValueError,
      "distribution '" & dist.name & "': version is required")
  if dist.components.len == 0:
    raise newException(ValueError,
      "distribution '" & dist.name & "': at least one component is required")
  if dist.sourceDateEpoch <= 0:
    # Refused rather than silently coerced. Zero is the value a
    # zero-initialised ``Distribution`` literal carries, and it is also
    # the one value that LOOKS like "epoch start, maximally
    # deterministic" and is not: dpkg-deb CLAMPS mtimes to
    # ``SOURCE_DATE_EPOCH`` rather than setting them, so at zero every
    # staged file keeps its wall-clock mtime and the archive stops
    # being reproducible in exactly the way this field exists to
    # prevent. See ``DefaultSourceDateEpoch``.
    raise newException(ValueError,
      "distribution '" & dist.name & "': sourceDateEpoch must be a " &
      "positive Unix time later than the build tree's files (got " &
      $dist.sourceDateEpoch & "); use newDistribution, or set it to " &
      "DefaultSourceDateEpoch")
  var seen = initTable[string, string]()
  for c in dist.components:
    let rel = installRelPath(dist, c)
    if rel in seen:
      raise newException(ValueError,
        "distribution '" & dist.name & "': two components both install to '" &
        rel & "' (" & seen[rel] & " and " & c.buildPath & ")")
    seen[rel] = c.buildPath
  for svc in dist.services:
    var found = false
    for c in dist.components:
      if c.role == crExecutable and defaultInstallName(c) == svc.execComponent:
        found = true
        break
    if not found:
      raise newException(ValueError,
        "distribution '" & dist.name & "': service '" & svc.name &
        "' names execComponent '" & svc.execComponent &
        "' which is not an executable component of this distribution")
  if dist.targetOs == toLinux and dist.runtime.vendorRuntimeClosure and
      interpreterPathFor(dist).len == 0:
    # Refused rather than skipped. Skipping would leave the staged
    # executables naming the BUILDER's ELF interpreter -- a path under
    # the build toolchain's store -- and the package would install
    # cleanly and fail to start with ``not found`` for a file that is
    # there. Better to fail the build and name the field that fixes it.
    raise newException(ValueError,
      "distribution '" & dist.name & "': no known ELF interpreter for " &
      "architecture '" & dist.architecture &
      "'; set runtime.interpreterPath explicitly")
