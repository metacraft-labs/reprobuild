## NDE0-A: apt-jammy native catalog adapter — Tier-1 native package.
##
## Implements the spec at
## ``reprobuild-specs/External-Package-Catalog-Adapters.md``
## §"Distro-Snapshot Adapters: apt, dnf, pacman". This `repro.nim`
## is the package's user-facing declaration; the actual implementation
## lives in the stdlib module
## ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/apt_jammy.nim``
## (precedent: ``apt_index.nim`` is the parser for ``foreign_apt.nim``).
##
## ## Why this layout
##
## The package spec calls for a typed surface:
##
##   apt.install(snapshot, debs, expectedFiles, outputName): Files
##   apt.extract(debPath, sha256, outputName): Files
##   apt.installSystemdUnit(unit, unitName, outputName): Files
##
## The current ``parsePackageDef`` macro at
## ``libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim:1234``
## recognises only ``executable`` / ``library`` / ``uses`` / ``config`` /
## ``outputs`` section heads — the ``files <name>:`` block called out
## in Package-Model.md §"Packaging Artifacts As Build Outputs" is purely
## spec at this point. Until the macro grows it, consumer packages
## import ``repro_dsl_stdlib/packages/apt_jammy`` and invoke
## ``extractAptDeb`` / ``installAptDeb`` / ``installSystemdUnit``
## directly as ordinary Nim procs from inside their own ``build:``
## bodies (precedent: ``recipes/bootstrap/tcc-chain/recipes/tcc/repro.nim``
## calls ``shell(command = ...)`` from its top-level ``build:`` block).
##
## ## Configurables
##
## * ``snapshot`` — the snapshot pin
##   (``"ubuntu/jammy/YYYYMMDDTHHMMSSZ"``). Provenance only: it names no
##   digest, so it is NOT part of any store identity. Store paths are keyed
##   by the bytes — the resolved ``(name, version, sha256)`` set (spec §3)
##   — so bumping the pin produces a fresh store path exactly for the
##   packages whose bytes changed.
## * ``adapterVersion`` — the implementation's revision string. Part of
##   every spec §2/§3 fingerprint so an adapter bugfix invalidates
##   downstream packages atomically.
## * ``cacheDir`` — host-side cache for pre-fetched .debs the
##   ``installAptDeb`` path consults before falling through to a future
##   live-fetch implementation (spec §6).
## * ``defaultMirror`` — informational; the live-fetch path (NOT
##   implemented in v1) will consult it.
##
## ## v1 honest scope statement
##
## v1 of NDE0-A ships the spec §1 / §2 / §5 build-time primitives
## against PRE-FETCHED .deb fixtures. The spec §6 four-link content
## chain (snapshot string → InRelease → Packages index → live .deb
## fetch) is DEFERRED. Consumers supply ``(name, version, debPath,
## sha256)`` triples, and the store path is keyed by those triples alone,
## so a future live-fetch implementation (which resolves the snapshot to
## the same triples) lands without breaking already-cached store paths.

import repro_project_dsl

# The stdlib module that owns the actual extract / install / unit
# normalisation logic. Imported here so it is in scope for downstream
# packages that ``uses: "apt-jammy >=1.0"`` and inline a ``build:``
# block invoking the procs directly.
#
# We re-export under a non-conflicting alias because the ``package``
# macro generates a module-level ``aptJammy`` identifier that would
# clash with the import's natural name. Downstream packages write
# ``import apt_jammy_adapter`` (alias below) or
# ``import repro_dsl_stdlib/packages/apt_jammy`` directly.
import repro_dsl_stdlib/packages/apt_jammy as aptJammyImpl
export aptJammyImpl

package aptJammy:
  ## Catalog adapter for jammy snapshots. Other Tier-1 packages call
  ## the exported procs (``extractAptDeb`` / ``installAptDeb`` /
  ## ``installSystemdUnit``) from their own ``build:`` blocks.

  defaultToolProvisioning "path"

  versions:
    ## Adapter implementation revision. Part of every spec §2/§3
    ## fingerprint (e.g. the full SHA-256 of the length-prefixed fields
    ## "apt.extract", adapterVersion, sha256(deb)) so a bugfix in the
    ## stdlib module invalidates every downstream cached store path
    ## atomically. 0.2.0 made the identities byte-keyed, framed and
    ## untruncated. Keep the version string in sync with
    ## ``AptJammyAdapterVersion`` in the stdlib module
    ## (``libs/repro_dsl_stdlib/.../apt_jammy.nim``). The snapshot pin
    ## that anchors the four-link chain (spec §6) lives below in
    ## ``config.snapshot``; the ``sourceUrl`` here records the upstream
    ## snapshot mirror so a future live-fetch implementation has a pin
    ## resolvable from the version registry alone.
    "0.2.0":
      sourceRevision = "ubuntu/jammy/20260615T000000Z"
      sourceUrl = "https://snapshot.ubuntu.com/ubuntu/20260615T000000Z"
      sourceRepository = "https://snapshot.ubuntu.com/ubuntu"

  config:
    ## The snapshot pin. Format: ``ubuntu/jammy/YYYYMMDDTHHMMSSZ``.
    ## Provenance only: it is not part of any store identity (spec §3,
    ## §6 — the string names no digest), and the four-link chain that
    ## would resolve it is a deferred milestone.
    snapshot: string = "ubuntu/jammy/20260615T000000Z"

    ## Host cache directory for pre-fetched .debs. Consumers that
    ## supply ``debPath`` directly bypass this.
    cacheDir: string = "/var/cache/reproos/apt-jammy"

    ## Default mirror used by the (deferred) live-fetch path. v1 does
    ## not consult it; recorded for forward-compat.
    defaultMirror: string = "http://archive.ubuntu.com/ubuntu"

    ## Adapter implementation revision. Part of every spec §2/§3
    ## fingerprint so a bugfix here invalidates every downstream cached
    ## store path. Keep in sync with ``AptJammyAdapterVersion`` in the
    ## stdlib module.
    adapterVersion: string = "0.2.0"
