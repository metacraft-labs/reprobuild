## M1's dogfood: reprobuild's OWN packages, produced through the M0 layer.
##
## M1: "package **reprobuild itself** through the M0 layer, baking the
## three daemon roles' service units and the runtime closure into each
## format, reproducing the §5 contract in every non-Nix package."
##
## The ``Distribution`` values are NOT defined here. They live in
## ``repro_dsl_stdlib/packaging/reprobuild_dist.nim``, because everything
## in them — the twenty wrapper variables' values, the private libdir,
## the dlopen leaf names, the three daemon roles, ``caches.conf`` — is a
## fact about reprobuild's RUNTIME CONTRACT and is the same on every
## host and in every format. What is a fact about a particular build,
## and therefore belongs here, is only which binaries exist and where
## they came from.
##
## ## Where the payload comes from, stated plainly
##
## The components are read from ``prebuilt/bin/``, which the gate script
## fills from an already-built reprobuild. That is a real limitation and
## it is recorded rather than hidden: a full ``repro build`` of
## reprobuild by reprobuild is the Bootstrap-And-Self-Build track's
## business, not this milestone's, and standing this recipe on it would
## make a packaging result depend on a self-hosting result.
##
## What it does NOT weaken is the thing M1 is actually testing. The
## payload arrives as ordinary build-tree files; from there every step —
## the RPATH rewrite, the ELF-interpreter rewrite, the runtime-closure
## walk, the ``dlopen`` post-condition, the wrappers, the dependency
## floor, the units, the archives — is the same code path the sample
## fixture uses, and none of it can tell where its inputs came from.
## The paths are relative, so the graph names no host directory.
##
## ## The one thing this fixture exercises that the sample cannot
##
## ``dlopenLeafNames``. M0's sample declares an empty list and documents
## why that is honest: ``hello.nim`` and ``adder.nim`` open nothing, so
## the walk finds their whole closure by itself, and the ``dlopen`` arm
## of the assertion is covered only by unit cases (M0 :residuals: R2).
## Reprobuild is the real case — ``repro_solver``'s clingo bindings
## ``dlopen`` at module-init time and the binary-cache client's zstd
## decoder does on first use, so neither library appears in any
## ``DT_NEEDED`` and the walk CANNOT discover them. Every build of this
## recipe either resolves both into the private libdir or fails naming
## the one it could not.

import repro_project_dsl
import repro_dsl_stdlib/packaging
import repro_dsl_stdlib/fs as dslfs

const
  ReprobuildVersion = "0.1.3"
  PrebuiltBin = "prebuilt/bin"
    ## Filled by the gate script from an already-built reprobuild. See
    ## the header for why, and for what it does and does not weaken.
  PrebuiltLib = "prebuilt/lib"
    ## The flake's ``installPhase`` copies ``build/lib/*`` into
    ## ``$out/lib``; this is the same two files (plus the three linker
    ## aliases), staged the same way ``prebuilt/bin`` is.
  PrebuiltTreeRoot = "prebuilt/tree"
    ## Parent of the DIRECTORY payloads, laid out under it exactly as
    ## they are laid out under the install prefix -- so
    ## ``prebuilt/tree/share/repro/src/nimcrypto`` becomes
    ## ``<prefix>/share/repro/src/nimcrypto`` and the recipe never has
    ## to translate between two spellings of the same path.

func hostTargetOs(): TargetOs =
  when defined(windows): toWindows
  elif defined(macosx): toDarwin
  else: toLinux

proc reprobuildComponents(targetOs: TargetOs): seq[DistComponent] =
  ## §3's shipped set for the ``reprobuild`` package: the one user CLI,
  ## the engine's helper processes, and nothing else.
  ##
  ## Deliberately NOT everything the build produces. §3 is explicit
  ## about what stays out — ``repro-harvest-*`` (catalog harvesters,
  ## infra), ``repro-peer-cache-*`` (tier-2/admin tools),
  ## ``repro-binary-cache-crosshost`` (a test driver) — and
  ## ``repro-binary-cache`` itself goes in the OTHER package. A
  ## packaging recipe that shipped the whole bin directory would be
  ## making a product decision by omission.
  let sfx = (if targetOs == toWindows: ".exe" else: "")
  result = @[
    # ``meta.mainProgram``: the one CLI that dispatches build, run,
    # shell, cache, store, daemon, home, infra, gc.
    executableComponent(PrebuiltBin & "/repro" & sfx)
  ]
  # The helper processes the ENGINE spawns. They are
  # ``crHelperExecutable`` rather than ``crExecutable``, which puts them
  # under ``libexec/<name>`` instead of on the user's PATH -- correct,
  # because a user never invokes them and a ``bin`` entry called
  # ``repro-standard-provider`` would be an interface nobody promised.
  #
  # ``repro-cache-daemon`` IS NOT HERE, and its absence is a correction
  # rather than an omission. M1's first component list named it as one of
  # §4's three daemon roles; the Action-Cache-Per-Edge-Store track had
  # already DELETED ``apps/repro-cache-daemon`` (and
  # ``repro_shm_index/daemon.nim`` with it) when the shm control region
  # went away, so no build produces such a binary and the flake installs
  # none. It shipped anyway because the fixture's ``prebuilt/bin`` was
  # filled by hand and a stale ``build/bin`` still had one -- exactly the
  # class of mistake the pre-built payload (see the header) makes
  # possible, and the reason this list is now cross-checked against the
  # store output the staging step copies from.
  for helper in ["repro-standard-provider",
                 "repro-cmake-dyndep-fragment",
                 "repro-cmake-trycompile-provider",
                 "repro-install-mirror-publish"]:
    result.add(component(crHelperExecutable, PrebuiltBin & "/" & helper & sfx))
  # ``reprobuild-nix-daemon`` is the ``tool-provisioning=nix`` bridge and
  # the flake installs it as a SHELL SCRIPT, not an ELF image, which is
  # what ``crHelperScript`` is for. Getting this wrong is not subtle:
  # the layer runs patchelf over every Linux executable component, and
  # the first build of this recipe failed in all three formats at once
  # with ``patchelf: not an ELF executable: Invalid argument``.
  #
  # Absent on Windows, and not by omission: ``tool-provisioning=nix`` is
  # a Unix path, so there is no such helper to ship and the wrapper
  # variable that names it points at a file a Windows package would
  # never have.
  if targetOs != toWindows:
    result.add(component(crHelperScript,
      PrebuiltBin & "/reprobuild-nix-daemon"))

proc reprobuildRuntimeLibraryComponents(targetOs: TargetOs):
    seq[DistComponent] =
  ## ``build/lib/*`` -- the payload the flake ships and M1's packages
  ## did not.
  ##
  ## Two of these are reprobuild's own shared libraries and the flake
  ## installs both (``for lib in build/lib/*; do install -m755 "$lib"
  ## "$out/lib/..."``). No ``Distribution`` had a component for either,
  ## so ``dpkg -L reprobuild`` contained neither -- and the FIRST error
  ## any ``repro build`` from an installed package produced was
  ## ``repro internal io monitor: error: cannot find
  ## librepro_monitor_shim.so``, before anything else could go wrong.
  ##
  ## ``crRuntimeLibrary`` rather than ``crHelperExecutable``: they go in
  ## the private libdir, they are RPATH-patched but get NO ELF
  ## interpreter (a shared object has no ``PT_INTERP`` and patchelf
  ## refuses one), and they seed the runtime-closure walk like every
  ## other shipped ELF object -- which is how their own dependencies end
  ## up vendored beside them.
  ##
  ## Shipping them was necessary and NOT sufficient, and that half is
  ## engine code rather than recipe: both consumers looked for these
  ## files only under a reprobuild SOURCE CHECKOUT. See
  ## ``repro_cli_support.resolveMonitorShimLibPath`` arm 4 and
  ## ``repro_interface_artifacts.dslRuntimeLibDirInLibraryPath``.
  let ext =
    if targetOs == toWindows: ".dll"
    elif targetOs == toDarwin: ".dylib"
    else: ".so"
  for stem in ["librepro_monitor_shim", "librepro_project_dsl_runtime"]:
    result.add(runtimeLibraryComponent(PrebuiltLib & "/" & stem & ext))
  if targetOs == toWindows:
    # The linker aliases below exist for ``-l<name>`` on POSIX. The
    # Windows provider compile takes the vendored-C-source path
    # (``-d:reproVendoredHash``) and links no such libraries, so there
    # is nothing to alias.
    return
  for alias in ReprobuildLinkerAliasLibraries:
    result.add(runtimeLibraryComponent(PrebuiltLib & "/" & alias))

proc reprobuildNimToolchainComponents(dist: Distribution):
    seq[DistComponent] =
  ## THE BUNDLED NIM COMPILER, and the single component that is not a
  ## fact about reprobuild's own build.
  ##
  ## `repro build` compiles the recipe before it can read it, and it
  ## shells out to `nim` to do so. That makes a Nim compiler a
  ## BOOTSTRAP dependency, and the three ways a package normally
  ## acquires one are all closed here, measured rather than assumed:
  ##
  ## * a distribution package -- `debian:trixie-slim` and
  ##   `fedora:latest` have NO `nim` package at all, and Debian
  ##   bookworm's is 1.6.10, older than the sources this very package
  ##   ships. Arch's 2.2.12 is the only adequate distribution build
  ##   found. So `Depends: nim` would be a package that will not
  ##   install on the two images M1's gate uses.
  ## * reprobuild's own tool provisioning -- it cannot, because the
  ##   compile that needs the compiler is the one that reads the
  ##   `uses:` block that would declare it.
  ## * the ambient `$PATH` -- which is what the shipped package did,
  ##   and it is why `repro build` from a .deb died before its first
  ##   edge on any machine that was not a developer's.
  ##
  ## A bootstrap dependency with no external supplier is the case for
  ## vendoring. What is vendored is the compiler binary, its standard
  ## library and its config -- 17.2 MB in 348 files, out of the
  ## toolchain's 49.5 MB in 1,242; the
  ## compiler's own sources, its auxiliary programs and its vendored
  ## third-party bundle are not shipped because nothing a `nim c`
  ## invocation does opens them.
  ##
  ## `crHelperExecutable` for the BINARY and not `crSourceTree`, and
  ## that distinction is load-bearing: the nix-built `nim` names a
  ## `/nix/store` ELF interpreter, so a copy that skipped patchelf would
  ## be a 9 MB file that answers `not found` on a Debian box. As a
  ## helper it is interpreter-rewritten, RPATH-patched and seeds the
  ## runtime-closure walk like every other shipped ELF image.
  let nimRoot = reprobuildNimToolchainPrefixRel(dist)
  let sfx = (if dist.targetOs == toWindows: ".exe" else: "")
  result.add(component(crHelperExecutable,
    PrebuiltTreeRoot & "/" & nimRoot & "/bin/nim" & sfx,
    subdir = ReprobuildNimToolchainSubdir & "/bin"))


package `reprobuild-packages`:
  config:
    sourceRepository = "https://github.com/metacraft-labs/reprobuild.git"
    sourceRevision = "refs/heads/dev"
    sourceChecksum = "sha256-fixture"

  uses:
    # Every producer's tools, as a UNION across formats and hosts -- the
    # ``uses:`` block is a macro-time literal list and cannot be
    # conditioned on the target, which is M0's :caveats: (1). Pinned
    # against the producers' exported selector constants by
    # t_packaging_producer_tool_dependencies.
    "tar"
    "gzip"
    "dpkg-deb"
    "rpmbuild"
    "find"
    "diff"
    "sed"
    "patchelf"
    "readelf"
    "install-file"
    "sh"
    "wix-candle"
    "wix-light"

  build:
    let targetOs = hostTargetOs()

    # --- the reprobuild package -------------------------------------
    var dist = newReprobuildDistribution(ReprobuildVersion, targetOs,
      prefix = (if targetOs == toWindows: "" else: "/usr"),
      stagingRoot = "build/dist/reprobuild-" & ReprobuildVersion,
      outputDir = "build/dist")
    dist.components = reprobuildComponents(targetOs)
    dist.components.add(reprobuildRuntimeLibraryComponents(targetOs))
    dist.components.add(reprobuildNimToolchainComponents(dist))
    # ...and what that compiler dlopens. Declared beside the components
    # that make it necessary rather than inside
    # ``newReprobuildDistribution``, because the requirement belongs to
    # the DECISION to bundle a toolchain and not to reprobuild's runtime
    # contract: the cache package makes the opposite decision and must
    # not inherit a post-condition it cannot satisfy.
    dist.runtime.dlopenLeafNames =
      dist.runtime.dlopenLeafNames & reprobuildNimDlopenLeafNames(targetOs)
    # Every DIRECTORY the twenty-one wrapper variables name, derived from
    # the values rather than listed here. Add a variable, or change a
    # value, and the component list follows without anyone editing it --
    # which is exactly what did NOT happen when these values first
    # landed and the package shipped thirteen paths to nowhere.
    dist.components.add(reprobuildShippedTreeComponents(dist,
      PrebuiltTreeRoot))
    # THE C TOOLCHAIN IS DECLARED; THE NIM ONE IS VENDORED. The
    # post-installation compile shells out to both, and the two get
    # opposite treatment for one measured reason: every target
    # distribution packages a C compiler and none of the two M1's gate
    # uses packages an adequate Nim (see
    # ``reprobuildNimToolchainComponents``). A ``Depends:`` on a package
    # that exists in no archive is not a dependency, it is a package
    # that will not install -- strictly worse than the gap it would
    # document.
    #
    # ``libc6-dev``/``glibc-devel`` and not just ``gcc``: Nim emits C
    # and links it, so the target needs headers and ``crt1.o``, which
    # the compiler package alone does not pull in on either
    # distribution.
    dist.metadata.debDepends = @["gcc", "libc6-dev"]
    dist.metadata.rpmRequires = @["gcc", "glibc-devel"]
    # The same fact in pacman's vocabulary. Arch's C toolchain is `gcc`
    # and its headers are in `glibc` itself rather than in a separate
    # `-dev` package, so the pair is `gcc` + `glibc` and not a
    # transliteration of the two above -- which is exactly why the layer
    # keeps three named lists instead of one abstract one.
    dist.metadata.archDepends = @["gcc", "glibc"]

    # §4: "reprobuild ships /etc/repro/caches.conf (client trust:
    # per-cache trusted-public-keys, priority)". Generated rather than
    # checked in, so the file the package ships and the text the layer
    # documents cannot drift; ``crConfigFile`` is what puts it at
    # /etc/repro/ rather than under the prefix (``types.escapesPrefix``)
    # and what makes it a dpkg conffile / rpm %config(noreplace).
    let cachesConf = dslfs.writeText("build/gen/caches.conf",
      reprobuildCachesConfText(), actionId = "gen-caches-conf")
    dist.components.add(component(crConfigFile, "build/gen/caches.conf",
      producedBy = @[cachesConf],
      installName = "caches.conf", subdir = "repro"))

    # --- the reprobuild-binary-cache package ------------------------
    #
    # §3's split-package: the network cache SERVER and its system unit
    # ship separately, because the server is the thing that opens a port
    # and a developer laptop should be able to install the CLI without
    # acquiring one.
    var cacheDist = newReprobuildCacheDistribution(ReprobuildVersion,
      targetOs,
      prefix = (if targetOs == toWindows: "" else: "/usr"),
      stagingRoot = "build/dist/reprobuild-binary-cache-" & ReprobuildVersion,
      outputDir = "build/dist")
    cacheDist.components = @[
      executableComponent(PrebuiltBin & "/repro-binary-cache" &
        (if targetOs == toWindows: ".exe" else: ""))
    ]

    let site = packagingSite("reprobuild-packages")
    when defined(windows):
      discard msiPackage(dist, site)
      discard msiPackage(cacheDist, site)
      # SCOOP, over the tarball rather than over the MSI, and that is
      # Scoop's model rather than a convenience: a manifest names an
      # ARCHIVE it unpacks into its own app directory, and an MSI is an
      # installer that writes to the registry and the SCM -- the two
      # ways of installing on Windows, and Scoop wants the first. So the
      # Windows leg produces both, and the manifest describes the
      # ARCHIVE THE USER DOWNLOADS by taking that producer's artifact as
      # a parameter.
      #
      # The URL is left as ``ScoopUrlToken``: where a release is
      # published is M3's business, and a manifest with a plausible but
      # wrong URL installs whatever is at that address.
      discard scoopPackage(dist, tarballPackage(dist, site), site)
    else:
      discard debPackage(dist, site)
      discard rpmPackage(dist, site)
      # ARCH, alongside deb and rpm rather than instead of either. It
      # is the third native Linux format and the first one whose
      # metadata is an ordinary archive MEMBER rather than a control
      # area or a spec file, which is what makes it worth having: a
      # producer that works for it is evidence the staged tree is
      # format-neutral, and not merely dpkg-and-rpm-neutral.
      discard archPackage(dist, site)
      discard tarballPackage(dist, site)
      discard debPackage(cacheDist, site)
      discard rpmPackage(cacheDist, site)
      discard archPackage(cacheDist, site)
