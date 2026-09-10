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
  # ``repro-cache-daemon`` is one of §4's three daemon ROLES and it is
  # here rather than in ``services``: it is auto-spawned per
  # action-cache root by the engine and self-reaps, so a service manager
  # starting one would be starting a second owner of a single-writer
  # resource.
  for helper in ["repro-cache-daemon", "repro-standard-provider",
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
    else:
      discard debPackage(dist, site)
      discard rpmPackage(dist, site)
      discard tarballPackage(dist, site)
      discard debPackage(cacheDist, site)
      discard rpmPackage(cacheDist, site)
